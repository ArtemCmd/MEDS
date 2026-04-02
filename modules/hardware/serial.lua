-- =====================================================================================================================================================================
-- NS8250/16550 UART emulation.
-- =====================================================================================================================================================================

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local serial = {}

local LCR_DB  = 0x03 -- Data Bits
local LCR_SB  = 0x04 -- Stop Bits
local LCR_PB  = 0x08 -- Parity Bits
local LCR_BEB = 0x40 -- Break Enable Bit
local LCR_DL  = 0x80 -- Divisor Latch Access Bit	

local IER_RDA  = 0x01 -- Received Data Available
local IER_THRE = 0x02 -- Transmitter Holding Register Empty
local IER_RLS  = 0x04 -- Receiver Line Status
local IER_MS   = 0x08 -- Modem Status

local IIR_IP = 0x01 -- Interrupt Pending
local IIR_IS = 0x06 -- Interrupt State

local MCR_DTR  = 0x01 -- Data Terminal Ready
local MCR_RTS  = 0x02 -- Request To Send
local MCR_OUT1 = 0x04 -- Out 1
local MCR_OUT2 = 0x08 -- Out 2
local MCR_LOOP = 0x10 -- Loopback

local LSR_DR   = 0x01 -- Data Ready
local LSR_OE   = 0x02 -- Overrun Error
local LSR_PE   = 0x04 -- Parity Error
local LSR_FE   = 0x08 -- Framing Error
local LSR_BI   = 0x10 -- Break Indicator
local LSR_THRE = 0x20 -- Transmitter Holding Register Empty
local LSR_TEMT = 0x40 -- Transmitter Empty
local LSR_IE   = 0x80 -- Impending Error

local MSR_DCTS = 0x01 -- Delta Clear to Send
local MSR_DDSR = 0x02 -- Delta Data Set Ready
local MSR_TERI = 0x04 -- Trailing Edge of Ring Indicator
local MSR_DDCD = 0x08 -- Delta Data Carrier Detect
local MSR_CTS  = 0x10 -- Clear to Send
local MSR_DSR  = 0x20 -- Data Set Ready
local MSR_RI   = 0x40 -- Ring Indicator
local MSR_DCD  = 0x80 -- Data Carrier Detect

local INT_LSR      = 0x01
local INT_TIMEOUT  = 0x02
local INT_RECEIVE  = 0x04
local INT_TRANSMIT = 0x08
local INT_MSR      = 0x10

--                     RLS   RDA   RDA   THRE  MS 
local ier_map = {[0] = 0x04, 0x01, 0x01, 0x02, 0x08, 0x40, 0x80}
local iir_map = {[0] = 0x06, 0x0C, 0x04, 0x02, 0x00, 0x0E, 0x0A}

local function update_interrupts(self)
    -- Calculate IIR value
    self.iir = bor(band(self.iir, 0xF0), IIR_IP)

    for i = 0, 6, 1 do
        if (band(self.ier, ier_map[i]) ~= 0) and (band(self.int_status, lshift(1, i)) ~= 0) then
            self.iir = bor(band(self.iir, 0xF0), iir_map[i])
            break
        end
    end

    local set = (band(self.iir, IIR_IP) == 0) and (band(self.mcr, MCR_OUT2) ~= 0)

    if set or (self.irq_state ~= set)  then
        if set then
            self.pic:request_interrupt(self.irq)
        else
            self.pic:clear_interrupt(self.irq)
        end

        self.irq_state = set
    end
end

local function update_timings(self)
    self.transmit_period = (16000000.0 * ((self.dlab == 0) and 65536.0 or self.dlab)) / 1843200.0

    if self.timeout_timer:is_enabled_period() then
        self.timeout_timer:period_start(4 * self.bits * self.transmit_period)
    end
end

local function timeout_callback(self)
    self.lsr = bor(self.lsr, LSR_DR)
    self.int_status = bor(self.int_status, INT_TIMEOUT)
    update_interrupts(self)
end

local function receive_callback(self)
    if self.send_data == 0xFFFF then -- Not enough data.
        return
    end

    if self.fifo_enabled then
        self.timeout_timer:disable()
        self.int_status = band(self.int_status, bnot(INT_TIMEOUT))
        update_interrupts(self)

        if self.rcvr_fifo:is_full() then
            self.lsr = bor(self.lsr, LSR_OE)
        end

        self.rcvr_fifo:push(self.send_data)
        self.lsr = bor(self.lsr, LSR_DR)

        if self.rcvr_fifo:get_count() >= self.trigger_len then
            self.int_status = bor(self.int_status, INT_RECEIVE)
            update_interrupts(self)
        end

        self.send_data = 0xFFFF
        self.timeout_timer:period_start(4 * self.bits * self.transmit_period)

        return
    end

    if band(self.lsr, LSR_DR) ~= 0 then
        self.lsr = bor(self.lsr, LSR_OE)
    end

    self.data = self.send_data
    self.send_data = 0xFFFF

    self.lsr = bor(self.lsr, LSR_DR)
    self.int_status = bor(self.int_status, INT_RECEIVE)

    if band(self.lsr, LSR_OE) ~= 0 then
        self.int_status = bor(self.int_status, INT_LSR)
    end

    update_interrupts(self)

    if self.send_data ~= 0xFFFF then -- Not enough data.
        self.receive_timer:period_start(self.transmit_period)
    end
end

local transmit_callback_2

local function transmit_callback_1(self) -- THR > TXSR
    self.txsr_empty = false

    if self.fifo_enabled then
        self.txsr = self.xmit_fifo:pop()
    else
        self.txsr = self.thr
        self.thr = 0x00
        self.thr_empty = true
    end

    self.lsr = band(self.lsr, bnot(LSR_TEMT))
    self.int_status = bor(self.int_status, INT_TRANSMIT)
    self.lsr = bor(self.lsr, LSR_THRE)

    if not self.fifo_enabled or (self.xmit_fifo:get_count() == 0) then
        update_interrupts(self)
    end

    self.transmit_timer.callback = transmit_callback_2
    self.transmit_timer:period_start(self.bits * self.transmit_period)
end

transmit_callback_2 = function(self) -- TXSR -> PORT
    if band(self.mcr, MCR_LOOP) ~= 0 then
        self.send_data = self.txsr
        self.receive_timer:period_start(self.bits * self.transmit_period)
    elseif self.handler and self.handler.write then
        self.handler:write(self.txsr)
    end

    self.txsr = 0x00
    self.txsr_empty = true

    if self.fifo_enabled and (self.xmit_fifo:get_count() > 0) then
        self.transmit_timer.callback = transmit_callback_1
        self.transmit_timer:period_start(2 * self.transmit_period)
    end

    if (self.fifo_enabled and self.xmit_fifo:is_empty()) or (not self.fifo_enabled and self.thr_empty) then
        self.lsr = bor(self.lsr, bor(LSR_TEMT, LSR_THRE))
        self.int_status = bor(self.int_status, INT_TRANSMIT)
    else
        self.lsr = band(self.lsr, bnot(bor(LSR_TEMT, LSR_THRE)))
        self.int_status = band(self.int_status, bnot(INT_TRANSMIT))
    end

    update_interrupts(self)
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Ports
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function port_0_in(self, cpu, port)
    cpu.cycles = cpu.cycles - 8

    if band(self.lcr, LCR_DL) ~= 0 then
        return band(self.dlab, 0x00FF)
    end

    if self.fifo_enabled then
        self.timeout_timer:disable()
        self.int_status = band(self.int_status, bnot(INT_TIMEOUT))
        update_interrupts(self)

        if band(self.lsr, LSR_DR) ~= 0 then
            self.timeout_timer:period_start(4 * self.bits * self.transmit_period)
        end

        if self.rcvr_fifo:get_count() == 1 then
            self.lsr = band(self.lsr, bnot(bor(LSR_DR, LSR_BI)))
        end

        if self.rcvr_fifo:get_count() < self.trigger_len then
            self.int_status = band(self.int_status, bnot(INT_RECEIVE))
            update_interrupts(self)
        end

        return self.rcvr_fifo:pop()
    end

    self.lsr = band(self.lsr, bnot(bor(LSR_DR, LSR_BI)))
    self.int_status = band(self.int_status, bnot(INT_RECEIVE))

    update_interrupts(self)

    return self.data
end

local function port_0_out(self, cpu, port, val)
    cpu.cycles = cpu.cycles - 8

    if band(self.lcr, LCR_DL) ~= 0 then
        self.dlab = bor(band(self.dlab, 0xFF00), val)
        update_timings(self)
        return
    end

    if self.fifo_enabled and (self.xmit_fifo:get_count() < 16) then
        self.lsr = band(self.lsr, bnot(bor(LSR_TEMT, LSR_THRE)))
        self.int_status = band(self.int_status, bnot(INT_TRANSMIT))

        self.xmit_fifo:push(val)

        self.transmit_timer.callback = transmit_callback_1
        self.transmit_timer:period_start(self.transmit_period)
    elseif not self.fifo_enabled then
        self.lsr = band(self.lsr, bnot(bor(LSR_TEMT, LSR_THRE)))
        self.int_status = band(self.int_status, bnot(INT_TRANSMIT))

        update_interrupts(self)

        self.thr = val
        self.thr_empty = false
        self.transmit_timer.callback = transmit_callback_1
        self.transmit_timer:period_start(self.transmit_period)
    end
end

local function port_1_in(self, cpu, port)
    cpu.cycles = cpu.cycles - 8

    if band(self.lcr, LCR_DL) ~= 0 then
        return band(rshift(self.dlab, 8), 0xFF)
    end

    return self.ier
end

local function port_1_out(self, cpu, port, val)
    cpu.cycles = cpu.cycles - 8

    if band(self.lcr, LCR_DL) ~= 0 then
        self.dlab = bor(band(self.dlab, 0x00FF), lshift(band(val, 0xFF), 8))
        update_timings(self)
        return
    end

    if (band(val, 0x02) ~= 0) and (band(self.lsr, LSR_THRE) ~= 0) then
        self.int_status = bor(self.int_status, INT_TRANSMIT)
    end

    self.ier = band(val, 0x0F)
    update_interrupts(self)
end

local function port_2_in(self, cpu, port)
    cpu.cycles = cpu.cycles - 8

    local val = self.iir

    if band(self.iir, 0x0E) == 0x02 then
        self.int_status = band(self.int_status, bnot(INT_TRANSMIT))
        update_interrupts(self)
    end

    if band(self.fcr, 0x01) ~= 0 then
        return bor(val, 0xC0)
    end

    return val
end

local function port_2_out(self, cpu, port, val)
    local reset

    if band(val, 0x01) ~= band(self.fcr, 0x01) then
        reset = true
    end

    if reset or (band(val, 0x02) ~= 0) then
        self.lsr = band(self.lsr, bnot(bor(LSR_OE, LSR_DR)))
        self.int_status = band(self.int_status, bnot(INT_RECEIVE))
        self.rcvr_fifo:reset()
    end

    if reset or (band(val, 0x04) ~= 0) then
        self.lsr = bor(self.lsr, LSR_THRE)
        self.int_status = band(self.int_status, bnot(INT_TRANSMIT))
        self.xmit_fifo:reset()
    end

    local trigger_level = band(rshift(val, 6), 0x03)

    if trigger_level == 0 then
        self.trigger_len = 1
    elseif trigger_level == 1 then
        self.trigger_len = 4
    elseif trigger_level == 2 then
        self.trigger_len = 8
    elseif trigger_level == 3 then
        self.trigger_len = 14
    end

    self.fcr = band(val, 0xF9)
    self.fifo_enabled = band(val, 0x01) ~= 0
    self.send_data = 0xFFFF

    update_interrupts(self)
end

local function port_3_in(self, cpu, port)
    cpu.cycles = cpu.cycles - 8
    return self.lcr
end

local function port_3_out(self, cpu, port, val)
    cpu.cycles = cpu.cycles - 8

    if band(bxor(self.lcr, val), 0x3F) ~= 0 then
        self.bits = band(self.lcr, LCR_DB) + 7 -- Data bits + start bit + first stop bit

        if band(self.lcr, LCR_SB) ~= 0 then
            self.bits = self.bits + 1 -- Second stop bit
        end

        if band(self.lcr, LCR_PB) ~= 0 then
            self.bits = self.bits + 1 -- Parity Bit
        end

        update_timings(self)
    end

    self.lcr = val
end

local function port_4_in(self, cpu, port)
    cpu.cycles = cpu.cycles - 8
    return self.mcr
end

local function port_4_out(self, cpu, port, val)
    cpu.cycles = cpu.cycles - 8

    self.mcr = band(val, 0x1F)

    if band(val, MCR_LOOP) ~= 0 then
        local msr = lshift(band(val, 0x0C), 4)

        if band(val, MCR_DTR) ~= 0 then
            msr = bor(msr, MSR_DSR)
        end

        if band(val, MCR_RTS) ~= 0 then
            msr = bor(msr, MSR_CTS)
        end

        if band(bxor(self.msr, msr), 0x10) ~= 0 then
            msr = bor(msr, MSR_DCTS)
        end

        if band(bxor(self.msr, msr), 0x20) ~= 0 then
            msr = bor(msr, MSR_DDSR)
        end

        if band(bxor(self.msr, msr), 0x80) ~= 0 then
            msr = bor(msr, MSR_DDCD)
        end

        if (band(self.msr, MSR_RI) ~= 0) and (band(msr, MSR_RI) == 0) then
            msr = bor(msr, MSR_TERI)
        end

        self.msr = msr

        if band(self.msr, 0x0F) ~= 0 then
            self.int_status = bor(self.int_status, INT_MSR)
            update_interrupts(self)
        end
    end
end

local function port_5_in(self, cpu, port)
    cpu.cycles = cpu.cycles - 8

    local result = self.lsr

    if band(self.lsr, 0x1F) ~= 0 then
        self.lsr = band(self.lsr, bnot(0x1E))
    end

    self.int_status = band(self.int_status, bnot(INT_LSR))
    update_interrupts(self)

    return result
end

local function port_5_out(self, cpu, port, val)
    cpu.cycles = cpu.cycles - 8

    self.lsr = bor(band(self.lsr, 0xE0), band(val, 0x1F))

    if band(self.lsr, LSR_DR) ~= 0 then
        self.int_status = bor(self.int_status, INT_RECEIVE)
    end

    if band(self.lsr, 0x1E) ~= 0  then
        self.int_status = bor(self.int_status, INT_LSR)
    end

    if band(self.lsr, LSR_THRE) ~= 0 then
        self.int_status = bor(self.int_status, INT_TRANSMIT)
    end

    update_interrupts(self)
end

local function port_6_in(self, cpu, port)
    cpu.cycles = cpu.cycles - 8

    local result = self.msr

    self.msr = band(self.msr, 0xF0)
    self.int_status = band(self.int_status, bnot(INT_MSR))

    update_interrupts(self)

    return result
end

local function port_6_out(self, cpu, port, val)
    cpu.cycles = cpu.cycles - 8

    self.msr = bor(band(self.msr, 0xF0), band(val, 0x0F))

    if band(self.msr, 0x0F) ~= 0 then
        self.int_status = bor(self.int_status, INT_MSR)
    end

    update_interrupts(self)
end

local function port_7_in(self, cpu, port)
    return self.scratch
end

local function port_7_out(self, cpu, port, val)
    self.scratch = val
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function create_port(self, cpu_io, scheduler, base_port, irq, index)
    local serial_port = {
        lcr = 0x00, -- Line Control Register
        ier = 0x00, -- Interrupt enable Register
        iir = 0x00, -- Interrupt Identification Register
        mcr = 0x00, -- Modem Control Register
        lsr = 0x00, -- Line Status Register
        msr = 0x00, -- Modem Status Register
        fcr = 0x00, -- First In First Out Control Register
        scratch = 0x00, -- Scratch Register
        thr = 0x00, -- Transmitter Holding Register
        thr_empty = false,
        bits = 0,
        data_bits = 0,
        dlab = 0x00,
        data = 0x00,
        send_data = 0x00,
        int_status = 0x00,
        irq = irq,
        pic = self.pic,
        xmit_fifo = require("emulator:util/fifo").new(16),
        rcvr_fifo = require("emulator:util/fifo").new(16)
    }

    serial_port.transmit_timer = scheduler:add(transmit_callback_1, serial_port, false)
    serial_port.receive_timer = scheduler:add(receive_callback, serial_port, false)
    serial_port.timeout_timer = scheduler:add(timeout_callback, serial_port, false)

    cpu_io:set_port(base_port, port_0_out, port_0_in)
    cpu_io:set_port(base_port + 1, port_1_out, port_1_in)
    cpu_io:set_port(base_port + 2, port_2_out, port_2_in)
    cpu_io:set_port(base_port + 3, port_3_out, port_3_in)
    cpu_io:set_port(base_port + 4, port_4_out, port_4_in)
    cpu_io:set_port(base_port + 5, port_5_out, port_5_in)
    cpu_io:set_port(base_port + 6, port_6_out, port_6_in)
    cpu_io:set_port(base_port + 7, port_7_out, port_7_in)
    cpu_io:set_function_argument_range(base_port, base_port + 7, serial_port)

    update_timings(serial_port)

    self.ports[index] = serial_port
end

local function write(self, port, val)
    local serial_port = self.ports[port]

    if serial_port and band(serial_port.mcr, MCR_LOOP) == 0 then
        serial_port.send_data = band(val, 0xFF)
        self.receive_timer:period_start(self.transmit_period)
    end
end

local function get_port_handler(self, port)
    local serial_port = self.ports[port]

    if serial_port then
        return serial_port.handler
    end

    return nil
end

local function set_port_handler(self, port, handler)
    local serial_port = self.ports[port]

    if serial_port then
        serial_port.handler = handler
    end
end

local function reset(self)
    for i = 1, #self.ports, 1 do
        local port = self.ports[i]

        port.lcr = 0x00
        port.ier = 0x00
        port.iir = 0x01 -- No interrupts pending
        port.mcr = 0x00
        port.lsr = 0x60 -- THR and TXSR are empty.
        port.msr = 0x00
        port.fcr = 0x06
        port.dlab = 96
        port.scratch = 0x00
        port.data = 0x00
        port.send_data = 0xFFFF
        port.fifo_enabled = false
        port.txsr_empty = true
        port.thr_empty = true
        port.irq_state = false
        port.xmit_fifo:reset()
    end
end

function serial.new(cpu, pic, ports, irqs)
    local self = {
        pic = pic,
        ports = {},
        get_port_handler = get_port_handler,
        set_port_handler = set_port_handler,
        write = write,
        reset = reset
    }

    local cpu_io = cpu:get_io()
    local scheduler = cpu:get_scheduler()

    for i = 1, math.min(#ports, #irqs), 1 do
        create_port(self, cpu_io, scheduler, ports[i], irqs[i], i)
    end

    return self
end

return serial
