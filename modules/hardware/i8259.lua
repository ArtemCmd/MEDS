-- =====================================================================================================================================================================
-- Programmable Interrupt Controller emulation.
-- =====================================================================================================================================================================

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local pic = {}

local STATE_NONE = 0
local STATE_ICW2 = 1
local STATE_ICW3 = 2
local STATE_ICW4 = 3

local ICW1_ICW4	           = 0x01
local ICW1_CASCADE_MODE    = 0x02
local ICW1_CALL_ADDRESS4   = 0x04
local ICW1_LEVEL_TRIGGERED = 0x08
local ICW1_ICW1            = 0x10

local ICW4_i86_MODE = 0x01
local ICW4_AUTO_EOI = 0x02

local OCW_OCW3 = 0x08

local OCW2_NONSPECIFIC_EOI = 0x20
local OCW2_SPECIFIC_EOI    = 0x60

local OCW3_SPECIAL_MASK_MODE = 0x40
local OCW3_POLL_ACTION       = 0x04

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function get_interrupt_ir(self)
    local result = -1

    for i = 0, 7, 1 do
        local ir = band(i + self.priority, 0x07)
        local mask = lshift(1, ir)

        if band(self.isr, mask) ~= 0 then
            break
        elseif (self.state == STATE_NONE) and (band(band(self.irr, bnot(self.imr)), mask) ~= 0) then
            result = ir
            break
        end
    end

    if result == -1 then
        self.interrupt = 0x17
    else
        self.interrupt = result
    end

    return result
end

local function get_interrupt_is(self)
    for i = 0, 7, 1 do
        local ir = band(i + self.priority, 0x07)
        local mask = lshift(1, ir)

        if (band(self.isr, mask) ~= 0) and ((not self.special_mode) or (band(self.imr, mask) == 0)) then
            return ir
        end
    end

    return 0xFF
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function update_pending(self)
    if band(self.interrupt, 0x20) == 0 then
        self.int_pending = get_interrupt_ir(self) ~= -1
    end
end

local function eoi(self) -- End Of Interrupt
    if band(self.icw4, ICW4_AUTO_EOI) == 0 then
        return
    end

    local irq = get_interrupt_is(self)

    if irq == 0xFF then
        return
    end

    if self.auto_rotate then
        self.priority = band(irq + 1, 0x07)
    end

    self.isr = band(self.isr, bnot(lshift(1, irq)))

    update_pending(self)
end

local function get_interrupt_vector(self)
    local interrupt = band(self.interrupt, 0x07)
    local mask = lshift(1, interrupt)
    local vector

    self.interrupt = bor(self.interrupt, 0x20)
    self.isr = bor(self.isr, mask)

    if band(self.icw1, ICW1_LEVEL_TRIGGERED) == 0 then
       self.irr = band(self.irr, bnot(mask))
    end

    if band(self.icw4, ICW4_i86_MODE) ~= 0 then
        self.int_pending = false
        eoi(self)
        vector = interrupt + band(self.icw2, 0xF8)
    else
        self.int_pending = false

        if band(self.icw1, ICW1_CALL_ADDRESS4) ~= 0 then
            vector = lshift(interrupt, 2) + band(self.icw1, 0xE0)
        else
            vector = lshift(interrupt, 3) + band(self.icw1, 0xC0)
        end

        vector = bor(vector, lshift(self.icw2, 8))
        eoi(self)
    end

    self.interrupt = 0x17
    update_pending(self)

    return vector
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Ports
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function port_command_out(self, cpu, port, val)
    if band(val, ICW1_ICW1) ~= 0 then
        self.icw1 = val
        self.icw2 = 0x00

        if band(self.icw1, ICW1_ICW4) == 0 then
            self.icw4 = 0x00
        end

        self.ocw3 = 0x00
        self.irr = 0x00
        self.imr = 0x00
        self.isr = 0x00
        self.interrupt = 0x17
        self.priority = 0
        self.state = STATE_ICW2
        self.auto_rotate = false
        self.special_mode = false
        self.int_pending = false

        update_pending(self)
    elseif band(val, OCW_OCW3) ~= 0 then
        self.ocw3 = val

        if band(self.ocw3, OCW3_POLL_ACTION) ~= 0 then
            self.interrupt = bor(self.interrupt, 0x20)
        end

        if band(self.ocw3, OCW3_SPECIAL_MASK_MODE) ~= 0 then
            self.special_mode = band(self.ocw3, 0x20) ~= 0
        end
    elseif band(val, OCW2_NONSPECIFIC_EOI) ~= 0 then
        local irq = get_interrupt_is(self)

        if irq == 0xFF then
            return
        end

        if band(val, 0x20) ~= 0 then
            self.isr = band(self.isr, bnot(lshift(1, irq)))
        end

        if band(val, 0x80) ~= 0 then
            self.priority = band(irq + 1, 0x07)
        end

        update_pending(self)
    elseif band(val, OCW2_SPECIFIC_EOI) ~= 0 then
        if band(val, 0x20) ~= 0 then
            self.isr = band(self.isr, bnot(lshift(1, band(val, 0x07))))
        end

        if band(val, 0x80) ~= 0 then
            self.priority = band(band(val, 0x07) + 1, 0x07)
        end

        update_pending(self)
    else
        self.auto_rotate = band(val, 0x80) ~= 0
    end
end

local function port_command_in(self, cpu, port)
    if band(self.ocw3, OCW3_POLL_ACTION) ~= 0 then
        self.interrupt = band(self.interrupt, bnot(0x20)) -- Disable Interrupts

        if self.int_pending then
            local irq = band(self.interrupt, 0x07)
            local mask = lshift(1, irq)

            self.int_pending = false
            self.isr = bor(self.isr, mask)
            self.irr = band(self.irr, bnot(mask))

            update_pending(self)

            return bor(irq, 0x80)
        end

        self.ocw3 = band(self.ocw3, bnot(OCW3_POLL_ACTION))

        return 0x00
    end

    if band(self.ocw3, 0x03) == 0x03 then
        return self.isr
    elseif band(self.ocw3, 0x03) == 0x02 then
        return self.irr
    end

    return 0x00
end

local function port_data_out(self, cpu, port, val)
    if self.state == STATE_NONE then
        self.imr = val
        update_pending(self)
    elseif self.state == STATE_ICW2 then
        self.icw2 = val

        if band(self.icw1, ICW1_CASCADE_MODE) ~= 0 then
            self.state = STATE_ICW3
            return
        end

        if band(self.icw1, ICW1_ICW4) ~= 0 then
            self.state = STATE_ICW4
        else
            self.state = STATE_NONE
        end
    elseif self.state == STATE_ICW3 then
        if band(self.icw1, ICW1_ICW4) ~= 0 then
            self.state = STATE_ICW4
        else
            self.state = STATE_NONE
        end
    elseif self.state == STATE_ICW4 then
        self.icw4 = val
        self.state = STATE_NONE
    end
end

local function port_data_in(self, cpu, port)
    return self.imr
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function request_interrupt(self, intr)
    self.irr = bor(self.irr, lshift(1, intr))
    update_pending(self)
end

local function clear_interrupt(self, intr)
    self.irr = band(self.irr, bnot(lshift(1, intr)))
    update_pending(self)
end

local function reset(self)
    self.icw1 = 0x00
    self.icw2 = 0x00
    self.icw4 = 0x00
    self.ocw3 = 0x00
    self.irr = 0x00
    self.imr = 0x00
    self.isr = 0x00
    self.priority = 0
    self.interrupt = 0x17
    self.state = STATE_NONE
    self.int_pending = false
    self.special_mode = false
    self.auto_rotate = false
end

function pic.new(cpu, base_port)
    local self = {
        icw1 = 0x00, -- Initialisation Command Word 1..4
        icw2 = 0x00,
        icw4 = 0x00,
        ocw3 = 0x00, -- Operation Command Word 2..3
        irr = 0x00, -- Interrupt Request Register
        isr = 0x00, -- Interrupt Mask Register
        imr = 0x00, -- In Service Register
        priority = 0x00,
        interrupt = 0x17,
        state = STATE_NONE,
        int_pending = false,
        special_mode = false,
        auto_rotate = false,
        update = update_pending,
        get_interrupt_vector = get_interrupt_vector,
        request_interrupt = request_interrupt,
        clear_interrupt = clear_interrupt,
        reset = reset
    }

    local cpu_io = cpu:get_io()

    cpu_io:set_port(base_port, port_command_out, port_command_in)
    cpu_io:set_port(base_port + 1, port_data_out, port_data_in)
    cpu_io:set_function_argument_range(base_port, base_port + 1, self)

    return self
end

return pic
