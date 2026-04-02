local logger = require("dave_logger:logger")("MEDS")
local filesystem = require("emulator:io/filesystem")

local band, bor, rshift, lshift, bxor = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor

local memory = {}

local function read8(self, addr)
    return self.data[band(addr, self.mask)]
end

local function write8(self, addr, val)
    self.data[band(addr, self.mask)] = val
end

local function read16_l(self, addr)
    return bor(self:read8(addr), lshift(self:read8(addr + 1), 8))
end

local function write16_l(self, addr, val)
    self:write8(addr, band(val, 0xFF))
    self:write8(addr + 1, band(rshift(val, 8), 0xFF))
end

local function read32_l(self, addr)
    return bor(bor(bor(self:read8(addr), lshift(self:read8(addr + 1), 8)), lshift(self:read8(addr + 2), 16)), lshift(self:read8(addr + 3), 32))
end

local function write32_l(self, addr, val)
    self:write8(addr, band(val, 0xFF))
    self:write8(addr + 1, band(rshift(val, 8), 0xFF))
    self:write8(addr + 2, band(rshift(val, 16), 0xFF))
    self:write8(addr + 3, band(rshift(val, 24), 0xFF))
end

local function write_bytes(self, addr, bytes)
    for i = 0, #bytes - 1, 1 do
        self:write8(addr + i, bytes[i + 1])
    end
end

local function load_rom(self, addr, path)
    local stream = filesystem.open(path, "r")

    if stream then
        self:write_bytes(addr, stream:read_bytes())
    else
        logger:error("ROM \"%s\" not found", path)
    end
end

local function reset(self)
    for i = 0, self.size - 1, 1 do
        self:write8(i, 0x00)
    end
end

function memory.new(size, mask)
    local self = {
        mask = mask or (size - 1),
        size = size,
        data = {},
        read8 = read8,
        write8 = write8,
        read16_l = read16_l,
        write16_l = write16_l,
        read32_l = read32_l,
        write32_l = write32_l,
        write_bytes = write_bytes,
        load_rom = load_rom,
        reset = reset
    }

    return self
end

return memory
