-- =====================================================================================================================================================================
-- IBM PC-XT Fixed Disk controller emulation.
-- =====================================================================================================================================================================

local logger = require("dave_logger:logger")("MEDS")

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local controller = {}

local HDC_IRQ = 0x05
local HDC_DMA = 0x03
local HDC_ROM = file.read_bytes("emulator:roms/hdd/ibm_xebec_62x0822_1985.bin", false)

local STATUS_REQ = 0x01 -- Request Bit
local STATUS_IO  = 0x02 -- Mode Bit
local STATUS_CD  = 0x04 -- Command/Data Bit
local STATUS_BSY = 0x08 -- Busy Bit
local STATUS_DRQ = 0x10 -- DMA Bit
local STATUS_IRQ = 0x20 -- IRQ Bit

local STATE_IDLE            = 0x0000
local STATE_RECEIVE_COMMAND = 0x0100
local STATE_START_COMMAND   = 0x0200
local STATE_RECEIVE_DATA    = 0x0300
local STATE_RECEIVED_DATA   = 0x0400
local STATE_SEND_DATA       = 0x0500
local STATE_SENT_DATA       = 0x0600
local STATE_COMPLETION_BYTE = 0x0700
local STATE_COMPLETE        = 0x0800

local ERR_BAD_COMMAND   = 0x20
local ERR_ILLEGAL_ADDR  = 0x21
local ERR_NO_READY      = 0x04
local ERR_SEEK_ERROR    = 0x15
local ERR_BAD_PARAMETER = 0x22
local ERR_NO_RECOVERY   = 0x1F

local file_formats = {
    ["hdf"] = require("emulator:hardware/disk/hdd_hdf")
}

local supported_formats = {
    [0] = {306, 4, 17},
    {612, 4, 17},
    {615, 4, 17},
    {306, 8, 17}
}

local function crate_drive(self, num)
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
    self.error = 0x80
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
    if not drive.present then
        self.last_error = ERR_NO_READY
        return -1
    end

    if self.head >= drive.heads then
        self.last_error = ERR_ILLEGAL_ADDR
        return -1
    end

    if self.sector >= drive.sectors then
        self.last_error = ERR_ILLEGAL_ADDR
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
    self.last_error = code
end

local function command_complete(self)
    self.status = bor(STATUS_BSY, bor(STATUS_IO, bor(STATUS_CD, STATUS_REQ)))
    self.state = STATE_COMPLETION_BYTE

    if self.dma_enabled then
        self.dma:clear_service(HDC_DMA)
    end

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
        self.state = STATE_COMPLETE
        self.timer:advance(self.delay_20)
    end,
    [bor(STATE_COMPLETE, 0x01)] = function(self)
        command_complete(self)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Status Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x03)] = function(self)
        self.buffer_pos = 0
        self.buffer_count = 4
        self.buffer[0] = bor(self.error, self.last_error)
        self.buffer[1] = bor(lshift(self.drive_select, 5), self.head)
        self.buffer[2] = bor(rshift(band(self.cylinder, 0x300), 2), self.sector)
        self.buffer[3] = band(self.cylinder, 0xFF)
        self.status = bor(STATUS_BSY, bor(STATUS_IO, STATUS_REQ))
        self.last_error = 0x00
        self.state = STATE_SEND_DATA
    end,
    [bor(STATE_SENT_DATA, 0x03)] = function(self)
        command_complete(self)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Format Drive Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x04)] = function(self)
        get_chs(self, self.drives[self.drive_select])
        self.state = STATE_SEND_DATA
        self.timer:advance(self.delay)
    end,
    [bor(STATE_SEND_DATA, 0x04)] = function(self)
        local drive = self.drives[self.drive_select]
        local addr = get_sector(self, drive)

        if addr == -1 then
            command_error(self, self.last_error)
            command_complete(self)
            return
        end

        drive.handler:format(addr, (drive.cylinders - 1) * drive.heads * drive.sectors)
        drive.edited = true

        self.state = STATE_SENT_DATA
        self.timer:set_delay(self.delay_20)
    end,
    [bor(STATE_SENT_DATA, 0x04)] = function(self)
        command_complete(self)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Verify Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x05)] = function(self)
        get_chs(self, self.drives[self.drive_select])
        self.state = STATE_SEND_DATA
        self.timer:advance(self.delay)
    end,
    [bor(STATE_SEND_DATA, 0x05)] = function(self)
        local drive = self.drives[self.drive_select]

        if self.count == 0 then
            command_complete(self)
        end

        self.count = self.count - 1

        if get_sector(self, drive) == -1 then
            command_error(self, self.last_error)
            command_complete(self)
            return
        end

        next_sector(self, drive)

        self.timer:advance(self.delay)
    end,
    [bor(STATE_COMPLETION_BYTE, 0x05)] = function(self) end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Format Track Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x06)] = function(self)
        get_chs(self, self.drives[self.drive_select])
        self.state = STATE_SEND_DATA
        self.timer:advance(self.delay)
    end,
    [bor(STATE_SEND_DATA, 0x06)] = function(self)
        local drive = self.drives[self.drive_select]
        local addr = get_sector(self, drive)

        if addr == -1 then
            command_error(self, self.last_error)
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

        get_chs(self, drive)

        local addr = get_sector(self, drive)

        if addr == -1 then
            command_error(self, self.last_error)
            command_complete(self)
            return
        end

        drive.handler:read_sector(addr, self.buffer)

        self.buffer_pos = 0
        self.buffer_count = 512
        self.status = bor(STATUS_BSY, bor(STATUS_IO, STATUS_REQ))
        self.state = STATE_SEND_DATA

        if self.dma_enabled then
            self.timer:advance(self.delay_20)
            self.dma:request_service(HDC_DMA)
        end
    end,
    [bor(STATE_SEND_DATA, 0x08)] = function(self)
        for _ = 1, 512, 1 do
            if self.dma:channel_write(HDC_DMA, self.buffer[self.buffer_pos]) == 0x200 then
                command_error(self, ERR_NO_RECOVERY)
                command_complete(self)
                return
            end

            self.buffer_pos = self.buffer_pos + 1
        end

        self.state = STATE_SENT_DATA
        self.dma:clear_service(HDC_DMA)
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
            command_error(self, self.last_error)
            command_complete(self)
            return
        end

        drive.handler:read_sector(addr, self.buffer)

        self.buffer_pos = 0
        self.buffer_count = 512
        self.status = bor(STATUS_BSY, bor(STATUS_IO, STATUS_REQ))
        self.state = STATE_SEND_DATA

        if self.dma_enabled then
            self.dma:request_service(HDC_DMA)
            self.timer:advance(self.delay_20)
        end
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Write Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x0A)] = function(self)
        local drive = self.drives[self.drive_select]
        get_chs(self, drive)

        if get_sector(self, drive) == -1 then
            command_error(self, ERR_BAD_PARAMETER)
            command_complete(self)
            return
        end

        self.buffer_pos = 0
        self.buffer_count = 512
        self.status = bor(STATUS_BSY, STATUS_REQ)
        self.state = STATE_RECEIVE_DATA

        if self.dma_enabled then
            self.dma:request_service(HDC_DMA)
            self.timer:advance(self.delay_20)
        end
    end,
    [bor(STATE_RECEIVE_DATA, 0x0A)] = function(self)
        for _ = 1, 512, 1 do
            local val = self.dma:channel_read(HDC_DMA, false)

            if val == 0x200 then
                command_error(self, ERR_NO_RECOVERY)
                command_complete(self)
                return
            end

            self.buffer[self.buffer_pos] = band(val, 0xFF)
            self.buffer_pos = self.buffer_pos + 1
        end

        self.state = STATE_RECEIVED_DATA
        self.dma:clear_service(HDC_DMA)
        self.timer:advance(self.delay)
    end,
    [bor(STATE_RECEIVED_DATA, 0x0A)] = function(self)
        local drive = self.drives[self.drive_select]
        local addr = get_sector(self, drive)

        if addr == -1 then
            command_error(self, self.last_error)
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

        self.buffer_pos = 0
        self.buffer_count = 512
        self.satus = bor(STATUS_BSY, STATUS_REQ)
        self.state = STATE_RECEIVE_DATA

        if self.dma_enabled then
            self.dma:request_service(HDC_DMA)
            self.timer:advance(self.delay_20)
        end
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Seek Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x0B)] = function(self)
        local drive = self.drives[self.drive_select]

        if not drive.present then
            command_error(self, ERR_NO_READY)
            command_complete(self)
            return
        end

        if not get_chs(self, drive) then
            command_error(self, ERR_SEEK_ERROR)
            command_complete(self)
            return
        end

        if get_sector(self, drive) == -1 then
            command_error(self, ERR_BAD_PARAMETER)
            command_complete(self)
            return
        end

        drive.cylinder = self.cylinder

        self.state = STATE_COMPLETE
        self.timer:advance(self.delay_20)
    end,
    [bor(STATE_COMPLETE, 0x0B)] = function(self)
        command_complete(self)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Specify Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x0C)] = function(self)
        self.buffer_pos = 0
        self.buffer_count = 8
        self.status = bor(STATUS_BSY, STATUS_REQ)
        self.state = STATE_RECEIVE_DATA
    end,
    [bor(STATE_RECEIVED_DATA, 0x0C)] = function(self)
        local drive = self.drives[self.drive_select]
        drive.cylinders = bor(self.buffer[1], lshift(self.buffer[0], 8))
        drive.heads = self.buffer[2]
        command_complete(self)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Read Buffer Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x0E)] = function(self)
        self.buffer_pos = 0
        self.buffer_count = 512
        self.status = bor(STATUS_BSY, bor(STATUS_IO, STATUS_REQ))
        self.state = STATE_SEND_DATA

        if self.dma_enabled then
            self.dma:request_service(HDC_DMA)
            self.timer:advance(self.delay)
        end
    end,
    [bor(STATE_SEND_DATA, 0x0E)] = function(self)
        for _ = 1, 512, 1 do
            if self.dma:channel_write(HDC_DMA, self.buffer[self.buffer_pos]) == 0x200 then
                command_error(self, ERR_NO_RECOVERY)
                command_complete(self)
                return
            end

            self.buffer_pos = self.buffer_pos + 1
        end

        self.state = STATE_SENT_DATA
        self.dma:clear_service(HDC_DMA)
        self.timer:advance(self.delay)
    end,
    [bor(STATE_SENT_DATA, 0x0E)] = function(self)
        command_complete(self)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Write Buffer Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0x0F)] = function(self)
        self.buffer_pos = 0
        self.buffer_count = 512
        self.status = bor(STATUS_BSY, STATUS_REQ)
        self.state = STATE_RECEIVE_DATA

        if self.dma_enabled then
            self.dma:request_service(HDC_DMA)
            self.timer:advance(self.delay)
        end
    end,
    [bor(STATE_RECEIVE_DATA, 0x0F)] = function(self)
        for _ = 1, 512, 1 do
            local val = self.dma:channel_read(HDC_DMA)

            if val == 0x200 then
                command_error(self, ERR_NO_RECOVERY)
                command_complete(self)
                return
            end

            self.buffer[self.buffer_pos] = band(val, 0xFF)
            self.buffer_pos = self.buffer_pos + 1
        end

        self.state = STATE_RECEIVED_DATA
        self.dma:clear_service(HDC_DMA)
        self.timer:advance(self.delay)
    end,
    [bor(STATE_RECEIVED_DATA, 0x0F)] = command_complete,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- RAM Diagnostic Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0xE0)] = command_complete,
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Diagnostic Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [bor(STATE_START_COMMAND, 0xE4)] = command_complete
}

local function update(self)
    local command_id = self.command[0]
    local command = commands[bor(self.state, command_id)]

    self.drive_select = band(rshift(self.command[1], 5), 0x01)
    self.completion = rshift(self.drive_select, 5)

    if command_id ~= 3 then
        self.error = 0x00
    end

    if command then
        command(self)
    else
        logger:error("ST506: Unknown command 0x%02X/0x%02X", command_id, self.state)
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
        local ret = self.buffer[self.buffer_pos]
        self.buffer_pos = self.buffer_pos + 1

        if self.buffer_pos == self.buffer_count then
            self.buffer_count = 0
            self.buffer_pos = 0
            self.status = STATUS_BSY
            self.state = STATE_SENT_DATA
            self.timer:set_delay(self.delay)
        end

        return ret
    end

    return 0xFF
end

local function port_data_out(self, cpu, port, val)
    if self.state == STATE_RECEIVE_COMMAND then
        self.command[self.buffer_pos] = val
        self.buffer_pos = self.buffer_pos + 1

        if self.buffer_pos == self.buffer_count then
            self.buffer_count = 0
            self.buffer_pos = 0
            self.status = STATUS_BSY
            self.state = STATE_START_COMMAND
            self.timer:set_delay(self.delay)
        end

        return
    elseif self.state == STATE_RECEIVE_DATA then
        self.buffer[self.buffer_pos] = val
        self.buffer_pos = self.buffer_pos + 1

        if self.buffer_pos == self.buffer_count then
            self.buffer_count = 0
            self.buffer_pos = 0
            self.status = STATUS_BSY
            self.state = STATE_RECEIVED_DATA
            self.timer:set_delay(self.delay)
        end
    end
end

local function port_status_in(self, cpu, port)
    return bor(self.status, (self.dma_enabled and self.dma:get_drq(HDC_DMA)) and STATUS_DRQ or 0x00)
end

local function port_status_out(self, cpu, port, val)
    self.status = 0x00
end

local function port_switches_in(self, cpu, port)
    return self.switches
end

local function port_select_pulse_out(self, cpu, port, val)
    self.status = bor(STATUS_BSY, bor(STATUS_CD, STATUS_REQ))
    self.buffer_pos = 0
    self.buffer_count = 6
    self.state = STATE_RECEIVE_COMMAND
end

local function port_mask_register_out(self, cpu, port, val)
    self.dma_enabled = band(val, 0x01) ~= 0
    self.irq_enabled = band(val, 0x02) ~= 0

    if not self.dma_enabled then
        self.dma:clear_service(HDC_DMA)
    end

    if not self.irq_enabled then
        self.status = band(self.status, bnot(STATUS_IRQ))
        self.pic:clear_interrupt(HDC_IRQ)
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function rom_read(self, addr)
    return self[band(addr, 0x1FFF)]
end

local function rom_write(self, addr, val)
    self[band(addr, 0x1FFF)] = val
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function set_switches(self)
    self.switches = 0x00

    for i = 0, 1, 1 do
        local drive = self.drives[i]

        if drive.present then
            for j = 0, 3, 1 do
                local format = supported_formats[j]

                if (drive.cylinders == format[1]) and (drive.heads == format[2]) and (drive.sectors == format[3]) then
                    self.switches = bor(self.switches, lshift(j, lshift(bxor(i, 0x01), 1)))
                    break
                end
            end
        end
    end
end

local function insert_drive(self, num, path)
    local drive = self.drives[num]

    if drive then
        if drive.present then
            drive.handler:save()
        end

        local file_ext = file.ext(path)
        local file_format = file_formats[file_ext]

        if file_format then
            local handler = file_format.load(path)

            drive.cylinders = handler.cylinders
            drive.heads = handler.heads
            drive.sectors = handler.sectors
            drive.handler = handler
            drive.present = true

            set_switches(self)
        else
            logger:error("HDC: Unsupported File Format: \"%s\"", num, file_ext)
        end
    else
        logger:error("HDC: Invalid Drive %d", num)
    end
end

local function initialize(self)
    for i = 0, 0x0FFF, 1 do
        self.rom[i] = HDC_ROM[i + 1]
    end

    self.rom[0x1000] = 0xFF
end

local function set_clock(self)
    self.delay = 250 * self.timer.scheduler.NANOSECOND
    self.delay_20 = 20000 * self.timer.scheduler.NANOSECOND
end

local function reset(self)
    self.state = STATE_IDLE
    self.completion = 0x00
    self.status = 0x00
    self.buffer_pos = 0
    self.buffer_count = 0
    self.count = 0
    self.cylinder = 0
    self.head = 0
    self.sector = 0
    self.error = 0
    self.drive_select = 0
    self.last_error = 0
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

function controller.new(cpu, memory, pic, dma)
    local self = {
        pic = pic,
        dma = dma,
        rom = {},
        command = {[0] = 0, 0, 0, 0, 0, 0},
        buffer = {[0] = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        drives = {},
        state = STATE_IDLE,
        status = 0x00,
        completion = 0x00,
        switches = 0x00,
        buffer_pos = 0,
        buffer_count = 0,
        count = 0,
        cylinder = 0,
        head = 0,
        sector = 0,
        drive_select = 0,
        error = 0,
        last_error = 0,
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

    crate_drive(self, 0)
    crate_drive(self, 1)

    local cpu_io = cpu:get_io()

    cpu_io:set_port(0x320, port_data_out, port_data_in)
    cpu_io:set_port(0x321, port_status_out, port_status_in)
    cpu_io:set_port(0x322, port_select_pulse_out, port_switches_in)
    cpu_io:set_port_out(0x323, port_mask_register_out)

    cpu_io:set_function_argument_range(0x320, 0x322, self)
    cpu_io:set_out_function_argument(0x323, self)

    memory:add_mapping(0xC8000, 0x1000, rom_read, rom_write, self.rom)

    self.timer = cpu:get_scheduler():add(update, self, false)

    return self
end

return controller
