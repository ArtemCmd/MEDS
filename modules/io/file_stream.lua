local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

local module = {}
local files = {}

local function check(self)
    if not self:is_open() then
        error("stream is closed")
    end
end

local function is_open(self)
    return not self.closed
end

local function get_position(self)
    return self.position - 1
end

local function set_position(self, val)
    self.position = val + 1
end

local function advance(self, offset)
    local old = self.position
    self.position = self.position + offset
    return old - 1
end

local function read_bytes(self, count)
    check(self)

    if not count then
        return self.buffer
    end

    local buffer = {}

    for i = 1, count, 1 do
        buffer[i] = self.buffer[self.position]
        self.position = self.position + 1
    end

    return buffer
end

local function read_bytes_zero_index(self, count)
    check(self)

    if not count then
        return self.buffer
    end

    local buffer = {}

    for i = 0, count - 1, 1 do
        buffer[i] = self.buffer[self.position]
        self.position = self.position + 1
    end

    return buffer
end

local function read_bytes_to_buffer(self, count, buffer)
    check(self)

    if not count then
        return
    end

    for i = 1, count, 1 do
        buffer[i] = self.buffer[self.position]
        self.position = self.position + 1
    end
end

local function read_bytes_to_buffer_zero(self, count, buffer)
    check(self)

    if not count then
        return
    end

    for i = 0, count - 1, 1 do
        buffer[i] = self.buffer[self.position]
        self.position = self.position + 1
    end
end

local function write_bytes(self, data)
    check(self)

    for i = 1, #data, 1 do
        self.buffer[self.position] = data[i]
        self.position = self.position + 1
    end
end

local function write_bytes_zero(self, data)
    check(self)

    for i = 0, #data - 1, 1 do
        self.buffer[self.position] = data[i]
        self.position = self.position + 1
    end
end

local function read_ascii(self, count)
    local result = {}

    for _ = 1, count, 1 do
        result[#result+1] = string.char(self:read8())
    end

    return table.concat(result)
end

local function write_ascii(self, str)
    for i = 1, #str, 1 do
        self:write8(string.byte(str, i, i))
    end
end

local function read_string(self)
    local count = self:read32_l()
    local result = {}

    for _ = 1, count, 1 do
        result[#result+1] = string.char(self:read8())
    end

    return table.concat(result)
end

local function write_string(self, str)
    self:write32_l(#str)

    for i = 1, #str, 1 do
        self:write8(string.byte(str, i, i))
    end
end

local function read8(self)
    check(self)
    local val = self.buffer[self.position]
    self.position = self.position + 1
    return val
end

local function write8(self, val)
    check(self)
    self.buffer[self.position] = val
    self.position = self.position + 1
end

local function read16_l(self)
    check(self)
    local low = self:read8()
    local high = self:read8()
    return bor(low, lshift(high, 8))
end

local function write16_l(self, val)
    check(self)
    self:write8(band(val, 0xFF))
    self:write8(band(rshift(val, 8), 0xFF))
end

local function read32_l(self)
    check(self)
    local low = self:read16_l()
    local high = self:read16_l()
    return bor(low, lshift(high, 16))
end

local function write32_l(self, val)
    check(self)
    self:write8(band(val, 0xFF))
    self:write8(band(rshift(val, 8), 0xFF))
    self:write8(band(rshift(val, 16), 0xFF))
    self:write8(band(rshift(val, 24), 0xFF))
end

local function close(self)
    if self:is_open() then
        self.closed = true
        self.buffer = nil
        self.path = nil
    end
end

local function flush(self)
    if not self:is_open() then
        error("stream is closed")
    end

    file.write_bytes(self.path, self.buffer)
end

function module.new(path, mode)
    local buffer

    if mode == "r" then
        if files[path] then
            buffer = files[path]
        elseif file.exists(path) then
            buffer = file.read_bytes(path)
        else
            error(string.format("file \"%s\" not found", path))
        end
    elseif mode == "w" then
        if file.is_writeable(path) then
            buffer = {}
            files[path] = buffer
        else
            error(string.format("file \"%s\" is read-only", path))
        end
    else
        error("invalid mode: " .. mode)
    end

    local self = {
        buffer = buffer,
        path = path,
        position = 1,
        closed = false,
        is_open = is_open,
        get_position = get_position,
        set_position = set_position,
        advance = advance,
        read_bytes = read_bytes,
        read_bytes_to_buffer = read_bytes_to_buffer,
        read_bytes_to_buffer_zero = read_bytes_to_buffer_zero,
        read_bytes_zero_index = read_bytes_zero_index,
        write_bytes = write_bytes,
        write_bytes_zero = write_bytes_zero,
        read_ascii = read_ascii,
        write_ascii = write_ascii,
        read_string = read_string,
        write_string = write_string,
        read8 = read8,
        write8 = write8,
        read16_l = read16_l,
        write16_l = write16_l,
        read32_l = read32_l,
        write32_l = write32_l,
        flush = flush,
        close = close
    }

    return self
end

return module
