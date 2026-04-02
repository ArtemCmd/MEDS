-- +--------------------------+--------+----------+
-- | HDF (Hard Disk File)     | Type   | Value    |
-- | Byteorder: Little-Endian |        |          |
-- +--------------------------+--------+----------+
-- | Signature                | ASCII  | "HDF"    |
-- | Version                  | uint16 |  0x0102  |
-- | Flags                    | uint8  |          |
-- | Sector size              | uint16 |          |
-- | Cylinders                | uint16 |          |
-- | Heads                    | uint16 |          |
-- | Sectors                  | uint16 |          |
-- | Sectors data             | Sectors|          |
-- +--------------------------+--------+----------+
--
-- +---------------------------------------------------------+
-- | Flags                                                   |
-- +-----------------------+--------+------------------------+
-- | Field                 | Bit    | Value                  |
-- +-----------------------+--------+------------------------+
-- | Type                  | 0      | 0 - Fixed, 1 - Dynamic |
-- | Compression Method    | 1 - 2  | 0 - None               |
-- | Reserved              | 3 - 7  | 0                      |
-- +-----------------------+--------+------------------------+
--
-- +-----------------------------------------+
-- | Sectors (only for dynamic type)         |
-- +-----------------------+---------+-------+
-- | Field                 | Type    | Value |
-- +-----------------------+---------+-------+
-- | Sectors count         | uint32  |       |
-- | Sector 1 id           | uint32  |       |
-- | Sector 1 data         | uint8[] |       |
-- | Sector 2 id           | uint32  |       |
-- | Sector 2 data         | uint8[] |       |
-- | Sector N id           | uint32  |       |
-- | Sector N data         | uint8[] |       |
-- | ...                   |         |       |
-- +-----------------------+---------+-------+
--
-- +-------------------------------------------+
-- | Sectors (only for fixed type)             |
-- +---------------------------------+---------+
-- | Raw Disk Data                   | uint8[] |
-- +---------------------------------+---------+

local filesystem = require("emulator:io/filesystem")
local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local hdf = {}

local HDF_SIGNATURE = {0x48, 0x44, 0x46}
local HDF_VERSION = 0x0201

local HDF_FLAG_DYNAMIC_SHIFT = 0
local HDF_FLAG_DYNAMIC_MASK = lshift(1, HDF_FLAG_DYNAMIC_SHIFT)
local HDF_FLAG_COMPRESSION_SHIFT = 1
local HDF_FLAG_COMPRESSION_MASK = lshift(0x03, HDF_FLAG_COMPRESSION_SHIFT)

local function hdf_dynamic_save(self)
    local stream = filesystem.open(self.path, "w")

    stream:write_bytes(HDF_SIGNATURE)
    stream:write16_l(HDF_VERSION)
    stream:write8(HDF_FLAG_DYNAMIC_MASK)
    stream:write_bytes(byteutil.pack(">HHHH", self.sector_size, self.cylinders, self.heads, self.sectors))
    stream:write32_l(self.sector_count)

    for id, data in pairs(self.sectors_table) do
        stream:write32_l(id)
        stream:write_bytes(data)
    end

    stream:flush()
    stream:close()
end

function hdf.create(path, cylinders, heads, sectors, sector_size, dynamic, compression)
    local stream = filesystem.open(path, "w")
    local disk_size = sector_size * cylinders * heads * sectors
    local disk_info = byteutil.pack(">HHHH", sector_size, cylinders, heads, sectors)
    local flags = 0

    if dynamic then
        flags = bor(flags, HDF_FLAG_DYNAMIC_MASK)
    end

    if compression then
        if compression == 0 then
            flags = bor(flags, lshift(compression, HDF_FLAG_COMPRESSION_SHIFT))
        else
            stream:close()
            error("invalid compression method")
        end
    end

    stream:write_bytes(HDF_SIGNATURE)
    stream:write16_l(HDF_VERSION)
    stream:write8(flags)
    stream:write_bytes(disk_info)

    if not dynamic then
        for _ = 1, disk_size, 1 do
            stream:write8(0)
        end
    else
        stream:write32_l(0)
    end

    stream:flush()
    stream:close()
end

function hdf.load(path)
    local stream = filesystem.open(path, "r")
    local signature = stream:read_bytes(3)

    if (signature[1] ~= HDF_SIGNATURE[1]) and (signature[2] ~= HDF_SIGNATURE[2]) and (signature[3] ~= HDF_SIGNATURE[3]) then
        error(string.format("file \"%s\" is not HDF", path))
    end

    local version = stream:read16_l()

    if version < HDF_VERSION then
        error("unsupported HDF version")
    end

    local flags = stream:read8()
    local compression = rshift(band(flags, HDF_FLAG_COMPRESSION_MASK), HDF_FLAG_COMPRESSION_SHIFT)

    if compression > 0 then
        error("unsupported compression mode: " .. compression)
    end

    local sector_size, cylinders, heads, sectors = byteutil.unpack(">HHHH", stream:read_bytes(8))
    local drive = {
        sector_size = sector_size,
        cylinders = cylinders,
        heads = heads,
        sectors = sectors,
    }

    if band(flags, HDF_FLAG_DYNAMIC_MASK) == 0 then
        drive.format = function(self, addr, count)
            stream:set_position(lshift(addr, 9) + 14)

            for _ = 1, count, 1 do
                for _ = 1, 512, 1 do
                    stream:write8(0x00)
                end
            end
        end

        drive.read_sector = function(self, addr, buffer)
            stream:set_position(lshift(addr, 9) + 14)
            return stream:read_bytes_to_buffer_zero(sector_size, buffer)
        end

        drive.write_sector = function(self, addr, data)
            stream:set_position(lshift(addr, 9) + 14)
            stream:write_bytes_zero(data)
        end

        drive.save = function(self)
            stream:flush()
        end
    else
        drive.stream = nil
        drive.path = path
        drive.sectors_table = {}
        drive.sector_count = stream:read32_l()

        for _ = 1, drive.sector_count, 1 do
            local id = stream:read32_l()
            drive.sectors_table[id] = stream:read_bytes(drive.sector_size)
        end

        stream:close()
        stream = nil

        drive.format = function(self, addr, count)
            for i = addr, count, 1 do
                if self.sectors_table[i] then
                    self.sectors_table[i] = nil
                    self.sector_count = self.sector_count - 1
                end
            end
        end

        drive.read_sector = function(self, addr, buffer)
            local sector = self.sectors_table[addr]

            if sector then
                for i = 1, drive.sector_size, 1 do
                    buffer[i - 1] = sector[i]
                end

                return
            end

            for i = 0, drive.sector_size - 1, 1 do
                buffer[i] = 0x00
            end
        end

        drive.write_sector = function(self, addr, data)
            if not self.sectors_table[addr] then
                self.sector_count = self.sector_count + 1
                self.sectors_table[addr] = {}
            end

            for i = 1, drive.sector_size, 1 do
                self.sectors_table[addr][i] = data[i - 1]
            end
        end

        drive.save = hdf_dynamic_save
    end

    return drive
end

return hdf
