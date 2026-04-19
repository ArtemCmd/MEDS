local event = require("emulator:events")
local band, bor, rshift, lshift, bxor = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor

local screen = {
    EVENTS = {
        SET_RESOLUTION = 1,
        SET_SCALE = 2
    }
}

local function get_pixel_rgb_i(self, index)
    local offset = lshift(index, 2) + 1
    return bor(lshift(self.buffer[offset], 16), bor(lshift(self.buffer[offset + 1], 8), self.buffer[offset + 2]))
end

local function set_pixel_rgb_i(self, index, color)
    local temp = band(rshift(color, 16), 0xFF)
    temp = bor(temp, band(color, 0x00FF00))
    temp = bor(temp, lshift(band(color, 0x0000FF), 16))
    temp = bor(temp, 0xFF000000)

    self.buffer4[index + 1] = temp
end

local function fill_rgb_i(self, index, length, color)
    local temp = band(rshift(color, 16), 0xFF)
    temp = bor(temp, band(color, 0x00FF00))
    temp = bor(temp, lshift(band(color, 0x0000FF), 16))
    temp = bor(temp, 0xFF000000)

    for i = 1, length, 1 do
        self.buffer4[index + i] = temp
    end
end

local function get_resolution(self)
    return self.width, self.height
end

local function set_resolution(self, width, height)
    if (width > self.width) or (height > self.height) then
        self.buffer = Bytearray(width * height * 4)
        self.buffer4 = U32view(self.buffer)
    end

    self.width = width
    self.height = height
    self.events:emit(screen.EVENTS.SET_RESOLUTION, width, height, self.scale_x, self.scale_y)
end

local function get_scale(self)
    return self.scale_x, self.scale_y
end

local function set_scale(self, x, y)
    self.scale_x = x
    self.scale_y = y
    self.events:emit(screen.EVENTS.SET_SCALE, x, y)
end

local function update(self) end

local function reset(self)
    for i = 1, self.width * self.height, 1 do
        self.buffer4[i] = 0x00000000
    end
end

function screen.new()
    local self = {
        events = event.new(),
        buffer = Bytearray(640 * 200 * 4),
        width = 640,
        height = 200,
        scale_x = 1.0,
        scale_y = 1.0,
        update = update,
        get_resolution = get_resolution,
        set_resolution = set_resolution,
        get_scale = get_scale,
        set_scale = set_scale,
        get_pixel_rgb_i = get_pixel_rgb_i,
        set_pixel_rgb_i = set_pixel_rgb_i,
        fill_rgb_i = fill_rgb_i,
        reset = reset
    }

    self.buffer4 = U32view(self.buffer)

    return self
end

return screen
