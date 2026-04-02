-- =====================================================================================================================================================================
-- MOS Technology 6502 emulation.
-- =====================================================================================================================================================================

local scheduler = require("emulator:scheduler")

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local cpu = {}

local FLAG_C = 0x01 -- Carry flag
local FLAG_Z = 0x02 -- Zero flag
local FLAG_I = 0x04 -- Interrupt inhibit flag
local FLAG_D = 0x08 -- Decimal flag
local FLAG_B = 0x10 -- Break flag
local FLAG_V = 0x40 -- Overflow flag
local FLAG_N = 0x80 -- Negative flag

local function write_flag(self, mask, val)
    if val then
        self.flags = bor(self.flags, mask)
    else
        self.flags = band(self.flags, bnot(mask))
    end
end

local function fetch8(self)
    local val = self.memory:read8(self.pc)
    self.pc = band(self.pc + 1, 0xFFFF)
    return val
end

local function fetch16(self)
    local val = self.memory:read16_l(self.pc)
    self.pc = band(self.pc + 2, 0xFFFF)
    return val
end

local function push(self, val)
    self.memory:write8(0x100 + self.sp, val)
    self.sp = band(self.sp - 1, 0xFF)
end

local function pop(self)
    self.sp = band(self.sp + 1, 0xFF)
    return self.memory:read8(0x100 + self.sp)
end

local ADDR_MODE_A   = 0 -- Accumulator
local ADDR_MODE_ZP  = 1 -- Zero Page
local ADDR_MODE_ZPX = 2 -- Zero Page X
local ADDR_MODE_ZPY = 3 -- Zero Page Y
local ADDR_MODE_IMM = 4 -- Immediate
local ADDR_MODE_ABS = 5 -- Absolute
local ADDR_MODE_ABX = 6 -- Absolute X
local ADDR_MODE_ABY = 7 -- Absolute Y
local ADDR_MODE_IMP = 8 -- Implied
local ADDR_MODE_IND = 9 -- Indirect
local ADDR_MODE_XIN = 10 -- X ndirect
local ADDR_MODE_YIN = 11 -- Indirect Y
local ADDR_MODE_REL = 12 -- Relative

-- Without page boundary check.
local ADDR_MODE_AXP = 13 -- Absolute X
local ADDR_MODE_AYP = 14 -- Absolute Y
local ADDR_MODE_YIP = 15 -- Indirect Y

local operand_addr = {
    [ADDR_MODE_ZP] = function(self)
        return fetch8(self)
    end,
    [ADDR_MODE_ZPX] = function(self)
        return band(fetch8(self) + self.x, 0xFF)
    end,
    [ADDR_MODE_ZPY] = function(self)
        return band(fetch8(self) + self.y, 0xFF)
    end,
    [ADDR_MODE_IMM] = function(self)
        local pc = self.pc
        self.pc = band(self.pc + 1, 0xFFFF)
        return pc
    end,
    [ADDR_MODE_ABS] = function(self)
        return fetch16(self)
    end,
    [ADDR_MODE_ABX] = function(self)
        local addr = band(fetch16(self) + self.x, 0xFFFF)

        if rshift(bxor(addr - self.x, addr), 8) ~= 0 then
            self.cycles = self.cycles - 1
        end

        return addr
    end,
    [ADDR_MODE_ABY] = function(self)
        local addr = band(fetch16(self) + self.y, 0xFFFF)

        if rshift(bxor(addr - self.y, addr), 8) ~= 0 then
            self.cycles = self.cycles - 1
        end

        return addr
    end,
    [ADDR_MODE_IND] = function(self)
        local addr = fetch16(self)
        local low = self.memory:read8(addr)
        local high = self.memory:read8(bor(band(addr, 0xFF00), band(addr + 1, 0xFF)))

        return bor(low, lshift(high, 8))
    end,
    [ADDR_MODE_XIN] = function(self)
        local addr = band(fetch8(self) + self.x, 0xFF)
        local low = self.memory:read8(addr)
        local high = self.memory:read8(band(addr + 1, 0xFF))

        addr = bor(low, lshift(high, 8))

        return addr
    end,
    [ADDR_MODE_YIN] = function(self)
        local addr = fetch8(self)
        local low = self.memory:read8(addr)
        local high = self.memory:read8(band(addr + 1, 0xFF))

        addr = bor(low, lshift(high, 8))
        addr = band(addr + self.y, 0xFFFF)

        if rshift(bxor(addr - self.y, addr), 8) ~= 0 then
            self.cycles = self.cycles - 1
        end

        return addr
    end,
    [ADDR_MODE_AXP] = function(self)
        return band(fetch16(self) + self.x, 0xFFFF)
    end,
    [ADDR_MODE_AYP] = function(self)
        return band(fetch16(self) + self.y, 0xFFFF)
    end,
    [ADDR_MODE_YIP] = function(self)
        local addr = fetch8(self)
        local low = self.memory:read8(addr)
        local high = self.memory:read8(band(addr + 1, 0xFF))

        addr = bor(low, lshift(high, 8))

        return band(addr + self.y, 0xFFFF)
    end
}

operand_addr[ADDR_MODE_REL] = operand_addr[ADDR_MODE_IMM]

local function set_zn(self, result)
    self.flags = band(self.flags, bnot(bor(FLAG_Z, FLAG_N)))
    self.flags = bor(self.flags, lshift(rshift(bxor(band(result, 0xFF), 0xFF) + 1, 8), 1))
    self.flags = bor(self.flags, band(result, 0x80))
end

local opcodes = {}

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Arithmetic Instructions.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function cpu_adc(self, mode)
    local val = self.memory:read8(operand_addr[mode](self))
    local carry = band(self.flags, FLAG_C)
    local result = self.a + val + carry

    write_flag(self, FLAG_Z, band(result, 0xFF) == 0)

    if band(self.flags, FLAG_D) ~= 0 then
        result = band(self.a, 0x0F) + band(val, 0x0F) + carry

        if result >= 0x0A then
            result = band(result + 0x06, 0x0F) + 0x10
        end

        result = band(self.a, 0xF0) + band(val, 0xF0) + result

        write_flag(self, FLAG_N, band(result, 0x80) ~= 0)
        write_flag(self, FLAG_V, band(band(bnot(bxor(self.a, val)), bxor(self.a, result)), 0x80) ~= 0)

        if result >= 0xA0 then
            result = result + 0x60
        end
    else
        write_flag(self, FLAG_N, band(result, 0x80) ~= 0)
        write_flag(self, FLAG_V, band(band(bnot(bxor(self.a, val)), bxor(self.a, result)), 0x80) ~= 0)
    end

    write_flag(self, FLAG_C, result > 0xFF)
    self.a = band(result, 0xFF)
end

opcodes[0x69] = {ADDR_MODE_IMM, cpu_adc, 2}
opcodes[0x65] = {ADDR_MODE_ZP , cpu_adc, 3}
opcodes[0x75] = {ADDR_MODE_ZPX, cpu_adc, 4}
opcodes[0x6D] = {ADDR_MODE_ABS, cpu_adc, 4}
opcodes[0x7D] = {ADDR_MODE_ABX, cpu_adc, 4}
opcodes[0x79] = {ADDR_MODE_ABY, cpu_adc, 4}
opcodes[0x61] = {ADDR_MODE_XIN, cpu_adc, 6}
opcodes[0x71] = {ADDR_MODE_YIN, cpu_adc, 5}

local function cpu_sbc(self, mode)
    local val = self.memory:read8(operand_addr[mode](self))
    local carry = bxor(band(self.flags, FLAG_C), FLAG_C)
    local result = self.a - val - carry

    write_flag(self, FLAG_C, band(result, 0x100) == 0)
    write_flag(self, FLAG_V, band(band(bxor(self.a, val), bxor(self.a, result)), 0x80) ~= 0)
    set_zn(self, result)

    if band(self.flags, FLAG_D) ~= 0 then
        result = band(self.a, 0x0F) - band(val, 0x0F) - carry

        if result < 0x00 then
            result = band(result - 0x06, 0x0F) - 0x10
        end

        result = band(self.a, 0xF0) - band(val, 0xF0) + result

        if result < 0x00 then
            result = result - 0x60
        end
    end

    self.a = band(result, 0xFF)
end

opcodes[0xE9] = {ADDR_MODE_IMM, cpu_sbc, 2}
opcodes[0xE5] = {ADDR_MODE_ZP , cpu_sbc, 3}
opcodes[0xF5] = {ADDR_MODE_ZPX, cpu_sbc, 4}
opcodes[0xED] = {ADDR_MODE_ABS, cpu_sbc, 4}
opcodes[0xFD] = {ADDR_MODE_ABX, cpu_sbc, 4}
opcodes[0xF9] = {ADDR_MODE_ABY, cpu_sbc, 4}
opcodes[0xE1] = {ADDR_MODE_XIN, cpu_sbc, 6}
opcodes[0xF1] = {ADDR_MODE_YIN, cpu_sbc, 5}

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Logical Instructions.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function cpu_and(self, mode)
    self.a = band(self.a, self.memory:read8(operand_addr[mode](self)))
    set_zn(self, self.a)
end

opcodes[0x29] = {ADDR_MODE_IMM, cpu_and, 2}
opcodes[0x25] = {ADDR_MODE_ZP , cpu_and, 3}
opcodes[0x35] = {ADDR_MODE_ZPX, cpu_and, 4}
opcodes[0x2D] = {ADDR_MODE_ABS, cpu_and, 4}
opcodes[0x3D] = {ADDR_MODE_ABX, cpu_and, 4}
opcodes[0x39] = {ADDR_MODE_ABY, cpu_and, 4}
opcodes[0x21] = {ADDR_MODE_XIN, cpu_and, 6}
opcodes[0x31] = {ADDR_MODE_YIN, cpu_and, 5}

local function cpu_eor(self, mode)
    self.a = bxor(self.a, self.memory:read8(operand_addr[mode](self)))
    set_zn(self, self.a)
end

opcodes[0x49] = {ADDR_MODE_IMM, cpu_eor, 2}
opcodes[0x45] = {ADDR_MODE_ZP , cpu_eor, 3}
opcodes[0x55] = {ADDR_MODE_ZPX, cpu_eor, 4}
opcodes[0x4D] = {ADDR_MODE_ABS, cpu_eor, 4}
opcodes[0x5D] = {ADDR_MODE_ABX, cpu_eor, 4}
opcodes[0x59] = {ADDR_MODE_ABY, cpu_eor, 4}
opcodes[0x41] = {ADDR_MODE_XIN, cpu_eor, 6}
opcodes[0x51] = {ADDR_MODE_YIN, cpu_eor, 5}

local function cpu_ora(self, mode)
    self.a = bor(self.a, self.memory:read8(operand_addr[mode](self)))
    set_zn(self, self.a)
end

opcodes[0x09] = {ADDR_MODE_IMM, cpu_ora, 2}
opcodes[0x05] = {ADDR_MODE_ZP , cpu_ora, 3}
opcodes[0x15] = {ADDR_MODE_ZPX, cpu_ora, 4}
opcodes[0x0D] = {ADDR_MODE_ABS, cpu_ora, 4}
opcodes[0x1D] = {ADDR_MODE_ABX, cpu_ora, 4}
opcodes[0x19] = {ADDR_MODE_ABY, cpu_ora, 4}
opcodes[0x01] = {ADDR_MODE_XIN, cpu_ora, 6}
opcodes[0x11] = {ADDR_MODE_YIN, cpu_ora, 5}

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Shift & Rotate Instructions.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function cpu_asl(self, mode)
    local addr
    local val

    if mode == ADDR_MODE_A then
        val = self.a
    else
        addr = operand_addr[mode](self)
        val = self.memory:read8(addr)
    end

    local result = band(lshift(val, 1), 0xFF)

    set_zn(self, result)
    write_flag(self, FLAG_C, band(val, 0x80) ~= 0)

    if mode == ADDR_MODE_A then
        self.a = result
    else
        self.memory:write8(addr, result)
    end
end

opcodes[0x0A] = {ADDR_MODE_A  , cpu_asl, 2}
opcodes[0x06] = {ADDR_MODE_ZP , cpu_asl, 5}
opcodes[0x16] = {ADDR_MODE_ZPX, cpu_asl, 6}
opcodes[0x0E] = {ADDR_MODE_ABS, cpu_asl, 6}
opcodes[0x1E] = {ADDR_MODE_AXP, cpu_asl, 7}

local function cpu_lsr(self, mode)
    local addr
    local val

    if mode == ADDR_MODE_A then
        val = self.a
    else
        addr = operand_addr[mode](self)
        val = self.memory:read8(addr)
    end

    local result = rshift(val, 1)

    self.flags = band(self.flags, bnot(FLAG_N))
    self.flags = bor(band(self.flags, bnot(FLAG_C)), band(val, 0x01))
    write_flag(self, FLAG_Z, result == 0x00)

    if mode == ADDR_MODE_A then
        self.a = result
    else
        self.memory:write8(addr, result)
    end
end

opcodes[0x4A] = {ADDR_MODE_A  , cpu_lsr, 2}
opcodes[0x46] = {ADDR_MODE_ZP , cpu_lsr, 5}
opcodes[0x56] = {ADDR_MODE_ZPX, cpu_lsr, 6}
opcodes[0x4E] = {ADDR_MODE_ABS, cpu_lsr, 6}
opcodes[0x5E] = {ADDR_MODE_AXP, cpu_lsr, 7}

local function cpu_rol(self, mode)
    local addr
    local val

    if mode == ADDR_MODE_A then
        val = self.a
    else
        addr = operand_addr[mode](self)
        val = self.memory:read8(addr)
    end

    local carry = rshift(val, 7)
    local result = band(bor(lshift(val, 1), band(self.flags, FLAG_C)), 0xFF)

    set_zn(self, result)
    self.flags = bor(band(self.flags, bnot(FLAG_C)), carry)

    if mode == ADDR_MODE_A then
        self.a = result
    else
        self.memory:write8(addr, result)
    end
end

opcodes[0x2A] = {ADDR_MODE_A  , cpu_rol, 2}
opcodes[0x26] = {ADDR_MODE_ZP , cpu_rol, 5}
opcodes[0x36] = {ADDR_MODE_ZPX, cpu_rol, 6}
opcodes[0x2E] = {ADDR_MODE_ABS, cpu_rol, 6}
opcodes[0x3E] = {ADDR_MODE_AXP, cpu_rol, 7}

local function cpu_ror(self, mode)
    local addr
    local val

    if mode == ADDR_MODE_A then
        val = self.a
    else
        addr = operand_addr[mode](self)
        val = self.memory:read8(addr)
    end

    local carry = band(val, 0x01)
    local result = band(bor(rshift(val, 1), lshift(band(self.flags, FLAG_C), 7)), 0xFF)

    set_zn(self, result)
    self.flags = bor(band(self.flags, bnot(FLAG_C)), carry)

    if mode == ADDR_MODE_A then
        self.a = result
    else
        self.memory:write8(addr, result)
    end
end

opcodes[0x6A] = {ADDR_MODE_A  , cpu_ror, 2}
opcodes[0x66] = {ADDR_MODE_ZP , cpu_ror, 5}
opcodes[0x76] = {ADDR_MODE_ZPX, cpu_ror, 6}
opcodes[0x6E] = {ADDR_MODE_ABS, cpu_ror, 6}
opcodes[0x7E] = {ADDR_MODE_AXP, cpu_ror, 7}

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Increment & Decrement Instructions.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function cpu_dec(self, mode)
    local addr = operand_addr[mode](self)
    local val = self.memory:read8(addr)
    local result = band(val - 1, 0xFF)

    set_zn(self, result)
    self.memory:write8(addr, result)
end

opcodes[0xC6] = {ADDR_MODE_ZP , cpu_dec, 5}
opcodes[0xD6] = {ADDR_MODE_ZPX, cpu_dec, 6}
opcodes[0xCE] = {ADDR_MODE_ABS, cpu_dec, 6}
opcodes[0xDE] = {ADDR_MODE_AXP, cpu_dec, 7}

local function cpu_dex(self, mode)
    self.x = band(self.x - 1, 0xFF)
    set_zn(self, self.x)
end

opcodes[0xCA] = {ADDR_MODE_IMP, cpu_dex, 2}

local function cpu_dey(self, mode)
    self.y = band(self.y - 1, 0xFF)
    set_zn(self, self.y)
end

opcodes[0x88] = {ADDR_MODE_IMP, cpu_dey, 2}

local function cpu_inc(self, mode)
    local addr = operand_addr[mode](self)
    local val = self.memory:read8(addr)
    local result = band(val + 1, 0xFF)

    set_zn(self, result)
    self.memory:write8(addr, result)
end

opcodes[0xE6] = {ADDR_MODE_ZP , cpu_inc, 5}
opcodes[0xF6] = {ADDR_MODE_ZPX, cpu_inc, 6}
opcodes[0xEE] = {ADDR_MODE_ABS, cpu_inc, 6}
opcodes[0xFE] = {ADDR_MODE_AXP, cpu_inc, 7}

local function cpu_inx(self, mode)
    self.x = band(self.x + 1, 0xFF)
    set_zn(self, self.x)
end

opcodes[0xE8] = {ADDR_MODE_IMP, cpu_inx, 2}

local function cpu_iny(self, mode)
    self.y = band(self.y + 1, 0xFF)
    set_zn(self, self.y)
end

opcodes[0xC8] = {ADDR_MODE_IMP, cpu_iny, 2}

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Flag Instructions.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function gen_clear_flag(flag)
    return load(string.format([[
        local band, bnot = ...
        return function(self, mode)
            self.flags = band(self.flags, bnot(%d))
        end
    ]], flag), "=6502.lua-clx", "t")(band, bnot)
end

opcodes[0x18] = {ADDR_MODE_IMP, gen_clear_flag(FLAG_C), 2}
opcodes[0xD8] = {ADDR_MODE_IMP, gen_clear_flag(FLAG_D), 2}
opcodes[0x58] = {ADDR_MODE_IMP, gen_clear_flag(FLAG_I), 2}
opcodes[0xB8] = {ADDR_MODE_IMP, gen_clear_flag(FLAG_V), 2}

local function gen_set_flag(flag)
    return load(string.format([[
        local bor = ...
        return function(self, mode)
            self.flags = bor(self.flags, %d)
        end
    ]], flag), "=6502.lua-sef", "t")(bor)
end

opcodes[0x38] = {ADDR_MODE_IMP, gen_set_flag(FLAG_C), 2}
opcodes[0xF8] = {ADDR_MODE_IMP, gen_set_flag(FLAG_D), 2}
opcodes[0x78] = {ADDR_MODE_IMP, gen_set_flag(FLAG_I), 2}

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Comparison Instrucions.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function cpu_cmp(self, mode)
    local val = self.memory:read8(operand_addr[mode](self))
    local result = self.a - val

    write_flag(self, FLAG_C, self.a >= val)
    set_zn(self, result)
end

opcodes[0xC9] = {ADDR_MODE_IMM, cpu_cmp, 2}
opcodes[0xC5] = {ADDR_MODE_ZP , cpu_cmp, 3}
opcodes[0xD5] = {ADDR_MODE_ZPX, cpu_cmp, 4}
opcodes[0xCD] = {ADDR_MODE_ABS, cpu_cmp, 4}
opcodes[0xDD] = {ADDR_MODE_ABX, cpu_cmp, 4}
opcodes[0xD9] = {ADDR_MODE_ABY, cpu_cmp, 4}
opcodes[0xC1] = {ADDR_MODE_XIN, cpu_cmp, 6}
opcodes[0xD1] = {ADDR_MODE_YIN, cpu_cmp, 5}

local function cpu_cpx(self, mode)
    local val = self.memory:read8(operand_addr[mode](self))
    local result = self.x - val

    write_flag(self, FLAG_C, self.x >= val)
    set_zn(self, result)
end

opcodes[0xE0] = {ADDR_MODE_IMM, cpu_cpx, 2}
opcodes[0xE4] = {ADDR_MODE_ZP , cpu_cpx, 3}
opcodes[0xEC] = {ADDR_MODE_ABS, cpu_cpx, 4}

local function cpu_cpy(self, mode)
    local val = self.memory:read8(operand_addr[mode](self))
    local result = self.y - val

    write_flag(self, FLAG_C, self.y >= val)
    set_zn(self, result)
end

opcodes[0xC0] = {ADDR_MODE_IMM, cpu_cpy, 2}
opcodes[0xC4] = {ADDR_MODE_ZP , cpu_cpy, 3}
opcodes[0xCC] = {ADDR_MODE_ABS, cpu_cpy, 4}


-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Bit Test Instruction.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function cpu_bit(self, mode)
    local val = self.memory:read8(operand_addr[mode](self))

    write_flag(self, FLAG_Z, band(self.a, val) == 0)
    write_flag(self, FLAG_N, band(val, 0x80) ~= 0)
    write_flag(self, FLAG_V, band(val, 0x40) ~= 0)
end

opcodes[0x24] = {ADDR_MODE_ZP , cpu_bit, 3}
opcodes[0x2C] = {ADDR_MODE_ABS, cpu_bit, 4}

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Transfer Instructions.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function cpu_lda(self, mode)
    self.a = self.memory:read8(operand_addr[mode](self))
    set_zn(self, self.a)
end

opcodes[0xA9] = {ADDR_MODE_IMM, cpu_lda, 2}
opcodes[0xA5] = {ADDR_MODE_ZP , cpu_lda, 3}
opcodes[0xB5] = {ADDR_MODE_ZPX, cpu_lda, 4}
opcodes[0xAD] = {ADDR_MODE_ABS, cpu_lda, 4}
opcodes[0xBD] = {ADDR_MODE_ABX, cpu_lda, 4}
opcodes[0xB9] = {ADDR_MODE_ABY, cpu_lda, 4}
opcodes[0xA1] = {ADDR_MODE_XIN, cpu_lda, 6}
opcodes[0xB1] = {ADDR_MODE_YIN, cpu_lda, 5}

local function cpu_ldx(self, mode)
    self.x = self.memory:read8(operand_addr[mode](self))
    set_zn(self, self.x)
end

opcodes[0xA2] = {ADDR_MODE_IMM, cpu_ldx, 2}
opcodes[0xA6] = {ADDR_MODE_ZP , cpu_ldx, 3}
opcodes[0xB6] = {ADDR_MODE_ZPY, cpu_ldx, 4}
opcodes[0xAE] = {ADDR_MODE_ABS, cpu_ldx, 4}
opcodes[0xBE] = {ADDR_MODE_ABY, cpu_ldx, 4}

local function cpu_ldy(self, mode)
    self.y = self.memory:read8(operand_addr[mode](self))
    set_zn(self, self.y)
end

opcodes[0xA0] = {ADDR_MODE_IMM, cpu_ldy, 2}
opcodes[0xA4] = {ADDR_MODE_ZP , cpu_ldy, 3}
opcodes[0xB4] = {ADDR_MODE_ZPX, cpu_ldy, 4}
opcodes[0xAC] = {ADDR_MODE_ABS, cpu_ldy, 4}
opcodes[0xBC] = {ADDR_MODE_ABX, cpu_ldy, 4}

local function cpu_sta(self, mode)
    self.memory:write8(operand_addr[mode](self), self.a)
end

opcodes[0x85] = {ADDR_MODE_ZP , cpu_sta, 3}
opcodes[0x95] = {ADDR_MODE_ZPX, cpu_sta, 4}
opcodes[0x8D] = {ADDR_MODE_ABS, cpu_sta, 4}
opcodes[0x9D] = {ADDR_MODE_AXP, cpu_sta, 5}
opcodes[0x99] = {ADDR_MODE_AYP, cpu_sta, 5}
opcodes[0x81] = {ADDR_MODE_XIN, cpu_sta, 6}
opcodes[0x91] = {ADDR_MODE_YIP, cpu_sta, 6}

local function cpu_stx(self, mode)
    self.memory:write8(operand_addr[mode](self), self.x)
end

opcodes[0x86] = {ADDR_MODE_ZP , cpu_stx, 3}
opcodes[0x96] = {ADDR_MODE_ZPY, cpu_stx, 4}
opcodes[0x8E] = {ADDR_MODE_ABS, cpu_stx, 4}

local function cpu_sty(self, mode)
    self.memory:write8(operand_addr[mode](self), self.y)
end

opcodes[0x84] = {ADDR_MODE_ZP , cpu_sty, 3}
opcodes[0x94] = {ADDR_MODE_ZPX, cpu_sty, 4}
opcodes[0x8C] = {ADDR_MODE_ABS, cpu_sty, 4}

local function gen_trr(opcode, dest, src, flags)
    opcodes[opcode] = {
        ADDR_MODE_IMP,
        load(string.format([[
            local set_zn = ...
            return function(self, mode)
                local src = self.%s
                self.%s = src
                %s
            end
        ]], src, dest, flags and "set_zn(self, src)" or ""), "=6502.lua-trr", "t")(set_zn),
        2
    }
end

gen_trr(0xAA, "x", "a", true)
gen_trr(0xA8, "y", "a", true)
gen_trr(0xBA, "x", "sp", true)
gen_trr(0x8A, "a", "x", true)
gen_trr(0x9A, "sp", "x", false)
gen_trr(0x98, "a", "y", true)

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Stack Instructions.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function cpu_pha(self, mode)
    push(self, self.a)
end

opcodes[0x48] = {ADDR_MODE_IMP, cpu_pha, 3}

local function cpu_php(self, mode)
    push(self, bor(self.flags, bor(FLAG_B, 0x20)))
end

opcodes[0x08] = {ADDR_MODE_IMP, cpu_php, 3}

local function cpu_pla(self, mode)
    self.a = pop(self)
    set_zn(self, self.a)
end

opcodes[0x68] = {ADDR_MODE_IMP, cpu_pla, 4}

local function cpu_plp(self, mode)
    self.flags = band(bor(pop(self), 0x20), bnot(FLAG_B))
end

opcodes[0x28] = {ADDR_MODE_IMP, cpu_plp, 4}

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Conditional Branch Instructions.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function gen_branch(opcode, flag, clear)
    opcodes[opcode] = {
        ADDR_MODE_REL,
        load(string.format([[
            local band, bxor, rshift, operand_addr = ...
            return function(self, mode)
                local addr = self.memory:read8(operand_addr[mode](self))

                if band(self.flags, %d) %s= 0 then
                    local pc = self.pc

                    self.cycles = self.cycles - 1
                    self.pc = band(self.pc + addr, 0xFFFF)

                    if band(addr, 0x80) ~= 0 then
                        self.pc = band(self.pc - 0x100, 0xFFFF)
                    end

                    if rshift(bxor(pc, self.pc), 8) ~= 0 then
                        self.cycles = self.cycles - 1
                    end
                end
            end
        ]], flag, clear and "=" or "~"), "=6502.lua-bxx", "t")(band, bxor, rshift, operand_addr),
        2
    }
end

gen_branch(0x90, FLAG_C, true)
gen_branch(0xB0, FLAG_C, false)
gen_branch(0xD0, FLAG_Z, true)
gen_branch(0xF0, FLAG_Z, false)
gen_branch(0x10, FLAG_N, true)
gen_branch(0x30, FLAG_N, false)
gen_branch(0x50, FLAG_V, true)
gen_branch(0x70, FLAG_V, false)

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Jumps & Subroutine.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function cpu_jmp(self, mode)
    self.pc = operand_addr[mode](self)
end

opcodes[0x4C] = {ADDR_MODE_ABS, cpu_jmp, 3}
opcodes[0x6C] = {ADDR_MODE_IND, cpu_jmp, 5}

local function cpu_jsr(self, mode)
    local low = fetch8(self)

    push(self, rshift(self.pc, 8))
    push(self, band(self.pc, 0xFF))

    local high = fetch8(self)

    self.pc = bor(low, lshift(high, 8))
end

opcodes[0x20] = {ADDR_MODE_ABS, cpu_jsr, 6}

local function cpu_rts(self, mode)
    self.pc = pop(self)
    self.pc = bor(self.pc, lshift(pop(self), 8))
    self.pc = band(self.pc + 1, 0xFFFF)
end

opcodes[0x60] = {ADDR_MODE_IMP, cpu_rts, 6}

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Interrupts.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function cpu_brk(self, mode)
    self.pc = band(self.pc + 1, 0xFFFF)

    push(self, rshift(self.pc, 8))
    push(self, band(self.pc, 0xFF))
    push(self, bor(self.flags, bor(0x20, FLAG_B)))

    self.pc = self.memory:read16_l(0xFFFE)
    self.flags = bor(self.flags, FLAG_I)
end

opcodes[0x00] = {ADDR_MODE_IMP, cpu_brk, 7}

local function cpu_rti(self, mode)
    self.flags = band(bor(pop(self), 0x20), bnot(FLAG_B))
    self.pc = pop(self)
    self.pc = bor(self.pc, lshift(pop(self), 8))
end

opcodes[0x40] = {ADDR_MODE_IMP, cpu_rti, 6}

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Other.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function cpu_nop(self, mode)
    if mode ~= ADDR_MODE_IMP then
        operand_addr[mode](self)
    end
end

opcodes[0xEA] = {ADDR_MODE_IMP, cpu_nop, 2}

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Illegal Instructions.
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

opcodes[0x1A] = opcodes[0xEA]
opcodes[0x3A] = opcodes[0xEA]
opcodes[0x5A] = opcodes[0xEA]
opcodes[0x7A] = opcodes[0xEA]
opcodes[0xDA] = opcodes[0xEA]
opcodes[0xFA] = opcodes[0xEA]
opcodes[0x80] = {ADDR_MODE_IMM, cpu_nop, 2}
opcodes[0x82] = opcodes[0x80]
opcodes[0x89] = opcodes[0x80]
opcodes[0xC2] = opcodes[0x80]
opcodes[0xE2] = opcodes[0x80]
opcodes[0x04] = {ADDR_MODE_ZP , cpu_nop, 3}
opcodes[0x44] = opcodes[0x04]
opcodes[0x64] = opcodes[0x04]
opcodes[0x14] = {ADDR_MODE_ZPX, cpu_nop, 4}
opcodes[0x34] = opcodes[0x14]
opcodes[0x54] = opcodes[0x14]
opcodes[0x74] = opcodes[0x14]
opcodes[0xD4] = opcodes[0x14]
opcodes[0xF4] = opcodes[0x14]
opcodes[0x0C] = {ADDR_MODE_ABS, cpu_nop, 4}
opcodes[0x1C] = {ADDR_MODE_ABX, cpu_nop, 4}
opcodes[0x3C] = opcodes[0x1C]
opcodes[0x5C] = opcodes[0x1C]
opcodes[0x7C] = opcodes[0x1C]
opcodes[0xDC] = opcodes[0x1C]
opcodes[0xFC] = opcodes[0x1C]

-- JAM
opcodes[0x02] = {
    ADDR_MODE_IMP,
    function(self, mode)
    end,
    11
}
opcodes[0x12] = opcodes[0x02]
opcodes[0x22] = opcodes[0x02]
opcodes[0x32] = opcodes[0x02]
opcodes[0x42] = opcodes[0x02]
opcodes[0x52] = opcodes[0x02]
opcodes[0x62] = opcodes[0x02]
opcodes[0x72] = opcodes[0x02]
opcodes[0x92] = opcodes[0x02]
opcodes[0xB2] = opcodes[0x02]
opcodes[0xD2] = opcodes[0x02]
opcodes[0xF2] = opcodes[0x02]

-- USBC
opcodes[0xEB] = opcodes[0xE9]

opcodes[0x4B] = { -- ALR
    ADDR_MODE_IMM,
    function(self, mode)
        local val = self.memory:read8(operand_addr[mode](self))
        local result = band(self.a, val)

        self.flags = band(self.flags, bnot(FLAG_N))
        self.flags = bor(band(self.flags, bnot(FLAG_C)), band(result, 0x01))

        result = rshift(result, 1)

        write_flag(self, FLAG_Z, result == 0x00)

        self.a = result
    end,
    2
}

opcodes[0x0B] = { -- ANC
    ADDR_MODE_IMM,
    function(self, mode)
        local val = self.memory:read8(operand_addr[mode](self))

        self.a = band(self.a, val)

        set_zn(self, self.a)
        write_flag(self, FLAG_C, band(self.a, 0x80) ~= 0)
    end,
    2
}
opcodes[0x2B] = opcodes[0x0B]

opcodes[0x8B] = { -- ANE
    ADDR_MODE_IMM,
    function(self, mode)
        local val = self.memory:read8(operand_addr[mode](self))
        self.a = band(band(bor(self.a, 0xEE), val), self.x)
        set_zn(self, self.a)
    end,
    2
}

opcodes[0x6B] = { -- ARR
    ADDR_MODE_IMM,
    function(self, mode)
        local val = self.memory:read8(operand_addr[mode](self))
        local temp = band(self.a, val)
        local carry = band(self.flags, FLAG_C)

        local ah = rshift(temp, 4)
        local al = band(temp, 0x0F)

        self.flags = band(self.flags, bnot(FLAG_N))
        self.flags = bor(self.flags, lshift(carry, 7))

        self.flags = band(self.flags, bnot(FLAG_C))
        self.flags = bor(self.flags, rshift(temp, 7))

        self.a = band(bor(rshift(temp, 1), lshift(carry, 7)), 0xFF)
        write_flag(self, FLAG_Z, self.a == 0)
        write_flag(self, FLAG_V, band(bxor(temp, self.a), 0x40) ~= 0)

        if band(self.flags, FLAG_D) ~= 0 then
            if (al + band(al, 0x01)) > 5 then
                self.a = bor(band(self.a, 0xF0), band(self.a + 6, 0xF))
            end

            if (ah +  band(ah, 0x01)) > 5 then
                self.a = band(self.a + 0x60, 0xFF)
                self.flags = bor(self.flags, FLAG_C)
            else
                self.flags = band(self.flags, bnot(FLAG_C))
            end
        end
    end,
    2
}

local function cpu_dcp(self, mode)
    local addr = operand_addr[mode](self)
    local val = self.memory:read8(addr)
    local result = band(val - 1, 0xFF)

    self.memory:write8(addr, result)
    result = self.a - result

    write_flag(self, FLAG_C, result >= 0)
    set_zn(self, result)
end

opcodes[0xC7] = {ADDR_MODE_ZP , cpu_dcp, 5}
opcodes[0xD7] = {ADDR_MODE_ZPX, cpu_dcp, 6}
opcodes[0xCF] = {ADDR_MODE_ABS, cpu_dcp, 6}
opcodes[0xDF] = {ADDR_MODE_AXP, cpu_dcp, 7}
opcodes[0xDB] = {ADDR_MODE_AYP, cpu_dcp, 7}
opcodes[0xC3] = {ADDR_MODE_XIN, cpu_dcp, 8}
opcodes[0xD3] = {ADDR_MODE_YIP, cpu_dcp, 8}

local function cpu_isc(self, mode)
    local addr = operand_addr[mode](self) 
    local val = self.memory:read8(addr)
    local carry = bxor(band(self.flags, FLAG_C), 0x00)
    local result = band(val + 1, 0xFF)

    self.memory:write8(addr, result)
    result = self.a - val - carry

    write_flag(self, FLAG_C, band(result, 0x100) == 0)
    write_flag(self, FLAG_V, band(band(bxor(self.a, val), bxor(self.a, result)), 0x80) ~= 0)
    set_zn(self, result)

    if band(self.flags, FLAG_D) ~= 0 then
        result = band(self.a, 0x0F) - band(val, 0x0F) - carry

        if result < 0x00 then
            result = band(result - 0x06, 0x0F) - 0x10
        end

        result = band(self.a, 0xF0) - band(val, 0xF0) + result

        if result < 0x00 then
            result = result - 0x60
        end
    end

    self.a = band(result, 0xFF)
end

opcodes[0xE7] = {ADDR_MODE_ZP , cpu_isc, 5}
opcodes[0xF7] = {ADDR_MODE_ZPX, cpu_isc, 6}
opcodes[0xEF] = {ADDR_MODE_ABS, cpu_isc, 6}
opcodes[0xFF] = {ADDR_MODE_AXP, cpu_isc, 7}
opcodes[0xFB] = {ADDR_MODE_AYP, cpu_isc, 7}
opcodes[0xE3] = {ADDR_MODE_XIN, cpu_isc, 8}
opcodes[0xF3] = {ADDR_MODE_YIP, cpu_isc, 8}

opcodes[0xBB] = { -- LAS
    ADDR_MODE_ABY,
    function(self, mode)
        local val = self.memory:read8(operand_addr[mode](self))

        self.a = band(val, self.sp)
        self.x = self.a
        self.sp = self.a

        set_zn(self, self.a)
    end,
    4
}

local function cpu_lax(self, mode)
    self.a = self.memory:read8(operand_addr[mode](self))
    self.x = self.a

    set_zn(self, self.a)
end

opcodes[0xA7] = {ADDR_MODE_ZP , cpu_lax, 3}
opcodes[0xB7] = {ADDR_MODE_ZPY, cpu_lax, 4}
opcodes[0xAF] = {ADDR_MODE_ABS, cpu_lax, 4}
opcodes[0xBF] = {ADDR_MODE_ABY, cpu_lax, 4}
opcodes[0xA3] = {ADDR_MODE_XIN, cpu_lax, 6}
opcodes[0xB3] = {ADDR_MODE_YIN, cpu_lax, 5}

opcodes[0xAB] = { -- LXA
    ADDR_MODE_IMM,
    function(self, mode)
        local val = self.memory:read8(operand_addr[mode](self))
        local result = band(bor(self.a, 0xEE), val)

        set_zn(self, result)

        self.a = result
        self.x = self.a
    end,
    2
}

local function cpu_rla(self, mode)
    local addr = operand_addr[mode](self)
    local val = self.memory:read8(addr)
    local temp = band(bor(lshift(val, 1), band(self.flags, FLAG_C)), 0xFF)

    self.memory:write8(addr, temp)
    self.a = band(self.a, temp)

    write_flag(self, FLAG_C, band(val, 0x80) ~= 0)
    set_zn(self, self.a)
end

opcodes[0x27] = {ADDR_MODE_ZP , cpu_rla, 5}
opcodes[0x37] = {ADDR_MODE_ZPX, cpu_rla, 6}
opcodes[0x2F] = {ADDR_MODE_ABS, cpu_rla, 6}
opcodes[0x3F] = {ADDR_MODE_AXP, cpu_rla, 7}
opcodes[0x3B] = {ADDR_MODE_AYP, cpu_rla, 7}
opcodes[0x23] = {ADDR_MODE_XIN, cpu_rla, 8}
opcodes[0x33] = {ADDR_MODE_YIP, cpu_rla, 8}

local function cpu_rra(self, mode)
    local addr = operand_addr[mode](self)
    local val = self.memory:read8(addr)
    local carry = band(self.flags, FLAG_C)
    local temp = band(bor(rshift(val, 1), lshift(carry, 7)), 0xFF)

    self.memory:write8(addr, temp)

    temp = self.a + temp + carry

    write_flag(self, FLAG_C, band(temp, 0x01) ~= 0)
    write_flag(self, FLAG_V, band(band(bxor(self.a, val), bxor(self.a, temp)), 0x80) ~= 0)
    set_zn(self, temp)

    if band(self.flags, FLAG_D) ~= 0 then
        local old = temp
        temp = band(self.a, 0x0F) + band(temp, 0x0F) + carry

        if temp >= 0x0A then
            temp = band(temp + 0x06, 0x0F) + 0x10
        end

        temp = band(self.a, 0xF0) + band(val, 0xF0) + temp

        write_flag(self, FLAG_N, band(temp, 0x80) ~= 0)
        write_flag(self, FLAG_V, band(band(bnot(bxor(self.a, old)), bxor(self.a, temp)), 0x80) ~= 0)

        if temp >= 0xA0 then
            temp = temp + 0x60
        end
    end

    self.a = band(temp, 0xFF)
end

opcodes[0x67] = {ADDR_MODE_ZP , cpu_rra, 5}
opcodes[0x77] = {ADDR_MODE_ZPX, cpu_rra, 6}
opcodes[0x6F] = {ADDR_MODE_ABS, cpu_rra, 6}
opcodes[0x7F] = {ADDR_MODE_AXP, cpu_rra, 7}
opcodes[0x7B] = {ADDR_MODE_AYP, cpu_rra, 7}
opcodes[0x63] = {ADDR_MODE_XIN, cpu_rra, 8}
opcodes[0x73] = {ADDR_MODE_YIP, cpu_rra, 8}

local function cpu_sax(self, mode)
    local addr = operand_addr[mode](self)
    self.memory:write8(addr, band(self.a, self.x))
end

opcodes[0x87] = {ADDR_MODE_ZP , cpu_sax, 3}
opcodes[0x97] = {ADDR_MODE_ZPY, cpu_sax, 4}
opcodes[0x8F] = {ADDR_MODE_ABS, cpu_sax, 4}
opcodes[0x83] = {ADDR_MODE_XIN, cpu_sax, 6}

opcodes[0xCB] = { -- SBX
    ADDR_MODE_IMM,
    function(self, mode)
        local val = self.memory:read8(operand_addr[mode](self))
        local result = band(self.a, self.x) - val

        set_zn(self, result)
        write_flag(self, FLAG_C, result >= 0)

        self.x = band(result, 0xFF)
    end,
    2
}

local function cpu_sha(self, mode)
    local addr = operand_addr[mode](self)
    self.memory:write8(addr, band(band(self.a, self.x), band(rshift(addr, 8) + 1, 0xFF)))
end

opcodes[0x9F] = {ADDR_MODE_ABY, cpu_sha, 4}
opcodes[0x93] = {ADDR_MODE_YIN, cpu_sha, 6}

opcodes[0x9E] = { --SHX
    ADDR_MODE_ABY,
    function(self, mode)
        local addr = operand_addr[mode](self)
        self.memory:write8(addr, band(self.x, band(rshift(addr, 8) + 1, 0xFF)))
    end,
    5
}

opcodes[0x9E] = { --SHX
    ADDR_MODE_ABY,
    function(self, mode)
        local addr = operand_addr[mode](self)
        self.memory:write8(addr, band(self.x, band(rshift(addr, 8) + 1, 0xFF)))
    end,
    5
}

opcodes[0x9C] = { --SHY
    ADDR_MODE_AXP,
    function(self, mode)
        local addr = operand_addr[mode](self)
        local temp = band(self.y, rshift(addr, 8) + 1)

        if rshift(bxor(addr - self.x, addr), 8) ~= 0 then
            addr = bor(band(addr, 0xFF), lshift(temp, 8))
        end

        self.memory:write8(addr, temp)
    end,
    5
}

local function cpu_slo(self, mode)
    local addr = operand_addr[mode](self)
    local val = self.memory:read8(addr)
    local temp = band(lshift(val, 1), 0xFF)

    self.memory:write8(addr, temp)
    self.a = bor(self.a, temp)

    write_flag(self, FLAG_C, band(val, 0x80) ~= 0)
    set_zn(self, self.a)
end

opcodes[0x07] = {ADDR_MODE_ZP , cpu_slo, 5}
opcodes[0x17] = {ADDR_MODE_ZPX, cpu_slo, 6}
opcodes[0x0F] = {ADDR_MODE_ABS, cpu_slo, 6}
opcodes[0x1F] = {ADDR_MODE_AXP, cpu_slo, 7}
opcodes[0x1B] = {ADDR_MODE_AYP, cpu_slo, 7}
opcodes[0x03] = {ADDR_MODE_XIN, cpu_slo, 8}
opcodes[0x13] = {ADDR_MODE_YIP, cpu_slo, 8}

local function cpu_sre(self, mode)
    local addr = operand_addr[mode](self)
    local val = self.memory:read8(addr)
    local temp = rshift(val, 1)

    self.memory:write8(addr, temp)
    self.a = bxor(self.a, temp)

    write_flag(self, FLAG_C, band(val, 0x01) ~= 0)
    set_zn(self, self.a)
end

opcodes[0x47] = {ADDR_MODE_ZP , cpu_sre, 5}
opcodes[0x57] = {ADDR_MODE_ZPX, cpu_sre, 6}
opcodes[0x4F] = {ADDR_MODE_ABS, cpu_sre, 6}
opcodes[0x5F] = {ADDR_MODE_AXP, cpu_sre, 7}
opcodes[0x5B] = {ADDR_MODE_AYP, cpu_sre, 7}
opcodes[0x43] = {ADDR_MODE_XIN, cpu_sre, 8}
opcodes[0x53] = {ADDR_MODE_YIP, cpu_sre, 8}

opcodes[0x9B] = {
    ADDR_MODE_AYP,
    function(self, mode)
        local addr = operand_addr[mode](self)
        local temp = band(band(self.a, self.x), rshift(addr, 8) + 1)

        if rshift(bxor(addr - self.y, addr), 8) ~= 0 then
            addr = bor(band(addr, 0xFF), lshift(temp, 8))
        end

        self.sp = band(self.a, self.x)
        self.memory:write8(addr, temp)
    end,
    5
}

-----------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function interrupt(self, addr)
    self.pc = band(self.pc + 1, 0xFFFF)

    push(self, rshift(self.pc, 8))
    push(self, band(self.pc, 0xFF))
    push(self, bor(self.flags, 0x20))

    self.pc = self.memory:read16_l(addr)
    self.flags = bor(self.flags, FLAG_I)
end

local function call_nmi(self)
    self.nmi = true
end

local function call_irq(self)
    self.irq = true
end

local function step(self)
    self.cycles_start = self.cycles

    if self.nmi then
        self.nmi = false
        interrupt(self, 0xFFFA)
    elseif self.irq and (band(self.flags, FLAG_I) == 0) then
        interrupt(self, 0xFFFE)
    end

    local instruction = opcodes[fetch8(self)]

    instruction[2](self, instruction[1])

    self.cycles = self.cycles - instruction[3]
    self.scheduler.clock = self.scheduler.clock + (self.cycles_start - self.cycles)

    if self.scheduler.clock >= self.scheduler.target then
        self.scheduler:process()
    end
end

local function execute(self, cycles)
    self.cycles = self.cycles + cycles

    while self.cycles > 0 do
        step(self)
    end
end

local function get_scheduler(self)
    return self.scheduler
end

local function get_reg(self, name)
    if name == "A" then
        return self.a
    elseif name == "X" then
        return self.x
    elseif name == "Y" then
        return self.y
    elseif name == "FLAGS" then
        return self.flags
    elseif name == "SP" then
        return self.sp
    elseif name == "PC" then
        return self.pc
    end

    error("invalid register: " .. name)
end

local function set_reg(self, name, val)
    if name == "A" then
        self.a = val
    elseif name == "X" then
        self.x = val
    elseif name == "Y" then
        self.y = val
    elseif name == "FLAGS" then
        self.flags = val
    elseif name == "SP" then
        self.sp = val
    elseif name == "PC" then
        self.pc = val
    else
        error("invalid register: " .. name)
    end
end

local function reset(self)
    self.a = 0x00
    self.x = 0x00
    self.y = 0x00
    self.flags = 0x00
    self.sp = 0x00
    self.pc = self.memory:read16_l(0xFFFC)
    self.cycles_start = 0
    self.cycles = 0
    self.nmi = false
    self.irq = false
end

function cpu.new(memory)
    local self = {
        memory = memory,
        scheduler = scheduler.new(),
        a = 0x00, -- Accumulator
        x = 0x00, -- Index Register X
        y = 0x00, -- Index register Y
        sp = 0x00, -- Stack Pointer
        pc = 0x0000, -- Program Counter
        flags = 0x00,
        cycles_start = 0,
        cycles = 0,
        nmi = false,
        irq = false,
        get_scheduler = get_scheduler,
        call_nmi = call_nmi,
        call_irq = call_irq,
        get_reg = get_reg,
        set_reg = set_reg,
        step = step,
        execute = execute,
        reset = reset
    }

    return self
end

return cpu
