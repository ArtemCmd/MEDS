-- =====================================================================================================================================================================
-- PC Speaker emulation.
-- =====================================================================================================================================================================

local speaker = {}

local SPEAKER_FREQ        = 48000
local SPEAKER_UPDATE_FREQ = 50

local BUFFER_LEN = SPEAKER_FREQ / SPEAKER_UPDATE_FREQ

local function update(self)
    self.updated = (self.gated and self.was_enable) or self.was_enable

    if self.buffer_position >= self.position then
        return
    end

    local amplitude = ((self.channel_count / 256.0) * 10240.0) - 5120.0

    if amplitude > 5120.0 then
        amplitude = 5120.0
    end

    local buffer = I16view(self.buffer)

    for i = self.buffer_position, self.position - 1, 1 do
        local val

        if self.gated and self.was_enable then
            if (self.channel_mode == 0) or (self.channel_mode == 4) then
                val = math.floor(amplitude)
            elseif self.channel_count < 64 then
                val = 0xA000
            elseif self.channel_out then
                val = 0x1400
            else
                val = 0x0000
            end
        else
            if self.was_enable then
                if self.channel_mode == 1 then
                    val = math.floor(amplitude)
                else
                    val = 0x1400
                end
            else
                val = 0x0000
            end
        end

        if not self.enabled then
            self.was_enable = false
        end

        buffer[self.offset + i + 1] = val
        self.buffer_position = i
    end
end

local function poll(self)
    self.timer:advance(self.delay)
    self.position = self.position + 1

    if self.position == BUFFER_LEN then
        update(self)

        if self.updated then
            self.stream:feed(self.buffer)
            self.updated = false
        end

        self.position = 0
        self.buffer_position = 0
    end
end

local function set_clock(self, clock)
    self.delay = math.floor(self.timer.scheduler.NANOSECOND * (1000000 / SPEAKER_FREQ))
end

local function get_handler(self)
    return self.handler
end

local function set_handler(self, handler)
    self.handler = handler
end

local function reset(self)
    self.channel_out = false
    self.channel_count = 0xFFFF
    self.channel_mode = 0
    self.enabled = false
    self.gated = false
    self.channel_out = false
    self.ppi_enabled = false
    self.timer:set_delay(self.delay)
end

function speaker.new(pit, cpu)
    local buffer = Bytearray(BUFFER_LEN * 2)
    local self = {
        buffer = buffer,
        stream = audio.PCMStream(SPEAKER_FREQ, 1, 16),
        offset = 0,
        buffer_position = 0,
        position = 0,
        delay = 0,
        channel_mode = 0,
        channel_count = 0xFFFF,
        channel_out = false,
        enabled = false,
        ppi_enabled = false,
        gated = false,
        set_clock = set_clock,
        get_handler = get_handler,
        set_handler = set_handler,
        update = update,
        reset = reset
    }

    self.stream:share("computer/pc_speaker")
    audio.play_stream_2d("computer/pc_speaker", 1.0, 1.0, "regular", false)

    pit:set_channel_out_handler(2, function(out, old_out)
        update(self)

        local count = pit:get_channel_count(2)

        if count == 0 then
            count = 0x10000
        end

        if count < 25 then
            self.channel_out = false
        else
            self.channel_out = out
        end

        self.ppi_enabled = out
    end)

    pit:set_channel_load_handler(2, function(mode, count)
        self.channel_count = count
        self.channel_mode = mode
    end)

    self.timer = cpu:get_scheduler():add(poll, self, false)

    return self
end

return speaker
