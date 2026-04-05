-- =====================================================================================================================================================================
-- NEC µPD765 Floppy Disk Controller emulation.
-- =====================================================================================================================================================================

local logger = require("dave_logger:logger")("MEDS")

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local fdc = {}

local FDC_IRQ = 0x06
local FDC_DMA = 0x02

local STATUS_BUSY = 0x10
local STATUS_NDMA = 0x20
local STATUS_DIO  = 0x40
local STATUS_MRQ  = 0x80

local ST0_NORMAL_TERMINATION   = 0x00
local ST0_ABNORMAL_TERMINATION = 0x40
local ST0_INVALID_OPCODE       = 0x80
local ST0_ABNORMAL_POLLING     = 0xD0
local ST0_HEAD_ACTIVE          = 0x04
local ST0_NOT_READY            = 0x08
local ST0_SEEK_END             = 0x20
local ST0_RESET                = 0xC0

local ST1_NOERROR       = 0x00
local ST1_NO_ID         = 0x01
local ST1_WRITE_PROTECT = 0x02
local ST1_NODATA        = 0x04
local ST1_OVERRUN       = 0x10
local ST1_CRC_ERROR     = 0x20

local ST3_HEAD          = 0x04
local ST3_DOUBLESIDED   = 0x08
local ST3_TRACK0        = 0x10
local ST3_READY         = 0x20
local ST3_WRITE_PROTECT = 0x40

local STATE_START_COMMAND   = 0x0100
local STATE_DONE            = 0x0200
local STATE_IDLE            = 0x0300
local STATE_EXECUTE_COMMAND = 0x0400

local sector_sizes = {
    [0x00] = 128,
    [0x01] = 256,
    [0x02] = 512,
    [0x03] = 1024,
    [0x04] = 2048,
    [0x05] = 4096,
    [0x06] = 8192,
    [0x07] = 16384,
}

local file_formats = {
    ["img"] = require("emulator:hardware/floppy/fdd_img")
}

local function create_drive(self, num)
    self.drives[num] = {
        id = num,
        cylinders = 0,
        heads = 0,
        sectors = 0,
        sector_size = 0,
        cylinder = 0,
        head = 0,
        sector = 0,
        present = false,
        motor_enabled = false,
        write_protected = false,
        edited = false
    }
end

local function drive_start_motor(self)
    if not self.motor_enabled and self.callbacks and self.callbacks.start_motor then
        self.callbacks.start_motor(self.callbacks.arg, self.id)
    end

    self.motor_enabled = true
end

local function drive_stop_motor(self)
    if self.motor_enabled and self.callbacks and self.callbacks.stop_motor then
        self.callbacks.stop_motor(self.callbacks.arg, self.id)
    end

    self.motor_enabled = false
end

local function reset_drive(self, num)
    local drive = self.drives[num]

    drive_stop_motor(drive)
    drive.cylinder = 0
    drive.head = 0
    drive.sector = 0
end

local function send_results(self, drive_id, cylinder, head, sector, sector_size, code)
    local drive = self.drives[drive_id]
    local st0 = bor(drive_id, code)
    local st1 = self.last_error

    -- ST0
    if drive.head == 1 then
        st0 = bor(st0, ST0_HEAD_ACTIVE)
    end

    if (not drive.motor_enabled) or (not drive.present) then
        st0 = bor(st0, ST0_NOT_READY)
    end

    -- ST1
    if not drive.present then
        st1 = bor(st1, bor(ST1_NODATA, ST1_NO_ID))
    end

    self.out[0] = sector_size
    self.out[1] = sector
    self.out[2] = head
    self.out[3] = cylinder
    self.out[4] = 0x00
    self.out[5] = st1
    self.out[6] = st0
    self.params_out = 7
    self.last_error = ST1_NOERROR
    self.msr = bor(STATUS_BUSY, bor(STATUS_DIO, STATUS_MRQ))
end

local function end_rw_operation(self, drive, drive_id, cylinder, head, sector, sector_size, code)
    drive.cylinder = self.cylinder
    drive.sector = self.sector

    self.state = STATE_IDLE
    self.dma:clear_service(FDC_DMA)

    send_results(self, drive_id, cylinder, head, sector, sector_size, code)

    self.pic:request_interrupt(FDC_IRQ)
    self.pending_interrupt = true
    self.timer:disable()
end

local function advance_sector(self, drive)
    if self.sector == self.sectors then
        if not self.mt then
            if self.drq_enabled then
                self.cylinder = self.cylinder + 1
                self.sector = 1
            end

            end_rw_operation(self, drive, self.drive_select, self.cylinder, self.head, self.sector, self.sector_size, ST0_NORMAL_TERMINATION)
            return false
        end

        if self.head == 1 then
            if self.drq_enabled then
                self.cylinder = self.cylinder + 1
                self.head = band(self.head, 0xFE)
                self.sector = 1
                drive.head = 0
            end

            end_rw_operation(self, drive, self.drive_select, self.cylinder, self.head, self.sector, self.sector_size, ST0_NORMAL_TERMINATION)
            return false
        end

        self.sector = 1
        self.head = 1

        if (drive.heads == 1) and (self.head == 1) then
            drive.head = 0
        else
            drive.head = self.head
        end
    elseif (self.sector < self.sectors) or (self.sectors == 0) then
        self.sector = self.sector + 1
    end

    return true
end

local function fdc_error(self, drive_id, error_code, code)
    self.last_error = error_code
    self.state = STATE_IDLE
    self.dma:clear_service(FDC_DMA)
    self.pic:request_interrupt(FDC_IRQ)
    self.pending_interrupt = true
    self.timer:disable()

    send_results(self, drive_id, self.cylinder, self.head, self.sector, self.sector_size, code)
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- [COMMAND] = Count of params
-- [STATE | COMMAND]
local commands = {
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Specify Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [0x03] = 2,
    [bor(STATE_START_COMMAND, 0x03)] = function(self)
        self.drq_enabled = band(self.params[1], 0x01) == 0

        if not self.drq_enabled then
            self.dma:clear_service(FDC_DMA)
        end
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Sense Drive Status Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [0x04] = 1,
    [bor(STATE_START_COMMAND, 0x04)] = function(self)
        local drive_id = bor(band(self.params[0], 0x07), ST3_READY)
        local drive = self.drives[drive_id]
        local st3 = drive_id

        if drive.head == 1 then
            st3 = bor(st3, ST3_HEAD)
        end

        if drive.heads == 2 then
            st3 = bor(st3, ST3_DOUBLESIDED)
        end

        if drive.cylinder == 0 then
            st3 = bor(st3, ST3_TRACK0)
        end

        if drive.write_protected then
            st3 = bor(st3, ST3_WRITE_PROTECT)
        end

        self.out[0] = st3
        self.msr = bor(band(self.msr, 0x0F), bor(STATUS_MRQ, bor(STATUS_BUSY, STATUS_DIO)))
        self.params_out = 1
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Write Data Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [0x05] = 8,
    [bor(STATE_START_COMMAND, 0x05)] = function(self)
        local drive_id = band(self.params[0], 0x03)
        local drive = self.drives[drive_id]

        if not drive.present then
            return
        end

        self.drive_select = drive_id
        self.cylinder = self.params[1]
        self.head = self.params[2]
        self.sector = self.params[3]
        self.sector_size = self.params[4]
        self.sectors = self.params[5]
        self.msr = STATUS_BUSY

        if self.drq_enabled then
            self.dma:request_service(FDC_DMA)
        else
            self.msr = bor(self.msr, bor(STATUS_NDMA, STATUS_MRQ))
        end

        if self.head >= drive.heads then
            fdc_error(self, ST1_NO_ID, ST0_ABNORMAL_POLLING)
            return
        end

        if drive.write_protected then
            fdc_error(self, bor(ST1_WRITE_PROTECT, ST1_NO_ID), ST0_ABNORMAL_POLLING)
            return
        end

        self.data_pos = 0
        self.state = STATE_EXECUTE_COMMAND
        self.timer:set_delay(0)
    end,
    [bor(STATE_EXECUTE_COMMAND, 0x05)] = function(self)
        local drive = self.drives[self.drive_select]
        local sector_size = sector_sizes[self.sector_size]

        if (self.sector > drive.sectors) or (self.head >= drive.heads) or (self.cylinder >= drive.cylinders) then
            fdc_error(self, self.drive_select, ST1_NO_ID, ST0_ABNORMAL_TERMINATION)
            return
        end

        if not self.drq_enabled then
            self.msr = bor(self.msr, bor(STATUS_BUSY, bor(STATUS_MRQ, STATUS_DIO)))
            self.sector_buffer[self.data_pos + 1] = self.data
            self.data_pos = self.data_pos + 1

            if self.data_pos >= sector_size then
                self.data_pos = 0

                drive.handler:write_sector(self.cylinder, self.head, self.sector, self.sector_buffer)

                if not advance_sector(self, drive) then
                    return
                end
            end

            return
        end

        local tc = false
        local val

        self.dma:request_service(FDC_DMA)
        self.msr = STATUS_BUSY

        for i = 1, sector_size, 1 do
            val = self.dma:channel_read(FDC_DMA, false)
            self.sector_buffer[i] = band(val, 0xFF)
            tc = band(val, 0x100) == 0x100
        end

        if tc then
            drive.handler:write_sector(self.cylinder, self.head, self.sector, self.sector_buffer)
            drive.edited = true

            if self.sector == self.sectors then
                if not self.mt then
                    self.cylinder = self.cylinder + 1
                    self.sector = 1
                else
                    self.cylinder = self.cylinder + band(self.head, 0x01)
                    self.head = bxor(self.head, 0x01)
                    self.sector = 1

                    if (drive.heads == 1) and (self.head == 1) then
                        drive.head = 0
                    else
                        drive.head = self.head
                    end
                end
            else
                self.sector = self.sector + 1
            end

            end_rw_operation(self, drive, self.drive_select, self.cylinder, self.head, self.sector, self.sector_size, ST0_NORMAL_TERMINATION)
            return
        end

        drive.handler:write_sector(self.cylinder, self.head, self.sector, self.sector_buffer)

        if not advance_sector(self, drive) then
            return
        end

        self.state = STATE_EXECUTE_COMMAND
        self.timer:advance(self.delay_rw)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Read Data Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [0x06] = 8,
    [bor(STATE_START_COMMAND, 0x06)] = function(self)
        local drive_id = band(self.params[0], 0x03)
        local drive = self.drives[drive_id]

        if not drive.present then
            return
        end

        if self.params[2] >= drive.heads then
            fdc_error(self, drive_id, ST1_NO_ID, ST0_ABNORMAL_POLLING)
            return
        end

        if self.drq_enabled then
            self.msr = bor(STATUS_DIO, STATUS_BUSY)
            self.dma:request_service(FDC_DMA)
        else
            self.msr = bor(STATUS_BUSY, bor(STATUS_DIO, STATUS_NDMA))
        end

        self.drive_select = drive_id

        self.cylinder = self.params[1]
        self.head = self.params[2]
        self.sector = self.params[3]
        self.sector_size = self.params[4]
        self.sectors = self.params[5]

        self.data_pos = 0
        self.state = STATE_EXECUTE_COMMAND
        self.timer:set_delay(0)
    end,
    [bor(STATE_EXECUTE_COMMAND, 0x06)] = function(self)
        local drive = self.drives[self.drive_select]
        local sector_size = sector_sizes[self.sector_size]

        if (self.sector > drive.sectors) or (self.head >= drive.heads) or (self.cylinder >= drive.cylinders) then
            fdc_error(self, self.drive_select, ST1_NO_ID, ST0_ABNORMAL_TERMINATION)
            return
        end

        local tc = false

        if not self.drq_enabled then
            if self.tc then
                self.data = 0x00
                return
            end

            if self.data_ready then
                fdc_error(self, self.drive_select, ST1_OVERRUN, ST0_ABNORMAL_POLLING)
                return
            end

            self.msr = bor(STATUS_BUSY, bor(STATUS_NDMA, bor(STATUS_DIO, STATUS_MRQ)))
            self.dma:channel_write(FDC_DMA, self.data, false)
            self.data = self.sector_buffer[self.data_pos + 1]
            self.data_pos = self.data_pos + 1

            if self.data_pos >= sector_size then
                self.data_pos = 0

                drive.handler:read_sector(self.cylinder, self.head, self.sector, sector_size, self.sector_buffer)

                if not advance_sector(self, drive) then
                    return
                end
            end

            return
        end

        drive.handler:read_sector(self.cylinder, self.head, self.sector, sector_size, self.sector_buffer)

        self.dma:request_service(FDC_DMA)
        self.msr = bor(STATUS_DIO, STATUS_BUSY)

        for i = 1, sector_size, 1 do
            tc = self.dma:channel_write(FDC_DMA, self.sector_buffer[i], false) == 0x100
        end

        if tc then
            if self.sector == self.sectors then
                if not self.mt then
                    self.cylinder = self.cylinder + 1
                    self.sector = 1
                else
                    self.cylinder = self.cylinder + band(self.head, 0x01)
                    self.head = bxor(self.head, 0x01)
                    self.sector = 1

                    if (drive.heads == 1) and (self.head == 1) then
                        drive.head = 0
                    else
                        drive.head = self.head
                    end
                end
            else
                self.sector = self.sector + 1
            end

            end_rw_operation(self, drive, self.drive_select, self.cylinder, self.head, self.sector, self.sector_size, ST0_NORMAL_TERMINATION)
            return
        end

        if not advance_sector(self, drive) then
            return
        end

        self.state = STATE_EXECUTE_COMMAND
        self.timer:advance(self.delay_rw)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Recalibrate Drive Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [0x07] = 1,
    [bor(STATE_START_COMMAND, 0x07)] = function(self)
        local drive_id = band(self.params[0], 0x03)

        self.drives[drive_id].cylinder = 0
        self.drive_select = drive_id
        self.msr = bor(STATUS_MRQ, lshift(1, self.drive_select))
        self.state = STATE_DONE
        self.timer:set_delay(self.delay_reset)
    end,
    [bor(STATE_DONE, 0x07)] = function(self)
        self.pic:request_interrupt(FDC_IRQ)
        self.pending_interrupt = true
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Sense Interrupt Status Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [0x08] = 0,
    [bor(STATE_START_COMMAND, 0x08)] = function(self)
        local st0
        local drive = self.drives[self.drive_select]

        if self.reset_flag then
            st0 = ST0_RESET
            self.reset_sense_count = 1
            self.reset_flag = false
        elseif self.last_command == 0x08 then
            if self.reset_sense_count < 4 then
                st0 = bor(ST0_RESET, band(self.reset_sense_count, 0x03))
                self.reset_sense_count = self.reset_sense_count + 1
            else
                self.reset_flag = false
                self.reset_sense_count = 0
                self.out[0] = ST0_INVALID_OPCODE
                self.params_out = 1
                goto continue
            end
        else
            if self.pending_interrupt then
                st0 = self.drive_select

                if drive.head == 1 then
                    st0 = bor(st0, ST0_HEAD_ACTIVE)
                end

                if (not drive.motor_enabled) or (not drive.present) then
                    st0 = bor(st0, ST0_NOT_READY)
                end

                if (self.last_command == 0x07) or (self.last_command == 0x0F) then
                    st0 = bor(st0, ST0_SEEK_END)
                end

                if self.last_error ~= ST1_NOERROR then
                    st0 = bor(st0, ST0_ABNORMAL_TERMINATION)
                end
            else
                self.out[0] = ST0_INVALID_OPCODE
                self.params_out = 1
                goto continue
            end
        end

        self.out[0] = drive.cylinder
        self.out[1] = st0
        self.params_out = 2

        ::continue::
        self.command = 0x00
        self.state = STATE_DONE
        self.msr = bor(self.msr, bor(STATUS_BUSY, bor(STATUS_DIO, STATUS_MRQ)))
        self.pending_interrupt = false
        self.pic:clear_interrupt(FDC_IRQ)
        self.timer:disable()
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Read Sector ID Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [0x0A] = 1,
    [bor(STATE_START_COMMAND, 0x0A)] = function(self)
        local drive_id = band(self.params[0], 0x03)
        local drive = self.drives[self.drive_select]

        send_results(self, drive_id, drive.cylinder, drive.head, drive.sector, drive.sector_size, ST0_NORMAL_TERMINATION)

        self.pic:request_interrupt(FDC_IRQ)
        self.pending_interrupt = true
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Format Track Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [0x0D] = 5,
    [bor(STATE_START_COMMAND, 0x0D)] = function(self)
        local drive = self.drives[self.drive_select]

        if not drive.present then
            return
        end

        if drive.write_protected then
            fdc_error(self, self.drive_select, bor(ST1_WRITE_PROTECT, ST1_NO_ID))
            return
        end

        self.head = rshift(band(self.params[0], 0x04), 2)

        if self.head > drive.heads then
            self.head = 0
        end

        self.msr = STATUS_BUSY
        self.state = STATE_IDLE
        self.timer:set_delay(256 * self.timer.scheduler.NANOSECOND)
    end,
    [bor(STATE_IDLE, 0x0D)] = function(self)
        self.state = STATE_EXECUTE_COMMAND
        self.timer:set_delay(8 * self.timer.scheduler.NANOSECOND)
    end,
    [bor(STATE_EXECUTE_COMMAND, 0x0D)] = function(self)
        self.drives[self.drive_select].handler:format_track(self.head, self.params[4], self.sector_buffer)
        self.state = STATE_DONE
        self.timer:set_delay(8 * self.timer.scheduler.NANOSECOND)
    end,
    [bor(STATE_DONE, 0x0D)] = function(self)
        end_rw_operation(self, self.drives[self.drive_select], self.drive_select, self.cylinder, self.head, self.sector, self.sector_size, ST0_NORMAL_TERMINATION)
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Seek Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [0x0F] = 2,
    [bor(STATE_START_COMMAND, 0x0F)] = function(self)
        local drive_id = band(self.params[0], 0x03)
        local drive = self.drives[drive_id]

        drive.head = band(rshift(self.params[0], 2), rshift(drive.heads, 1))

        self.msr = bor(STATUS_MRQ, lshift(1, drive_id))

        if self.mt then
            if self.mfm then
                drive.cylinder = drive.cylinder + self.params[1]
            else
                drive.cylinder = drive.cylinder - self.params[1]
            end
        end

        if (not drive.present) or (not drive.motor_enabled) then
            self.pic:request_interrupt(FDC_IRQ)
            self.pending_interrupt = true
            return
        end

        if self.mt then
            if self.params[1] == 0 then
                self.pic:request_interrupt(FDC_IRQ)
                self.pending_interrupt = true
            end

            return
        end

        if (self.params[1] - drive.cylinder) == 0 then
            self.pic:request_interrupt(FDC_IRQ)
            self.pending_interrupt = true
            return
        end

        drive.cylinder = self.params[1]

        self.state = STATE_DONE
        self.timer:set_delay(self.delay_seek)
    end,
    [bor(STATE_DONE, 0x0F)] = function(self)
        self.pic:request_interrupt(FDC_IRQ)
        self.pending_interrupt = true
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Get Version Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [0x10] = 0,
    [bor(STATE_START_COMMAND, 0x10)] = function(self)
        self.msr = bor(band(self.msr, 0x0F), bor(STATUS_MRQ, bor(STATUS_DIO, STATUS_BUSY)))
        self.out[0] = 0x90
        self.params_out = 1
    end,
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Verify Version Command
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    [0x16] = 8,
    [bor(STATE_START_COMMAND, 0x16)] = function(self)
        local drive_id = band(self.params[0], 0x03)
        local drive = self.drives[drive_id]

        if not drive.present then
            return
        end

        if self.params[2] >= drive.heads then
            fdc_error(self, drive_id, ST1_NO_ID, ST0_ABNORMAL_POLLING)
            return
        end

        if self.drq_enabled then
            self.msr = bor(STATUS_DIO, STATUS_BUSY)
            self.dma:request_service(FDC_DMA)
        else
            self.msr = bor(STATUS_BUSY, bor(STATUS_DIO, STATUS_NDMA))
        end

        self.drive_select = drive_id

        self.cylinder = self.params[1]
        self.head = self.params[2]
        self.sector = self.params[3]
        self.sector_size = self.params[4]
        self.sectors = self.params[5]

        if band(self.params[0], 0x80) ~= 0 then
            self.sc = self.params[7]
        end

        self.data_pos = 0
        self.state = STATE_EXECUTE_COMMAND
        self.timer:set_delay(0)
    end,
    [bor(STATE_EXECUTE_COMMAND, 0x16)] = function(self)
        local drive = self.drives[self.drive_select]

        if (self.sector > drive.sectors) or (self.head >= drive.heads) or (self.cylinder >= drive.cylinders) then
            fdc_error(self, self.drive_select, ST1_NO_ID, ST0_ABNORMAL_TERMINATION)
            return
        end

        if band(self.params[0], 0x80) ~= 0 then
            self.sc = self.sc - 1

            if self.sc == 0 then
                self.sector = self.sector + 1
                end_rw_operation(self, drive, self.drive_select, self.cylinder, self.head, self.sector, self.sector_size, ST0_NORMAL_TERMINATION)
            end
        elseif self.head == (self.mt and 1 or 0) then
            self.sector = self.sector + 1
            end_rw_operation(self, drive, self.drive_select, self.cylinder, self.head, self.sector, self.sector_size, ST0_NORMAL_TERMINATION)
        end

        self.msr = bor(STATUS_DIO, STATUS_BUSY)

        if not advance_sector(self, drive) then
            return
        end

        self.state = STATE_EXECUTE_COMMAND
        self.timer:advance(self.delay_rw)
    end
}

local function timer_callback(self)
    local command = commands[bor(self.state, self.command)]

    if command then
        command(self)
        return
    end

    logger:error("FDC: Invalid command: 0x%02X/0x%04X", self.command, self.state)
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Ports
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function port_dor_out(self, cpu, port, val)
    cpu.cycles = cpu.cycles - 8

    if band(val, 0x04) == 0 then
        self.params_num = 0
        self.params_in = 0
        self.msr = 0x00
    elseif band(self.dor, 0x04) == 0 then
        self.params_num = 0
        self.params_in = 0
        self.reset_sense_count = 0
        self.drive_select = 0
        self.msr = STATUS_MRQ
        self.reset_flag = true
        self.pic:request_interrupt(FDC_IRQ)
        self.pending_interrupt = true
    end

    self.drq_enabled = band(val, 0x08) ~= 0
    self.drive_select = band(val, 0x03)
    self.dor = val

    for i = 0, 3, 1 do
        if band(val, lshift(0x10, self.drive_select)) ~= 0 then
            drive_start_motor(self.drives[i])
        else
            drive_stop_motor(self.drives[i])
        end
    end
end

local function port_msr_in(self, cpu, port)
    cpu.cycles = cpu.cycles - 8
    return self.msr
end

local function port_command_register_out(self, cpu, port, val)
    cpu.cycles = cpu.cycles - 8

    if band(self.msr, 0xF0) == 0xB0 then
        self.msr = band(self.msr, bnot(STATUS_MRQ))
        self.data = val
        self.timer:set_delay(0)
        return
    end

    if self.params_num == self.params_in then
        self.last_command = self.command
        self.command = band(val, 0x1F)
        self.mt = band(val, 0x80) ~= 0
        self.mfm = band(val, 0x40) ~= 0

        local params_count = commands[self.command]

        if params_count then
            self.last_error = ST1_NOERROR
            self.params_in = params_count
            self.params_out = 0
            self.params_num = 0

            if self.params_in == 0 then
                self.state = STATE_START_COMMAND
                timer_callback(self)
            end
        else
            logger:error("FDC: Unknown Command 0x%02X", self.command)
        end
    else
        self.params[self.params_num] = val
        self.params_num = self.params_num + 1

        if self.params_num == self.params_in then
            self.timer:disable()
            self.interrupt = self.command
            self.state = STATE_START_COMMAND
            timer_callback(self)
        end
    end
end

local function port_command_register_in(self, cpu, port)
    cpu.cycles = cpu.cycles - 8

    self.msr = band(self.msr, 0xF0)

    if self.msr == 0xF0 then
        self.timer:set_delay(0)
        self.msr = band(self.msr, bnot(STATUS_MRQ))
        self.data_ready = false
        return self.data
    end

    if self.params_out > 0 then
        self.msr = band(self.msr, bnot(STATUS_MRQ))
        self.params_out = self.params_out - 1

        if self.params_out == 0 then
            self.msr = STATUS_MRQ
        else
            self.msr = bor(self.msr, bor(STATUS_MRQ, STATUS_DIO))
        end

        return self.out[self.params_out]
    end

    return 0x00
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function set_drive_callbacks(self, num, callbacks)
    local drive = self.drives[num]

    if not drive then
        error("Invalid drive: " .. num)
    end

    drive.callbacks = callbacks
end

local function insert_drive(self, num, path, write_protected)
    local drive = self.drives[num]

    if not drive then
        error("invalid drive: " .. num)
    end

    local file_ext = file.ext(path)
    local file_format = file_formats[file_ext]

    if not file_format then
        error("unsupported file fromat: " .. file_ext)
    end

    local success, result = pcall(file_format.load, path)

    if not success then
        error("failed to load file: " .. result)
    end

    drive.cylinders = result.cylinders
    drive.heads = result.heads
    drive.sectors = result.sectors
    drive.sector_size = result.sector_size
    drive.handler = result
    drive.write_protected = write_protected
    drive.present = true
end

local function eject_drive(self, num)
    local drive = self.drives[num]

    if not drive then
        error("invalid drive: " .. num)
    end

    drive_stop_motor(self)
    drive.present = false

    if drive.edited then
        drive.edited = false
        drive.handler:save()
    end
end

local function set_clock(self)
    self.delay_rw = 512 * self.timer.scheduler.NANOSECOND
    self.delay_reset = 1000 * self.timer.scheduler.NANOSECOND
    self.delay_seek = 10256 * self.timer.scheduler.NANOSECOND
end

local function reset(self)
    self.params_in = 0
    self.params_out = 0
    self.params_num = 0
    self.dor = 0x00
    self.msr = 0x80
    self.command = 0
    self.last_command = 0
    self.reset_sense_count = 0
    self.drive_select = 0
    self.sectors = 0
    self.cylinder = 0
    self.head = 0
    self.sector = 0
    self.sector_size = 0
    self.state = STATE_IDLE
    self.last_error = 0
    self.sc = 0
    self.data = 0x00
    self.data_pos = 0
    self.data_ready = false
    self.reset_flag = false
    self.mt = false
    self.mfm = false
    self.drq_enabled = false
    self.pending_interrupt = false
    self.timer:disable()
    self.timer:reset()

    reset_drive(self, 0)
    reset_drive(self, 1)
    reset_drive(self, 2)
    reset_drive(self, 3)
end

local function save(self)
    for i = 0, 3, 1 do
        local drive = self.drives[i]

        if drive.edited then
            drive.handler:save()
        end
    end
end

function fdc.new(cpu, pic, dma)
    local self = {
        pic = pic,
        dma = dma,
        params = {[0] = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        out = {[0] = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
        drives = {},
        sector_buffer = {},
        params_in = 0,
        params_out = 0,
        params_num = 0,
        dor = 0x00, -- Digital Output Register
        msr = 0x80, -- Main Status Register
        command = 0,
        last_command = 0x00,
        reset_sense_count = 0,
        drive_select = 0,
        cylinder = 0,
        head = 0,
        sector = 0,
        sector_size = 0,
        sectors = 0,
        delay_rw = 1,
        delay_reset = 1,
        delay_seek = 1,
        state = STATE_IDLE,
        last_error = 0,
        sc = 0,
        data = 0x00,
        data_ready = false,
        data_pos = 0,
        mt = false,
        mfm = false,
        reset_flag = false,
        drq_enabled = false,
        pending_interrupt = false,
        set_clock = set_clock,
        set_drive_callbacks = set_drive_callbacks,
        insert_drive = insert_drive,
        eject_drive = eject_drive,
        save = save,
        reset = reset
    }

    local cpu_io = cpu:get_io()

    cpu_io:set_port_out(0x3F2, port_dor_out)
    cpu_io:set_port_in(0x3F4, port_msr_in)
    cpu_io:set_port(0x3F5, port_command_register_out, port_command_register_in)

    cpu_io:set_out_function_argument(0x3F2, self)
    cpu_io:set_in_function_argument(0x3F4, self)
    cpu_io:set_function_argument(0x3F5, self)

    create_drive(self, 0)
    create_drive(self, 1)
    create_drive(self, 2)
    create_drive(self, 3)

    self.timer = cpu:get_scheduler():add(timer_callback, self, false)

    return self
end

return fdc
