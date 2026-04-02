-- =====================================================================================================================================================================
-- Okean 240 Videocard emulation.
-- =====================================================================================================================================================================

-- TODO: Recalculate timings

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local video = {}

local palette_color = {
    [0] = {[0] = 0x000000, 0xFF0000, 0x00FF00, 0x0000FF},
    {[0] = 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF},
    {[0] = 0xFF0000, 0x00FF00, 0xFF0000, 0xFFFF00},
    {[0] = 0x000000, 0xFF0000, 0xBF00FF, 0xFFFFFF},
    {[0] = 0x000000, 0xFF0000, 0xFFFF00, 0x0000FF},
    {[0] = 0x000000, 0x0000FF, 0x00FF00, 0xFFFF00},
    {[0] = 0xFF0000, 0xFFFFFF, 0xFFFF00, 0x0000FF},
    {[0] = 0x000000, 0x000000, 0x000000, 0x000000}
}

local palette_mono = {
    [0] = {[0] = 0xFFFFFF, 0x000000},
	{[0] = 0x00007F, 0x00FF00},
	{[0] = 0xFF0000, 0x7F0000},
	{[0] = 0xCF00CF, 0x0000FF},
	{[0] = 0x007F00, 0xBF00FF},
	{[0] = 0x004B96, 0xFFFF00},
	{[0] = 0xFF4000, 0x000000},
	{[0] = 0x7F7F7F, 0x7F7F7F}
}

local function get_vram(self)
    return self.vram
end

local function render_mono(self)
    self.timer:advance(self.delay)

    for i = 0, 255, 1 do
        local addr = i
        local offset_y = lshift(band(i - self.vertical_offset, 0xFF), 9)

        for j = 0, 511, 1 do
            local offset_x = lshift(self.horizontal_scroll, 9)
            local color = band(rshift(self.vram[addr], band(j, 0x07)), 0x01)

            if band(j, 0x07) == 0x07 then
                addr = addr + 0x100
            end

            self.screen:set_pixel_rgb_i(offset_y + offset_x + i, self.palette[color])
        end
    end

    self.screen:update()
end

local function render_color(self)
    self.timer:advance(self.delay)

    for i = 0, 255, 1 do
        local addr = i
        local offset_y = lshift(band(i - self.vertical_offset, 0xFF), 8)

        for j = 0, 255, 1 do
            local offset_x = lshift(self.horizontal_scroll, 8)
            local bit = band(j, 0x07)
            local color = lshift(band(rshift(self.vram[addr], bit), 0x01), 1)
            color = bor(color, band(rshift(self.vram[bor(addr, 0x100)], bit), 0x01))

            if band(j, 0x07) == 0x07 then
                addr = addr + 0x200
            end

            self.screen:set_pixel_rgb_i(offset_y + offset_x + j, self.palette[color])
        end
    end

    self.screen:update()
end

local function update_mode(self, val)
    local palette

    self.screen.scale_y = 2.0

    if band(val, 0x40) ~= 0 then
        palette = palette_color
        self.timer.callback = render_color
        self.screen.scale_x = 2.0
        self.screen:set_resolution(256, 256)
    else
        palette = palette_mono
        self.timer.callback = render_mono
        self.screen.scale_x = 1.0
        self.screen:set_resolution(512, 256)
    end

    self.palette = palette[band(val, 0x07)]
end

local function get_type(self)
    return 0
end

local function set_clock(self)
    self.delay = math.floor(300000 * self.timer.scheduler.USEC)
end

local function reset(self)
    self.palette = palette_mono[0]
    self.vram_offset = 0
    self.render = render_mono
    self.screen:set_scale(1.0, 1.0)
    self.screen:set_resolution(512, 256)
    self.timer:set_delay(self.delay)
end

function video.new(cpu, screen)
    local self = {
        screen = screen,
        vram = {},
        palette = palette_mono[0],
        delay = 150,
        current_line = 0,
        vram_offset = 0,
        vertical_offset = 0,
        horizontal_scroll = 0,
        set_clock = set_clock,
        update_mode = update_mode,
        get_vram = get_vram,
        get_type = get_type,
        reset = reset
    }

    for i = 0, 16383, 1 do
        self.vram[i] = 0x00
    end

    self.timer = cpu:get_scheduler():add(render_mono, self, false)

    return self
end

return video
