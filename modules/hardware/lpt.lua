-- =====================================================================================================================================================================
-- Line Print Terminal emulation.
-- =====================================================================================================================================================================

local band, bor = bit.band, bit.bor

local lpt = {}

local function port_data_register_out(self, cpu, port, val)
    if self.handler and self.handler.write_data then
        self.handler:write_data(val)
    end

    self.data_reg = val
end

local function port_data_register_in(self, cpu, port)
    return self.data_reg
end

local function port_status_register_in(self, cpu, port)
    if self.handler and self.handler.read_status then
        return bor(band(self.handler:read_status(), 0xF8), 0x07)
    end

    return 0xDF
end

local function port_control_register_out(self, cpu, port, val)
    if self.handler and self.handler.write_control then
        self.handler:write_control(val)
    end

    self.control_reg = val
    self.enable_irq = band(val, 0x10) ~= 0

    if not self.enable_irq then
        self.pic:clear_interrupt(self.irq)
    end
end

local function port_control_register_in(self, cpu, port)
    if self.handler and self.handler.read_control  then
        return band(bor(band(self.handler:read_control(), 0xEF), self.enable_irq and 0x10 or 0x00), 0xDF)
    end

    return band(bor(bor(0xE0, self.control_reg), self.enable_irq and 0x10 or 0x00), 0xDF)
end

local function create_port(self, cpu_io, port_num, base, irq)
    local port = {
        pic = self.pic,
        handler = nil,
        data_reg = 0x00,
        control_reg = 0x00,
        irq = irq,
        enable_irq = true
    }

    cpu_io:set_port(base, port_data_register_out, port_data_register_in)
    cpu_io:set_port_in(base + 1, port_status_register_in)
    cpu_io:set_port(base + 2, port_control_register_out, port_control_register_in)

    cpu_io:set_function_argument(base, port)
    cpu_io:set_in_function_argument(base + 1, port)
    cpu_io:set_function_argument(base + 2, port)

    self.ports[port_num] = port
end

local function get_port_handler(self, port)
    return self.ports[port].handler
end

local function set_port_handler(self, port, handler)
    self.ports[port].handler = handler
end

local function reset(self)
    for i = 1, #self.ports, 1 do
        local port = self.ports[i]

        port.data_reg = 0x00
        port.control_reg = 0x00
        port.enable_irq = true
    end
end

function lpt.new(cpu, pic, ports, irqs)
    local self = {
        pic = pic,
        ports = {},
        get_port_handler = get_port_handler,
        set_port_handler = set_port_handler,
        reset = reset
    }

    local cpu_io = cpu:get_io()

    for i = 1, math.min(#ports, #irqs), 1 do
        create_port(self, cpu_io, i, ports[i], irqs[i])
    end

    return self
end

return lpt
