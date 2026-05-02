-- =====================================================================================================================================================================
-- Programmable Interval Timer emulation.
-- =====================================================================================================================================================================

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local pit = {}

local CHANNEL_MODE_TERMINAL_COUNT = 0 -- Interrupt On Terminal Count.
local CHANNEL_MODE_ONE_SHOT = 1       -- Hardware Re-triggerable One-shot.
local CHANNEL_MODE_RATE = 2           -- Rate Generator.
local CHANNEL_MODE_SQUARE_WAVE = 3    -- Square Wave Generator.
local CHANNEL_MODE_SSTROBE = 4        -- Software Triggered Strobe.
local CHANNEL_MODE_HSTROBE = 5        -- Hardware Triggered Strobe.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Channel
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function channel_create(self, channel_num)
    self.channels[channel_num] = {
        count = 0,
        clock = 0,
        reload = 0,
        load = 0xFFFF,
        mode = 0,
        read_mode = 0,
        write_mode = 0,
        rlatch = false,
        thit = true,
        gate = false,
        out = false,
        new_count = false,
        latched = false,
        initial = false,
        enabled = false,
        disabled = false,
        running = false
    }
end

local function channel_reset(channel)
    channel.count = 0x0000
    channel.reload = 0x0000
    channel.load = 0x0000
    channel.mode = 0
    channel.read_mode = 0
    channel.write_mode = 0
    channel.rlatch = false
    channel.thit = true
    channel.out = false
    channel.new_count = false
    channel.latched = false
    channel.initial = false
    channel.enabled = false
    channel.running = false
    channel.timer:reset()
end

local function channel_get_count(channel)
    if (not ((channel.mode == CHANNEL_MODE_SQUARE_WAVE) and (not channel.gate))) and channel.timer.enabled then
        local count = math.floor(channel.timer:get_remaining() / channel.clock)

        if channel.mode == CHANNEL_MODE_RATE then
            count = count + 1
        end

        if count < 0 then
            count = 0
        end

        if count > 0x10000 then
            count = 0x10000
        end

        if channel.mode == CHANNEL_MODE_SQUARE_WAVE then
            count = lshift(count, 1)
        end

        return count
    end

    if channel.mode == CHANNEL_MODE_RATE then
        return channel.count + 1
    end

    return channel.count
end

local function channel_disable(channel)
    if channel.timer.enabled then
        channel.count = channel_get_count(channel)

        if channel.mode == CHANNEL_MODE_RATE then
            channel.count = channel.count - 1
        end

        channel.timer:disable()
    end
end

local function channel_out(channel, out)
    if channel.out_handler then
        channel.out_handler(out, channel.out)
    end

    channel.out = out
end

local channel_load_mode = {
    [CHANNEL_MODE_TERMINAL_COUNT] = function(channel, count)
        channel.count = count
        channel.timer:set_delay(count * channel.clock, 0)
        channel.enabled = channel.gate
        channel.thit = false
        channel_out(channel, false)
    end,
    [CHANNEL_MODE_ONE_SHOT] = function(channel, count)
        channel.enabled = true
    end,
    [CHANNEL_MODE_RATE] = function(channel, count)
        if channel.initial then
            channel.count = count - 1
            channel.thit = false
            channel.timer:set_delay((count - 1) * channel.clock, 0)
            channel_out(channel, true)
        end

        channel.enabled = channel.gate
    end,
    [CHANNEL_MODE_SQUARE_WAVE] = function(channel, count)
        if channel.initial then
            channel.count = count
            channel.thit = false
            channel.timer:set_delay(rshift(count + 1, 1) * channel.clock, 0)
            channel_out(channel, true)
        end

        channel.enabled = channel.gate
    end,
    [CHANNEL_MODE_SSTROBE] = function(channel, count)
        if (not channel.thit) and (not channel.initial) then
            channel.new_count = true
        else
            channel.count = count
            channel.thit = false
            channel.timer:set_delay(count * channel.clock, 0)
            channel_out(channel, false)
        end

        channel.enabled = channel.gate
    end,
    [CHANNEL_MODE_HSTROBE] = function(channel, count)
        channel.enabled = true
    end
}

local function channel_load(channel)
    local count = channel.load

    if count == 0 then
        count = 0x10000
    end

    channel.new_count = false
    channel.disabled = false

    channel_load_mode[channel.mode](channel, count)

    if channel.load_handler then
        channel.load_handler(channel.mode, count)
    end

    channel.initial = false
    channel.running = channel.enabled and (not channel.disabled)

    if not channel.running then
        channel_disable(channel)
    end
end

local function channel_clock(self)
    if self.disabled then
        self.count = self.count + 0xFFFF
        self.timer:advance(0xFFFF * self.clock)
        return
    end

    local count = self.load

    if count == 0 then
        count = 0x10000
    end

    if (self.mode == CHANNEL_MODE_TERMINAL_COUNT) or (self.mode == CHANNEL_MODE_ONE_SHOT) then
        if not self.thit then
            channel_out(self, true)
        end

        self.thit = true
        self.count = self.count + 0xFFFF
        self.timer:advance(0xFFFF * self.clock)
    elseif self.mode == CHANNEL_MODE_RATE then
        self.count = self.count + count
        self.timer:advance(count * self.clock)

        channel_out(self, false)
        channel_out(self, true)
    elseif self.mode == CHANNEL_MODE_SQUARE_WAVE then
        if self.out then
            channel_out(self, false)
            self.count = self.count + rshift(count, 1)
            self.timer:advance(rshift(count, 1) * self.clock)
        else
            channel_out(self, true)
            self.count = self.count + rshift(count + 1, 1)
            self.count = self.count + rshift(count, 1)
            self.timer:advance(rshift(count + 1, 1) * self.clock)
        end
    elseif self.mode == CHANNEL_MODE_SSTROBE then
        if not self.thit then
            channel_out(self, false)
            channel_out(self, true)
        end

        if self.new_count then
            self.new_count = false
            self.count = self.count + count
            self.timer:advance(count * self.clock, 0)
        else
            self.thit = true
            self.count = self.count + 0xFFFF
            self.timer:advance(0xFFFF * self.clock, 0)
        end
    elseif self.mode == CHANNEL_MODE_HSTROBE then
        if not self.thit then
            channel_out(self, false)
            channel_out(self, true)
        end

        self.thit = true
        self.count = self.count + 0xFFFF
        self.timer:advance(0xFFFF * self.clock, 0)
    end

    self.running = self.enabled and (not self.disabled)

    if not self.running then
        channel_disable(self)
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Ports
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local read_modes = {
    [0x00] = function(channel)
        channel.read_mode = 3
        channel.latched = false
        channel.rlatch = true

        return band(rshift(channel.reload, 8), 0xFF)
    end,
    [0x01] = function(channel)
        channel.latched = false
        channel.rlatch = true

        return band(channel.reload, 0xFF)
    end,
    [0x02] = function(channel)
        channel.latched = false
        channel.rlatch = true

        return band(rshift(channel.reload, 8), 0xFF)
    end,
    [0x03] = function(channel)
        if band(channel.mode, 0x80) ~= 0 then
            channel.mode = band(channel.mode, 0x07)
        else
            channel.read_mode = 0x00
        end

        return band(channel.reload, 0xFF)
    end
}

local write_modes = {
    [0x00] = function(self, channel, val)
        channel.load = bor(band(channel.load, 0x00FF), lshift(val, 8))
        channel.write_mode = 0x03
        channel_load(channel)
    end,
    [0x01] = function(self,channel, val)
        channel.load = val
        channel_load(channel)
    end,
    [0x02] = function(self, channel, val)
        channel.load = lshift(val, 8)
        channel_load(channel)
    end,
    [0x03] = function(self, channel, val)
        channel.load = bor(band(channel.load, 0xFF00), val)
        channel.write_mode = 0x00
    end
}

local function port_out_channel(self, cpu, port, val)
    local channel = self.channels[band(port, 0x03)]

    cpu.cycles = cpu.cycles - 8
    write_modes[channel.write_mode](self, channel, val)
end

local function port_channel_in(self, cpu, port)
    local channel = self.channels[band(port, 0x03)]

    cpu.cycles = cpu.cycles - 8

    if channel.rlatch and (not channel.latched) then
        channel.rlatch = false
        channel.reload = channel_get_count(channel)
    end

    return read_modes[channel.read_mode](channel)
end

local function port_control_out(self, cpu, port, val)
    cpu.cycles = cpu.cycles - 8

    local channel_num = rshift(val, 6)
    local channel = self.channels[channel_num]

    if band(val, 0x30) == 0 then
        channel.reload = channel_get_count(channel)
        channel.read_mode = 3
        channel.latched = true
        channel.rlatch = false
    else
        channel.read_mode = band(rshift(val, 4), 0x03)
        channel.write_mode = channel.read_mode
        channel.mode = band(rshift(val, 1), 0x07)

        if channel.mode > 5 then
            channel.mode = band(channel.mode, 0x03)
        end

        if channel.read_mode == 0 then
            channel.read_mode = 3
            channel.reload = channel_get_count(channel)
        end

        channel.rlatch = true
        channel.initial = true
        channel.disabled = true

        channel_out(channel, channel.mode ~= 0)
    end

    channel.thit = false
end

local function port_control_in(self, cpu, port)
    cpu.cycles = cpu.cycles - 8
    return 0x00
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function get_channel_gate(self, channel_num)
    local channel = self.channels[channel_num]

    if channel then
        return channel.gate
    end
end

local function set_channel_gate(self, channel_num, gate)
    local channel = self.channels[channel_num]

    if not channel then
        return
    end

    if channel.disabled then
        channel.gate = gate
        return
    end

    local count = channel.load
    local mode = channel.mode

    if count == 0 then
        count = 0x10000
    end

    if (mode == CHANNEL_MODE_TERMINAL_COUNT) or (mode == CHANNEL_MODE_SSTROBE) then
        if not channel.running then
            channel.timer:set_delay(count * channel.clock, 0)
        end

        channel.enabled = gate
    elseif (mode == CHANNEL_MODE_ONE_SHOT) or (mode == CHANNEL_MODE_HSTROBE) then
        if gate and (not channel.gate) then
            channel.count = count
            channel.thit = false
            channel.enabled = true
            channel.timer:set_delay(count * channel.clock, 0)
            channel_out(channel, false)
        end
    elseif mode == CHANNEL_MODE_RATE then
        if gate and (not channel.gate) then
            channel.count = count - 1
            channel.thit = false
            channel.timer:set_delay(count * channel.clock, 0)
            channel_out(channel, true)
        end

        channel.enabled = gate
    elseif mode == CHANNEL_MODE_SQUARE_WAVE then
        if gate and (not channel.gate) then
            channel.count = count
            channel.thit = false
            channel.timer:set_delay(rshift(count  + 1, 1) * channel.clock, 0)
            channel_out(channel, true)
        end

        channel.enabled = gate
    end

    channel.gate = gate
    channel.running = channel.enabled and (not channel.disabled)

    if not channel.running then
        channel_disable(channel)
    end
end

local function get_channel_count(self, chunnel_num)
    local channel = self.channels[chunnel_num]

    if channel then
        return channel.load
    end
end

local function set_channel_out_handler(self, channel_num, func)
    local channel = self.channels[channel_num]

    if channel then
        channel.out_handler = func
    end
end

local function set_channel_load_handler(self, channel_num, func)
    local channel = self.channels[channel_num]

    if channel then
        channel.load_handler = func
    end
end

local function set_clock(self, val)
    for i = 0, 2, 1 do
        self.channels[i].clock = val
    end
end

local function reset(self)
    channel_reset(self.channels[0])
    channel_reset(self.channels[1])
    channel_reset(self.channels[2])

    self.channels[0].gate = true
    self.channels[1].gate = true
    self.channels[2].gate = false
end

function pit.new(cpu, base_port)
    local self = {
        channels = {},
        set_clock = set_clock,
        set_channel_out_handler = set_channel_out_handler,
        set_channel_load_handler = set_channel_load_handler,
        get_channel_count = get_channel_count,
        get_channel_gate = get_channel_gate,
        set_channel_gate = set_channel_gate,
        reset = reset
    }

    channel_create(self, 0)
    channel_create(self, 1)
    channel_create(self, 2)

    local cpu_io = cpu:get_io()

    cpu_io:set_port(base_port, port_out_channel, port_channel_in)
    cpu_io:set_port(base_port + 1, port_out_channel, port_channel_in)
    cpu_io:set_port(base_port + 2, port_out_channel, port_channel_in)
    cpu_io:set_port(base_port + 3, port_control_out, port_control_in)
    cpu_io:set_function_argument_range(base_port, base_port + 3, self)

    self.channels[0].gate = true
    self.channels[1].gate = true

    local timer = cpu:get_scheduler()

    for i = 0, 2, 1 do
        local channel = self.channels[i]
        channel.timer = timer:add(channel_clock, channel, false)
    end

    return self
end

return pit
