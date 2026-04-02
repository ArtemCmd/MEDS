-- =====================================================================================================================================================================
-- Intel 8088 CPU emulation.
-- =====================================================================================================================================================================

local common = require("emulator:hardware/cpu/common")
local io_ports = require("emulator:io_ports")
local scheduler = require("emulator:scheduler")

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local cpu = {}

local FLAG_C = 0x0001 -- Carry Flag
local FLAG_P = 0x0004 -- Parity Flag
local FLAG_A = 0x0010 -- Auxiliary Carry Flag
local FLAG_Z = 0x0040 -- Zero Flag
local FLAG_S = 0x0080 -- Sign Flag
local FLAG_T = 0x0100 -- Trace Flag
local FLAG_I = 0x0200 -- Interrupt Flag
local FLAG_D = 0x0400 -- Direction Flag
local FLAG_O = 0x0800 -- Overflow Flag

local CLEAR_CAO = bnot(bor(FLAG_C, bor(FLAG_A, FLAG_O)))
local CLEAR_CA = bnot(bor(FLAG_C, FLAG_A))

local REG_AX = 1
local REG_CX = 2
local REG_DX = 3
local REG_BX = 4
local REG_SP = 5
local REG_BP = 6
local REG_SI = 7
local REG_DI = 8

local SEG_ES = 1
local SEG_CS = 2
local SEG_SS = 3
local SEG_DS = 4

local rm_seg_table = {
    [0] = SEG_DS,
    [1] = SEG_DS,
    [2] = SEG_SS,
    [3] = SEG_SS,
    [4] = SEG_DS,
    [5] = SEG_DS,
    [6] = SEG_SS,
    [7] = SEG_DS
}

local mod_rm = {
    [0] = function(self) return self.regs[REG_BX] + self.regs[REG_SI] end,
    [1] = function(self) return self.regs[REG_BX] + self.regs[REG_DI] end,
    [2] = function(self) return self.regs[REG_BP] + self.regs[REG_SI] end,
    [3] = function(self) return self.regs[REG_BP] + self.regs[REG_DI] end,
    [4] = function(self) return self.regs[REG_SI] end,
    [5] = function(self) return self.regs[REG_DI] end,
    [6] = function(self) return self.regs[REG_BP] end,
    [7] = function(self) return self.regs[REG_BX] end
}

local function clock_timer(self)
    local diff = self.cycles_start - self.cycles

    self.scheduler.clock = self.scheduler.clock + diff * 3

    if self.scheduler.clock >= self.scheduler.target then
        self.scheduler:process()
    end
end

local function to_sign_8(val)
    return val - lshift(band(val, 0x80), 1)
end

local function to_sign_16(val)
    return val - lshift(band(val, 0x8000), 1)
end

local function set_of_add(self, bits, oper1, oper2, result)
    local mask = lshift(1, bits - 1)
    local flag = band(band(bxor(result, oper2), bxor(result, oper1)), mask)

    flag = rshift(lshift(flag, rshift(16 - bits, 1)), band(rshift(bits, 2), 0x04))
    self.flags = bor(band(self.flags, bnot(FLAG_O)), flag)
end

local function set_of_sub(self, bits, oper1, oper2, result)
    local mask = lshift(1, bits - 1)
    local flag = band(band(bxor(oper1, oper2), bxor(result, oper1)), mask)

    flag = rshift(lshift(flag, rshift(16 - bits, 1)), band(rshift(bits, 2), 0x04))
    self.flags = bor(band(self.flags, bnot(FLAG_O)), flag)
end

local function set_of_rot(self, bits, val, result)
    local flag = band(bxor(result, val), lshift(1, bits - 1))

    flag = rshift(lshift(flag, rshift(16 - bits, 1)), band(rshift(bits, 2), 0x04))
    self.flags = bor(band(self.flags, bnot(FLAG_O)), flag)
end

local function set_pzs(self, bits, result)
    local size_mask = lshift(1, bits) - 1
    local sign_mask = lshift(1, bits - 1)

    self.flags = band(self.flags, bnot(bor(FLAG_P, bor(FLAG_Z, FLAG_S)))) -- Clear PZS

    self.flags = bor(self.flags, rshift(band(bxor(band(result, size_mask), size_mask) + 1, lshift(1, bits)), bits - 6)) -- Set ZF
    self.flags = bor(self.flags, rshift(band(result, sign_mask), bits - 8)) -- Set SF
    self.flags = bor(self.flags, lshift(common.parity_table[band(result, 0xFF)], 2)) -- Set PF
end

local function set_apzs(self, bits, oper1, oper2, result)
    set_pzs(self, bits, result)
    self.flags = bor(band(self.flags, bnot(FLAG_A)), band(bxor(bxor(result, oper2), oper1), 0x10))
end

local function set_flags_bit(self, bits, result)
    self.flags = band(self.flags, CLEAR_CAO)
    set_pzs(self, bits, result)
end

local function memory_read16(self, segment, offset)
    local low = self.memory:read8(segment + offset)
    local high = self.memory:read8(segment + band(offset + 1, 0xFFFF))

    self.cycles = self.cycles - 8

    return bor(low, lshift(high, 8))
end

local function read_memory(self, opcode, segment, offset)
    if band(opcode, 0x01) == 0x01 then
        return memory_read16(self, segment, band(offset, 0xFFFF))
    end

    self.cycles = self.cycles - 4

    return self.memory:read8(segment + band(offset, 0xFFFF))
end

local function fetch_byte(self)
    local addr = lshift(self.segments[SEG_CS], 4) + self.ip
    self.ip = band(self.ip + 1, 0xFFFF)
    self.cycles = self.cycles - 4
    return self.memory:read8(addr)
end

local function fetch_word(self)
    local addr = lshift(self.segments[SEG_CS], 4) + self.ip
    self.ip = band(self.ip + 2, 0xFFFF)
    self.cycles = self.cycles - 8
    return self.memory:read16_l(addr)
end

local function fetch(self, word)
    if word then
        return fetch_word(self)
    end

    return fetch_byte(self)
end

local function get_reg_byte(self, reg)
    local reg_index = band(reg, 0x03) + 1

    if reg > 3 then
        return rshift(self.regs[reg_index], 8)
    end

    return band(self.regs[reg_index], 0xFF)
end

local function get_reg(self, opcode, reg)
    if band(opcode, 0x1) == 0x1 then
        return self.regs[reg + 1]
    end

    return get_reg_byte(self, reg)
end

local function set_reg_byte(self, reg, val)
    local reg_index = band(reg, 0x03) + 1

    if reg > 3 then
        self.regs[reg_index] = bor(band(self.regs[reg_index], 0x00FF), lshift(band(val, 0xFF), 8))
    else
        self.regs[reg_index] = bor(band(self.regs[reg_index], 0xFF00), band(val, 0xFF))
    end
end

local function set_reg(self, opcode, reg, val)
    if band(opcode, 0x01) == 0x01 then
        self.regs[reg + 1] = band(val, 0xFFFF)
    else
        set_reg_byte(self, reg, val)
    end
end

local function do_mod_rm(self)
    local rm_data = fetch_byte(self)

    self.rm = band(rm_data, 0x07)
    self.reg = band(rshift(rm_data, 3), 0x07)
    self.mode = band(rshift(rm_data, 6), 0x03)
    self.cycles = self.cycles - 1

    if self.mode == 3 then
        return
    end

    self.cycles = self.cycles - 1

    if band(rm_data, 0xC7) == 0x06 then -- 0 mode, 6 R/M
        self.ea_addr = fetch_word(self)
        self.ea_seg = lshift(self.segments[self.segment_mode or SEG_DS], 4)
        self.cycles = self.cycles - 2
    else
        local temp_ea = mod_rm[self.rm](self)

        if (self.rm == 0) or (self.rm == 3) then
            self.cycles = self.cycles - 2
        elseif (self.rm == 1) or (self.rm == 2) then
            self.cycles = self.cycles - 3
        end

        if self.mode == 1 then
            self.cycles = self.cycles - 3
            temp_ea = temp_ea + to_sign_8(fetch_byte(self))
        elseif self.mode == 2 then
            self.cycles = self.cycles - 3
            temp_ea = temp_ea + fetch_word(self)
        end

        self.ea_addr = band(temp_ea, 0xFFFF)
        self.ea_seg = lshift(self.segments[self.segment_mode or rm_seg_table[self.rm]], 4)
        self.cycles = self.cycles - 2
    end
end

local function read_rm_byte(self)
    if self.mode == 3 then
        return get_reg_byte(self, self.rm)
    end

    return self.memory:read8(self.ea_seg + self.ea_addr)
end

local function read_rm_word(self)
    if self.mode == 3 then
        return self.regs[self.rm + 1]
    end

    return memory_read16(self, self.ea_seg, self.ea_addr)
end

local function write_rm_byte(self, val)
    if self.mode == 3 then
        set_reg_byte(self, self.rm, val)
    else
        self.memory:write8(self.ea_seg + self.ea_addr, band(val, 0xFF))
        self.cycles = self.cycles - 4
    end
end

local function write_rm_word(self, val)
    if self.mode == 3 then
        self.regs[self.rm + 1] = band(val, 0xFFFF)
    else
        self.memory:write8(self.ea_seg + self.ea_addr, band(val, 0xFF))
        self.memory:write8(self.ea_seg + band(self.ea_addr + 1, 0xFFFF), band(rshift(val, 8), 0xFF))
        self.cycles = self.cycles - 8
    end
end

local function read_rm(self, opcode)
    if band(opcode, 0x01) == 0x01 then
        return read_rm_word(self)
    end

    return read_rm_byte(self)
end

local function write_rm(self, opcode, val)
    if band(opcode, 0x1) == 0x1 then
        write_rm_word(self, val)
    else
        write_rm_byte(self, val)
    end
end

local function push(self, val)
    self.regs[REG_SP] = band(self.regs[REG_SP] - 2, 0xFFFF)

    local base = lshift(self.segments[SEG_SS], 4)
    local offset = self.regs[REG_SP]

    self.memory:write8(base + offset, band(val, 0xFF))
    self.memory:write8(base + band(offset + 1, 0xFFFF), rshift(val, 8))
    self.cycles = self.cycles - 8
end

local function pop(self)
    local base_addr = lshift(self.segments[SEG_SS], 4)
    local low = self.memory:read8(base_addr + self.regs[REG_SP])
    local high = self.memory:read8(base_addr + band(self.regs[REG_SP] + 1, 0xFFFF))

    self.cycles = self.cycles - 8
    self.regs[REG_SP] = band(self.regs[REG_SP] + 2, 0xFFFF)

    return bor(low, lshift(high, 8))
end

local function call_interrupt(self, id)
    local addr = lshift(id, 2)

    push(self, band(self.flags, 0xFFD7))
    push(self, self.segments[SEG_CS])
    push(self, self.ip)

    self.ip = self.memory:read16_l(addr)
    self.segments[SEG_CS] = self.memory:read16_l(addr + 2)
    self.flags = band(self.flags, bnot(0x0300)) -- IF, TF
    self.cycles = self.cycles - 37
end

local function irq_pending(self)
    return (self.nmi and self.nmi_enabled and not self.nmi_triggered) or
           ((band(self.flags, FLAG_T) ~= 0) and (self.no_int == 0)) or
           ((band(self.flags, FLAG_I) ~= 0) and (self.no_int == 0) and self.pic.int_pending)
end

local function check_interrupts(self)
    if not irq_pending(self) then
        return
    end

    if (band(self.flags, FLAG_T) ~= 0) and (self.no_int ~= 1) then
        call_interrupt(self, 0x01)
        return
    end

    if self.nmi and self.nmi_enabled and not self.nmi_triggered then
        self.nmi_triggered = true
        call_interrupt(self, 0x02)
        return
    end

    if (band(self.flags, FLAG_I) ~= 0) and self.pic.int_pending and (self.no_int == 0) then
        self.repeating = false
        self.completed = true
        self.segment_mode = nil
        self.opcode = 0x00
        self.cycles = self.cycles - 17

        call_interrupt(self, self.pic:get_interrupt_vector())

        return
    end
end

local function cpu_add(self, opcode, alu_opcode, oper1, oper2)
    local bits = lshift(8, band(opcode, 0x01))
    local size_mask = lshift(1, bits) - 1
    local result = oper1 + oper2
    local carry = 0

    if (alu_opcode == 2) and (band(self.flags, FLAG_C) ~= 0) then
        carry = 1
    end

    set_of_add(self, bits, oper1, oper2 - carry, result)
    set_apzs(self, bits, oper1, oper2 - carry, result)

    if ((alu_opcode == 2) and (band(oper2, size_mask) == 0) and (band(self.flags, FLAG_C) ~= 0)) or (band(oper2, size_mask) > band(result, size_mask)) then
        self.flags = bor(self.flags, FLAG_C)
    else
        self.flags = band(self.flags, bnot(FLAG_C))
    end

    return result
end

local function cpu_or(self, opcode, alu_opcode, oper1, oper2)
    local bits = lshift(8, band(opcode, 0x01))
    local result = bor(oper1, oper2)
    set_flags_bit(self, bits, result)
    return result
end

local function cpu_test(self, opcode, alu_opcode, oper1, oper2)
    local bits = lshift(8, band(opcode, 0x01))
    local result = band(oper1, oper2)
    set_flags_bit(self, bits, result)
    return result
end

local function cpu_xor(self, opcode, alu_opcode, oper1, oper2)
    local bits = lshift(8, band(opcode, 0x01))
    local result = bxor(oper1, oper2)
    set_flags_bit(self, bits, result)
    return result
end

local function cpu_sub(self, opcode, alu_opcode, oper1, oper2)
    local bits = lshift(8, band(opcode, 0x01))
    local result = oper1 - oper2
    local size_mask = lshift(1, bits) - 1
    local carry = 0

    if (alu_opcode == 3) and (band(self.flags, FLAG_C) ~= 0) then
        carry = 1
    end

    set_apzs(self, bits, oper1, oper2 - carry, result)
    set_of_sub(self, bits, oper1, oper2 - carry, result)

    if ((alu_opcode == 3) and (band(oper2, size_mask) == 0) and (band(self.flags, FLAG_C) ~= 0)) or (band(oper2, size_mask) > band(oper1, size_mask)) then
        self.flags = bor(self.flags, FLAG_C)
    else
        self.flags = band(self.flags, bnot(FLAG_C))
    end

    return result
end

local function cpu_rol(self, bits, val)
    self.flags = bor(band(self.flags, bnot(FLAG_C)), band(rshift(val, bits - 1), 0x01))

    local result = bor(lshift(val, 1), band(self.flags, FLAG_C))
    set_of_rot(self, bits, val, result)

    return result
end

local function cpu_ror(self, bits, val)
    local result = rshift(val, 1)

    self.flags = bor(band(self.flags, bnot(FLAG_C)), band(val, 0x01))
    result = bor(result, lshift(band(self.flags, FLAG_C), bits - 1))
    set_of_rot(self, bits, val, result)

    return result
end

local function cpu_rcl(self, bits, val)
    local mask = lshift(1, bits) - 1
    local result = band(bor(lshift(val, 1), band(self.flags, 0x01)), mask)

    self.flags = bor(band(self.flags, bnot(FLAG_C)), band(rshift(val, bits - 1), 0x01))
    set_of_rot(self, bits, val, result)

    return result
end

local function cpu_rcr(self, bits, val)
    local result = bor(rshift(val, 1), lshift(band(self.flags, FLAG_C), bits - 1))

    self.flags = bor(band(self.flags, bnot(FLAG_C)), band(val, 0x01))
    set_of_rot(self, bits, val, result)

    return result
end

local function cpu_shl(self, bits, val)
    local result = lshift(val, 1)

    self.flags = band(self.flags, CLEAR_CA)
    self.flags = bor(self.flags, band(rshift(val, bits - 1), 0x01)) -- Set CF
    self.flags = bor(self.flags, band(result, 0x10)) -- Set AF

    set_of_rot(self, bits, val, result)
    set_pzs(self, bits, result)

    return result
end

local function cpu_shr(self, bits, val)
    local result = rshift(val, 1)

    self.flags = band(self.flags, CLEAR_CA)
    self.flags = bor(self.flags, band(val, 0x01)) -- Set CF

    set_of_rot(self, bits, val, result)
    set_pzs(self, bits, result)

    return result
end

local function cpu_setmo(self, bits, val)
    self.flags = band(self.flags, bnot(bor(FLAG_C, bor(FLAG_A, FLAG_O))))
    set_pzs(self, bits, 0xFFFF)
    return 0xFFFF
end

local function cpu_sar(self, bits, val)
    local mask = lshift(1, bits - 1)
    local result = bor(rshift(val, 1), band(val, mask))

    self.flags = band(self.flags, CLEAR_CA)
    self.flags = bor(self.flags, band(val, 0x01)) -- Set CF

    set_of_rot(self, bits, val, result)
    set_pzs(self, bits, result)

    return result
end

local function cpu_mul(self, bits, oper1, oper2)
    local size_mask = lshift(1, bits) - 1
    local a = band(oper1, size_mask)
    local b = band(oper2, size_mask)
    local c = 0
    local temp = 0
    local carry = band(a, 0x01)

    self.cycles = self.cycles - (16 - bits) - 3

    a = rshift(a, 1)

    for _ = 1, bits, 1 do
        self.cycles = self.cycles - 7

        if carry ~= 0 then
            local temp_c = c
            c = band(b + c, size_mask)
            carry = (band(temp_c, size_mask) > c) and 0x01 or 0x00
            self.cycles = self.cycles - 1
        end

        temp = bor(rshift(c, 1), lshift(carry, bits - 1))
        carry = band(c, 0x01)
        c = temp

        temp = bor(rshift(a, 1), lshift(carry, bits - 1))
        carry = band(a, 0x01)
        a = temp
    end

    local mask = bor(FLAG_C, FLAG_O)

    if c ~= 0 then
        self.flags = bor(self.flags, mask)
    else
        self.flags = band(self.flags, bnot(mask))
    end

    return bor(a, lshift(c, bits))
end

local function cpu_imul(self, bits, oper1, oper2)
    local size_mask = lshift(1, bits) - 1
    local high_bit = lshift(1, bits - 1)
    local a = oper1
    local b = oper2
    local c = 0
    local negate = false

    self.cycles = self.cycles - 10

    if band(a, high_bit) == 0 then
        if band(b, high_bit) ~= 0 then
            self.cycles = self.cycles - 1

            b = bnot(b) + 1
            negate = true
        end
    else
        self.cycles = self.cycles - 1
        a = bnot(a) + 1

        if band(b, high_bit) ~= 0 then
            b = bnot(b) + 1
            negate = false
        else
            self.cycles = self.cycles - 4
            negate = true
        end
    end

    local result = cpu_mul(self, bits, a, b)

    a = band(result, size_mask)
    c = rshift(result, bits)

    if negate then
        c = bnot(c)
        a = band(bnot(a) + 1, size_mask)

        if a == 0 then
            c = c + 1
        end

        self.cycles = self.cycles - 9
    end

    result = c + rshift(band(a, high_bit), bits - 1)
    c = band(c, size_mask)

    set_apzs(self, 16, c, 0, result)

    local mask = bor(FLAG_C, FLAG_O)

    if result ~= 0 then
        self.flags = bor(self.flags, mask)
    else
        self.flags = band(self.flags, bnot(mask))
    end

    return bor(a, lshift(c, bits))
end

local function cpu_div(self, bits, high, low, oper2)
    local size_mask = lshift(1, bits) - 1
    local high_bit = lshift(1, bits - 1)
    local tmp_high = high
    local tmp_low = low
    local tmp_oper2 = band(oper2, size_mask)
    local carry = (tmp_oper2 > band(high, size_mask)) and 0x01 or 0x00
    local result = high - oper2

    self.flags = bor(band(self.flags, bnot(FLAG_C)), carry)
    self.cycles = self.cycles - 8

    set_apzs(self, bits, high, oper2, result)
    set_of_sub(self, bits, high, oper2, result)

    if carry == 0x00 then
        call_interrupt(self, 0x00)
        return nil
    end

    self.cycles = self.cycles - 3

    for i = 1, bits, 1 do
        self.cycles = self.cycles - 8

        local new_low = bor(lshift(tmp_low, 1), carry)
        carry = rshift(band(tmp_low, high_bit), bits - 1)
        tmp_low = new_low

        local new_high = bor(lshift(tmp_high, 1), carry)
        carry = rshift(band(tmp_high, high_bit), bits - 1)
        tmp_high = new_high

        if carry ~= 0 then
            carry = 0
            tmp_high = tmp_high - tmp_oper2

            if i == bits then
                self.cycles = self.cycles - 2
            end
        else
            result = tmp_high - tmp_oper2

            set_apzs(self, bits, tmp_high, oper2, result)
            set_of_sub(self, bits, tmp_high, oper2, result)
            carry = (band(oper2, size_mask) > band(tmp_high, size_mask)) and 0x01 or 0x00

            if carry == 0 then
                self.cycles = self.cycles - 1
                tmp_high = result

                if i == bits then
                    self.cycles = self.cycles - 2
                end
            end
        end
    end

    tmp_low = bor(lshift(tmp_low, 1), carry)
    carry = band(tmp_low, high_bit)

    self.flags = bor(band(self.flags, bnot(FLAG_C)), carry)

    return {tmp_high, bnot(tmp_low)}
end

local function cpu_idiv(self, bits, high, low, oper2, negate)
    local high_bit = lshift(1, bits - 1)
    local size_mask = lshift(1, bits) - 1
    local a = high
    local b = low
    local c = oper2
    local negative = negate
    local dividend_negative = false

    self.cycles = self.cycles - 17

    if band(a, high_bit) ~= 0 then
        a = bnot(a)
        b = band(bnot(b) + 1, size_mask)

        if b == 0 then
            a = a + 1
        end

        a = band(a, size_mask)

        negative = not negative
        dividend_negative = true

        self.cycles = self.cycles - 4
    end

    if band(c, high_bit) ~= 0 then
        c = bnot(c) + 1
        negative = not negative
    else
        self.cycles = self.cycles - 1
    end

    c = band(c, size_mask)

    local result = cpu_div(self, bits, a, b, c)

    if result then
        self.cycles = self.cycles - 11

        a = result[1]
        b = result[2]

        if band(b, high_bit) ~= 0 then
            if self.mode == 3 then
                self.cycles = self.cycles - 1
            end

            call_interrupt(self, 0x00)
            return nil
        end

        if negative then
            b = bnot(b) + 1
        end

        if dividend_negative then
            a = bnot(a) + 1
        end

        self.flags = band(self.flags, bnot(bor(FLAG_C, FLAG_O))) -- Clear CF & OF

        return {a, b}
    end
end

local function rep_action(self)
    if self.rep_type == 0 then
        return false
    end

    self.cycles = self.cycles - 2

    if irq_pending(self) and self.repeating then
        self.ip = band(self.ip - 2, 0xFFFF)
        self.completed = true
        self.repeating = false
        return true
    end

    if self.regs[REG_CX] == 0 then
        self.cycles = self.cycles - 1
        self.completed = true
        self.repeating = false
        return true
    end

    if not self.repeating then
        self.cycles = self.cycles - 2
    end

    self.cycles = self.cycles - 2
    self.regs[REG_CX] = band(self.regs[REG_CX] - 1, 0xFFFF)
    self.completed = false

    return false
end

local function string_increment(self, opcode, val)
    local amount = lshift(1, band(opcode, 0x1))

    if band(self.flags, FLAG_D) ~= 0 then
        return band(val - amount, 0xFFFF)
    else
        return band(val + amount, 0xFFFF)
    end
end

local function cpu_loads(self, opcode)
    local base = lshift(self.segments[self.segment_mode or SEG_DS], 4)
    local offset = self.regs[REG_SI]

    self.regs[REG_SI] = string_increment(self, opcode, self.regs[REG_SI])

    if band(opcode, 0x01) == 0x01 then
        local low = self.memory:read8(base + offset)
        local high = self.memory:read8(base + band(offset + 1, 0xFFFF))

        self.cycles = self.cycles - 8

        return bor(low, lshift(high, 8))
    end

    self.cycles = self.cycles - 4


    return self.memory:read8(base + offset)
end

local function cpu_stos(self, opcode, val)
    local base = lshift(self.segments[SEG_ES], 4)
    local offset = self.regs[REG_DI]

    if band(opcode, 0x01) == 0x01 then
        self.memory:write8(base + offset, band(val, 0xFF))
        self.memory:write8(base + band(offset + 1, 0xFFFF), band(rshift(val, 8), 0xFF))
        self.cycles = self.cycles - 8
    else
        self.memory:write8(base + offset, band(val, 0xFF))
        self.cycles = self.cycles - 4
    end

    self.regs[REG_DI] = string_increment(self, opcode, self.regs[REG_DI])
end

local alu_opcodes = {
    [0] = cpu_add,
    [1] = cpu_or,
    [2] = function(self, opcode, alu_opcode, oper1, oper2) -- ADC
        return cpu_add(self, opcode, alu_opcode, oper1, oper2 + band(self.flags, FLAG_C))
    end,
    [3] = function(self, opcode, alu_opcode, oper1, oper2) -- SBB
        return cpu_sub(self, opcode, alu_opcode, oper1, oper2 + band(self.flags, FLAG_C))
    end,
    [4] = cpu_test,
    [5] = cpu_sub,
    [6] = cpu_xor,
    [7] = cpu_sub -- CMP
}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function generate_read_rm(opcode)
    if band(opcode, 0x01) ~= 0 then
       return "read_rm_word"
    end

    return "read_rm_byte"
end

local function generate_read_reg(opcode)
    if band(opcode, 0x01) ~= 0 then
       return "self.regs[self.reg + 1]"
    end

    return "get_reg_byte(self, self.reg)"
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local opcodes = {}

-- NOP
opcodes[0x90] = function(self, opcode)
    self.cycles = self.cycles - 2
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
--- Arithmetic/logical instructions.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- ALU RM, R / R, RM
local alu_opcodes_code = {
    [0] = "cpu_add(self, opcode, %s, %s)",
    [1] = "cpu_or(self, opcode, %s, %s)",
    [2] = "cpu_add(self, opcode, %s, %s + band(self.flags, FLAG_C))", -- ADC
    [3] = "cpu_sub(self, opcode, %s, %s + band(self.flags, FLAG_C))", -- SBB
    [4] = "cpu_test(self, opcode, %s, %s)",
    [5] = "cpu_sub(self, opcode, %s, %s)",
    [6] = "cpu_xor(self, opcode, %s, %s)",
    [7] = "cpu_sub(self, opcode, %s, %s)" -- CMP
}

local function generate_opcode_alu_rm_rm(opcode)
    local code = [[
        local do_mod_rm, read_rm, get_reg_byte, write_rm, set_reg, cpu_add, cpu_or, cpu_sub, cpu_test, cpu_xor, read_rm_word, read_rm_byte, FLAG_C, band = ...
        return function(self, opcode)
            do_mod_rm(self)

            local oper1 = %s(self)
            local oper2 = %s
            local result = %s

            self.cycles = self.cycles - 3

            if self.mode ~= 3 then
                self.cycles = self.cycles - 2
            end

            %s
        end
    ]]

    local operands
    local output
    local alu_opcode = band(rshift(opcode, 3), 0x07)

    if band(opcode, 0x02) == 0 then
        operands = "oper1, oper2"
    else
        operands = "oper2, oper1"
    end

    if alu_opcode ~= 7 then
        if band(opcode, 0x02) == 0 then
            output = [[
            write_rm(self, opcode, result)

            if self.mode == 3 then
                self.cycles = self.cycles - 1
            end
            ]]
        else
            output = [[
            set_reg(self, opcode, self.reg, result)
            self.cycles = self.cycles - 1
            ]]
        end
    else
        output = "self.cycles = self.cycles - 1"
    end

    opcodes[opcode] = load(string.format(code, generate_read_rm(opcode), generate_read_reg(opcode), string.format(alu_opcodes_code[alu_opcode], tostring(alu_opcode), operands), output), "=i8088.lua-alu", "t")(do_mod_rm, read_rm, get_reg_byte, write_rm, set_reg, cpu_add, cpu_or, cpu_sub, cpu_test, cpu_xor, read_rm_word, read_rm_byte, FLAG_C, band)
end

generate_opcode_alu_rm_rm(0x00)
generate_opcode_alu_rm_rm(0x01)
generate_opcode_alu_rm_rm(0x02)
generate_opcode_alu_rm_rm(0x03)
generate_opcode_alu_rm_rm(0x08)
generate_opcode_alu_rm_rm(0x09)
generate_opcode_alu_rm_rm(0x0A)
generate_opcode_alu_rm_rm(0x0B)
generate_opcode_alu_rm_rm(0x10)
generate_opcode_alu_rm_rm(0x11)
generate_opcode_alu_rm_rm(0x12)
generate_opcode_alu_rm_rm(0x13)
generate_opcode_alu_rm_rm(0x18)
generate_opcode_alu_rm_rm(0x19)
generate_opcode_alu_rm_rm(0x1A)
generate_opcode_alu_rm_rm(0x1B)
generate_opcode_alu_rm_rm(0x20)
generate_opcode_alu_rm_rm(0x21)
generate_opcode_alu_rm_rm(0x22)
generate_opcode_alu_rm_rm(0x23)
generate_opcode_alu_rm_rm(0x28)
generate_opcode_alu_rm_rm(0x29)
generate_opcode_alu_rm_rm(0x2A)
generate_opcode_alu_rm_rm(0x2B)
generate_opcode_alu_rm_rm(0x30)
generate_opcode_alu_rm_rm(0x31)
generate_opcode_alu_rm_rm(0x32)
generate_opcode_alu_rm_rm(0x33)
generate_opcode_alu_rm_rm(0x38)
generate_opcode_alu_rm_rm(0x39)
generate_opcode_alu_rm_rm(0x3A)
generate_opcode_alu_rm_rm(0x3B)

-- ALU A, IMM
local function generate_opcode_alu_ax_imm(opcode)
    local operand1, operand2, output, alu_opcode, operaton

    if band(opcode, 0x01) == 0x01 then -- 16 bit
        operand1 = string.format("self.regs[%d]", REG_AX)
        operand2 = "fetch_word(self)"
    else -- 8 bit
        operand1 = string.format("band(self.regs[%d], 0xFF)", REG_AX)
        operand2 = "fetch_byte(self)"
    end

    alu_opcode = band(rshift(opcode, 0x03), 0x07)
    operaton = string.format(alu_opcodes_code[alu_opcode], tostring(alu_opcode), "oper1, oper2")

    if alu_opcode ~= 7 then
        if band(opcode, 0x01) ~= 0 then -- 16 bit
            output = string.format("self.regs[%d] = band(result, 0xFFFF)", REG_AX)
        else -- 8 bit
            output = string.format("self.regs[%d] = bor(band(self.regs[%d], 0xFF00), band(result, 0xFF))", REG_AX, REG_AX)
        end
    else -- CMP
        output = ""
    end

    opcodes[opcode] = load(string.format([[
        local band, bor, fetch_word, fetch_byte, FLAG_C, cpu_add, cpu_or, cpu_sub, cpu_test, cpu_xor = ...
        return function(self, opcode)
            local oper1, oper2 = %s, %s
            local result = %s
            %s
            self.cycles = self.cycles - 3
        end
    ]], operand1, operand2, operaton, output), "i8088-alu_ax_imm", "t", _G)(band, bor, fetch_word, fetch_byte, FLAG_C, cpu_add, cpu_or, cpu_sub, cpu_test, cpu_xor)
end

generate_opcode_alu_ax_imm(0x04)
generate_opcode_alu_ax_imm(0x05)
generate_opcode_alu_ax_imm(0x0C)
generate_opcode_alu_ax_imm(0x0D)
generate_opcode_alu_ax_imm(0x14)
generate_opcode_alu_ax_imm(0x15)
generate_opcode_alu_ax_imm(0x1C)
generate_opcode_alu_ax_imm(0x1D)
generate_opcode_alu_ax_imm(0x24)
generate_opcode_alu_ax_imm(0x25)
generate_opcode_alu_ax_imm(0x2C)
generate_opcode_alu_ax_imm(0x2D)
generate_opcode_alu_ax_imm(0x34)
generate_opcode_alu_ax_imm(0x35)
generate_opcode_alu_ax_imm(0x3C)
generate_opcode_alu_ax_imm(0x3D)

-- INC r16
opcodes[0x40] = function(self, opcode)
    local reg = band(opcode, 0x07) + 1
    local val = self.regs[reg]
    local result = val + 1

    set_of_add(self, 16, val, 1, result)
    set_apzs(self, 16, val, 1, result)

    self.regs[reg] = band(result, 0xFFFF)
    self.cycles = self.cycles - 1
end
opcodes[0x41] = opcodes[0x40]
opcodes[0x42] = opcodes[0x40]
opcodes[0x43] = opcodes[0x40]
opcodes[0x44] = opcodes[0x40]
opcodes[0x45] = opcodes[0x40]
opcodes[0x46] = opcodes[0x40]
opcodes[0x47] = opcodes[0x40]

-- DEC r16
opcodes[0x48] = function(self, opcode)
    local reg = band(opcode, 0x07) + 1
    local val = self.regs[reg]
    local result = val - 1

    set_of_sub(self, 16, val, 1, result)
    set_apzs(self, 16, val, 1, result)

    self.regs[reg] = band(result, 0xFFFF)
    self.cycles = self.cycles - 1
end
opcodes[0x49] = opcodes[0x48]
opcodes[0x4A] = opcodes[0x48]
opcodes[0x4B] = opcodes[0x48]
opcodes[0x4C] = opcodes[0x48]
opcodes[0x4D] = opcodes[0x48]
opcodes[0x4E] = opcodes[0x48]
opcodes[0x4F] = opcodes[0x48]

-- TEST rm, reg
opcodes[0x84] = function(self, opcode)
    do_mod_rm(self)

    local bits = lshift(8, band(opcode, 0x01))
    local result = band(read_rm(self, opcode), get_reg(self, opcode, self.reg))

    set_flags_bit(self, bits, result)
    self.cycles = self.cycles - 3

    if self.mode == 3 then
        self.cycles = self.cycles - 2
    end
end
opcodes[0x85] = opcodes[0x84]

-- TEST AL, imm8
opcodes[0xA8] = function(self, opcode)
    set_flags_bit(self, 8, band(band(self.regs[REG_AX], 0xFF), fetch_byte(self)))
    self.cycles = self.cycles - 2
end

-- TEST AX, imm16
opcodes[0xA9] = function(self, opcode)
    set_flags_bit(self, 16, band(self.regs[REG_AX], fetch_word(self)))
    self.cycles = self.cycles - 2
end

-- CBW
opcodes[0x98] = function(self, opcode)
    local val = band(self.regs[REG_AX], 0xFF)

    if val >= 0x80 then
        val = bor(val, 0xFF00)
    end

    self.regs[REG_AX] = val
    self.cycles = self.cycles - 1
end

-- CWD
opcodes[0x99] = function(self, opcode)
    if self.regs[REG_AX] >= 0x8000 then
        self.cycles = self.cycles - 1
        self.regs[REG_DX] = 0xFFFF
    else
        self.regs[REG_DX] = 0x0000
    end

    self.cycles = self.cycles - 4
end

-- AAM
opcodes[0xD4] = function(self, opcode)
    local val = fetch_byte(self)

    self.flags = band(self.flags, bnot(bor(FLAG_C, bor(FLAG_A, FLAG_O))))

    if val == 0 then
        set_pzs(self, 8, 0)
        call_interrupt(self, 0x00)
        return
    end

    local al = band(self.regs[REG_AX], 0xFF)
    local new_ah = math.floor(al / val)
    local new_al = al % val

    set_pzs(self, 8, new_al)

    self.regs[REG_AX] = bor(lshift(band(new_ah, 0xFF), 8), band(new_al, 0xFF))
    self.cycles = self.cycles - 78
end

-- AAD
opcodes[0xD5] = function(self, opcode)
    local val = fetch_byte(self)
    local ah = band(rshift(self.regs[REG_AX], 8), 0xFF)
    local result = band(cpu_add(self, 0, 0, ah * val, band(self.regs[REG_AX], 0xFF)), 0xFF)

    self.regs[REG_AX] = result
    set_pzs(self, 8, result)

    self.cycles = self.cycles - 54
end

-- DAA
opcodes[0x27] = function(self, opcode)
    local al = band(self.regs[REG_AX], 0xFF)
    local af = band(self.flags, FLAG_A) ~= 0
    local temp_al = al

    self.flags = band(self.flags, bnot(FLAG_O))

    if af or (band(temp_al, 0x0F) > 9) then
        al = al + 0x06
        set_of_add(self, 8, temp_al, 6, al)
        self.flags = bor(self.flags, FLAG_A)
    end

    if (band(self.flags, FLAG_C) ~= 0) or (temp_al > (af and 0x9F or 0x99)) then
        al = al + 0x60
        set_of_add(self, 8, temp_al, 6, al)
        self.flags = bor(self.flags, FLAG_C)
    end

    set_pzs(self, 8, al)

    self.regs[REG_AX] = bor(band(self.regs[REG_AX], 0xFF00), band(al, 0xFF))
    self.cycles = self.cycles - 3
end

-- DAS
opcodes[0x2F] = function(self, opcode)
    local al = band(self.regs[REG_AX], 0xFF)
    local af = band(self.flags, FLAG_A) ~= 0
    local temp_al = al

    self.flags = band(self.flags, bnot(FLAG_O))

    if af or (band(temp_al, 0x0F) > 9) then
        al = al - 0x06
        set_of_sub(self, 8, temp_al, 6, al)
        self.flags = bor(self.flags, FLAG_A)
    end

    if (band(self.flags, FLAG_C) ~= 0) or (temp_al > (af and 0x9F or 0x99)) then
        al = al - 0x60
        set_of_sub(self, 8, temp_al, 6, al)
        self.flags = bor(self.flags, FLAG_C)
    end

    set_pzs(self, 8, al)

    self.regs[REG_AX] = bor(band(self.regs[REG_AX], 0xFF00), band(al, 0xFF))
    self.cycles = self.cycles - 3
end

-- AAA
opcodes[0x37] = function(self, opcode)
    local al = band(self.regs[REG_AX], 0xFF)
    local src

    self.cycles = self.cycles - 7

    if (band(self.flags, FLAG_A) ~= 0) or (band(al, 0x0F) > 9) then
        src = 0x06
        self.regs[REG_AX] = band(self.regs[REG_AX] + 0x100, 0xFFFF)
        self.flags = bor(self.flags, 0x11) -- AF, CF
    else
        src = 0x00
        self.flags = band(self.flags, bnot(0x11)) -- AF, CF
        self.cycles = self.cycles - 1
    end

    local result = al + src
    self.regs[REG_AX] = bor(band(self.regs[REG_AX], 0xFF00), band(result, 0x0F))

    set_of_add(self, 8, al, src, result)
    set_pzs(self, 8, result)
end

-- AAS
opcodes[0x3F] = function(self, opcode)
    local al = band(self.regs[REG_AX], 0xFF)
    local oper2

    self.cycles = self.cycles - 7

    if (band(self.flags, FLAG_A) ~= 0) or (band(al, 0x0F) > 9) then
        oper2 = 0x06
        self.regs[REG_AX] = band(self.regs[REG_AX] - 0x100, 0xFFFF)
        self.flags = bor(self.flags, 0x11) -- AF, CF
    else
        oper2 = 0
        self.flags = band(self.flags, bnot(0x11)) -- AF, CF
        self.cycles = self.cycles - 1
    end

    local result = al - oper2

    set_of_sub(self, 8, al, oper2, result)
    set_pzs(self, 8, result)

    self.regs[REG_AX] = bor(band(self.regs[REG_AX], 0xFF00), band(result, 0x0F))
end

-- SALC
opcodes[0xD6] = function(self, opcode)
    if band(self.flags, 0x01) ~= 0 then
        self.regs[REG_AX] = bor(self.regs[REG_AX], 0xFF)
    else
        self.regs[REG_AX] = band(self.regs[REG_AX], 0xFF00)
    end

    self.cycles = self.cycles - 2
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Groups Instructions.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- GRP1
opcodes[0x80] = function(self, opcode)
    do_mod_rm(self)

    local oper1 = read_rm(self, opcode)
    local oper2

    self.cycles = self.cycles - 2

    if opcode == 0x81 then
        self.cycles = self.cycles - 1
        oper2 = fetch_word(self)
    elseif opcode == 0x83 then
        oper2 = to_sign_8(fetch_byte(self))

        if self.mode == 3 then
            self.cycles = self.cycles - 1
        end
    else
        oper2 = fetch_byte(self)

        if self.mode == 3 then
            self.cycles = self.cycles - 1
        end
    end

    local result = alu_opcodes[self.reg](self, opcode, self.reg, oper1, oper2)

    if self.mode ~= 3 then
        self.cycles = self.cycles - 3
    end

    if self.reg ~= 7 then
        self.cycles = self.cycles - 2
        write_rm(self, opcode, result)
    elseif self.mode ~= 3 then
        self.cycles = self.cycles - 1
    end
end
opcodes[0x81] = opcodes[0x80]
opcodes[0x82] = opcodes[0x80]
opcodes[0x83] = opcodes[0x80]

-- GRP2
local grp2_table = {
    [0] = cpu_rol,
    [1] = cpu_ror,
    [2] = cpu_rcl,
    [3] = cpu_rcr,
    [4] = cpu_shl,
    [5] = cpu_shr,
    [6] = cpu_setmo,
    [7] = cpu_sar
}

opcodes[0xD0] = function(self, opcode)
    do_mod_rm(self)

    local bits = lshift(8, band(opcode, 0x01))
    local result = read_rm(self, opcode)
    local operation = grp2_table[self.reg]

    self.cycles = self.cycles - 3

    if band(opcode, 0x02) == 0x02 then
        local count = band(self.regs[REG_CX], 0xFF)

        while count ~= 0 do
            result = operation(self, bits, result)
            count = count - 1
            self.cycles = self.cycles - 4
        end

        if self.mode ~= 3 then
            self.cycles = self.cycles - 4
        else
            self.cycles = self.cycles - 1
        end
    else
        result = operation(self, bits, result)

        if self.mode ~= 3 then
            self.cycles = self.cycles - 9
        else
            self.cycles = self.cycles - 7
        end
    end

    write_rm(self, opcode, result)
end
opcodes[0xD1] = opcodes[0xD0]
opcodes[0xD2] = opcodes[0xD0]
opcodes[0xD3] = opcodes[0xD0]

-- GRP3
local grp3_table = {
    [1] = function(self, opcode, val) -- TEST
        local bits = lshift(8, band(opcode, 0x01))
        local result = band(val, fetch(self, band(opcode, 0x01) == 0x01))
        set_flags_bit(self, bits, result)
        self.cycles = self.cycles - 4

        if self.mode ~= 3 then
            self.cycles = self.cycles - 2
        end
    end,
    [2] = function(self, opcode, val) -- NOT
        write_rm(self, opcode, bnot(val))
        self.cycles = self.cycles - 5
    end,
    [3] = function(self, opcode, val) -- NEG
        local result = cpu_sub(self, opcode, 0, 0, val)
        write_rm(self, opcode, result)
        self.cycles = self.cycles - 5
    end,
    [4] = function(self, opcode, val) -- MUL
        local bits = lshift(8, band(opcode, 0x01))

        self.cycles = self.cycles - 1

        if self.mode ~= 3 then
            self.cycles = self.cycles - 1
        end

        if bits == 8 then
            local result = cpu_mul(self, bits, band(self.regs[REG_AX], 0xFF), val)

            self.regs[REG_AX] = band(result, 0xFFFF)

            set_pzs(self, bits, rshift(self.regs[REG_AX], 8))
        else
            local result = cpu_mul(self, bits, self.regs[REG_AX], val)

            self.regs[REG_AX] = band(result, 0xFFFF)
            self.regs[REG_DX] = band(rshift(result, 16), 0xFFFF)

            set_pzs(self, bits, self.regs[REG_DX])
        end

        self.flags = band(self.flags, bnot(FLAG_A))
    end,
    [5] = function(self, opcode, val) -- IMUL
        local bits = lshift(8, band(opcode, 0x01))

        self.cycles = self.cycles - 1

        if self.mode ~= 3 then
            self.cycles = self.cycles - 1
        end

        if bits == 8 then
            local result = cpu_imul(self, bits, band(self.regs[REG_AX], 0xFF), val)
            self.regs[REG_AX] = band(result, 0xFFFF)
        else
            local result = cpu_imul(self, bits, self.regs[REG_AX], val)

            self.regs[REG_AX] = band(result, 0xFFFF)
            self.regs[REG_DX] = band(rshift(result, 16), 0xFFFF)
        end
    end,
    [6] = function(self, opcode, val) -- DIV
        local bits = lshift(8, band(opcode, 0x01))

        if self.mode ~= 3 then
            self.cycles = self.cycles - 1
        end

        if bits == 16 then
            local result = cpu_div(self, bits, self.regs[REG_DX], self.regs[REG_AX], val)

            if result then
                self.regs[REG_DX] = band(result[1], 0xFFFF)
                self.regs[REG_AX] = band(result[2], 0xFFFF)
                self.cycles = self.cycles - 1
            end
        else
            local oper1 = self.regs[REG_AX]
            local result = cpu_div(self, bits, rshift(oper1, 8), band(oper1, 0xFF), val)

            if result then
                self.regs[REG_AX] = bor(band(result[2], 0xFF), lshift(band(result[1], 0xFF), 8))
                self.cycles = self.cycles - 1
            end
        end
    end,
    [7] = function(self, opcode, val) -- IDIV
        local bits = lshift(8, band(opcode, 0x01))
        local negate = self.rep_type ~= 0

        if self.mode ~= 3 then
            self.cycles = self.cycles - 1
        end

        if bits == 16 then
            local result = cpu_idiv(self, bits, self.regs[REG_DX], self.regs[REG_AX], val, negate)

            if result then
                self.regs[REG_DX] = band(result[1], 0xFFFF)
                self.regs[REG_AX] = band(result[2], 0xFFFF)
                self.cycles = self.cycles - 1
            end
        else
            local oper1 = self.regs[REG_AX]
            local result = cpu_idiv(self, bits, rshift(oper1, 8), band(oper1, 0xFF), val, negate)

            if result then
                self.regs[REG_AX] = bor(band(result[2], 0xFF), lshift(band(result[1], 0xFF), 8))
                self.cycles = self.cycles - 1
            end
        end
    end
}
grp3_table[0x00] = grp3_table[0x01]

opcodes[0xF6] = function(self, opcode)
    do_mod_rm(self)
    grp3_table[self.reg](self, opcode, read_rm(self, opcode))
end
opcodes[0xF7] = opcodes[0xF6]

-- GRP4/5
local grp4_grp5_table = {
    [0] = function(self, opcode) -- INC rm
        local bits = lshift(8, band(opcode, 0x01))
        local val = read_rm(self, opcode)
        local result = val + 1

        set_of_add(self, bits, val, 1, result)
        set_apzs(self, bits, val, 1, result)
        write_rm(self, opcode, result)

        self.cycles = self.cycles - 3
    end,
    [1] = function(self, opcode) -- DEC rm
        local bits = lshift(8, band(opcode, 0x01))
        local val = read_rm(self, opcode)
        local result = val - 1

        set_of_sub(self, bits, val, 1, result)
        set_apzs(self, bits, val, 1, result)
        write_rm(self, opcode, result)

        self.cycles = self.cycles - 3
    end,
    [2] = function(self, opcode) -- CALL near abs
        local new_ip = read_rm(self, opcode)

        push(self, self.ip)

        self.ip = new_ip
        self.cycles = self.cycles - 10

        if self.mode ~= 3 then
            self.cycles = self.cycles - 1
        end
    end,
    [3] = function(self, opcode) -- CALL abs near
        local new_ip = read_memory(self, opcode, self.ea_seg, self.ea_addr)
        local new_cs = read_memory(self, opcode, self.ea_seg, self.ea_addr + 2)

        push(self, self.segments[SEG_CS])
        push(self, self.ip)

        self.ip = new_ip
        self.segments[SEG_CS] = new_cs
        self.cycles = self.cycles - 16

        if self.mode ~= 3 then
            self.cycles = self.cycles - 1
        end
    end,
    [4] = function(self, opcode) -- JMP near abs
        self.ip = read_rm(self, opcode)
        self.cycles = self.cycles - 3

        if self.mode ~= 3 then
            self.cycles = self.cycles - 1
        end
    end,
    [5] = function(self, opcode) -- JMP far
        self.ip = read_memory(self, opcode, self.ea_seg, self.ea_addr)
        self.segments[SEG_CS] = read_memory(self, opcode, self.ea_seg, self.ea_addr + 2)
        self.cycles = self.cycles - 6

        if self.mode ~= 3 then
            self.cycles = self.cycles - 1
        end
    end,
    [6] = function(self, opcode) -- PUSH rm
        if (band(opcode, 0x01) == 0x01) and (self.mode == 3) and (self.rm == 4) then -- SP
            push(self, self.regs[REG_SP] - 2)
        else
            push(self, read_rm(self, opcode))
        end

        self.cycles = self.cycles - 6

        if self.mode ~= 3 then
            self.cycles = self.cycles - 1
        end
    end
}

grp4_grp5_table[0x07] = grp4_grp5_table[0x06]

-- GRP4 / GRP5
opcodes[0xFE] = function(self, opcode)
    do_mod_rm(self)
    grp4_grp5_table[self.reg](self, opcode)
end
opcodes[0xFF] = opcodes[0xFE]

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Load/store/move instructions.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- PUSH seg
local function generate_opcode_push_seg(opcode, segment)
    opcodes[opcode] = load(string.format([[
        local push = ...
        return function(self, opcode)
            push(self, self.segments[%d])
            self.cycles = self.cycles - 4
        end
    ]], segment), "=i8088.lua-push-seg", "t")(push)
end

generate_opcode_push_seg(0x06, SEG_ES)
generate_opcode_push_seg(0x0E, SEG_CS)
generate_opcode_push_seg(0x16, SEG_SS)
generate_opcode_push_seg(0x1E, SEG_DS)

-- POP seg
local function generate_opcode_pop_seg(opcode, segment)
    opcodes[opcode] = load(string.format([[
        local pop = ...
        return function(self, opcode)
            self.segments[%d] = pop(self)
            self.no_int = 1
            self.cycles = self.cycles - 3
        end
    ]], segment), "=i8088.lua-pop-seg", "t")(pop)
end

generate_opcode_pop_seg(0x07, SEG_ES)
generate_opcode_pop_seg(0x0F, SEG_CS)
generate_opcode_pop_seg(0x17, SEG_SS)
generate_opcode_pop_seg(0x1F, SEG_DS)

-- PUSH r16
local function generate_opcode_push_r16(opcode, reg, code)
    opcodes[opcode] = load(string.format([[
        local push = ...
        return function(self, opcode)
            push(self, self.regs[%d]%s)
            self.cycles = self.cycles - 4
        end
    ]], reg, code or ""), "=i8088.lua-push_r16", "t")(push)
end

generate_opcode_push_r16(0x50, REG_AX)
generate_opcode_push_r16(0x51, REG_CX)
generate_opcode_push_r16(0x52, REG_DX)
generate_opcode_push_r16(0x53, REG_BX)
generate_opcode_push_r16(0x54, REG_SP, " - 2")
generate_opcode_push_r16(0x55, REG_BP)
generate_opcode_push_r16(0x56, REG_SI)
generate_opcode_push_r16(0x57, REG_DI)

-- POP r16
local function generate_opcode_pop_r16(opcode, reg)
    opcodes[opcode] = load(string.format([[
        local pop = ...
        return function(self, opcode)
            self.regs[%d] = pop(self)
            self.cycles = self.cycles - 11
        end
    ]], reg), "=i8088.lua-pop_r16", "t")(pop)
end

generate_opcode_pop_r16(0x58, REG_AX)
generate_opcode_pop_r16(0x59, REG_CX)
generate_opcode_pop_r16(0x5A, REG_DX)
generate_opcode_pop_r16(0x5B, REG_BX)
generate_opcode_pop_r16(0x5C, REG_SP)
generate_opcode_pop_r16(0x5D, REG_BP)
generate_opcode_pop_r16(0x5E, REG_SI)
generate_opcode_pop_r16(0x5F, REG_DI)

-- PUSHF
opcodes[0x9C] = function(self, opcode)
    push(self, bor(band(self.flags, 0x0FD7), 0xF000))
    self.cycles = self.cycles - 4
end

-- POPF
opcodes[0x9D] = function(self, opcode)
    local old = self.flags

    self.flags = bor(band(pop(self), 0xFD5), 0xF002)

    if band(bxor(self.flags, old), FLAG_T) ~= 0 then
        self.no_int = 1
    end

    self.cycles = self.cycles - 3
end

-- POPW
opcodes[0x8F] = function(self, opcode)
    do_mod_rm(self)
    write_rm_word(self, pop(self))
    self.cycles = self.cycles - 6

    if self.mode ~= 3 then
        self.cycles = self.cycles - 2
    end
end

-- XCHG A, reg
opcodes[0x91] = function(self, opcode)
    local reg = band(opcode, 0x7) + 1
    local temp = self.regs[reg]
    self.regs[reg] = self.regs[REG_AX]
    self.regs[REG_AX] = temp
    self.cycles = self.cycles - 2
end
opcodes[0x92] = opcodes[0x91]
opcodes[0x93] = opcodes[0x91]
opcodes[0x94] = opcodes[0x91]
opcodes[0x95] = opcodes[0x91]
opcodes[0x96] = opcodes[0x91]
opcodes[0x97] = opcodes[0x91]

-- XCHG rm, reg
opcodes[0x86] = function(self, opcode)
    do_mod_rm(self)

    local val = get_reg(self, opcode, self.reg)
    set_reg(self, opcode, self.reg, read_rm(self, opcode))
    write_rm(self, opcode, val)

    self.cycles = self.cycles - 8
end
opcodes[0x87] = opcodes[0x86]

-- MOV rm, reg
opcodes[0x88] = function(self, opcode)
    do_mod_rm(self)
    write_rm(self, opcode, get_reg(self, opcode, self.reg))
    self.cycles = self.cycles - 2

    if self.mode ~= 3 then
        self.cycles = self.cycles - 2
    end
end
opcodes[0x89] = opcodes[0x88]

-- MOV reg, rm
opcodes[0x8A] = function(self, opcode)
    do_mod_rm(self)
    set_reg(self, opcode, self.reg, read_rm(self, opcode))
    self.cycles = self.cycles - 2

    if self.mode ~= 3 then
        self.cycles = self.cycles - 2
    end
end
opcodes[0x8B] = opcodes[0x8A]

-- MOV rm, seg
opcodes[0x8C] = function(self, opcode)
    do_mod_rm(self)
    write_rm_word(self, self.segments[band(self.reg, 0x03) + 1])
    self.cycles = self.cycles - 4

    if self.mode == 3 then
        self.cycles = self.cycles - 1
    end
end

-- MOV seg, rm
opcodes[0x8E] = function(self, opcode)
    do_mod_rm(self)
    self.segments[band(self.reg, 0x03) + 1] = read_rm_word(self)

    if self.reg == 2 then
        self.no_int = 1
    end

    self.cycles = self.cycles - 2

    if self.mode ~= 3 then
        self.cycles = self.cycles - 3
    end
end

-- MOV rm, imm
opcodes[0xC6] = function(self, opcode)
    do_mod_rm(self)
    write_rm(self, opcode, fetch(self, band(opcode, 0x1) ~= 0))
    self.cycles = self.cycles - 4

    if self.mode ~= 3 then
        self.cycles = self.cycles - 10
    end
end
opcodes[0xC7] = opcodes[0xC6]

-- MOV AL, offset8
opcodes[0xA0] = function(self, opcode)
    local addr = fetch_word(self)
    self.regs[REG_AX] = bor(band(self.regs[REG_AX], 0xFF00), self.memory:read8(lshift(self.segments[self.segment_mode or 4], 4) + addr))
    self.cycles = self.cycles - 7
end

-- MOV AX, offset16
opcodes[0xA1] = function(self, opcode)
    local addr = fetch_word(self)
    self.regs[REG_AX] = self.memory:read16_l(lshift(self.segments[self.segment_mode or 4], 4) + addr)
    self.cycles = self.cycles - 11
end

-- MOV offset8, AL
opcodes[0xA2] = function(self, opcode)
    local addr = fetch_word(self)
    self.memory:write8(lshift(self.segments[self.segment_mode or 4], 4) + addr, band(self.regs[REG_AX], 0xFF))
    self.cycles = self.cycles - 6
end

-- MOV offset16, AL
opcodes[0xA3] = function(self, opcode)
    local addr = fetch_word(self)
    self.memory:write16_l(lshift(self.segments[self.segment_mode or 4], 4) + addr, self.regs[REG_AX])
    self.cycles = self.cycles - 10
end

-- MOV regL, imm8
opcodes[0xB0] = function(self, opcode)
    local reg = band(opcode, 0x03) + 1
    self.regs[reg] = bor(band(self.regs[reg], 0xFF00), fetch_byte(self))
    self.cycles = self.cycles - 2
end
opcodes[0xB1] = opcodes[0xB0]
opcodes[0xB2] = opcodes[0xB0]
opcodes[0xB3] = opcodes[0xB0]

-- MOV regH, imm8
opcodes[0xB4] = function(self, opcode)
    local reg = band(opcode, 0x03) + 1
    self.regs[reg] = bor(band(self.regs[reg], 0xFF), lshift(fetch_byte(self), 8))
    self.cycles = self.cycles - 2
end
opcodes[0xB5] = opcodes[0xB4]
opcodes[0xB6] = opcodes[0xB4]
opcodes[0xB7] = opcodes[0xB4]

-- MOV reg, imm16
opcodes[0xB8] = function(self, opcode)
    self.regs[band(opcode, 0x07) + 1] = fetch_word(self)
    self.cycles = self.cycles - 2
end
opcodes[0xB9] = opcodes[0xB8]
opcodes[0xBA] = opcodes[0xB8]
opcodes[0xBB] = opcodes[0xB8]
opcodes[0xBC] = opcodes[0xB8]
opcodes[0xBD] = opcodes[0xB8]
opcodes[0xBE] = opcodes[0xB8]
opcodes[0xBF] = opcodes[0xB8]

-- LES/LDS
opcodes[0xC4] = function(self, opcode)
    do_mod_rm(self)

    self.regs[self.reg + 1] = memory_read16(self, self.ea_seg, self.ea_addr)
    local val = memory_read16(self, self.ea_seg, band(self.ea_addr + 2, 0xFFFF))

    if opcode == 0xC5 then
        self.segments[SEG_DS] = val
    else
        self.segments[SEG_ES] = val
    end

    self.cycles = self.cycles - 7

    if self.mode ~= 3 then
        self.cycles = self.cycles - 2
    end
end
opcodes[0xC5] = opcodes[0xC4]

-- LEA
opcodes[0x8D] = function(self, opcode)
    do_mod_rm(self)
    self.regs[self.reg + 1] = self.ea_addr
    self.cycles = self.cycles - 1

    if self.mode ~= 3 then
        self.cycles = self.cycles - 2
    end
end

-- SAHF
opcodes[0x9E] = function(self, opcode)
    self.flags = bor(band(self.flags, 0xFF02), rshift(band(self.regs[REG_AX], 0xD500), 8))
    self.cycles = self.cycles - 3
end

-- LAHF
opcodes[0x9F] = function(self, opcode)
    self.regs[REG_AX] = bor(band(self.regs[REG_AX], 0xFF), lshift(band(self.flags, 0xD7), 8))
    self.cycles = self.cycles - 1
end

-- XLAT
opcodes[0xD7] = function(self, opcode)
    local addr = band(self.regs[REG_BX] + band(self.regs[REG_AX], 0xFF), 0xFFFF)
    self.regs[REG_AX] = bor(band(self.regs[REG_AX], 0xFF00), self.memory:read8(lshift(self.segments[self.segment_mode or 4], 4) + addr))
    self.cycles = self.cycles - 10
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- String instructions.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- MOVSB/MOVSW
opcodes[0xA4] = function(self, opcode)
    if not self.repeating then
        self.cycles = self.cycles - 1 - band(self.rep_type, 0x01) - rshift(self.rep_type, 1)
    end

    if rep_action(self) then
        self.cycles = self.cycles - 1
        return
    end

    self.cycles = self.cycles - 4
    cpu_stos(self, opcode, cpu_loads(self, opcode))

    if self.rep_type == 0 then
        self.cycles = self.cycles - 3
        return
    end

    self.repeating = true
    clock_timer(self)
end
opcodes[0xA5] = opcodes[0xA4]

-- CMPSB/CMPSW
opcodes[0xA6] = function(self, opcode)
    if not self.repeating then
        self.cycles = self.cycles - 1
    end

    if rep_action(self) then
        self.cycles = self.cycles - 2
        return
    end

    local oper1 = cpu_loads(self, opcode)
    local oper2 = read_memory(self, opcode, lshift(self.segments[SEG_ES], 4), self.regs[REG_DI])

    self.regs[REG_DI] = string_increment(self, opcode, self.regs[REG_DI])
    self.cycles = self.cycles - 5

    cpu_sub(self, opcode, 0, oper1, oper2)

    if self.rep_type == 0 then
        self.cycles = self.cycles - 3
        return
    end

    self.cycles = self.cycles - 1

    if (band(self.flags, FLAG_Z) ~= 0) == (self.rep_type == 1) then
        self.completed = true
        self.cycles = self.cycles - 4
        return
    end

    self.repeating = true
    clock_timer(self)
end
opcodes[0xA7] = opcodes[0xA6]

-- STOSB/STOSW
opcodes[0xAA] = function(self, opcode)
    if not self.repeating then
        self.cycles = self.cycles - 1 - band(self.rep_type, 0x01) - rshift(self.rep_type, 1)
    end

    if rep_action(self) then
        self.cycles = self.cycles - 1
        return
    end

    cpu_stos(self, opcode, self.regs[REG_AX])
    self.cycles = self.cycles - 1

    if self.rep_type == 0 then
        self.cycles = self.cycles - 3
        return
    end

    self.repeating = true
    clock_timer(self)
end
opcodes[0xAB] = opcodes[0xAA]

-- LODSB/LODSW
opcodes[0xAC] = function(self, opcode)
    if not self.repeating then
        self.cycles = self.cycles - 1 - band(bxor(rshift(opcode, 3), 0x01), self.rep_type) - band(bxor(rshift(opcode, 3), 0x01), rshift(self.rep_type, 1))
    end

    if rep_action(self) then
        self.cycles = self.cycles - 1 - band(rshift(opcode, 3), 0x01)
        return
    end

    local val = cpu_loads(self, opcode)

    if band(opcode, 0x01) == 0x01 then
        self.regs[REG_AX] = val
    else
        self.regs[REG_AX] = bor(band(self.regs[REG_AX], 0xFF00), band(val, 0xFF))
    end

    self.cycles = self.cycles - 1

    if self.rep_type == 0 then
        self.cycles = self.cycles - 3 - rshift(band(opcode, 0x08), 3)
        return
    end

    self.cycles = self.cycles - 2 - rshift(band(opcode, 0x08), 3)
    self.repeating = true

    clock_timer(self)
end
opcodes[0xAD] = opcodes[0xAC]

-- SCASB/SCASW
opcodes[0xAE] = function(self, opcode)
    if not self.repeating then
        self.cycles = self.cycles - 1
    end

    if rep_action(self) then
        self.cycles = self.cycles - 2
        return
    end

    local oper1
    local oper2 = read_memory(self, opcode, lshift(self.segments[SEG_ES], 4), self.regs[REG_DI])

    if band(opcode, 0x01) == 0x01 then
        oper1 = self.regs[REG_AX]
    else
        oper1 = band(self.regs[REG_AX], 0xFF)
    end

    self.regs[REG_DI] = string_increment(self, opcode, self.regs[REG_DI])
    self.cycles = self.cycles - 3

    cpu_sub(self, opcode, 0, oper1, oper2)

    if self.rep_type == 0 then
        self.cycles = self.cycles - 3
        return
    end

    self.cycles = self.cycles - 1

    if (band(self.flags, FLAG_Z) ~= 0) == (self.rep_type == 1) then
        self.completed = true
        self.cycles = self.cycles - 4
        return
    end

    self.repeating = true
    clock_timer(self)
end
opcodes[0xAF] = opcodes[0xAE]

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Jumps/calls instructions.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- JMP
local jmp_conds = {
    [0] = "band(self.flags, FLAG_O) ~= 0",
    "band(self.flags, FLAG_O) == 0",
    "band(self.flags, FLAG_C) ~= 0",
    "band(self.flags, FLAG_C) == 0",
    "band(self.flags, FLAG_Z) ~= 0",
    "band(self.flags, FLAG_Z) == 0",
    "(band(self.flags, FLAG_C) ~= 0) or (band(self.flags, FLAG_Z) ~= 0)",
    "(band(self.flags, FLAG_C) == 0) and (band(self.flags, FLAG_Z) == 0)",
    "band(self.flags, FLAG_S) ~= 0",
    "band(self.flags, FLAG_S) == 0",
    "band(self.flags, FLAG_P) ~= 0",
    "band(self.flags, FLAG_P) == 0",
    "(band(self.flags, FLAG_O) ~= 0) ~= (band(self.flags, FLAG_S) ~= 0)",
    "(band(self.flags, FLAG_O) ~= 0) == (band(self.flags, FLAG_S) ~= 0)",
    "(band(self.flags, FLAG_Z) ~= 0) or ((band(self.flags, FLAG_S) ~= 0) ~= (band(self.flags, FLAG_O) ~= 0))",
    "(band(self.flags, FLAG_Z) == 0) and ((band(self.flags, FLAG_S) ~= 0) == (band(self.flags, FLAG_O) ~= 0))"
}

local function generate_opcode_jmp_cond(opcode, cond)
    opcodes[opcode] = load(string.format([[
        local to_sign_8, fetch_byte, band, FLAG_O, FLAG_C, FLAG_Z, FLAG_S, FLAG_P = ...
        return function(self, opcode)
            local offset = fetch_byte(self)
            self.cycles = self.cycles - 2

            if %s then
                self.ip = band(self.ip + to_sign_8(offset), 0xFFFF)
                self.cycles = self.cycles - 5
            end
        end
    ]], cond), "=i8088.lua-jmp", "t")(to_sign_8, fetch_byte, band, FLAG_O, FLAG_C, FLAG_Z, FLAG_S, FLAG_P)
end

for i = 0x60, 0x7F, 1 do
    generate_opcode_jmp_cond(i, jmp_conds[band(i, 0xF)])
end

-- JMP rel16
opcodes[0xE9] = function(self, opcode)
    local offset = to_sign_16(fetch_word(self))
    self.ip = band(self.ip + offset, 0xFFFF)
    self.cycles = self.cycles - 6
end

-- JMP ptr
opcodes[0xEA] = function(self, opcode)
    local new_ip = fetch_word(self)
    local new_cs = fetch_word(self)
    self.ip = new_ip
    self.segments[SEG_CS] = new_cs
    self.cycles = self.cycles - 7
end

-- JMP rel8
opcodes[0xEB] = function(self, opcode)
    local offset = to_sign_8(fetch_byte(self))
    self.ip = band(self.ip + offset, 0xFFFF)
    self.cycles = self.cycles - 7
end

-- JCXZ r8
opcodes[0xE3] = function(self, opcode)
    local offset = to_sign_8(fetch_byte(self))
    self.cycles = self.cycles - 4

    if self.regs[REG_CX] == 0 then
        self.ip = band(self.ip + offset, 0xFFFF)
        self.cycles = self.cycles - 5
    end
end

-- CALL FAR
opcodes[0x9A] = function(self, opcode)
    local new_ip = fetch_word(self)
    local new_cs = fetch_word(self)

    push(self, self.segments[SEG_CS])
    push(self, self.ip)

    self.ip = new_ip
    self.segments[SEG_CS] = new_cs
    self.cycles = self.cycles - 15
end

-- CALL rel16
opcodes[0xE8] = function(self, opcode)
    local offset = to_sign_16(fetch_word(self))
    push(self, self.ip)
    self.ip = band(self.ip + offset, 0xFFFF)
    self.cycles = self.cycles - 5
end

-- RET
opcodes[0xC0] = function(self, opcode)
    local disp = fetch_word(self)
    self.ip = pop(self)
    self.regs[REG_SP] = band(self.regs[REG_SP] + disp, 0xFFFF)
    self.cycles = self.cycles - 7
end
opcodes[0xC2] = opcodes[0xC0]

-- RET
opcodes[0xC1] = function(self, opcode)
    self.ip = pop(self)
    self.cycles = self.cycles - 4
end
opcodes[0xC3] = opcodes[0xC1]

-- RETF
opcodes[0xCA] = function(self, opcode)
    local imm16 = fetch_word(self)
    self.ip = pop(self)
    self.segments[SEG_CS] = pop(self)
    self.regs[REG_SP] = band(self.regs[REG_SP] + imm16, 0xFFFF)
    self.cycles = self.cycles - 10 - band(opcode, 0x01)
end
opcodes[0xC8] = opcodes[0xCA]

-- RETF
opcodes[0xCB] = function(self, opcode)
    self.ip = pop(self)
    self.segments[SEG_CS] = pop(self)
    self.cycles = self.cycles - 9 - band(opcode, 0x01)
end
opcodes[0xC9] = opcodes[0xCB]

-- LOOPNZ rel8
opcodes[0xE0] = function(self, opcode)
    local offset = to_sign_8(fetch_byte(self))

    self.regs[REG_CX] = band(self.regs[REG_CX] - 1, 0xFFFF)
    self.cycles = self.cycles - 4

    if (self.regs[REG_CX] ~= 0) and (band(self.flags, 0x40) == 0) then
        self.ip = band(self.ip + offset, 0xFFFF)
        self.cycles = self.cycles - 5
    end
end

-- LOOPZ rel8
opcodes[0xE1] = function(self, opcode)
    local offset = to_sign_8(fetch_byte(self))

    self.regs[REG_CX] = band(self.regs[REG_CX] - 1, 0xFFFF)
    self.cycles = self.cycles - 4

    if (self.regs[REG_CX] ~= 0) and (band(self.flags, 0x40) ~= 0) then
        self.ip = band(self.ip + offset, 0xFFFF)
        self.cycles = self.cycles - 5
    end
end

-- LOOP rel8
opcodes[0xE2] = function(self, opcode)
    local offset = to_sign_8(fetch_byte(self))

    self.regs[REG_CX] = band(self.regs[REG_CX] - 1, 0xFFFF)
    self.cycles = self.cycles - 3

    if self.regs[REG_CX] ~= 0 then
        self.ip = band(self.ip + offset, 0xFFFF)
        self.cycles = self.cycles - 5
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 	Misc/control instructions.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- INT 3
opcodes[0xCC] = function(self, opcode)
    call_interrupt(self, 0x03)
end

-- INT imm
opcodes[0xCD] = function(self, opcode)
    call_interrupt(self, fetch_byte(self))
    self.cycles = self.cycles - 1
end

-- INTO
opcodes[0xCE] = function(self, opcode)
    self.cycles = self.cycles - 3

    if band(self.flags, FLAG_O) ~= 0 then
        self.cycles = self.cycles - 2
        call_interrupt(self, 0x04)
    end
end

-- IRET
opcodes[0xCF] = function(self, opcode)
    self.ip = pop(self)
    self.segments[SEG_CS] = pop(self)
    self.flags =  bor(band(pop(self), 0xFD5), 0xF002)
    self.no_int = 2
    self.nmi_triggered = false
    self.cycles = self.cycles - 13
end

-- WAIT
opcodes[0x9B] = function(self, opcode)
    if not self.repeating then
        self.cycles = self.cycles - 2
    end

    self.cycles = self.cycles - 12
    check_interrupts(self)
end

-- 8087 FPU
opcodes[0xD8] = function(self, opcode)
    do_mod_rm(self)
    self.cycles = self.cycles - 3

    if self.mode ~= 3 then
        self.cycles = self.cycles - 2
    end
end
opcodes[0xD9] = opcodes[0xD8]
opcodes[0xDA] = opcodes[0xD8]
opcodes[0xDB] = opcodes[0xD8]
opcodes[0xDC] = opcodes[0xD8]
opcodes[0xDD] = opcodes[0xD8]
opcodes[0xDE] = opcodes[0xD8]
opcodes[0xDF] = opcodes[0xD8]

-- IN
local function generate_opcode_in(opcode, word, port, cycles)
    local io_code
    local destination

    if word then
        io_code = [[
            local low = self.io:in_port(port)
            local high = self.io:in_port(port + 1)
            local val = bor(low, lshift(high, 8))
        ]]

        destination = [[
            self.regs[REG_AX] = val
        ]]
    else
        io_code = [[
            local val = self.io:in_port(port)
        ]]

        destination = [[
            self.regs[REG_AX] = bor(band(self.regs[REG_AX], 0xFF00), val)
        ]]
    end

    opcodes[opcode] = load(string.format([[
        local fetch_byte, band, bor, lshift, rshift, REG_AX, REG_DX = ...
        return function(self, opcode)
            self.cycles = self.cycles - %d

            local old_cycles = self.cycles
            local port = %s
            %s
            %s

            if old_cycles > self.cycles then
                local diff = old_cycles - self.cycles
                self.cycles = old_cycles

                if diff <= 0 then
                    return
                end

                self.cycles = self.cycles - diff
            end
        end
    ]], cycles, port, io_code, destination), "=i8088.lua-in", "t")(fetch_byte, band, bor, lshift, rshift, REG_AX, REG_DX)
end

generate_opcode_in(0xE4, false, "fetch_byte(self)", 7)
generate_opcode_in(0xE5, true, "fetch_byte(self)", 11)
generate_opcode_in(0xEC, false, "self.regs[REG_DX]", 6)
generate_opcode_in(0xED, true, "self.regs[REG_DX]", 10)

-- OUT
local function generate_opcode_out(opcode, word, port, val, cycles)
    local io_code

    if word then
        io_code = [[
            self.io:out_port(port, band(val, 0xFF))
            self.io:out_port(port + 1, rshift(val, 8))
        ]]
    else
        io_code = [[
            self.io:out_port(port, val)
        ]]
    end

    opcodes[opcode] = load(string.format([[
        local fetch_byte, band, rshift, REG_AX, REG_DX = ...
        return function(self, opcode)
            self.cycles = self.cycles - %d

            local old_cycles = self.cycles
            local port = %s
            local val = %s
            %s

            if old_cycles > self.cycles then
                local diff = old_cycles - self.cycles
                self.cycles = old_cycles

                if diff <= 0 then
                    return
                end

                self.cycles = self.cycles - diff
            end
        end
    ]], cycles, port, val, io_code), "=i8088.lua-out", "t")(fetch_byte, band, rshift, REG_AX, REG_DX)
end

generate_opcode_out(0xE6, false, "fetch_byte(self)", "band(self.regs[REG_AX], 0xFF)", 6)
generate_opcode_out(0xE7, true, "fetch_byte(self)", "self.regs[REG_AX]", 10)
generate_opcode_out(0xEE, false, "self.regs[REG_DX]", "band(self.regs[REG_AX], 0xFF)", 5)
generate_opcode_out(0xEF, true, "self.regs[REG_DX]", "self.regs[REG_AX]", 9)

-- HLT
opcodes[0xF4] = function(self, opcode)
    if not self.repeating then
        self.cycles = self.cycles - 1
    end

    self.cycles = self.cycles - 1

    if irq_pending(self) then
        self.cycles = self.cycles - band(self.cycles, 0x01)
        check_interrupts(self)
    else
        self.repeating = true
        self.completed = false
        clock_timer(self)
    end
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Prefixes.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- REPNZ
opcodes[0xF2] = function(self, opcode)
    self.rep_type = 1
    self.completed = false
    self.cycles = self.cycles - 1
end

-- REPZ
opcodes[0xF3] = function(self, opcode)
    self.rep_type = 2
    self.completed = false
    self.cycles = self.cycles - 1
end

-- LOCK
opcodes[0xF0] = function(self, opcode)
    self.cycles = self.cycles - 1
    self.completed = false
end
opcodes[0xF1] = opcodes[0xF0]

-- SEGMENT:
local function generate_opcode_segment_prefix(opcode, segment)
    opcodes[opcode] = load(string.format([[
        return function(self, opcode)
            self.segment_mode = %d
            self.completed = false
            self.cycles = self.cycles - 1
        end
    ]], segment), "=i8088.lua-seg-prefix", "t")()
end

generate_opcode_segment_prefix(0x26, SEG_ES)
generate_opcode_segment_prefix(0x2E, SEG_CS)
generate_opcode_segment_prefix(0x36, SEG_SS)
generate_opcode_segment_prefix(0x3E, SEG_DS)

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Flag control instructions.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function generate_opcode_clear_flag(opcode, flag)
    opcodes[opcode] = load(string.format([[
        local band, bnot = ...
        return function(self, opcode)
            self.flags = band(self.flags, bnot(%d))
            self.cycles = self.cycles - 1
        end
    ]], flag), "=i8088.lua-clear_flag", "t")(band, bnot)
end

local function generate_opcode_set_flag(opcode, flag)
    opcodes[opcode] = load(string.format([[
        local bor = ...
        return function(self, opcode)
            self.flags = bor(self.flags, %d)
            self.cycles = self.cycles - 1
        end
    ]], flag), "=i8088.lua-set_flag", "t")(bor)
end

generate_opcode_clear_flag(0xF8, FLAG_C)
generate_opcode_set_flag(0xF9, FLAG_C)

generate_opcode_clear_flag(0xFA, FLAG_I)
generate_opcode_set_flag(0xFB, FLAG_I)

generate_opcode_clear_flag(0xFC, FLAG_D)
generate_opcode_set_flag(0xFD, FLAG_D)

-- CMC
opcodes[0xF5] = function(self, opcode)
    self.flags = bxor(self.flags, FLAG_C)
    self.cycles = self.cycles - 1
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function step(self)
    self.cycles_start = self.cycles

    if not self.repeating then
        self.cycles = self.cycles - 1
        self.opcode = fetch_byte(self)
    end

    self.completed = true
    opcodes[self.opcode](self, self.opcode)

    if self.completed then
        self.repeating = false
        self.segment_mode = nil
        self.rep_type = 0

        clock_timer(self)
        check_interrupts(self)

        self.no_int = 0
    end
end

local function execute(self, cycles)
    self.cycles = self.cycles + cycles

    while self.cycles > 0 do
        step(self)
    end
end

local function set_reset_vector(self, cs, ip)
    self.reset_cs = band(cs, 0xFFFF)
    self.reset_ip = band(ip, 0xFFFF)
end

local function get_io(self)
    return self.io
end

local function get_scheduler(self)
    return self.scheduler
end

local function get_reg_name(self, name)
    if name == "AX" then
        return self.regs[REG_AX]
    elseif name == "BX" then
        return self.regs[REG_BX]
    elseif name == "CX" then
        return self.regs[REG_CX]
    elseif name == "DX" then
        return self.regs[REG_DX]
    elseif name == "CS" then
        return self.segments[SEG_CS]
    elseif name == "SS" then
        return self.segments[SEG_SS]
    elseif name == "DS" then
        return self.segments[SEG_DS]
    elseif name == "ES" then
        return self.segments[SEG_ES]
    elseif name == "SP" then
        return self.regs[REG_SP]
    elseif name == "BP" then
        return self.regs[REG_BP]
    elseif name == "SI" then
        return self.regs[REG_SI]
    elseif name == "DI" then
        return self.regs[REG_DI]
    elseif name == "IP" then
        return self.ip
    elseif name == "FLAGS" then
        return self.flags
    end

    error("invalid register: " .. name)
end

local function set_reg_name(self, name, val)
    if name == "AX" then
        self.regs[REG_AX] = val
    elseif name == "BX" then
        self.regs[REG_BX] = val
    elseif name == "CX" then
        self.regs[REG_CX] = val
    elseif name == "DX" then
        self.regs[REG_DX] = val
    elseif name == "CS" then
        self.segments[SEG_CS] = val
    elseif name == "SS" then
        self.segments[SEG_SS] = val
    elseif name == "DS" then
        self.segments[SEG_DS] = val
    elseif name == "ES" then
        self.segments[SEG_ES] = val
    elseif name == "SP" then
        self.regs[REG_SP] = val
    elseif name == "BP" then
        self.regs[REG_BP] = val
    elseif name == "SI" then
        self.regs[REG_SI] = val
    elseif name == "DI" then
        self.regs[REG_DI] = val
    elseif name == "IP" then
        self.ip = val
    elseif name == "FLAGS" then
        self.flags = val
    else
        error("invalid register: " .. name)
    end
end

local function set_nmi(self, set)
    self.nmi_enabled = set
end

local function trigger_nmi(self)
    self.nmi = true
end

local function get_clock(self)
    return self.clock
end

local function set_clock(self, clock)
    self.clock = clock
end

local function reset(self)
    for i = 1, 8, 1 do
        self.regs[i] = 0
    end

    self.segments[1] = 0x0000
    self.segments[2] = self.reset_cs
    self.segments[3] = 0x0000
    self.segments[4] = 0x0000
    self.ip = self.reset_ip
    self.flags = 0
    self.rep_type = 0
    self.segment_mode = nil
    self.no_int = 0
    self.completed = false
    self.repeating = false
    self.nmi = false
    self.nmi_enabled = false
    self.nmi_triggered = false
    self.cycles = 0
    self.cycles_start = 0
    self.scheduler:reset()
end

function cpu.new(memory)
    local self = {
        memory = memory,
        pic = {},
        regs = {
            0x0000, -- AX
            0x0000, -- CX
            0x0000, -- DX
            0x0000, -- BX
            0x0000, -- SP
            0x0000, -- BP
            0x0000, -- SI
            0x0000  -- DI
        },
        segments = {
            0x0000, -- ES
            0x0000, -- CS
            0x0000, -- SS
            0x0000  -- DS
        },
        flags = 0x0000,
        ip = 0x0000,
        ea_addr = 0x0000,
        ea_seg = 0x0000,
        opcode = 0x00,
        reset_ip = 0x0000,
        reset_cs = 0xFFFF,
        mode = 0,
        rm = 0,
        reg = 0,
        rep_type = 0,
        cycles_start = 0,
        cycles = 0,
        clock = 0,
        no_int = 0,
        segment_mode = nil,
        completed = false,
        repeating = false,
        nmi = false,
        nmi_enabled = false,
        nmi_triggered = false,
        scheduler = scheduler.new(),
        get_clock = get_clock,
        set_clock = set_clock,
        get_reg = get_reg_name,
        set_reg = set_reg_name,
        get_io = get_io,
        get_scheduler = get_scheduler,
        trigger_nmi = trigger_nmi,
        set_nmi = set_nmi,
        set_reset_vector = set_reset_vector,
        interrupt = call_interrupt,
        step = step,
        execute = execute,
        reset = reset
    }

    self.io = io_ports.new(self)

    return self
end

return cpu
