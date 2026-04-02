local pcap = {}

local function dump(self, packet, offset, length)
    self.stream:write("<IIII",
        os.time(),
        0,
        length,
        length
    )

    for i = offset, offset + length - 1, 1 do
        self.stream:write(packet[i])
    end

    self.stream:flush()
end

local function close(self)
    self.stream:flush()
    self.stream:close()
end

function pcap.open(path)
    local self = {
        stream = file.open(path, "wb"),
        dump = dump,
        close = close
    }

    self.stream:set_mode("buffered")
    self.stream:set_flush_mode("all")
    self.stream:set_max_buffer_size(1024)

    self.stream:write("<IHHIIII",
        0xA1B2C3D4,
        0x00000002,
        0x00000004,
        0x00000000,
        0x00000000,
        0x0000FFFF,
        0x00000001
    )

    self.stream:flush()

    return self
end

return pcap
