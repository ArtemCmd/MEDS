-- =====================================================================================================================================================================
-- DP8390 Network Interface Controller emulation.
-- =====================================================================================================================================================================

local emulator_network = require("emulator:network/network")

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local function empty_function()
    return 0xFF
end

local IMR_PRXE = 0x01
local IMR_PTXE = 0x02
local IMR_PXEE = 0x04
local IMR_TXEE = 0x08
local IMR_OVWE = 0x10
local IMR_CNTE = 0x20
local IMR_RDCE = 0x40

local ISR_PRX = 0x01 -- Packet Received
local ISR_PTX = 0x02 -- Packet Transmited
local ISR_RXE = 0x04 -- Receive error
local ISR_TXE = 0x08 -- Transmit error
local ISR_OVW = 0x10 -- Buffer out of space
local ISR_CNT = 0x20 -- Counters need emptying
local ISR_RDC = 0x40 -- Remote DMA
local ISR_RST = 0x80 -- Reset

local TCR_CRC  = 0x01
local TCR_LB   = 0x06
local TCR_ATD  = 0x08
local TCR_OFST = 0x10

local TSR_PTX = 0x01
local TSR_COL = 0x04
local TSR_ABT = 0x08
local TSR_CRS = 0x10
local TSR_FU  = 0x20
local TSR_CDH = 0x40
local TSR_OWC = 0x80

local CR_STP = 0x01
local CR_START = 0x02
local CR_TXP = 0x04
local CR_RD = 0x05

local RCR_RX_OK = 0x01
local RCR_RUNTS_OK = 0x02
local RCR_BROADCAST = 0x04
local RCR_MULTICAST = 0x08
local RCR_PROMISC = 0x10

local DCR_LAS = 0x04

local dp8390 = {}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Page 0
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local page0_registers_read = {
    [0x01] = function(self) -- CLDA0
        return band(self.local_dma, 0xFF)
    end,
    [0x02] = function(self) -- CLDA1
        return rshift(self.local_dma, 8)
    end,
    [0x03] = function(self) -- BNRY
        return self.bound_position
    end,
    [0x04] = function(self) -- TSR
        return self.tsr
    end,
    [0x05] = function(self) -- NCR
        return self.ncr
    end,
    [0x06] = function(self) -- FIFO
        return self.fifo
    end,
    [0x07] = function(self) -- ISR
        return self.isr
    end,
    [0x08] = function(self) -- CRDA0
        return band(self.remote_dma, 0xFF)
    end,
    [0x09] = function(self) -- CRDA1
        return rshift(self.remote_dma, 8)
    end,
    [0x0A] = empty_function,
    [0x0B] = empty_function,
    [0x0C] = function(self) -- RSR
        return self.rsr
    end,
    [0x0D] = function(self) -- CNTR0
        return 0x00
    end,
    [0x0E] = function(self) -- CNTR1
        return 0x00
    end,
    [0x0F] = function(self) -- CNTR2
        return 0x00
    end
}

local page0_registers_write = {
    [0x01] = function(self, val) -- PSTART
        self.page_start = val
    end,
    [0x02] = function(self, val) -- PSTOP
        self.page_stop = val
    end,
    [0x03] = function(self, val) -- BNRY
        self.bound_position = val
    end,
    [0x04] = function(self, val) -- TPSR
        self.tx_page_start = val
    end,
    [0x05] = function(self, val) -- TBCR0
        self.tx_length = bor(band(self.tx_length, 0xFF00), band(val, 0xFF))
    end,
    [0x06] = function(self, val) -- TBCR1
        self.tx_length = bor(band(self.tx_length, 0x00FF), lshift(band(val, 0xFF), 8))
    end,
    [0x07] = function(self, val) -- ISR
        self.isr = band(self.isr, bnot(band(val, 0x7F))) -- Clear RST bit - status-only bit

        if (val == 0x00) and self.interrupt_handler then
            self.interrupt_handler(self.handler_arg, false)
        end
    end,
    [0x08] = function(self, val) -- RSAR0
        self.remote_start = bor(band(self.remote_start, 0xFF00), band(val, 0xFF))
        self.remote_dma = self.remote_start
    end,
    [0x09] = function(self, val) -- RSAR1
        self.remote_start = bor(band(self.remote_start, 0x00FF), lshift(band(val, 0xFF), 8))
        self.remote_dma = self.remote_start
    end,
    [0x0A] = function(self, val) -- RBCR0
        self.remote_length = bor(band(self.remote_length, 0xFF00), band(val, 0xFF))
    end,
    [0x0B] = function(self, val) -- RBCR1
        self.remote_length = bor(band(self.remote_length, 0x00FF), lshift(band(val, 0xFF), 8))
    end,
    [0x0C] = function(self, val) -- RCR
        self.rcr = val
    end,
    [0x0D] = function(self, val) -- TCR
        self.tcr = val
    end,
    [0x0E] = function(self, val) -- DCR
        self.dcr = val
    end,
    [0x0F] = function(self, val) -- IMR
        self.imr = val

        if self.interrupt_handler then
            self.interrupt_handler(self.handler_arg, band(band(val, self.isr), 0x7F) ~= 0)
        end
    end
}

local function page0_read(self, addr)
    local register = page0_registers_read[addr]

    if register then
        return register(self)
    end

    return 0x00
end

local function page0_write(self, addr, val)
    local register = page0_registers_write[addr]

    if register then
        register(self, val)
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Page 1
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function page1_read(self, addr)
    if (addr >= 0x01) and (addr <= 0x06) then
        return self.phys_addr[addr - 0x01]
    elseif (addr >= 0x08) and (addr <= 0x0F) then
        return self.multicast_hash[addr - 0x08]
    elseif addr == 0x07 then
        return self.current_page
    end

    return 0x00
end

local function page1_write(self, addr, val)
    if (addr >= 0x01) and (addr <= 0x06) then
        self.phys_addr[addr - 0x01] = val
    elseif (addr >= 0x08) and (addr <= 0x0F) then
        self.multicast_hash[addr - 0x08] = val
    elseif addr == 0x07 then
        self.current_page = val
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Page 2
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local page2_registers_read = {
    [0x01] = function(self)
        return self.page_start
    end,
    [0x02] = function(self)
        return self.page_stop
    end,
    [0x03] = function(self)
        return self.remote_packet_position
    end,
    [0x04] = function(self)
        return self.tx_page_start
    end,
    [0x05] = function(self)
        return self.local_packet_position
    end,
    [0x06] = function(self)
        return rshift(self.address_counter, 8)
    end,
    [0x07] = function(self)
        return band(self.address_counter, 0xFF)
    end,
    [0x08] = empty_function,
    [0x09] = empty_function,
    [0x0A] = empty_function,
    [0x0B] = empty_function,
    [0x0C] = function(self) -- RCR
        return self.rcr
    end,
    [0x0D] = function(self) -- TCR
        return self.tcr
    end,
    [0x0E] = function(self) -- DCR
        return self.dcr
    end,
    [0x0F] = function(self) -- IMR
        return self.imr
    end
}

local page2_registers_write = {
    [0x01] = function(self, val) -- CLDA0 
        self.local_dma = bor(band(self.local_dma, 0xFF00), band(val, 0xFF))
    end,
    [0x02] = function(self, val) -- CLDA1
        self.local_dma = bor(band(self.local_dma, 0x00FF), lshift(band(val, 0xFF), 8))
    end,
    [0x03] = function(self, val)
        self.remote_packet_position = val
    end,
    [0x05] = function(self, val)
        self.local_packet_position = val
    end,
    [0x06] = function(self, val)
        self.address_counter = bor(band(self.address_counter, 0x00FF), lshift(band(val, 0xFF), 8))
    end,
    [0x07] = function(self, val)
        self.address_counter = bor(band(self.address_counter, 0xFF00), band(val, 0xFF))
    end
}

local function page2_read(self, addr)
    local register = page2_registers_read[addr]

    if register then
        return register(self)
    end

    return 0x00
end

local function page2_write(self, addr, val)
    local register = page2_registers_write[addr]

    if register then
        register(self, val)
        return
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function memory_read8(self, addr)
    if (addr >= self.memory_start) and (addr < self.memory_end) then
        return self.memory[addr - self.memory_start]
    elseif addr < self.mac_address_size then
        return self.mac_address[band(addr, self.mac_address_size - 1)]
    end

    return 0xFF
end

local function memory_write8(self, addr, val)
    if (addr >= self.memory_start) and (addr < self.memory_end) then
        self.memory[addr - self.memory_start] = val
    elseif addr < self.mac_address_size then
        self.mac_address[band(addr, self.mac_address_size - 1)] = val
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function get_multicast_index(data, start)
    local crc = 0xFFFFFFFF
    local carry, val

    for i = 5, 0, -1 do
        val = data[start + 5 - i]

        for j = 7, 0, -1 do
            carry = bxor(rshift(band(crc, 0x80000000), 31), band(val, 0x01))
            crc = lshift(crc, 1)
            val = rshift(val, 1)

            if carry ~= 0 then
                crc = bor(bxor(crc, 0x04C11DB6), carry)
            end
        end
    end

    return rshift(crc, 26)
end

local function rx_common(self, data, start, length)
    if (band(self.cr, CR_STP) ~= 0) or (self.page_start == 0) then
        return
    end

    local pages = rshift(length + 8 + 255, 8)
    local avail

    if self.current_page < self.bound_position then
        avail = self.bound_position - self.current_page
    else
        avail = (self.page_stop - self.page_start) - (self.current_page - self.bound_position)
    end

    if avail <= pages then
        return
    end

    if (length < 40) and (band(self.rcr, RCR_RUNTS_OK) == 0) then
        return
    end

    if length < 60 then
        length = 60
    end

    if band(self.rcr, RCR_PROMISC) == 0 then
        if  (data[start] == 0xFF) and
            (data[start + 1] == 0xFF) and
            (data[start + 2] == 0xFF) and
            (data[start + 3] == 0xFF) and
            (data[start + 4] == 0xFF) and
            (data[start + 5] == 0xFF) then -- Broadcast frame
            if band(self.rcr, RCR_BROADCAST) == 0 then
                return
            end
        elseif band(data[start], 0x01) ~= 0 then -- Multicast frame
            if band(self.rcr, RCR_MULTICAST) == 0 then
                return
            end

            local index = get_multicast_index(data, start)

            if band(self.multicast_hash[rshift(index, 3)], lshift(1, band(index, 0x07))) == 0 then
                return
            end
        elseif (data[start] ~= self.phys_addr[0]) or
            (data[start + 1] ~= self.phys_addr[1]) or
            (data[start + 2] ~= self.phys_addr[2]) or
            (data[start + 3] ~= self.phys_addr[3]) or
            (data[start + 4] ~= self.phys_addr[4]) or
            (data[start + 5] ~= self.phys_addr[5]) then -- Unicast frame
            return
        end
    end

    local next_page = self.current_page + pages

    if next_page >= self.page_stop then
        next_page = next_page - (self.page_stop - self.page_start)
    end

    local position = lshift(self.current_page, 8) - self.memory_start

    if position < self.memory_size then
        self.memory[position] = bor(0x01, lshift(band(data[start], 0x01), 5)) -- RXOK - packet is OK
        self.memory[position + 1] = next_page
        self.memory[position + 2] = band(length + 4, 0xFF)
        self.memory[position + 3] = band(rshift(length + 4, 8), 0xFF)

        position = position + 4

        if (next_page > self.current_page) or ((self.current_page + pages) == self.page_stop) then
            for i = 0, length - 1, 1 do
                self.memory[position + i] = data[start + i]
            end
        else
            local new_length = lshift(self.page_stop - self.current_page, 8)

            for i = 0, new_length - 4, 1 do
                self.memory[position + i] = data[start + i]
            end

            position = band(lshift(self.page_start, 8) - self.memory_start, self.memory_mask)

            for i = 0, length - new_length + 8, 1 do
                self.memory[position + i] = data[start + new_length - 4 + i]
            end
        end
    end

    self.current_page = next_page

    self.rsr = bor(self.rsr, RCR_RX_OK)
    self.rsr = bor(self.rsr, lshift(band(data[start], 0x01), 5))
    self.isr = bor(self.isr, ISR_PRX)

    if (band(self.imr, IMR_PRXE) ~= 0) and self.interrupt_handler then
        self.interrupt_handler(self.handler_arg, true)
    end
end

local function read_command_register(self)
    return self.cr
end

local function write_command_register(self, val)
    if band(val, 0x38) == 0x00 then
        val = bor(val, 0x20)
    end

    if band(val, 0x01) ~= 0 then
        self.isr = bor(self.isr, ISR_RST)
        self.cr = bor(self.cr, CR_STP)
    else
        self.cr = band(self.cr, bnot(CR_STP))
    end

    if (band(val, 0x02) ~= 0) and (band(self.cr, 0x02) == 0) then
        self.isr = band(self.isr, bnot(ISR_RST))
    end

    self.cr = val

    local command = band(rshift(val, 3), 0x07)

    if command == 3 then
        local addr = lshift(self.bound_position, 8) + 2

        self.remote_start = lshift(self.bound_position, 8)
        self.remote_dma = self.remote_start
        self.remote_length = bor(memory_read8(self, addr), lshift(memory_read8(self, addr + 1), 8))
    end

    if (band(val, 0x04) ~= 0) and (band(self.tcr, TCR_LB) ~= 0) then
        rx_common(self, self.memory, band(lshift(self.tx_page_start, 8) - self.memory_start, self.memory_mask), self.tx_length)

        if (band(self.imr, IMR_PRXE) ~= 0) and (band(self.isr, ISR_PTX) == 0) and self.interrupt_handler then
            self.interrupt_handler(self.handler_arg, true)
        end

        self.isr = bor(self.isr, ISR_PTX)
    elseif band(val, 0x04) ~= 0 then
        if (band(self.cr, CR_STP) ~= 0) or (band(self.cr, CR_START) == 0) then
            if self.tx_length == 0 then
                return
            end
        end

        emulator_network.tx(self.memory, band(lshift(self.tx_page_start, 8) - self.memory_start, self.memory_mask), self.tx_length)

        self.cr = band(self.cr, bnot(CR_TXP))
        self.tsr = bor(self.tsr, TSR_PTX)

        if (band(self.imr, IMR_PTXE) ~= 0) and (band(self.isr, ISR_PTX) == 0) and self.interrupt_handler then
            self.interrupt_handler(self.handler_arg, true)
        end

        self.isr = bor(self.isr, ISR_PTX)
    end

    if (command == 0x01) and (band(self.cr, CR_START) ~= 0) and (self.remote_length == 0) then
        self.isr = bor(self.isr, ISR_RDC)

        if (band(self.imr, IMR_RDCE) ~= 0) and self.interrupt_handler then
            self.interrupt_handler(self.handler_arg, false)
        end
    end
end

local function allocate_memory(self, start, size)
    self.memory_start = start
    self.memory_end = start + size
    self.memory_size = size
    self.memory_mask = size - 1

    for i = 0, size - 1, 1 do
        self.memory[i] = 0x00
    end
end

local function set_interrupt_handler(self, handler, arg)
    self.interrupt_handler = handler
    self.handler_arg = arg
end

local function set_physical_address(self, address)
    self.phys_addr[0] = address[1]
    self.phys_addr[1] = address[2]
    self.phys_addr[2] = address[3]
    self.phys_addr[3] = address[4]
    self.phys_addr[4] = address[5]
    self.phys_addr[5] = address[6]
end

local function get_selected_page(self)
    return band(rshift(self.cr, 6), 0x03)
end

local function soft_reset(self)
    self.isr = ISR_RST
end

local function reset(self)
    self.cr = 0x00
    self.isr = 0x00
    self.imr = 0x00
    self.dcr = 0x00
    self.tcr = 0x00
    self.tsr = 0x00
    self.rcr = 0x00
    self.rsr = 0x00
    self.local_dma = 0x00
    self.page_start = 0x00
    self.page_stop = 0x00
    self.bound_position = 0x0000
    self.ncr = 0x00
    self.tx_page_start = 0x00
    self.tx_length = 0x00
    self.remote_dma = 0x00
    self.remote_start = 0x00
    self.remote_length = 0x00
    self.current_length = 0x00

    self.cr = bor(self.cr, CR_STP)
    self.cr = bor(self.cr, lshift(0x04, 3))
    self.isr = bor(self.isr, ISR_RST)
    self.dcr = bor(self.dcr, DCR_LAS)
end

function dp8390.new()
    local self = {
        cr = 0x00, -- Command Register
        isr = 0x00, -- Interrupt Status Register
        imr = 0x00, -- Interrupt Mask Register
        dcr = 0x00, -- Data Configuration Register
        tcr = 0x00, -- Transmit Configuration Register
        tsr = 0x00, -- Transmit Status Register
        rcr = 0x00, -- Receive Configuration Register
        rsr = 0x00, -- Receive Status Register
        local_dma = 0x00,
        page_start = 0x00,
        page_stop = 0x00,
        bound_position = 0x00,
        ncr = 0x00,
        tx_page_start = 0x00,
        tx_length = 0x0000,
        remote_dma = 0x00,
        remote_start = 0x00,
        remote_length = 0x00,
        current_page = 0x00,
        phys_addr = {[0] = 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
        multicast_hash = {[0] = 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
        remote_packet_position = 0x00,
        local_packet_position = 0x00,
        address_counter = 0x00,
        memory_start = 0,
        memory_end = 0,
        memory_size = 0,
        memory_mask = 0,
        memory = {},
        set_physical_address = set_physical_address,
        set_interrupt_handler = set_interrupt_handler,
        allocate_memory = allocate_memory,
        get_selected_page = get_selected_page,
        memory_read8 = memory_read8,
        memory_write8 = memory_write8,
        page0_read = page0_read,
        page0_write = page0_write,
        page1_read = page1_read,
        page1_write = page1_write,
        page2_read = page2_read,
        page2_write = page2_write,
        read_command_register = read_command_register,
        write_command_register = write_command_register,
        rx_common = rx_common,
        soft_reset = soft_reset,
        reset = reset
    }

    return self
end

return dp8390
