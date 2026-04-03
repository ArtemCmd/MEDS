-- =====================================================================================================================================================================
-- IDE-XTA Disk Controller Emulation.
-- =====================================================================================================================================================================

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local hdc = {}

local HDC_IRQ = 0x05
local HDC_DMA = 0x03
local HDC_ROM = file.read_bytes("emulator:roms/hdd/infowdbios.rom", false)

local STATUS_REQ = 0x01 -- Request Bit
local STATUS_IO  = 0x02 -- Mode Bit
local STATUS_CD  = 0x04 -- Command/Data Bit
local STATUS_BSY = 0x08 -- Busy Bit
local STATUS_DRQ = 0x10 -- DMA bit
local STATUS_IRQ = 0x20 -- IRQ bit

local ERR_NONE          = 0x00
local ERR_NO_READY      = 0x04
local ERR_BAD_COMMAND   = 0x20
local ERR_ILLEGAL_ADDR  = 0x21
local ERR_SEEK_ERROR    = 0x15

local COMP_DRIVE = 0x20
local COMP_ERROR = 0x02

local STATE_IDLE            = 0x0000
local STATE_RECEIVE_COMMAND = 0x0100
local STATE_START_COMMAND   = 0x0200
local STATE_RECEIVE_DATA    = 0x0300
local STATE_RECEIVED_DATA   = 0x0400
local STATE_SEND_DATA       = 0x0500
local STATE_SENT_DATA       = 0x0600
local STATE_COMPLETION_BYTE = 0x0700
local STATE_COMPLETE        = 0x0800

local file_formats = {
    ["hdf"] = require("emulator:hardware/disk/hdd_hdf")
}

local supported_formats = {
    {977, 5, 17, 0x12}, -- 42 MB
    {1024, 4, 17, 0x02},-- 35 MB
    {976, 4, 17, 0x00}, -- 33 MB
    {615, 6, 17, 0x11}, -- 32 MB
    {1024, 3, 17, 0x01}, -- 26 MB
    {615, 4, 17, 0x13}, -- 21 MB
    {612, 4, 17, 0x10}, -- 21 MB
    {1024, 2, 17, 0x03}, -- 17 MB
}

local function create_drive(self, num)
    self.drives[num] = {
        cylinders = 0,
        heads = 0,
        sectors = 0,
        cylinder = 0,
        head = 0,
        sector = 0,
        present = false,
        edited = false
    }
end

local function get_chs(self, drive)
    self.head = band(self.command[1], 0x1F)
    self.sector = band(self.command[2], 0x3F)
    self.cylinder = bor(self.command[3], lshift(band(self.command[2], 0xC0), 2))
    self.count = self.command[4]

    if self.cylinder >= drive.cylinders then
        drive.cylinder = drive.cylinders - 1
        return false
    end

    drive.cylinder = self.cylinder

    return true
end

local function get_sector(self, drive)
    if self.cylinder ~= drive.cylinder then
        self.error = ERR_ILLEGAL_ADDR
        return - 1
    end

    if self.head >= drive.heads then
        self.error = ERR_ILLEGAL_ADDR
        return -1
    end

    if self.sector >= drive.sectors then
        self.error = ERR_ILLEGAL_ADDR
        return -1
    end

    return (((self.cylinder * drive.heads) + self.head) * drive.sectors) + self.sector
end

local function next_sector(self, drive)
    self.sector = self.sector + 1

    if self.sector >= drive.sectors then
        self.sector = 0
        self.head = self.head + 1

        if self.head >= drive.heads then
            self.head = 0
            drive.cylinder = drive.cylinder + 1

            if drive.cylinder >= drive.cylinders then
                drive.cylinder = drive.cylinders - 1
            else
                self.cylinder = self.cylinder + 1
            end
        end
    end
end

local function command_error(self, code)
    self.completion = bor(self.completion, 0x02)
    self.error = code
end

local function command_complete(self)
    self.status = bor(STATUS_BSY, bor(STATUS_IO, bor(STATUS_CD, STATUS_REQ)))
    self.state = STATE_COMPLETION_BYTE

    if self.irq_enabled then
        self.status = bor(self.status, STATUS_IRQ)
        self.pic:request_interrupt(HDC_IRQ)
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- [STATE | COMMAND]
local commands = {
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Test Drive Ready Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x00)] = function(self)
        if not self.drives[self.drive_select].present then
            command_error(self, ERR_NO_READY)
        end

        command_complete(self)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Recalibrate Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x01)] = function(self)
        local drive = self.drives[self.drive_select]

        if not drive.present then
            command_error(self, ERR_NO_READY)
            command_complete(self)
            return
        end

        drive.cylinder = 0
        self.cylinder = 0

        command_complete(self)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Status Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x03)] = function(self)
        self.buffer_index = 0
        self.buffer_count = 4

        self.buffer[0] = self.error
        self.buffer[1] = lshift(self.drive_select, 5)
        self.buffer[2] = bor(rshift(self.cylinder, 2), band(self.sector, 0x3F))
        self.buffer[3] = band(self.cylinder, 0xFF)

        self.error = ERR_NONE
        self.status = bor(self.status, bor(STATUS_IO, STATUS_REQ))
        self.state = STATE_SEND_DATA
    end,
    [bor(STATE_SENT_DATA, 0x03)] = function(self)
        command_complete(self)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Format Drive Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x04)] = function(self)
        local drive = self.drives[self.drive_select]

        if not drive.present then
            command_error(self, ERR_NO_READY)
            command_complete(self)
            return
        end

        local addr

        for cylinder = 0, drive.cylinders - 1, 1 do
            self.cylinder = cylinder

            for head = 0, drive.heads - 1, 1 do
                self.head = head

                for sector = 0, drive.sectors - 1, 1 do
                    self.sector = sector
                    addr = get_sector(self, drive)

                    if addr == -1 then
                        break
                    end

                    drive.handler:write_sector(addr, self.buffer)
                end
            end
        end

        command_complete(self)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Verify Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x05)] = function(self)
        local drive = self.drives[self.drive_select]

        if not drive.present then
            command_error(self, ERR_NO_READY)
            command_complete(self)
            return
        end

        get_chs(self, drive)

        if get_sector(self, drive) == -1 then
            command_error(self, self.error)
            command_complete(self)
            return
        end

        if self.count == 0 then
            self.count = 256
        end

        self.buffer_index = 0
        self.buffer_count = 512
        self.state = STATE_SEND_DATA
        self.timer:advance(self.delay)
    end,
    [bor(STATE_SEND_DATA, 0x05)] = function(self)
        self.state = STATE_SENT_DATA
        self.timer:advance(self.delay)
    end,
    [bor(STATE_SENT_DATA, 0x05)] = function(self)
        local drive = self.drives[self.drive_select]

        self.count = self.count - 1

        if self.count == 0 then
            command_complete(self)
            return
        end

        next_sector(self, drive)

        self.state = STATE_SEND_DATA
        self.buffer_index = 0
        self.buffer_count = 512
        self.state = STATE_SEND_DATA
        self.timer:advance(self.delay)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Format Track Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x06)] = function(self)
        local drive = self.drives[self.drive_select]

        if not drive.present then
            command_error(self, ERR_NO_READY)
            command_complete(self)
            return
        end

        get_chs(self, drive)

        self.sector = 0
        self.state = STATE_SEND_DATA
        self.timer:advance(self.delay)
    end,
    [bor(STATE_SEND_DATA, 0x06)] = function(self)
        local drive = self.drives[self.drive_select]
        local addr = get_sector(self, drive)

        if addr == -1 then
            self.completion = bor(self.completion, COMP_ERROR)
            command_complete(self)
            return
        end

        drive.handler:format(addr, drive.sectors)
        drive.edited = true

        self.state = STATE_SENT_DATA
        self.timer:advance(self.delay_20)
    end,
    [bor(STATE_SENT_DATA, 0x06)] = function(self)
        command_complete(self)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Read Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x08)] = function(self)
        local drive = self.drives[self.drive_select]

        if not drive.present then
            command_error(self, ERR_NO_READY)
            command_complete(self)
            return
        end

        get_chs(self, drive)

        if self.count == 0 then
            self.count = 256
        end

        self.buffer_index = 0
        self.buffer_count = 512

        local addr = get_sector(self, drive)

        if addr == -1 then
            self.completion = bor(self.completion, COMP_ERROR)
            command_complete(self)
            return
        end

        drive.handler:read_sector(addr, self.buffer)
        self.state = STATE_SEND_DATA

        if self.dma_enabled then
            self.timer:advance(self.delay)
        else
            self.status = bor(self.status, bor(STATUS_IO, STATUS_REQ))
        end
    end,
    [bor(STATE_SEND_DATA, 0x08)] = function(self)
        for _ = 1, 512, 1 do
            if self.dma:channel_write(HDC_DMA, self.buffer[self.buffer_index]) == 0x200 then
                self.status = bor(self.status, bor(bor(STATUS_IO, STATUS_REQ), STATUS_CD))
                self.timer:advance(self.delay)
                return
            end

            self.buffer_index = self.buffer_index + 1
        end

        self.state = STATE_SENT_DATA
        self.timer:advance(self.delay)
    end,
    [bor(STATE_SENT_DATA, 0x08)] = function(self)
        local drive = self.drives[self.drive_select]

        self.count = self.count - 1

        if self.count == 0 then
            command_complete(self)
            return
        end

        next_sector(self, drive)

        local addr = get_sector(self, drive)

        if addr == -1 then
            self.completion = bor(self.completion, COMP_ERROR)
            command_complete(self)
            return
        end

        drive.handler:read_sector(addr, self.buffer)

        self.buffer_index = 0
        self.buffer_count = 512
        self.state = STATE_SEND_DATA

        if self.dma_enabled then
            self.timer:advance(self.delay)
        else
            self.status = bor(self.status, bor(STATUS_IO, STATUS_REQ))
        end
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Write Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x0A)] = function(self)
        local drive = self.drives[self.drive_select]

        if not drive.present then
            command_error(self, ERR_NO_READY)
            command_complete(self)
            return
        end

        get_chs(self, drive)

        self.buffer_index = 0
        self.buffer_count = 512
        self.state = STATE_RECEIVE_DATA

        if self.count == 0 then
            self.count = 256
        end

        if self.dma_enabled then
            self.timer:advance(self.delay)
        else
            self.status = bor(self.status, STATUS_REQ)
        end
    end,
    [bor(STATE_RECEIVE_DATA, 0x0A)] = function(self)
        for _ = 1, 512, 1 do
            local val = self.dma:channel_read(HDC_DMA, false)

            if val == 0x200 then
                self.status = bor(self.status, bor(STATUS_CD, bor(STATUS_IO, STATUS_REQ)))
                self.timer:advance(self.delay)
                return
            end

            self.buffer[self.buffer_index] = band(val, 0xFF)
            self.buffer_index = self.buffer_index + 1
        end

        self.state = STATE_RECEIVED_DATA
        self.status = STATUS_BSY
        self.timer:advance(self.delay)
    end,
    [bor(STATE_RECEIVED_DATA, 0x0A)] = function(self)
        local drive = self.drives[self.drive_select]
        local addr = get_sector(self, drive)

        if addr == -1 then
            self.completion = bor(self.completion, COMP_ERROR)
            command_complete(self)
            return
        end

        drive.handler:write_sector(addr, self.buffer)
        drive.edited = true

        self.count = self.count - 1

        if self.count == 0 then
            command_complete(self)
            return
        end

        next_sector(self, drive)

        self.buffer_index = 0
        self.buffer_count = 512
        self.state = STATE_RECEIVE_DATA

        if self.dma_enabled then
            self.timer:advance(self.delay)
        else
            self.status = bor(self.status, STATUS_REQ)
        end
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Seek Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x0B)] = function(self)
        local drive = self.drives[self.drive_select]

        if drive.present then
            if not get_chs(self, drive) then
                command_error(self, ERR_SEEK_ERROR)
            end
        else
            command_error(self, ERR_NO_READY)
        end

        command_complete(self)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Specify Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x0C)] = function(self)
        self.buffer_index = 0
        self.buffer_count = 8
        self.status = bor(self.status, STATUS_REQ)
        self.state = STATE_RECEIVE_DATA
    end,
    [bor(STATE_RECEIVED_DATA, 0x0C)] = function(self)
        local drive = self.drives[self.drive_select]

        drive.cylinders = bor(self.buffer[1], lshift(self.buffer[0], 8))
        drive.heads = self.buffer[2]

        command_complete(self)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Write Buffer Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x0F)] = function(self)
        self.buffer_index = 0
        self.buffer_count = 512
        self.status = bor(STATUS_BSY, STATUS_REQ)
        self.state = STATE_RECEIVE_DATA

        if self.dma_enabled then
            self.timer:advance(self.delay)
        else
            self.status = bor(self.status, STATUS_REQ)
        end
    end,
    [bor(STATE_RECEIVE_DATA, 0x0F)] = function(self)
        if not self.dma_enabled then
            return
        end

        for _ = 1, 512, 1 do
            local val = self.dma:channel_read(HDC_DMA)

            if val == 0x200 then
                self.status = bor(self.status, bor(STATUS_CD, bor(STATUS_IO, STATUS_REQ)))
                self.timer:advance(self.delay)
                return
            end

            self.buffer[self.buffer_index] = band(val, 0xFF)
            self.buffer_index = self.buffer_index + 1
        end

        self.state = STATE_RECEIVED_DATA
        self.timer:advance(self.delay)
    end,
    [bor(STATE_RECEIVED_DATA, 0x0F)] = command_complete,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- RAM Diagnostic Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0xE0)] = function(self)
        self.state = STATE_RECEIVED_DATA
        self.timer:advance(5 * self.delay)
    end,
    [bor(STATE_RECEIVED_DATA, 0xE0)] = command_complete,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Drive Diagnostic Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0xE3)] = function(self)
        local drive = self.drives[self.drive_select]

        if not drive.present then
            command_error(self, ERR_NO_READY)
            command_complete(self)
            return
        end

        self.state = STATE_RECEIVED_DATA
        self.timer:advance(5 * self.delay)
    end,
    [bor(STATE_RECEIVED_DATA, 0xE3)] = command_complete,
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Diagnostic Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0xE4)] = function(self)
        self.state = STATE_RECEIVED_DATA
        self.timer:advance(10 * self.delay)
    end,
    [bor(STATE_RECEIVED_DATA, 0xE4)] = command_complete
}

local function update(self)
    local command = commands[bor(self.state, self.command[0])]

    self.drive_select = band(rshift(self.command[1], 5), 0x01)
    self.completion = rshift(self.drive_select, 5)

    if command then
        command(self)
    else
        command_error(self, ERR_BAD_COMMAND)
        command_complete(self)
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Ports
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function port_data_in(self, cpu, port)
    self.status = band(self.status, bnot(STATUS_IRQ))

    if self.state == STATE_COMPLETION_BYTE then
        self.status = 0x00
        self.state = STATE_IDLE
        return self.completion
    elseif self.state == STATE_SEND_DATA then
        if self.buffer_index > self.buffer_count then -- Read Empty Buffer
            command_error(self, ERR_BAD_COMMAND)
            return 0xFF
        end

        local ret = self.buffer[self.buffer_index]
        self.buffer_index = self.buffer_index + 1

        if self.buffer_index == self.buffer_count then
            self.status = band(self.status, bnot(STATUS_REQ))
            self.state = STATE_SENT_DATA
            self.timer:set_delay(self.delay)
        end

        return ret
    end

    return 0xFF
end

local function port_data_out(self, cpu, port, val)
    if band(self.status, STATUS_REQ) == 0 then
        command_error(self, ERR_BAD_COMMAND)
        return
    end

    if self.state == STATE_RECEIVE_COMMAND then
        self.command[self.buffer_index] = val
        self.buffer_index = self.buffer_index + 1

        if self.buffer_index == self.buffer_count then
            self.buffer_count = 0
            self.buffer_index = 0
            self.status = band(self.status, bnot(bor(STATUS_REQ, STATUS_CD)))
            self.state = STATE_START_COMMAND
            self.timer:set_delay(self.delay)
        end

        return
    elseif self.state == STATE_RECEIVE_DATA then
        if self.buffer_index >= self.buffer_count then
            command_error(self, ERR_BAD_COMMAND)
            return
        end

        self.buffer[self.buffer_index] = val
        self.buffer_index = self.buffer_index + 1

        if self.buffer_index == self.buffer_count then
            self.status = band(self.status, bnot(bor(STATUS_REQ, STATUS_CD)))
            self.state = STATE_RECEIVED_DATA
            self.timer:set_delay(self.delay)
        end
    end
end

local function port_status_in(self, cpu, port)
    return self.status
end

local function port_status_out(self, cpu, port, val)
    self.error = 0x00
    self.state = STATE_IDLE
end

local function port_switches_in(self, cpu, port)
    return self.switches
end

local function port_select_pulse_out(self, cpu, port, val)
    self.buffer_index = 0
    self.buffer_count = 6
    self.state = STATE_RECEIVE_COMMAND
    self.status = bor(STATUS_BSY, bor(STATUS_CD, STATUS_REQ))
end

local function port_mask_register_out(self, cpu, port, val)
    self.dma_enabled = band(val, 0x01) ~= 0
    self.irq_enabled = band(val, 0x02) ~= 0
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function rom_read(self, addr)
    return self[band(addr, 0x1FFF)]
end

local function rom_write(self, addr, val)
    self[band(addr, 0x1FFF)] = val
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function insert_drive(self, num, path)
    local drive = self.drives[num]

    if not drive then
        error("invalid drive " .. num)
    end

    local file_ext = file.ext(path)
    local file_format = file_formats[file_ext]

    if not file_format then
        error("unsupported file format: " .. file_ext)
    end

    local handler = file_format.load(path)

    drive.cylinders = handler.cylinders
    drive.heads = handler.heads
    drive.sectors = handler.sectors
    drive.handler = handler
    drive.present = true

    local format, found

    for i = 1, #supported_formats, 1 do
        format = supported_formats[i]

        if (drive.cylinders == format[1]) and (drive.heads == format[2]) and (drive.sectors == format[3]) then
            found = true
            break
        end
    end

    if not found then
        error("invalid drive geometry")
    end

    self.switches = band(self.switches, band(0xEF, (num == 1) and 0xF3 or 0xFC))
    self.switches = bor(self.switches, band(format[4], 0x10)) -- Set bit 4
    self.switches = bor(self.switches, lshift(band(format[4], 0x0F), lshift(num, 1)))
end

local function set_clock(self)
    self.delay = 250 * self.timer.scheduler.NANOSECOND
    self.delay_20 = 20 * 1000 * self.timer.scheduler.NANOSECOND
end

local function initialize(self)
    for i = 0, 0x1FFF, 1 do
        self.rom[i] = HDC_ROM[i + 1]
    end
end

local function reset(self)
    self.state = STATE_IDLE
    self.completion = 0x00
    self.status = 0x00
    self.buffer_index = 0
    self.buffer_count = 0
    self.count = 0
    self.cylinder = 0
    self.head = 0
    self.sector = 0
    self.error = 0
    self.drive_select = 0
    self.irq_enabled = false
    self.dma_enabled = false
    self.timer:disable()
end

local function save(self)
    for i = 0, 1, 1 do
        local drive = self.drives[i]

        if drive.present and drive.edited then
            drive.handler:save()
        end
    end
end

function hdc.new(cpu, memory, pic, dma)
    local self = {
        cpu = cpu,
        pic = pic,
        dma = dma,
        rom = {},
        command = {[0] = 0, 0, 0, 0, 0, 0},
        buffer = {[0] = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        drives = {},
        state = STATE_IDLE,
        status = 0x00,
        completion = 0x00,
        switches = 0xFF,
        buffer_index = 0,
        buffer_count = 0,
        count = 0,
        cylinder = 0,
        head = 0,
        sector = 0,
        drive_select = 0,
        error = 0,
        dma_enabled = false,
        irq_enabled = false,
        delay = 0,
        delay_20 = 0,
        set_clock = set_clock,
        initialize = initialize,
        insert_drive = insert_drive,
        save = save,
        reset = reset
    }

    create_drive(self, 0)
    create_drive(self, 1)

    local cpu_io = cpu:get_io()

    cpu_io:set_port(0x320, port_data_out, port_data_in)
    cpu_io:set_port(0x321, port_status_out, port_status_in)
    cpu_io:set_port(0x322, port_select_pulse_out, port_switches_in)
    cpu_io:set_port_out(0x323, port_mask_register_out)

    cpu_io:set_function_argument_range(0x320, 0x322, self)
    cpu_io:set_out_function_argument(0x323, self)

    memory:add_mapping(0xC8000, 0x02000, rom_read, rom_write, self.rom)

    self.timer = cpu:get_scheduler():add(update, self, false)

    return self
end

return hdc
