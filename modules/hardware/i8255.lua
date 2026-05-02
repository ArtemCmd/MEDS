-- =====================================================================================================================================================================
-- Programmable Peripheral Interface emulation.
-- =====================================================================================================================================================================

local logger = require("dave_logger:logger")("MEDS")
local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local ppi = {}

local PORT_MODE_OUT = 0
local PORT_MODE_IN = 1

local EMPTY_FUNC = function() return 0x00 end
local DEFAULT_HANDLER = {
    port_a_set_mode = EMPTY_FUNC,
    port_b_set_mode = EMPTY_FUNC,
    port_c_set_mode = EMPTY_FUNC,
    port_a_write = EMPTY_FUNC,
    port_b_write = EMPTY_FUNC,
    port_c_write = EMPTY_FUNC,
    port_a_read = EMPTY_FUNC,
    port_b_read = EMPTY_FUNC,
    port_c_read = EMPTY_FUNC
}
DEFAULT_HANDLER.__index = DEFAULT_HANDLER

local function port_a_out(self, cpu, port, val)
    if self.port_a_mode == PORT_MODE_OUT then
        self.port_a = val

        if self.handler then
            self.handler:port_a_write(val)
        end
    end
end

local function port_a_in(self, cpu, port)
    if self.port_a_mode == PORT_MODE_IN then
        if self.handler then
            return self.handler:port_a_read()
        end

        return 0x00
    end

    return self.port_a
end

local function port_b_out(self, cpu, port, val)
    if self.port_b_mode == PORT_MODE_OUT then
        self.port_b = val

        if self.handler then
            self.handler:port_b_write(val)
        end
    end
end

local function port_b_in(self, cpu, port)
    if self.port_b_mode == PORT_MODE_IN then
        if self.handler then
            return self.handler:port_b_read()
        end

        return 0x00
    end

    return self.port_b
end

local function port_c_out(self, cpu, port, val)
    if self.port_c_h_mode == PORT_MODE_OUT then
        self.port_c = bor(band(self.port_c, 0x0F), band(val, 0xF0))
    end

    if self.port_c_l_mode == PORT_MODE_OUT then
        self.port_c = bor(band(self.port_c, 0xF0), band(val, 0x0F))
    end

    if self.handler and ((self.port_c_h_mode == PORT_MODE_OUT) or (self.port_c_l_mode == PORT_MODE_OUT)) then
        self.handler:port_c_write(self.port_c)
    end
end

local function port_c_in(self, cpu, port)
    local out = self.port_c

    if (self.port_c_h_mode == PORT_MODE_IN) or (self.port_c_l_mode == PORT_MODE_IN) then
        local val

        if self.handler then
            val = self.handler:port_c_read()
        else
            val = 0x00
        end

        if self.port_c_h_mode == PORT_MODE_IN then
            out = bor(band(out, 0x0F), band(val, 0xF0))
        end

        if self.port_c_l_mode == PORT_MODE_IN then
            out = bor(band(out, 0xF0), band(val, 0x0F))
        end
    end

    return out
end

local function port_control_out(self, cpu, port, val)
    if band(val, 0x80) == 0 then -- BSR Mode
        local bit = rshift(band(val, 0x0E), 1)
        local mask = bnot(lshift(1, bit))

        self.port_c = band(self.port_c, mask)
        self.port_c = bor(self.port_c, lshift(band(val, 0x01), bit))

        if self.handler then
            self.handler:port_c_write(self.port_c)
        end

        return
    end

    self.port_a = 0x00
    self.port_b = 0x00
    self.port_c = 0x00

    if band(val, 0x40) == 0 then
        self.port_a_mode = rshift(band(val, 0x10), 4)
        self.port_b_mode = rshift(band(val, 0x02), 1)
        self.port_c_l_mode = band(val, 0x01)
        self.port_c_h_mode = rshift(band(val, 0x08), 7)

        if self.handler then
            self.handler.port_a_set_mode(self.port_a_mode)
            self.handler.port_b_set_mode(self.port_b_mode)
            self.handler.port_c_set_mode(self.port_c_mode)

            if self.port_a_mode == PORT_MODE_OUT then
                self.handler:port_a_write(0x00)
            end

            if self.port_b_mode == PORT_MODE_OUT then
                self.handler:port_b_write(0x00)
            end

            if (self.port_c_l_mode == PORT_MODE_OUT) or (self.port_c_h_mode == PORT_MODE_OUT) then
                self.handler:port_c_write(0x00)
            end
        end
    else
        logger:warning("PPI: Unsupported Bi-directional data bus mode.")
    end
end

local function get_handler(self)
    return self.handler
end

local function set_handler(self, handler)
    self.handler = handler
    setmetatable(self.handler, DEFAULT_HANDLER)
end

local function reset(self)
    self.port_a = 0x00
    self.port_b = 0x00
    self.port_c = 0x00
    self.port_a_mode = PORT_MODE_IN
    self.port_b_mode = PORT_MODE_IN
    self.port_c_h_mode = PORT_MODE_IN
    self.port_c_l_mode = PORT_MODE_IN
end

function ppi.new(cpu, base_port)
    local self = {
        port_a = 0x00,
        port_b = 0x00,
        port_c = 0x00,
        port_a_mode = PORT_MODE_IN,
        port_b_mode = PORT_MODE_IN,
        port_c_h_mode = PORT_MODE_IN,
        port_c_l_mode = PORT_MODE_IN,
        get_handler = get_handler,
        set_handler = set_handler,
        reset = reset
    }

    local cpu_io = cpu:get_io()

    cpu_io:set_port(base_port, port_a_out, port_a_in)
    cpu_io:set_port(base_port + 1, port_b_out, port_b_in)
    cpu_io:set_port(base_port + 2, port_c_out, port_c_in)
    cpu_io:set_port_out(base_port + 3, port_control_out)
    cpu_io:set_function_argument_range(base_port, base_port + 2, self)
    cpu_io:set_out_function_argument(base_port + 3, self)

    return self
end

return ppi
