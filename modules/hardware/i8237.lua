-- =====================================================================================================================================================================
-- Direct Memory Access Controller emulation.
-- =====================================================================================================================================================================

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local dma = {}

local TRANSFER_TYPE_VEIFY = 0x00
local TRANSFER_TYPE_WRITE = 0x01
local TRANSFER_TYPE_READ = 0x02

local TRANSFER_MODE_DEMAND = 0x00
local TRANSFER_MODE_SINGLE = 0x01
local TRANSFER_MODE_BLOCK = 0x02
local TRANSFER_MODE_CASCADE = 0x03

local STATUS_NO_DATA = 0x200
local STATUS_OVER = 0x100
local STATUS_OK = 0x000

local page_channels = {[0] = -1, 2, 3, 1, -1, -1, -1, 0}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function create_channel(self, channel)
    self.channels[channel] = {
        curr_addr = 0x000000,
        base_addr = 0x000000,
        base_count = 0x0000,
        curr_count = 0x0000,
        transfer_type = 0x00,
        transfer_mode = 0x00,
        page = 0x00,
        auto_init = false,
        decrement = false
    }
end

local function reset_channel(self, channel_num)
    local channel = self.channels[channel_num]

    channel.curr_addr = 0x000000
    channel.base_addr = 0x000000
    channel.base_count = 0x0000
    channel.curr_count = 0x0000
    channel.transfer_type = 0x00
    channel.transfer_mode = 0x00
    channel.page = 0x00
    channel.auto_init = false
    channel.decrement = false
end

local function channel_read(self, channel_num, check_mask)
    local channel = self.channels[channel_num]
    local channel_mask = lshift(1, channel_num)

    if not self.enabled then
        return STATUS_NO_DATA
    end

    if (band(self.mask_reg, channel_mask) ~= 0) and check_mask then
        return STATUS_NO_DATA
    end

    if channel.transfer_type ~= TRANSFER_TYPE_READ then
        return STATUS_NO_DATA
    end

    local temp = self.memory:read8(channel.curr_addr)

    if channel.decrement then
        channel.curr_addr = bor(band(channel.curr_addr, 0xFF0000), band(channel.curr_addr - 1, 0xFFFF))
    else
        channel.curr_addr = bor(band(channel.curr_addr, 0xFF0000), band(channel.curr_addr + 1, 0xFFFF))
    end

    channel.curr_count = channel.curr_count - 1

    if channel.curr_count < 0 then
        if channel.auto_init then
            channel.curr_count = channel.base_count
            channel.curr_addr = channel.base_addr
        else
            self.mask_reg = bor(self.mask_reg, channel_mask)
        end

        self.status_reg = bor(self.status_reg, channel_mask)

        return bor(temp, STATUS_OVER)
    end

    return temp
end

local function channel_write(self, channel_num, val, check_mask)
    local channel = self.channels[channel_num]
    local channel_mask = lshift(1, channel_num)

    if not self.enabled then
        return STATUS_NO_DATA
    end

    if (band(self.mask_reg, channel_mask) ~= 0) and check_mask then
        return STATUS_NO_DATA
    end

    if channel.transfer_type ~= TRANSFER_TYPE_WRITE then
        return STATUS_NO_DATA
    end

    self.memory:write8(channel.curr_addr, band(val, 0xFF))

    if channel.decrement then
        channel.curr_addr = bor(band(channel.curr_addr, 0xFF0000), band(channel.curr_addr - 1, 0xFFFF))
    else
        channel.curr_addr = bor(band(channel.curr_addr, 0xFF0000), band(channel.curr_addr + 1, 0xFFFF))
    end

    channel.curr_count = channel.curr_count - 1

    if channel.curr_count < 0 then
        if channel.auto_init then
            channel.curr_count = channel.base_count
            channel.curr_addr = channel.base_addr
        else
            self.mask_reg = bor(self.mask_reg, channel_mask)
        end

        self.status_reg = bor(self.status_reg, channel_mask)
    end

    if band(self.mask_reg, channel_mask) ~= 0 then
        return STATUS_OVER
    end

    return STATUS_OK
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function block_transfer(self, channel_num)
    local channel = self.channels[channel_num]

    if channel.transfer_mode == TRANSFER_MODE_BLOCK then
        if channel.transfer_type == TRANSFER_TYPE_READ then
            for i = 0, channel.base_count, 1 do
                self.buffer[i] = channel_read(self, channel_num, false)
            end
        elseif channel.transfer_type == TRANSFER_TYPE_WRITE then
            for i = 0, channel.base_count, 1 do
                channel_write(self, channel_num, self.buffer[i], false)
            end
        end
    end
end

local function mem_to_mem_transfer(self)
    for i = 0, self.channels[0].base_count, 1 do
        self.buffer[i] = band(channel_read(self, 0), 0xFF)
        channel_write(self, 0, self.buffer[i], false)
    end
end

local function request_service(self, channel_num)
    self.request_reg = bor(self.request_reg, lshift(1, channel_num))
end

local function clear_service(self, channel_num)
    self.request_reg = bor(self.request_reg, bnot(lshift(1, channel_num)))
end

local function get_drq(self, channel_num)
    return band(self.request_reg, lshift(1, channel_num)) ~= 0
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Ports
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function port_address_register_out(self, cpu, port, val)
    local channel = self.channels[band(rshift(port, 1), 0x03)]

    self.flipflop = not self.flipflop

    if self.flipflop then
        channel.base_addr = bor(band(channel.base_addr, 0xFFFF00), val)
    else
        channel.base_addr = bor(band(channel.base_addr, 0xFF00FF), lshift(val, 8))
    end

    channel.curr_addr = channel.base_addr
end

local function port_address_register_in(self, cpu, port)
    local channel = self.channels[band(rshift(port, 1), 0x03)]

    self.flipflop = not self.flipflop

    if self.flipflop then
        return band(channel.curr_addr, 0xFF)
    end

    return band(rshift(channel.curr_addr, 8), 0xFF)
end

local function port_count_register_out(self, cpu, port, val)
    local channel = self.channels[band(rshift(port, 1), 0x03)]

    self.flipflop = not self.flipflop

    if self.flipflop then
        channel.base_count = bor(band(channel.base_count, 0xFF00), val)
    else
        channel.base_count = bor(band(channel.base_count, 0x00FF), lshift(val, 8))
    end

    channel.curr_count = channel.base_count
end

local function port_count_register_in(self, cpu, port)
    local channel = self.channels[band(rshift(port, 1), 0x03)]

    self.flipflop = not self.flipflop

    if self.flipflop then
        return band(channel.curr_count, 0xFF)
    end

    return band(rshift(channel.curr_count, 8), 0xFF)
end

local function port_page_register_out(self, cpu, port, val)
    local channel = self.channels[page_channels[band(port, 0x03)]]

    channel.page = band(val, 0xF)
    channel.base_addr = bor(band(channel.base_addr, 0xFFFF), lshift(channel.page, 16))
    channel.curr_addr = bor(band(channel.curr_addr, 0xFFFF), lshift(channel.page, 16))
end

local function port_page_register_in(self, cpu, port)
    return self.channels[page_channels[band(port, 0x03)]].page
end

local function port_command_out(self, cpu, port, val)
    self.enabled = band(val, 0x04) == 0
    self.mem_to_mem_mode = band(val, 0x01) ~= 0
end

local function port_status_in(self, cpu, port)
    local status = self.status_reg
    self.status_reg = band(self.status_reg, bnot(0x0F))
    return bor(band(status, 0x0F), lshift(self.request_reg, 4))
end

local function port_request_register_out(self, cpu, port, val)
    local channel_num = band(val, 0x03)
    local channel_mask = lshift(1, channel_num)

    if band(val, 0x04) ~= 0 then
        self.request_reg = bor(self.request_reg, channel_mask)

        if (channel_num == 0) and self.mem_to_mem_mode then
            mem_to_mem_transfer(self)
        else
            block_transfer(self, channel_num)
        end
    else
        self.request_reg = band(self.request_reg, bnot(channel_mask))
    end
end

local function port_single_mask_register_out(self, cpu, port, val)
    local channel_num = band(val, 0x03)
    local channel_mask = lshift(1, channel_num)

    if band(val, 0x04) ~= 0 then
        self.mask_reg = bor(self.mask_reg, channel_mask)
    else
        self.mask_reg = band(self.mask_reg, bnot(channel_mask))
    end
end

local function port_mode_register_out(self, cpu, port, val)
    local channel_num = band(val, 0x03)
    local channel = self.channels[channel_num]

    channel.transfer_type = band(rshift(val, 2), 0x03)
    channel.transfer_mode = band(rshift(val, 6), 0x03)
    channel.auto_init = band(val, 0x10) ~= 0
    channel.decrement = band(val, 0x20) ~= 0
end

local function port_clear_flipflop_register_out(self, cpu, port, val)
    self.flipflop = false
end

local function port_master_reset_out(self, cpu, port, val)
    self.flipflop = false
    self.mask_reg = bor(self.mask_reg, 0x0F)
    self.request_reg = band(self.request_reg, bnot(0x0F))
end

local function port_temporary_register_in(self, cpu, port)
    return 0x00
end

local function port_clear_mask_register_out(self, cpu, port, val)
    self.mask_reg = band(self.mask_reg, 0xF0)
end

local function port_mask_register_out(self, cpu, port, val)
    self.mask_reg = bor(band(self.mask_reg, 0xF0), band(val, 0xF))
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function reset(self)
    self.master_reg = 0x00
    self.request_reg = 0x00
    self.mask_reg = 0x00
    self.status_reg = 0x00
    self.enabled = true
    self.flipflop = false
    self.mem_to_mem_transfer = false

    reset_channel(self, 0)
    reset_channel(self, 1)
    reset_channel(self, 2)
    reset_channel(self, 3)
end

function dma.new(cpu, memory)
    local self = {
        memory = memory,
        channels = {},
        buffer = {},
        master_reg = 0x00,
        request_reg = 0x00,
        status_reg = 0x00,
        mask_reg = 0x00,
        flipflop = false,
        enabled = true,
        mem_to_mem_mode = false,
        channel_read = channel_read,
        channel_write = channel_write,
        get_drq = get_drq,
        request_service = request_service,
        clear_service = clear_service,
        reset = reset
    }

    create_channel(self, 0)
    create_channel(self, 1)
    create_channel(self, 2)
    create_channel(self, 3)

    local cpu_io = cpu:get_io()

    cpu_io:set_port(0x00, port_address_register_out, port_address_register_in)
    cpu_io:set_port(0x02, port_address_register_out, port_address_register_in)
    cpu_io:set_port(0x04, port_address_register_out, port_address_register_in)
    cpu_io:set_port(0x06, port_address_register_out, port_address_register_in)

    cpu_io:set_port(0x01, port_count_register_out, port_count_register_in)
    cpu_io:set_port(0x03, port_count_register_out, port_count_register_in)
    cpu_io:set_port(0x05, port_count_register_out, port_count_register_in)
    cpu_io:set_port(0x07, port_count_register_out, port_count_register_in)

    cpu_io:set_port(0x81, port_page_register_out, port_page_register_in)
    cpu_io:set_port(0x82, port_page_register_out, port_page_register_in)
    cpu_io:set_port(0x83, port_page_register_out, port_page_register_in)
    cpu_io:set_port(0x87, port_page_register_out, port_page_register_in)

    cpu_io:set_port(0x08, port_command_out, port_status_in)
    cpu_io:set_port_out(0x09, port_request_register_out)
    cpu_io:set_port_out(0x0A, port_single_mask_register_out)
    cpu_io:set_port_out(0x0B, port_mode_register_out)
    cpu_io:set_port_out(0x0C, port_clear_flipflop_register_out)
    cpu_io:set_port(0x0D, port_master_reset_out, port_temporary_register_in)
    cpu_io:set_port_out(0x0E, port_clear_mask_register_out)
    cpu_io:set_port_out(0x0F, port_mask_register_out)

    cpu_io:set_function_argument_range(0x00, 0x0F, self)
    cpu_io:set_function_argument_range(0x81, 0x83, self)
    cpu_io:set_function_argument(0x87, self)

    -- Initilize buffer
    for i = 0, 0xFFFF, 1 do
        self.buffer[i] = 0x00
    end

    return self
end

return dma
