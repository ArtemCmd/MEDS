-- =====================================================================================================================================================================
-- Western Digital WD8003 device emulation.
-- =====================================================================================================================================================================

local logger = require("dave_logger:logger")("MEDS")

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local wd8003 = {}

local MSR_SOFT_RESET = 0x80
local MSR_ENABLE_RAM = 0x40

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- RAM
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function ram_read(self, addr)
    return self.dp8390.memory[band(addr, 0x2000 - 1)]
end

local function ram_write(self, addr, val)
    self.dp8390.memory[band(addr, 0x2000 - 1)] = val
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Ports
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local smc_register_read = {
    [0x00] = function(self)
        return self.dp8390.phys_addr[0]
    end,
    [0x01] = function(self)
        return self.dp8390.phys_addr[1]
    end,
    [0x02] = function(self)
        return self.dp8390.phys_addr[2]
    end,
    [0x03] = function(self)
        return self.dp8390.phys_addr[3]
    end,
    [0x04] = function(self)
        return self.dp8390.phys_addr[4]
    end,
    [0x05] = function(self)
        return self.dp8390.phys_addr[5]
    end,
    [0x06] = function(self)
        return 0x03 -- WD8003
    end,
    [0x07] = function(self)
        return 0xFF - band(
            self.dp8390.phys_addr[0] +
            self.dp8390.phys_addr[1] +
            self.dp8390.phys_addr[2] +
            self.dp8390.phys_addr[3] +
            self.dp8390.phys_addr[4] +
            self.dp8390.phys_addr[5] +
            0x03, 0xFF
        )
    end
}

local function port_smc_in(self, cpu, port)
    local register = smc_register_read[band(port - self.base_addr, 0x07)]

    if register then
        return register(self)
    end

    return 0x00
end

local function port_smc_out(self, cpu, port, val)
    if (band(self.msr, MSR_SOFT_RESET) == 0) and (band(val, MSR_SOFT_RESET) ~= 0) then
        self.dp8390:soft_reset()
    end

    if band(self.msr, 0x7F) ~= band(val, 0x7F) then
        self.msr = bor(band(self.msr, 0x3F), band(val, 0xC0))

        if band(self.msr, MSR_ENABLE_RAM) ~= 0 then
            self.memory:add_mapping(self.ram_addr, 0x2000, ram_read, ram_write, self)
        else
            self.memory:remove_mapping(self.ram_addr, 0x2000)
        end
    else
        self.msr = bor(band(self.msr, 0x3F), band(val, 0xC0))
    end
end

local function port_command_in(self, cpu, port)
    return self.dp8390:read_command_register()
end

local function port_command_out(self, cpu, port, val)
    self.dp8390:write_command_register(val)
end

local function port_page_in(self, cpu, port)
    local selected_page = self.dp8390:get_selected_page()

    if selected_page == 0x00 then
        return self.dp8390:page0_read(port - self.base_addr - 0x10)
    elseif selected_page == 0x01 then
        return self.dp8390:page1_read(port - self.base_addr - 0x10)
    elseif selected_page == 0x02 then
        return self.dp8390:page2_read(port - self.base_addr - 0x10)
    end

    return 0x00
end

local function port_page_out(self, cpu, port, val)
    local selected_page = self.dp8390:get_selected_page()

    if selected_page == 0x00 then
        self.dp8390:page0_write(port - self.base_addr - 0x10, val)
    elseif selected_page == 0x01 then
        self.dp8390:page1_write(port - self.base_addr - 0x10, val)
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function interrupt(self, set)
    if set then
        self.pic:request_interrupt(self.irq)
    else
        self.pic:clear_interrupt(self.irq)
    end
end

local function reset(self)
    self.dp8390:reset()
    self.msr = 0x00
end

function wd8003.new(cpu, memory, pic, base_addr, ram_addr, irq)
    local self = {
        memory = memory,
        pic = pic,
        dp8390 = require("emulator:hardware/network/dp8390").new(),
        base_addr = base_addr or 0x240,
        ram_addr = ram_addr or 0xCE000,
        irq = irq or 2,
        msr = 0x00, -- Memory Select Register
        reset = reset
    }

    self.dp8390:allocate_memory(0x0000, 0x2000)
    self.dp8390:set_interrupt_handler(interrupt, self)
    self.dp8390:set_physical_address({0x00, 0x00, 0xC0, math.random(0x00, 0xFF), math.random(0x00, 0xFF), math.random(0x00, 0xFF)})

    local cpu_io = cpu:get_io()

    cpu_io:set_port_out(self.base_addr, port_smc_out)
    cpu_io:set_port_out(self.base_addr + 0x08, port_smc_out)
    cpu_io:set_port_in_range(self.base_addr, self.base_addr + 0x0F, port_smc_in)
    cpu_io:set_port(self.base_addr + 0x10, port_command_out, port_command_in)
    cpu_io:set_port_range(self.base_addr + 0x11, self.base_addr + 0x20, port_page_out, port_page_in)

    cpu_io:set_function_argument_range(self.base_addr, self.base_addr + 0x0F, self)
    cpu_io:set_function_argument(self.base_addr + 0x10, self)
    cpu_io:set_function_argument_range(self.base_addr + 0x11, self.base_addr + 0x20, self)

    require("emulator:network/network").attach(string.format("%02X:%02X:%02X:%02X:%02X:%02X",
        self.dp8390.phys_addr[0],
        self.dp8390.phys_addr[1],
        self.dp8390.phys_addr[2],
        self.dp8390.phys_addr[3],
        self.dp8390.phys_addr[4],
        self.dp8390.phys_addr[5]
    ), self.dp8390, self.dp8390.rx_common)
end

return wd8003
