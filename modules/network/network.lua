local logger = require("dave_logger:logger")("MEDS")
local config = require("emulator:config")

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local v_network = {}
local dump_stream

local HOSTNAME = "Dave"
local SPECIAL_MAC_ADDRESS = {0x52, 0x55, 0x00, 0x00, 0x00, 0x00}

local ETH_HEADER_LEN = 14
local ETH_PROTOCOL_ARP = 0x0806
local ETH_PROTOCOL_IP4 = 0x0800

local IP_HEADER_LEN = 20
local IP_PROTOCOL_UDP = 17
local IP_DF = 0x4000

local UDP_HEADER_LEN = 8

local ARP_HEADER_LEN = 28
local ARP_REQUEST = 0x01
local ARP_REPLY = 0x02

local cards = {}
local packet_buffer = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
}

local cards_count = 2
local ip_id = 0
local DNS_SERVER_ADDR = 0x00000000

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function get_mac(packet, offset)
    return string.format("%02X:%02X:%02X:%02X:%02X:%02X",
        packet[offset],
        packet[offset + 1],
        packet[offset + 2],
        packet[offset + 3],
        packet[offset + 4],
        packet[offset + 5]
    )
end

local function create_mac_address(byte1, byte2, byte3, byte4, byte5, byte6)
    return string.format("%02X:%02X:%02X:%02X:%02X:%02X",
        byte1,
        byte2,
        byte3,
        byte4,
        byte5,
        byte6
    )
end

local function ip_parse(str)
    local result = 0x00000000
    local shift = 24
    local pos = 1

    for i = 1, #str, 1 do
        if str:sub(i, i) == "." then
            result = bor(result, lshift(tonumber(str:sub(pos, i - 1), 10), shift))
            shift = shift - 8
            pos = i + 1
        elseif i == #str then
            result = bor(result, lshift(tonumber(str:sub(pos, i), 10), shift))
        end
    end

    if shift ~= 0 then
        error("invalid ip address")
    end

    return result
end

local ZERO_MAC_ADDRESS = create_mac_address(0x00, 0x00, 0x00, 0x00, 0x00, 0x00)

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function ip_checksum(packet, offset, length)
    if length == 0 then
        return 0xFFFF
    end

    local checksum = 0x0000

    while length > 0 do
        checksum = checksum + bor(packet[offset + 1], lshift(packet[offset], 8))
        length = length - 2
        offset = offset + 2
    end

    if length > 0 then
        checksum = checksum + 0xFF00
    end

    while rshift(checksum, 16) ~= 0 do
        checksum = band(checksum, 0xFFFF) + rshift(checksum, 16)
    end

    return band(bnot(checksum), 0xFFFF)
end

local function udp_checksum(packet, offset, length, source_address, dest_address)
    local checksum = 0x0000

    checksum = checksum + band(rshift(source_address, 16), 0xFFFF)
    checksum = checksum + band(source_address, 0xFFFF)
    checksum = checksum + band(rshift(dest_address, 16), 0xFFFF)
    checksum = checksum + band(dest_address, 0xFFFF)
    checksum = checksum + 17
    checksum = checksum + length

    while length > 1 do
        checksum = checksum + bor(packet[offset + 1], lshift(packet[offset], 8))
        offset = offset + 2
        length = length - 2
    end

    if length > 0 then
        checksum = checksum + lshift(packet[offset], 8)
    end

    while rshift(checksum, 16) ~= 0 do
        checksum = band(checksum, 0xFFFF) + rshift(checksum, 16)
    end

    return band(bnot(checksum), 0xFFFF)
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- ARP
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local arp_table = {}

local function arp_add(card, ip_address, mac_address)
    local broadcast = bor(bnot(card.mask), card.address)

    if (ip_address == 0) or (ip_address == 0xFFFFFFFF) or (ip_address == broadcast) then
        return -- Do not register broadcast addresses
    end

    arp_table[ip_address] = mac_address

    logger:debug("Network: ARP: Register: %d.%d.%d.%d(%s)", rshift(ip_address, 24), band(rshift(ip_address, 16), 0xFF), band(rshift(ip_address, 8), 0xFF), band(ip_address, 0xFF), mac_address)
end

local function arp_get(card, ip_address)
    local broadcast = bor(bnot(card.mask), card.address)

    if (ip_address == 0) or (ip_address == 0xFFFFFFFF) or (ip_address == broadcast) then
        return create_mac_address(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)
    end

    return arp_table[ip_address]
end

local function arp_process(packet, offset, length)
    if length < ARP_HEADER_LEN then
        return -- Packet too short
    end

    local source_mac = get_mac(packet, offset + 6)

    offset = offset + ETH_HEADER_LEN

    local hlen = packet[offset + 4]
    local plen = packet[offset + 5]
    local oper = bor(lshift(packet[offset + 6], 8), packet[offset + 7])
    local sha = get_mac(packet, offset + 8)
    local spa = bor(bor(bor(lshift(packet[offset + 14], 24), lshift(packet[offset + 15], 16)), lshift(packet[offset + 16], 8)), packet[offset + 17])
    local tha = get_mac(packet, offset + 18)
    local tpa = bor(bor(bor(lshift(packet[offset + 24], 24), lshift(packet[offset + 25], 16)), lshift(packet[offset + 26], 8)), packet[offset + 27])

    logger:debug("Network: ARP: HLEN = %d, PLEN = %d, Operation = %d, SHA = %s, SPA = %04X, THA = %s, TPA = %04X", hlen, plen, oper, sha, spa, tha, tpa)

    local card = cards[source_mac]

    if not card then
        logger:debug("Network: ARP: Failed to process packet: Unknown Network Card: %s", sha)
        return
    end

    if oper == ARP_REPLY then
        arp_add(card, spa, sha)
        return
    end

    if tpa == spa then
        arp_add(card, spa, sha)
        return
    end

    if band(tpa, card.mask) == card.address then
        if (tpa == card.dns) or (tpa == card.host) then
            logger:debug("Network: ARP: Send Reply Packet")

            arp_add(card, spa, sha)

            for i = 1, 42, 1 do
                packet_buffer[i] = 0x00
            end

            offset = offset - ETH_HEADER_LEN

            -- Ethenet:
            packet_buffer[1] = packet[offset + 6] -- Destination MAC Address
            packet_buffer[2] = packet[offset + 7]
            packet_buffer[3] = packet[offset + 8]
            packet_buffer[4] = packet[offset + 9]
            packet_buffer[5] = packet[offset + 10]
            packet_buffer[6] = packet[offset + 11]

            offset = offset + ETH_HEADER_LEN

            packet_buffer[7] = SPECIAL_MAC_ADDRESS[1] -- Source MAC Address
            packet_buffer[8] = SPECIAL_MAC_ADDRESS[2]
            packet_buffer[9] = packet[offset + 24]
            packet_buffer[10] = packet[offset + 25]
            packet_buffer[11] = packet[offset + 26]
            packet_buffer[12] = packet[offset + 27]
            packet_buffer[13] = rshift(ETH_PROTOCOL_ARP, 8) -- EtherType
            packet_buffer[14] = band(ETH_PROTOCOL_ARP, 0xFF)

            -- ARP:
            packet_buffer[15] = 0x00 -- Hardware Type
            packet_buffer[16] = 0x01
            packet_buffer[17] = rshift(ETH_PROTOCOL_IP4, 8) -- Protocol Type
            packet_buffer[18] = band(ETH_PROTOCOL_IP4, 0xFF)
            packet_buffer[19] = 0x06 -- Hardware Length
            packet_buffer[20] = 0x04 -- Protocol Length
            packet_buffer[21] = 0x00 -- Operation
            packet_buffer[22] = ARP_REPLY
            packet_buffer[23] = packet_buffer[7] -- Sender Hardware Address
            packet_buffer[24] = packet_buffer[8]
            packet_buffer[25] = packet_buffer[9]
            packet_buffer[26] = packet_buffer[10]
            packet_buffer[27] = packet_buffer[11]
            packet_buffer[28] = packet_buffer[12]
            packet_buffer[29] = packet[offset + 24] -- Sender Protocol Address
            packet_buffer[30] = packet[offset + 25]
            packet_buffer[31] = packet[offset + 26]
            packet_buffer[32] = packet[offset + 27]
            packet_buffer[33] = packet[offset + 8] -- Target Hardware Address
            packet_buffer[34] = packet[offset + 9]
            packet_buffer[35] = packet[offset + 10]
            packet_buffer[36] = packet[offset + 11]
            packet_buffer[37] = packet[offset + 12]
            packet_buffer[38] = packet[offset + 13]
            packet_buffer[39] = packet[offset + 14] -- Target Protocol Address
            packet_buffer[40] = packet[offset + 15]
            packet_buffer[41] = packet[offset + 16]
            packet_buffer[42] = packet[offset + 17]

            v_network.rx(packet_buffer, 1, 42)
        end
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- DHCP / BOOTP
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local BOOTP_REQUEST = 0x01
local BOOTP_REPLY   = 0x02

local BOOTP_SERVER = 67
local BOOTP_CLIENT = 68

local DHCP_MAGIC = {99, 130, 83, 99}
local DHCP_PAD = 0
local DHCP_NET_MASK = 1
local DHCP_GATEWAY = 3
local DHCP_DNS = 6
local DHCP_HOSTNAME = 12
local DHCP_REQ_ADDR = 50
local DHCP_LEASE_TIME = 51
local DHCP_MSG_TYPE = 53
local DHCP_SRV_ID = 54
local DHCP_MESSAGE = 56
local DHCP_END = 0xFF
local DHCP_OPTIONS_OFFSET = 236

local DHCP_DISCOVER = 0x01
local DHCP_OFFER    = 0x02
local DHCP_REQUEST  = 0x03
local DHCP_PACK     = 0x05
local DHCP_NAK      = 0x06

local BOOTP_HEADER_LEN = 228
local DHCP_OPT_LEN = 312

local LEASE_TIME = 24 * 3600

local BOOTP_CLIENTS = {}

local function request_address(card, address, mac)
    if (address >= card.dhcp) and (address < card.dhcp + 16) then
        local client = BOOTP_CLIENTS[address - card.dhcp]

        if not client or client == mac then
            BOOTP_CLIENTS[address - card.dhcp] = ZERO_MAC_ADDRESS
            return address - card.dhcp
        end
    end

    return nil
end

local function get_new_address(card, mac)
    for i = 0, 15, 1 do
        if not BOOTP_CLIENTS[i] or (BOOTP_CLIENTS[i] == mac) then
            BOOTP_CLIENTS[i] = ZERO_MAC_ADDRESS
            return i, card.dhcp + i
        end
    end

    return nil, nil
end

local function find_address(card, mac)
    for i = 0, 15, 1 do
        if BOOTP_CLIENTS[i] == mac then
            return i, card.dhcp + i
        end
    end

    return nil, nil
end

local function dhcp_decode(packet, start, length)
    local client_addr = bor(bor(bor(lshift(packet[start + 12], 24), lshift(packet[start + 13], 16)), lshift(packet[start + 14], 8)), packet[start + 15])

    start = start + DHCP_OPTIONS_OFFSET

    if (packet[start] ~= DHCP_MAGIC[1]) or
       (packet[start + 1] ~= DHCP_MAGIC[2]) or
       (packet[start + 2] ~= DHCP_MAGIC[3]) or
       (packet[start + 3] ~= DHCP_MAGIC[4]) then
        return
    end

    local tag, len, msg_type, addr
    local max = start + length

    start = start + 4

    while start < max do
        tag = packet[start]

        if tag == DHCP_PAD then
            start = start + 1
        elseif tag == DHCP_END then
            break
        else
            start = start + 1

            if start >= max then
                break
            end

            len = packet[start]
            start = start + 1

            if start + len > max then
                break
            end

            if tag == DHCP_MSG_TYPE then
                if len >= 1 then
                    msg_type = packet[start]
                end
            elseif tag == DHCP_REQ_ADDR then
                if len >= 4 then
                    addr = bor(bor(packet[start], lshift(packet[start + 1], 8)), lshift(bor(packet[start + 2], lshift(packet[start + 3], 8)), 16))
                end
            end

            start = start + len
        end
    end

    if (msg_type == DHCP_REQUEST) and (addr == 0) and (client_addr > 0) then
        addr = client_addr
    else
        addr = 0x00000000
    end

    return addr, msg_type
end

local function bootp_process(card, packet, offset, length)
    offset = offset + UDP_HEADER_LEN

    if packet[offset] ~= BOOTP_REQUEST then
        return
    end

    local addr, msg_type = dhcp_decode(packet, offset, length)

    if msg_type == 0 then
        msg_type = DHCP_REQUEST
    end

    if (msg_type ~= DHCP_DISCOVER) and (msg_type ~= DHCP_REQUEST) then
        return
    end

    local client_mac = get_mac(packet, offset + 28)
    local client_id, d_addr

    if msg_type == DHCP_DISCOVER then
        if addr ~= 0x00000000 then
            client_id = request_address(card, addr, client_mac)

            if client_id then
                d_addr = addr
            end
        end

        if not client_id then
            client_id, d_addr = get_new_address(card, client_mac)

            if not client_id then
                return
            end
        end

        BOOTP_CLIENTS[client_id] = client_mac
    elseif addr ~= 0x00000000 then
        client_id = request_address(card, addr, client_mac)

        if client_id then
            d_addr = addr
            BOOTP_CLIENTS[client_id] = client_mac
        else
            d_addr = 0xFFFFFFFF
        end
    else
        client_id, d_addr = find_address(card, client_mac)

        if not client_id then
            client_id, d_addr = get_new_address(card, client_mac)

            if not client_id then
                return
            end

            BOOTP_CLIENTS[client_id] = client_mac
        end
    end

    if not d_addr then
        return
    end

    arp_add(card, d_addr, client_mac)

    -- Send packet
    offset = offset - ETH_HEADER_LEN - IP_HEADER_LEN - UDP_HEADER_LEN

    for i = 1, #packet_buffer, 1 do
        packet_buffer[i] = 0x00
    end

    local d_mac = arp_get(card, d_addr)

    if not d_mac then
        logger:debug("Network: MAC Address not found. Send ARP packet")
        -- Send ARP packet
        -- Destination MAC Address
        packet_buffer[1] = 0xFF
        packet_buffer[2] = 0xFF
        packet_buffer[3] = 0xFF
        packet_buffer[4] = 0xFF
        packet_buffer[5] = 0xFF
        packet_buffer[6] = 0xFF

        -- Source MAC Address
        packet_buffer[7] = SPECIAL_MAC_ADDRESS[1]
        packet_buffer[8] = SPECIAL_MAC_ADDRESS[2]
        packet_buffer[9] = band(rshift(card.host, 24), 0xFF)
        packet_buffer[10] = band(rshift(card.host, 16), 0xFF)
        packet_buffer[11] = band(rshift(card.host, 8), 0xFF)
        packet_buffer[12] = band(card.host, 0xFF)

        -- EtherType
        packet_buffer[13] = rshift(ETH_PROTOCOL_ARP, 8)
        packet_buffer[14] = band(ETH_PROTOCOL_ARP, 0xFF)

        -- Hardware Type
        packet_buffer[15] = 0x00
        packet_buffer[16] = 0x01

        -- Protocol Type
        packet_buffer[17] = 0x08
        packet_buffer[18] = 0x06

        -- Hardware Length & Protocol Length
        packet_buffer[19] = 6
        packet_buffer[20] = 4

        -- Operation
        packet_buffer[21] = 0
        packet_buffer[22] = ARP_REPLY

        -- Sender Hardware Address
        packet_buffer[23] = packet_buffer[7]
        packet_buffer[24] = packet_buffer[8]
        packet_buffer[25] = packet_buffer[9]
        packet_buffer[26] = packet_buffer[10]
        packet_buffer[27] = packet_buffer[11]
        packet_buffer[28] = packet_buffer[12]

        -- Sender Protocol Address
        packet_buffer[29] = band(rshift(card.host, 24), 0xFF)
        packet_buffer[30] = band(rshift(card.host, 16), 0xFF)
        packet_buffer[31] = band(rshift(card.host, 8), 0xFF)
        packet_buffer[32] = band(card.host, 0xFF)

        -- Target Hardware Address
        packet_buffer[33] = 0x00
        packet_buffer[34] = 0x00
        packet_buffer[35] = 0x00
        packet_buffer[36] = 0x00
        packet_buffer[37] = 0x00
        packet_buffer[38] = 0x00

        -- Target Protocol Address
        packet_buffer[39] = band(rshift(d_addr, 24), 0xFF)
        packet_buffer[40] = band(rshift(d_addr, 16), 0xFF)
        packet_buffer[41] = band(rshift(d_addr, 8), 0xFF)
        packet_buffer[42] = band(d_addr, 0xFF)

        v_network.rx(packet_buffer, 1, 42)
        return
    end

    -- Destination MAC Address
    packet_buffer[1] = 0xFF
    packet_buffer[2] = 0xFF
    packet_buffer[3] = 0xFF
    packet_buffer[4] = 0xFF
    packet_buffer[5] = 0xFF
    packet_buffer[6] = 0xFF

    -- Source MAC Address
    packet_buffer[7] = SPECIAL_MAC_ADDRESS[1]
    packet_buffer[8] = SPECIAL_MAC_ADDRESS[2]
    packet_buffer[9] = band(rshift(card.host, 24), 0xFF)
    packet_buffer[10] = band(rshift(card.host, 16), 0xFF)
    packet_buffer[11] = band(rshift(card.host, 8), 0xFF)
    packet_buffer[12] = band(card.host, 0xFF)

    -- EtherType
    packet_buffer[13] = rshift(ETH_PROTOCOL_IP4, 8)
    packet_buffer[14] = band(ETH_PROTOCOL_IP4, 0xFF)

    -- IPv4:
    packet_buffer[15] = 0x45 -- Version / Internet Header Length
    packet_buffer[16] = 0x10 -- ToS
    packet_buffer[17] = rshift(IP_HEADER_LEN + UDP_HEADER_LEN + BOOTP_HEADER_LEN + DHCP_OPT_LEN, 8) -- Length
    packet_buffer[18] = band(IP_HEADER_LEN + UDP_HEADER_LEN + BOOTP_HEADER_LEN + DHCP_OPT_LEN, 0xFF)
    packet_buffer[19] = rshift(ip_id, 8) -- Id
    packet_buffer[20] = band(ip_id, 0xFF)
    packet_buffer[21] = 0x00 -- Offset
    packet_buffer[22] = 0x00
    packet_buffer[23] = 64 -- TTL
    packet_buffer[24] = IP_PROTOCOL_UDP
    packet_buffer[25] = 0x00 -- Checksum
    packet_buffer[26] = 0x00
    packet_buffer[27] = band(rshift(card.host, 24), 0xFF)
    packet_buffer[28] = band(rshift(card.host, 16), 0xFF)
    packet_buffer[29] = band(rshift(card.host, 8), 0xFF)
    packet_buffer[30] = band(card.host, 0xFF)
    packet_buffer[31] = band(rshift(d_addr, 24), 0xFF)
    packet_buffer[32] = band(rshift(d_addr, 16), 0xFF)
    packet_buffer[33] = band(rshift(d_addr, 8), 0xFF)
    packet_buffer[34] = band(d_addr, 0xFF)

    local checksum = ip_checksum(packet_buffer, 15, 34 - 15)

    packet_buffer[25] = rshift(checksum, 8) -- Checksum
    packet_buffer[26] = band(checksum, 0xFF)

    ip_id = ip_id + 1

    -- UDP:
    packet_buffer[35] = rshift(BOOTP_SERVER, 8) -- Source Port
    packet_buffer[36] = band(BOOTP_SERVER, 0xFF)
    packet_buffer[37] = rshift(BOOTP_CLIENT, 8) -- Destination Port
    packet_buffer[38] = band(BOOTP_CLIENT, 0xFF)
    packet_buffer[39] = rshift(UDP_HEADER_LEN + BOOTP_HEADER_LEN + DHCP_OPT_LEN, 8) -- Length
    packet_buffer[40] = band(UDP_HEADER_LEN + BOOTP_HEADER_LEN + DHCP_OPT_LEN, 0xFF)
    packet_buffer[41] = 0x00 -- Checksum
    packet_buffer[42] = 0x00

    -- BOOTP:
    offset = offset + UDP_HEADER_LEN + IP_HEADER_LEN + 12 + 2

    packet_buffer[43] = BOOTP_REPLY -- Opcode
    packet_buffer[44] = 0x01 -- Htype
    packet_buffer[45] = 0x06 -- Hlen
    packet_buffer[46] = 0x00 -- Hops
    packet_buffer[47] = packet[offset + 4] -- Transaction ID
    packet_buffer[48] = packet[offset + 5]
    packet_buffer[49] = packet[offset + 6]
    packet_buffer[50] = packet[offset + 7]
    packet_buffer[51] = 0x00 -- Secs
    packet_buffer[52] = 0x00
    packet_buffer[53] = 0x00 -- Flags
    packet_buffer[54] = 0x00
    packet_buffer[55] = 0x00 -- CIAddr
    packet_buffer[56] = 0x00
    packet_buffer[57] = 0x00
    packet_buffer[58] = 0x00
    packet_buffer[59] = band(rshift(d_addr, 24), 0xFF) -- YIAddr
    packet_buffer[60] = band(rshift(d_addr, 16), 0xFF)
    packet_buffer[61] = band(rshift(d_addr, 8), 0xFF)
    packet_buffer[62] = band(d_addr, 0xFF)
    packet_buffer[63] = band(rshift(card.host, 24), 0xFF) -- SIAddr
    packet_buffer[64] = band(rshift(card.host, 16), 0xFF)
    packet_buffer[65] = band(rshift(card.host, 8), 0xFF)
    packet_buffer[66] = band(card.host, 0xFF)
    packet_buffer[67] = 0x00 -- GIAddr
    packet_buffer[68] = 0x00
    packet_buffer[69] = 0x00
    packet_buffer[70] = 0x00
    packet_buffer[71] = packet[offset + 28] -- CHAddr
    packet_buffer[72] = packet[offset + 29]
    packet_buffer[73] = packet[offset + 30]
    packet_buffer[74] = packet[offset + 31]
    packet_buffer[75] = packet[offset + 32]
    packet_buffer[76] = packet[offset + 33]
    packet_buffer[77] = packet[offset + 34]
    packet_buffer[78] = packet[offset + 35]
    packet_buffer[79] = packet[offset + 36]
    packet_buffer[80] = packet[offset + 37]
    packet_buffer[81] = packet[offset + 38]
    packet_buffer[82] = packet[offset + 39]
    packet_buffer[83] = packet[offset + 40]
    packet_buffer[84] = packet[offset + 41]
    packet_buffer[85] = packet[offset + 42]
    packet_buffer[86] = packet[offset + 43]

    for i = 87, 278, 1 do -- SName + File
        packet_buffer[i] = 0x00
    end

    offset = 279
    local dhcp_start = offset

    packet_buffer[offset] = DHCP_MAGIC[1]
    packet_buffer[offset + 1] = DHCP_MAGIC[2]
    packet_buffer[offset + 2] = DHCP_MAGIC[3]
    packet_buffer[offset + 3] = DHCP_MAGIC[4]

    offset = offset + 4

    if d_mac then
        packet_buffer[offset] = DHCP_MSG_TYPE
        packet_buffer[offset + 1] = 1

        if msg_type == DHCP_DISCOVER then
            packet_buffer[offset + 2] = DHCP_OFFER
        else
            packet_buffer[offset + 2] = DHCP_PACK
        end

        offset = offset + 3

        packet_buffer[offset] = DHCP_SRV_ID
        packet_buffer[offset + 1] = 4
        packet_buffer[offset + 2] = band(rshift(card.host, 24), 0xFF)
        packet_buffer[offset + 3] = band(rshift(card.host, 16), 0xFF)
        packet_buffer[offset + 4] = band(rshift(card.host, 8), 0xFF)
        packet_buffer[offset + 5] = band(card.host, 0xFF)
        offset = offset + 6

        packet_buffer[offset] = DHCP_NET_MASK
        packet_buffer[offset + 1] = 4
        packet_buffer[offset + 2] = band(rshift(card.mask, 24), 0xFF)
        packet_buffer[offset + 3] = band(rshift(card.mask, 16), 0xFF)
        packet_buffer[offset + 4] = band(rshift(card.mask, 8), 0xFF)
        packet_buffer[offset + 5] = band(card.mask, 0xFF)
        offset = offset + 6

        packet_buffer[offset] = DHCP_GATEWAY
        packet_buffer[offset + 1] = 4
        packet_buffer[offset + 2] = band(rshift(card.host, 24), 0xFF)
        packet_buffer[offset + 3] = band(rshift(card.host, 16), 0xFF)
        packet_buffer[offset + 4] = band(rshift(card.host, 8), 0xFF)
        packet_buffer[offset + 5] = band(card.host, 0xFF)
        offset = offset + 6

        packet_buffer[offset] = DHCP_DNS
        packet_buffer[offset + 1] = 4
        packet_buffer[offset + 2] = band(rshift(card.dns, 24), 0xFF)
        packet_buffer[offset + 3] = band(rshift(card.dns, 16), 0xFF)
        packet_buffer[offset + 4] = band(rshift(card.dns, 8), 0xFF)
        packet_buffer[offset + 5] = band(card.dns, 0xFF)
        offset = offset + 6

        packet_buffer[offset] = DHCP_LEASE_TIME
        packet_buffer[offset + 1] = 4
        packet_buffer[offset + 2] = band(rshift(LEASE_TIME, 24), 0xFF)
        packet_buffer[offset + 3] = band(rshift(LEASE_TIME, 16), 0xFF)
        packet_buffer[offset + 4] = band(rshift(LEASE_TIME, 8), 0xFF)
        packet_buffer[offset + 5] = band(LEASE_TIME, 0xFF)
        offset = offset + 6

        packet_buffer[offset] = DHCP_HOSTNAME
        packet_buffer[offset + 1] = #HOSTNAME

        for i = 1, #HOSTNAME, 1 do
            packet_buffer[offset + 1 + i] = string.byte(HOSTNAME, i, i)
        end

        offset = offset + 2 + #HOSTNAME
    else
        local msg = "requested address not available"

        packet_buffer[offset] = DHCP_MSG_TYPE
        packet_buffer[offset + 1] = 1
        packet_buffer[offset + 2] = DHCP_NAK
        offset = offset + 3

        packet_buffer[offset] = DHCP_MESSAGE
        packet_buffer[offset + 1] = #msg

        for i = 1, #msg, 1 do
            packet_buffer[offset + 2 + i] = string.byte(msg, i, i)
        end

        offset = offset + #msg
    end

    packet_buffer[offset] = DHCP_END

    assert(offset <= BOOTP_HEADER_LEN + DHCP_OPT_LEN)

    for i = offset + 1, dhcp_start + DHCP_OPT_LEN, 1 do
        packet_buffer[i] = 0x00
    end

    checksum = udp_checksum(packet_buffer, 35, UDP_HEADER_LEN + BOOTP_HEADER_LEN + DHCP_OPT_LEN, card.host, d_addr)

    packet_buffer[41] = rshift(checksum, 8)
    packet_buffer[42] = band(checksum, 0xFF)

    v_network.rx(packet_buffer, 1, ETH_HEADER_LEN + IP_HEADER_LEN + UDP_HEADER_LEN + BOOTP_HEADER_LEN + DHCP_OPT_LEN)
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- UDP
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function udp_process(card, packet, offset, length)
    if length > IP_HEADER_LEN then
        length = IP_HEADER_LEN
    end

    local s_addr = bor(bor(bor(lshift(packet[offset + 12], 24), lshift(packet[offset + 13], 16)), lshift(packet[offset + 14], 8)), packet[offset + 15])
    local d_addr = bor(bor(bor(lshift(packet[offset + 16], 24), lshift(packet[offset + 17], 16)), lshift(packet[offset + 18], 8)), packet[offset + 19])
    local old_addr = d_addr

    offset = offset + IP_HEADER_LEN

    local s_port = bor(packet[offset + 1], lshift(packet[offset], 8))
    local d_port = bor(packet[offset + 3], lshift(packet[offset + 2], 8))
    local len = bor(packet[offset + 5], lshift(packet[offset + 4], 8))
    local checksum = bor(packet[offset + 7], lshift(packet[offset + 6], 8))

    logger:debug("Network: UDP: Source Port = %d, Destination Port = %d, Length = %d, Checksum = 0x%04X", s_port, d_port, len, checksum)

    if checksum ~= 0 then
        if udp_checksum(packet, offset, len, s_addr, d_addr) ~= 0 then
            return
        end
    end

    if (d_port == BOOTP_SERVER) and ((d_addr == card.host) or (d_addr == bit.tobit(0xFFFFFFFF))) then -- I ♥ Lua
        bootp_process(card, packet, offset, length)
        return
    end

    if (d_addr == card.dns) and (d_port == 53) then
        d_addr = DNS_SERVER_ADDR
    end

    local socket
    socket = network.udp_connect(string.format("%d.%d.%d.%d", rshift(d_addr, 24), band(rshift(d_addr, 16), 0xFF), band(rshift(d_addr, 8), 0xFF), band(d_addr, 0xFF)), d_port, function(data)
        local data_length = #data

        offset = offset - ETH_HEADER_LEN - IP_HEADER_LEN

        -- Ethenet:
        packet_buffer[1] = packet[offset + 6] -- Destination MAC Address
        packet_buffer[2] = packet[offset + 7]
        packet_buffer[3] = packet[offset + 8]
        packet_buffer[4] = packet[offset + 9]
        packet_buffer[5] = packet[offset + 10]
        packet_buffer[6] = packet[offset + 11]
        packet_buffer[7] = packet[offset] -- Source MAC Address
        packet_buffer[8] = packet[offset + 1]
        packet_buffer[9] = packet[offset + 2]
        packet_buffer[10] = packet[offset + 3]
        packet_buffer[11] = packet[offset + 4]
        packet_buffer[12] = packet[offset + 5]
        packet_buffer[13] = rshift(ETH_PROTOCOL_IP4, 8) -- EtherType
        packet_buffer[14] = band(ETH_PROTOCOL_IP4, 0xFF)

        -- IPv4:
        packet_buffer[15] = 0x45 -- Version / Internet Header Length
        packet_buffer[16] = 0x10 -- ToS
        packet_buffer[17] = rshift(IP_HEADER_LEN + UDP_HEADER_LEN + data_length, 8) -- Length
        packet_buffer[18] = band(IP_HEADER_LEN + UDP_HEADER_LEN + data_length, 0xFF)
        packet_buffer[19] = rshift(ip_id, 8) -- Id
        packet_buffer[20] = band(ip_id, 0xFF)
        packet_buffer[21] = 0x00 -- Offset
        packet_buffer[22] = 0x00
        packet_buffer[23] = 64 -- TTL
        packet_buffer[24] = IP_PROTOCOL_UDP
        packet_buffer[25] = 0x00 -- Checksum
        packet_buffer[26] = 0x00
        packet_buffer[27] = band(rshift(old_addr, 24), 0xFF)
        packet_buffer[28] = band(rshift(old_addr, 16), 0xFF)
        packet_buffer[29] = band(rshift(old_addr, 8), 0xFF)
        packet_buffer[30] = band(old_addr, 0xFF)
        packet_buffer[31] = band(rshift(s_addr, 24), 0xFF)
        packet_buffer[32] = band(rshift(s_addr, 16), 0xFF)
        packet_buffer[33] = band(rshift(s_addr, 8), 0xFF)
        packet_buffer[34] = band(s_addr, 0xFF)

        checksum = ip_checksum(packet_buffer, 15, 34 - 15)

        packet_buffer[25] = rshift(checksum, 8) -- Checksum
        packet_buffer[26] = band(checksum, 0xFF)

        ip_id = ip_id + 1

        -- UDP:
        packet_buffer[35] = rshift(d_port, 8) -- Source Port
        packet_buffer[36] = band(d_port, 0xFF)
        packet_buffer[37] = rshift(s_port, 8) -- Destination Port
        packet_buffer[38] = band(s_port, 0xFF)
        packet_buffer[39] = rshift(UDP_HEADER_LEN + data_length, 8) -- Length
        packet_buffer[40] = band(UDP_HEADER_LEN + data_length, 0xFF)
        packet_buffer[41] = 0x00 -- Checksum
        packet_buffer[42] = 0x00

        for i = 1, data_length, 1 do
            packet_buffer[42 + i] = data[i]
        end

        checksum = udp_checksum(packet_buffer, 35, UDP_HEADER_LEN + data_length, old_addr, s_addr)

        packet_buffer[41] = rshift(checksum, 8)
        packet_buffer[42] = band(checksum, 0xFF)

        v_network.rx(packet_buffer, 1, ETH_HEADER_LEN + IP_HEADER_LEN + UDP_HEADER_LEN + data_length)

        socket:close()
    end)

    for i = 0, len - UDP_HEADER_LEN - 1, 1 do
        packet_buffer[i + 1] = packet[offset + UDP_HEADER_LEN + i]
    end

    socket:send(packet_buffer)
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
--- IP
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function ip_process(packet, offset, length)
    if length < 20 then
        return
    end

    local card = cards[get_mac(packet, offset + 6)]

    if not card then
        return
    end

    offset = offset + ETH_HEADER_LEN

    local version_len = packet[offset]

    if rshift(version_len, 4) ~= 4 then
        return
    end

    local hlen = lshift(band(version_len, 0x0F), 2)

    if (hlen < IP_HEADER_LEN) or (hlen > length) then
        return
    end

    if ip_checksum(packet, offset, hlen) ~= 0 then
        logger:debug("Network: IPv4: Invalid Checksum")
        return
    end

    -- local tos = packet[offset + 1]
    local len = bor(packet[offset + 3], lshift(packet[offset + 2], 8))

    if len < hlen then
        return
    end

    if length < len then
        return
    end

    -- local id = bor(packet[offset + 5], lshift(packet[offset + 4], 8))
    local off = bor(packet[offset + 7], lshift(packet[offset + 6], 8))
    local ttl = packet[offset + 8]
    local protocol = packet[offset + 9]

    if ttl == 0 then
        return -- TODO: Add ICMP
    end

    if band(off, bnot(IP_DF)) ~= 0 then
        logger:warning("Network: IP: Unsupported Fragments")
    end

    if protocol == 17 then
        udp_process(card, packet, offset, hlen)
    else
        logger:error("Network: IP4: Unsupported Protocol: %d", protocol)
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function v_network.tx(packet, offset, length)
    logger:debug("Network: TX: Length = %d, DMAC address = %s, SMAC address = %s", length, get_mac(packet, offset), get_mac(packet, offset + 6))

    if dump_stream then
        dump_stream:dump(packet, offset, length)
    end

    if length < ETH_HEADER_LEN then
        return
    end

    local protocol = bor(packet[offset + 13], lshift(packet[offset + 12], 8))

    if protocol == ETH_PROTOCOL_ARP then -- ARP Packet
        arp_process(packet, offset, length)
    elseif protocol == ETH_PROTOCOL_IP4 then -- IP Packet
        ip_process(packet, offset, length)
    else
        logger:error("Network: Unsupported protocol: 0x%04X", protocol)
    end
end

function v_network.rx(packet, offset, length)
    if dump_stream then
        dump_stream:dump(packet, offset, length)
    end

    if (packet[offset] == 0xFF) and
       (packet[offset + 1] == 0xFF) and
       (packet[offset + 2] == 0xFF) and
       (packet[offset + 3] == 0xFF) and
       (packet[offset + 4] == 0xFF) and
       (packet[offset + 5] == 0xFF) then -- Broadcast

        for _, card in pairs(cards) do
            if card.rx_callback then
                card.rx_callback(card.arg, packet, offset, length)
            end
        end

        return
    end

    local card = cards[get_mac(packet, offset)]

    if card then
        card.rx_callback(card.arg, packet, offset, length)
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function v_network.attach(mac, arg, rx_callback)
    if cards[mac] then
        error("network card arleady attached")
    end

    cards[mac] = {
        address = bor(0x0A000000, lshift(cards_count, 8)),
        host = bor(0x0A000002, lshift(cards_count, 8)),
        dns = bor(0x0A000003, lshift(cards_count, 8)),
        dhcp = bor(0x0A00000F, lshift(cards_count, 8)),
        mask = 0xFFFFFF00,
        arg = arg,
        rx_callback = rx_callback,
    }

    cards_count = cards_count + 1
end

function v_network.initialize()
    local success

    success, DNS_SERVER_ADDR = pcall(ip_parse, config.network.dns)

    if not success then
        logger:error("Network: Config: Invalid DNS IP address")
        DNS_SERVER_ADDR = 0x01010101
    end

    if config.network.dump_packets then
        dump_stream = require("emulator:network/pcap").open("export:dump.pcap")
    end
end

function v_network.close()
    if dump_stream then
        dump_stream:close()
    end
end

return v_network
