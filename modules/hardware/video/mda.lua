-- =====================================================================================================================================================================
-- IBM Monochrome Display Adapter (MDA) emulation.
-- =====================================================================================================================================================================

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local mda = {}

local font_9_14 = file.read_bytes("emulator:roms/video/mda.bin", false)
local palette = {
    [0] = {0x000000, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0x000000, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0x000000, 0xAAAAAA},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0x000000, 0xAAAAAA},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0x000000, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0x000000, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0x000000, 0xAAAAAA},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0xAAAAAA, 0x000000},
    {0x000000, 0xAAAAAA},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000},
    {0xFFFFFF, 0x000000}
}


local function update_timings(self)
    self.delay_off = math.floor(((self.crtc_horizontal_total + 1) - self.crtc_horizontal_displayed) * self.clock)
    self.delay_on = math.floor(self.crtc_horizontal_displayed * self.clock)
end

local crtc_regs_write = {
    [0x00] = function(self, val) -- Horizontal Total Register
        self.crtc_horizontal_total = val
        update_timings(self)
    end,
    [0x01] = function(self, val) -- Horizontal Displayed Register
        self.crtc_horizontal_displayed = val
        update_timings(self)
    end,
    [0x02] = function(self, val) -- Horizontal Sync Position Register
    end,
    [0x03] = function(self, val) -- Horizontal Sync Pulse Width Register
    end,
    [0x04] = function(self, val) -- Vertical Total Register
        self.crtc_vertical_total = band(val, 0x7F)
    end,
    [0x05] = function(self, val) -- Vertical Total Adjust Register
    end,
    [0x06] = function(self, val) -- Vertical Displayed Register
        self.crtc_vertical_displayed = band(val, 0x7F)
    end,
    [0x07] = function(self, val) -- Vertical Sync Register
        self.crtc_vsync = band(val, 0x7F)
    end,
    [0x08] = function(self, val) -- Interlase Mode Register
    end,
    [0x09] = function(self, val) -- Max Scan Line Register
        self.crtc_max_scanline = band(val, 0x1F)
    end,
    [0x0A] = function(self, val) -- Cursor Start Register
        self.crtc_cursor_start = band(val, 0x1F)
    end,
    [0x0B] = function(self, val) -- Cursor End Register
        self.crtc_cursor_end = band(val, 0x1F)
    end,
    [0x0C] = function(self, val) -- Start Address Register High
        self.crtc_start_addr = bor(band(self.crtc_start_addr, 0x00FF), lshift(band(val, 0x3F), 8))
    end,
    [0x0D] = function(self, val) -- Start Address Register Low
        self.crtc_start_addr = bor(band(self.crtc_start_addr, 0xFF00), val)
    end,
    [0x0E] = function(self, val) -- Cursor Location Register High
        self.crtc_cursor_addr = bor(band(self.crtc_cursor_addr, 0x00FF), lshift(val, 8))
    end,
    [0x0F] = function(self, val) -- Cursor Location Register Low
        self.crtc_cursor_addr = bor(band(self.crtc_cursor_addr, 0xFF00), val)
    end
}

local crtc_regs_read = {
    [0x0E] = function(self)
        return band(rshift(self.crtc_cursor_addr, 8), 0xFF)
    end,
    [0x0F] = function(self)
        return band(self.crtc_cursor_addr, 0xFF)
    end
}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- VRAM
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function vram_read(self, addr)
    return self[band(addr, 0xFFF)]
end

local function vram_write(self, addr, val)
    self[band(addr, 0xFFF)] = val
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Ports
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function port_crtc_address_out(self, cpu, port, val)
    self.crtc_index = band(val, 0x1F)
end

local function port_crtc_address_in(self, cpu, port)
    return self.crtc_index
end

local function port_crtc_data_out(self, cpu, port, val)
    local reg = crtc_regs_write[self.crtc_index]

    if reg then
        reg(self, val)
    end
end

local function port_crtc_data_in(self, cpu, port)
    local reg = crtc_regs_read[self.crtc_index]

    if reg then
        return reg(self)
    end

    return 0xFF
end

local function port_mode_register_out(self, cpu, port, val)
    self.video_enable = band(val, 0x08) ~= 0
    self.blink_char_enable = band(val, 0x20) ~= 0
end

local function port_status_in(self, cpu, port)
    return self.status
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Render
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local update_2

local function update_1(self)
    self.status = bor(self.status, 0x01)

    if self.display_on and self.video_enable then
        local screen_buffer_index = self.current_line * 720

        for x = 0, 719, 9 do
            local chr = self.vram[band(lshift(self.address, 1), 0xFFF)]
            local attr = self.vram[band(lshift(self.address, 1) + 1, 0xFFF)]
            local glyph_row = font_9_14[lshift(self.scanline, 8) + chr + 1]
            local draw_cursor = (self.crtc_cursor_addr == self.address) and self.cursor_enable and self.cursor_visible
            local blink = self.blink_enabled and self.blink_char_enable and (band(attr, 0x80) ~= 0) and (not draw_cursor)
            local colors = palette[attr]
            local foreground
            local background

            if blink or draw_cursor then
                foreground = colors[2]
                background = colors[1]
            else
                foreground = colors[1]
                background = colors[2]
            end

            if (self.scanline == 12) and (band(attr, 0x07) == 0x01) then -- Underline
                for i = 0, 8, 1 do
                    self.screen:set_pixel_rgb_i(screen_buffer_index + x + i, foreground)
                end
            else
                local color

                for i = 0, 7, 1 do
                    if (band(glyph_row, rshift(0x80, band(i, 0x07))) ~= 0) then
                        color = foreground
                    else
                        color = background
                    end

                    self.screen:set_pixel_rgb_i(screen_buffer_index + x + i, color)
                end

                if band(chr, 0xE0) == 0xC0 then
                    self.screen:set_pixel_rgb_i(screen_buffer_index + x + 8, color)
                else
                    self.screen:set_pixel_rgb_i(screen_buffer_index + x + 8, background)
                end
            end

            self.address = self.address + 1
        end
    elseif self.display_on then
        local index = self.current_line * 720

        for x = 0, 719, 1 do
            self.screen:set_pixel_rgb_i(index + x, 0x000000)
        end
    end

    if (self.vlc == self.crtc_vsync) and (self.scanline == 0) then
        self.status = bor(self.status, 0x08)
    end

    self.current_line = self.current_line + 1

    if self.current_line >= 500 then
        self.current_line = 0
    end

    self.timer.callback = update_2
    self.timer:advance(self.delay_off)
end

update_2 = function(self)
    if self.display_on then
        self.status = band(self.status, bnot(0x01))
    end

    if self.vsync_time > 0 then
        self.vsync_time = self.vsync_time - 1

        if self.vsync_time == 0 then
            self.status = band(self.status, bnot(0x08))
        end
    end

    if self.scanline == self.crtc_cursor_end then
        self.cursor_visible = false
    end

    if self.scanline == self.crtc_max_scanline then
        local old_vlc = self.vlc

        self.start_address = self.address
        self.scanline = 0
        self.vlc = band(self.vlc + 1, 0x7F)

        if self.vlc == self.crtc_vertical_displayed then
            self.display_on = false
        end

        if old_vlc == self.crtc_vertical_total then
            self.vlc = 0
            self.display_on = true
            self.start_address = self.crtc_start_addr
            self.address = self.start_address
            self.current_line = 0

            if band(self.crtc_cursor_start, 0x60) == 0x20 then
                self.cursor_enable = false
            else
                self.cursor_enable = band(self.blink, 0x10) ~= 0
            end
        end

        if self.vlc == self.crtc_vsync then
            self.current_line = 0
            self.vsync_time = 16
            self.display_on = false
            self.blink = band(self.blink + 1, 0x7F)
            self.blink_enabled = band(self.blink, 0x10) ~= 0

            if self.crtc_vsync > 0 then
                self.screen:update()
            end
        end
    else
        self.scanline = band(self.scanline + 1, 0x1F)
        self.address = self.start_address
    end

    if self.scanline == self.crtc_cursor_start then
        self.cursor_visible = true
    end

    self.timer.callback = update_1
    self.timer:advance(self.delay_on)
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function set_clock(self, clock)
    self.clock = clock
    update_timings(self)
end

local function get_type(self)
    return require("emulator:hardware/video/common").TYPE.MDA
end

local function reset(self)
    self.crtc_index = 0
    self.crtc_horizontal_total = 0x61
    self.crtc_horizontal_displayed = 0x50
    self.crtc_vertical_total = 0x19
    self.crtc_vertical_displayed = 0x19
    self.crtc_vsync = 0x19
    self.crtc_max_scanline = 0x0D
    self.crtc_cursor_start = 0
    self.crtc_cursor_end = 0
    self.crtc_start_addr = 0
    self.crtc_cursor_addr = 0
    self.status = 0xF0
    self.current_line = 0
    self.scanline = 0
    self.vlc = 0
    self.address = 0
    self.start_address = 0
    self.blink = 0
    self.delay_off = 136
    self.delay_on = 640
    self.vsync_time = 0
    self.blink_enabled = false
    self.blink_char_enable = false
    self.video_enable = true
    self.display_on = false
    self.cursor_enable = false
    self.cursor_visible = false

    self.timer.callback = update_1
    self.timer:set_delay(self.delay_off)

    self.screen:set_scale(1.0, 1.0)
    self.screen:set_resolution(720, 350)
end

function mda.new(cpu, memory, screen)
    local self = {
        screen = screen,
        crtc_index = 0,
        crtc_horizontal_total = 0x61,
        crtc_horizontal_displayed = 0x50,
        crtc_vertical_total = 0x19,
        crtc_vertical_displayed = 0x19,
        crtc_vsync = 0x19,
        crtc_max_scanline = 0x0D,
        crtc_cursor_start = 0,
        crtc_cursor_end = 0,
        crtc_start_addr = 0,
        crtc_cursor_addr = 0,
        status = 0xF0,
        current_line = 0,
        scanline = 0,
        vlc = 0,
        address = 0,
        start_address = 0,
        blink = 0,
        delay_on = 640,
        delay_off = 136,
        clock = 8,
        vsync_time = 0,
        display_on = false,
        vertical_beam = true,
        blink_enabled = false,
        video_enable = false,
        blink_char_enable = false,
        cursor_enable = false,
        cursor_visible = false,
        vram = {},
        set_clock = set_clock,
        get_type = get_type,
        reset = reset
    }

    local cpu_io = cpu:get_io()

    cpu_io:set_port(0x3B0, port_crtc_address_out, port_crtc_address_in)
    cpu_io:set_port(0x3B1, port_crtc_data_out, port_crtc_data_in)
    cpu_io:set_port(0x3B2, port_crtc_address_out, port_crtc_address_in)
    cpu_io:set_port(0x3B3, port_crtc_data_out, port_crtc_data_in)
    cpu_io:set_port(0x3B4, port_crtc_address_out, port_crtc_address_in)
    cpu_io:set_port(0x3B5, port_crtc_data_out, port_crtc_data_in)
    cpu_io:set_port(0x3B6, port_crtc_address_out, port_crtc_address_in)
    cpu_io:set_port(0x3B7, port_crtc_data_out, port_crtc_data_in)
    cpu_io:set_port_out(0x3B8, port_mode_register_out)
    cpu_io:set_port(0x3B9, port_crtc_data_out, port_crtc_data_in)
    cpu_io:set_port_in(0x3BA, port_status_in)

    cpu_io:set_function_argument_range(0x3B0, 0x3B7, self)
    cpu_io:set_out_function_argument(0x3B8, self)
    cpu_io:set_function_argument(0x3B9, self)
    cpu_io:set_in_function_argument(0x3BA, self)

    for i = 0, 0xFFF, 1 do
        self.vram[i] = 0x00
    end

    memory:add_mapping(0xB0000, 0x8000, vram_read, vram_write, self.vram)

    self.timer = cpu:get_scheduler():add(update_1, self, false)

    return self
end

return mda
