-- =====================================================================================================================================================================
-- Intel 8080 CPU emulation.
-- =====================================================================================================================================================================

local common = require("emulator:hardware/cpu/common")
local io_ports = require("emulator:io_ports")
local scheduler = require("emulator:scheduler")

local band, bor, rshift, lshift, bxor, bnot = bit.band, bit.bor, bit.rshift, bit.lshift, bit.bxor, bit.bnot

local cpu = {}

local opcode_cycles = {
    [0x00] =
    4, 10,  7,  5,  5,  5,  7,  4,  4, 10,  7,  5,  5,  5, 7,  4,
    4, 10,  7,  5,  5,  5,  7,  4,  4, 10,  7,  5,  5,  5, 7,  4,
    4, 10, 16,  5,  5,  5,  7,  4,  4, 10, 16,  5,  5,  5, 7,  4,
    4, 10, 13,  5, 10, 10, 10,  4,  4, 10, 13,  5,  5,  5, 7,  4,
    5,  5,  5,  5,  5,  5,  7,  5,  5,  5,  5,  5,  5,  5, 7,  5,
    5,  5,  5,  5,  5,  5,  7,  5,  5,  5,  5,  5,  5,  5, 7,  5,
    5,  5,  5,  5,  5,  5,  7,  5,  5,  5,  5,  5,  5,  5, 7,  5,
    7,  7,  7,  7,  7,  7,  7,  7,  5,  5,  5,  5,  5,  5, 7,  5,
    4,  4,  4,  4,  4,  4,  7,  4,  4,  4,  4,  4,  4,  4, 7,  4,
    4,  4,  4,  4,  4,  4,  7,  4,  4,  4,  4,  4,  4,  4, 7,  4,
    4,  4,  4,  4,  4,  4,  7,  4,  4,  4,  4,  4,  4,  4, 7,  4,
    4,  4,  4,  4,  4,  4,  7,  4,  4,  4,  4,  4,  4,  4, 7,  4,
    5, 10, 10, 10, 11, 11,  7, 11,  5, 10, 10, 10, 11, 17, 7, 11,
    5, 10, 10, 10, 11, 11,  7, 11,  5, 10, 10, 10, 11, 17, 7, 11,
    5, 10, 10, 18, 11, 11,  7, 11,  5,  5, 10,  4, 11, 17, 7, 11,
    5, 10, 10,  4, 11, 11,  7, 11,  5,  5, 10,  4, 11, 17, 7, 11
}

local interrupt_vectors = {
    [0x00] = 0xC7,
    [0x01] = 0xCF,
    [0x02] = 0xD7,
    [0x03] = 0xDF,
    [0x04] = 0xE7,
    [0x05] = 0xEF,
    [0x06] = 0xF7,
    [0x07] = 0xFF
}

local FLAG_C = 0x01 -- Carry Flag
local FLAG_P = 0x04 -- Parity Flag
local FLAG_A = 0x10 -- Auxiliary Carry Flag
local FLAG_Z = 0x40 -- Zero FLag
local FLAG_S = 0x80 -- Sign Flag

local CLEAR_CA = bnot(bor(FLAG_C, FLAG_A))
local CLEAR_ZSP = bnot(bor(FLAG_Z, bor(FLAG_S, FLAG_P)))

local function fetch_byte(self)
    local byte = self.memory:read8(self.pc)
    self.pc = band(self.pc + 1, 0xFFFF)
    return byte
end

local function fetch_word(self)
    local word = self.memory:read16_l(self.pc)
    self.pc = band(self.pc + 2, 0xFFFF)
    return word
end

local function set_bc(self, val)
    self.b = rshift(val, 8)
    self.c = band(val, 0xFF)
end

local function set_de(self, val)
    self.d = rshift(val, 8)
    self.e = band(val, 0xFF)
end

local function set_hl(self, val)
    self.h = rshift(val, 8)
    self.l = band(val, 0xFF)
end

local function get_bc(self)
    return bor(self.c, lshift(self.b, 8))
end

local function get_de(self)
    return bor(self.e, lshift(self.d, 8))
end

local function get_hl(self)
    return bor(self.l, lshift(self.h, 8))
end

local function push(self, val)
    self.sp = band(self.sp - 2, 0xFFFF)
    self.memory:write16_l(self.sp, val)
end

local function pop(self)
    local ret = self.memory:read16_l(self.sp)
    self.sp = band(self.sp + 2, 0xFFFF)
    return ret
end

local function set_zsp(self, val)
    self.flags = band(self.flags, CLEAR_ZSP)
    self.flags = bor(self.flags, rshift(band(bxor(val, 0xFF) + 1, 0x100), 2)) -- Set ZF
    self.flags = bor(self.flags, band(val, 0x80)) -- Set SF
    self.flags = bor(self.flags, lshift(common.parity_table[band(val, 0xFF)], 2)) -- Set PF
end

local function cpu_inr(self, val)
    local result = band(val + 1, 0xFF)

    self.flags = bor(band(self.flags, bnot(FLAG_A)), band(bxor(band(result, 0x0F), 0x0F) + 1, 0x10))
    set_zsp(self, result)

    return result
end

local function cpu_dcr(self, val)
    local result = band(val - 1, 0xFF)

    self.flags = bor(band(self.flags, bnot(FLAG_A)), bxor(band(band(result, 0x0F) + 1, 0x10), 0x10)) -- Set AF
    set_zsp(self, result)

    return result
end

local function cpu_add(self, val, cf)
    local oper1 = self.a
    local result = oper1 + val + cf
    local bresult = bxor(bxor(result, oper1), val)

    self.flags = band(self.flags, CLEAR_CA)
    self.flags = bor(self.flags, rshift(band(bresult, 0x100), 8)) -- Set CF
    self.flags = bor(self.flags, band(bresult, 0x010)) -- Set AF

    set_zsp(self, band(result, 0xFF))

    self.a = band(result, 0xFF)
end

local function cpu_sub(self, val, cf)
    local result = self.a - val - cf
    local bresult = bxor(result, bxor(self.a, val))

    self.flags = band(self.flags, CLEAR_CA)
    self.flags = bor(self.flags, rshift(band(bresult, 0x100), 8)) -- Set CF
    self.flags = bor(self.flags, bxor(band(bresult, 0x010), 0x010)) -- Set AF

    set_zsp(self, band(result, 0xFF))

    self.a = band(result, 0xFF)
end

local function cpu_ana(self, val)
    local oper1 = self.a
    local result = band(oper1, val)

    self.flags = band(self.flags, CLEAR_CA)
    self.flags = bor(self.flags, lshift(band(bor(oper1, val), 0x08), 1))

    set_zsp(self, result)

    self.a = result
end

local function cpu_ora(self, val)
    local result = bor(self.a, val)

    self.flags = band(self.flags, CLEAR_CA)
    set_zsp(self, result)

    self.a = result
end

local function cpu_xra(self, val)
    local result = bxor(self.a, val)

    self.flags = band(self.flags, CLEAR_CA)
    set_zsp(self, result)

    self.a = result
end

local function cpu_cmp(self, val)
    local oper1 = self.a
    local result = oper1 - val

    self.flags = band(self.flags, CLEAR_CA)
    self.flags = bor(self.flags, band(rshift(result, 8), 0x01))
    self.flags = bor(self.flags, band(bnot(bxor(bxor(oper1, result), val)), 0x10))

    set_zsp(self, band(result, 0xFF))
end

local function cpu_dad(self, val)
    local result = get_hl(self) + val
    self.flags = bor(band(self.flags, bnot(FLAG_C)), rshift(band(result, 0x10000), 16))
    set_hl(self, band(result, 0xFFFF))
end

local opcodes = {}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 8 Bit Load Instructions.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

opcodes[0x02] = function(self) -- STAX B
    self.memory:write8(bor(self.c, lshift(self.b, 8)), self.a)
end

opcodes[0x12] = function(self) -- STAX D
    self.memory:write8(bor(self.e, lshift(self.d, 8)), self.a)
end

opcodes[0x32] = function(self) -- STA NN
    self.memory:write8(fetch_word(self), self.a)
end

opcodes[0x06] = function(self) -- MVI B, N
    self.b = fetch_byte(self)
end

opcodes[0x16] = function(self) -- MVI D, N
    self.d = fetch_byte(self)
end

opcodes[0x26] = function(self) -- MVI H, N
    self.h = fetch_byte(self)
end

opcodes[0x36] = function(self) -- MVI M, N
    self.memory:write8(bor(self.l, lshift(self.h, 8)), fetch_byte(self))
end

opcodes[0x0A] = function(self) -- LDAX BC
    self.a = self.memory:read8(bor(self.c, lshift(self.b, 8)))
end

opcodes[0x1A] = function(self) -- LDAX DE
    self.a = self.memory:read8(bor(self.e, lshift(self.d, 8)))
end

opcodes[0x3A] = function(self) -- LDA NN
    self.a = self.memory:read8(fetch_word(self))
end

opcodes[0x0E] = function(self) -- MVI C, N
    self.c = fetch_byte(self)
end

opcodes[0x1E] = function(self) -- MVI E, N
    self.e = fetch_byte(self)
end

opcodes[0x2E] = function(self) -- MVI L, N
    self.l = fetch_byte(self)
end

opcodes[0x3E] = function(self) -- MVI A, N
    self.a = fetch_byte(self)
end

local REGS = {
    [0] = "b",
    "c",
    "d",
    "e",
    "h",
    "l",
    "memory:read8(bor(self.l, lshift(self.h, 8)))",
    "a"
}

local function gen_mov(opcode)
    for i = opcode, opcode + 0x07, 1 do
        local src = band(i, 0x07)
        local dest = band(rshift(i, 3), 0x07)
        local code

        if dest == 0x06 then
            if src == 0x06 then
                goto continue
            end

            code = string.format([[
            local band, bor, lshift, rshift = ...
            return function(self)
                local addr = bor(self.l, lshift(self.h, 8))
                self.memory:write8(addr, self.%s)
            end
            ]], REGS[src])
        else
            code = string.format([[
            local band, bor, lshift, rshift = ...
            return function(self)
                self.%s = self.%s
            end        
            ]], REGS[dest], REGS[src])
        end

        opcodes[i] = load(code, "=i8080.lua-mov", "t")(band, bor, lshift, rshift)

        ::continue::
    end
end

gen_mov(0x40) -- MOV B, X
gen_mov(0x48) -- MOV C, X
gen_mov(0x50) -- MOV D, X
gen_mov(0x58) -- MOV E, X
gen_mov(0x60) -- MOV H, X
gen_mov(0x68) -- MOV L, X
gen_mov(0x70) -- MOV M, X
gen_mov(0x78) -- MOV A, X

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 16 Bit Load Instructions.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

opcodes[0x01] = function(self) -- LXI B, NN
    local val = fetch_word(self)

    self.b = rshift(val, 8)
    self.c = band(val, 0xFF)
end

opcodes[0x11] = function(self) -- LXI D, NN
    local val = fetch_word(self)

    self.d = rshift(val, 8)
    self.e = band(val, 0xFF)
end

opcodes[0x21] = function(self) -- LXI H, NN
    local val = fetch_word(self)

    self.h = rshift(val, 8)
    self.l = band(val, 0xFF)
end

opcodes[0x31] = function(self) -- LXI SP, NN
    self.sp = fetch_word(self)
end

opcodes[0x22] = function(self) -- SHLD NN
    self.memory:write16_l(fetch_word(self), bor(self.l, lshift(self.h, 8)))
end

opcodes[0x2A] = function(self) -- LHLD NN
    local val = self.memory:read16_l(fetch_word(self))

    self.h = rshift(val, 8)
    self.l = band(val, 0xFF)
end

opcodes[0xC1] = function(self) -- POP BC
    set_bc(self, pop(self))
end

opcodes[0xD1] = function(self) -- POP DE
    set_de(self, pop(self))
end

opcodes[0xE1] = function(self) -- POP HL
    set_hl(self, pop(self))
end

opcodes[0xF1] = function(self) -- POP PSW
    local val = pop(self)

    self.a = rshift(val, 8)
    self.flags = band(val, 0xD7)
end

opcodes[0xC5] = function(self) -- PUSH BC
    push(self, get_bc(self))
end

opcodes[0xD5] = function(self) -- PUSH DE
    push(self, get_de(self))
end

opcodes[0xE5] = function(self) -- PUSH HL
    push(self, get_hl(self))
end

opcodes[0xF5] = function(self) -- PUSH PSW
    push(self, bor(bor(self.flags, lshift(self.a, 8)), 0x02))
end

opcodes[0xE3] = function(self) -- XTHL
    local val = self.memory:read16_l(self.sp)

    self.memory:write16_l(self.sp, get_hl(self))
    set_hl(self, val)
end

opcodes[0xF9] = function(self) -- SPHL
    self.sp = get_hl(self)
end

opcodes[0xEB] = function(self) -- XCHG
    local de = get_de(self)
    set_de(self, get_hl(self))
    set_hl(self, de)
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 8 Bit Arithmetic/Logical Instructions.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

opcodes[0x04] = function(self) -- INR B
    self.b = cpu_inr(self, self.b)
end

opcodes[0x14] = function(self) -- INR D
    self.d = cpu_inr(self, self.d)
end

opcodes[0x24] = function(self) -- INR H
    self.h = cpu_inr(self, self.h)
end

opcodes[0x34] = function(self) -- INR M
    local hl = get_hl(self)
    self.memory:write8(hl, cpu_inr(self, self.memory:read8(hl)))
end

opcodes[0x05] = function(self) -- DCR B
    self.b = cpu_dcr(self, self.b)
end

opcodes[0x15] = function(self) -- DCR D
    self.d = cpu_dcr(self, self.d)
end

opcodes[0x25] = function(self) -- DCR H
    self.h = cpu_dcr(self, self.h)
end

opcodes[0x35] = function(self) -- DCR M
    local hl = get_hl(self)
    self.memory:write8(hl, cpu_dcr(self, self.memory:read8(hl)))
end

opcodes[0x0C] = function(self) -- INR C
    self.c = cpu_inr(self, self.c)
end

opcodes[0x1C] = function(self) -- INR E
    self.e = cpu_inr(self, self.e)
end

opcodes[0x2C] = function(self) -- INR L
    self.l = cpu_inr(self, self.l)
end

opcodes[0x3C] = function(self) -- INR A
    self.a = cpu_inr(self, self.a)
end

opcodes[0x0D] = function(self) -- DCR C
    self.c = cpu_dcr(self, self.c)
end

opcodes[0x1D] = function(self) -- DCR E
    self.e = cpu_dcr(self, self.e)
end

opcodes[0x2D] = function(self) -- DCR L
    self.l = cpu_dcr(self, self.l)
end

opcodes[0x3D] = function(self) -- DCR A
    self.a = cpu_dcr(self, self.a)
end

opcodes[0x07] = function(self) -- RLC
    local a = self.a
    local cf = rshift(a, 7)

    self.flags = bor(band(self.flags, bnot(FLAG_C)), cf)
    self.a = band(bor(lshift(a, 1), cf), 0xFF)
end

opcodes[0x0F] = function(self) -- RRC
    local a = self.a
    local cf = band(a, 0x01)

    self.flags = bor(band(self.flags, bnot(FLAG_C)), cf)
    self.a = band(bor(rshift(a, 1), lshift(cf, 7)), 0xFF)
end

opcodes[0x17] = function(self) -- RAL
    local a = self.a

    self.a = band(bor(lshift(a, 1), band(self.flags, FLAG_C)), 0xFF)
    self.flags = bor(band(self.flags, bnot(FLAG_C)), rshift(a, 7))
end

opcodes[0x1F] = function(self) -- RAR
    local a = self.a

    self.a = band(bor(rshift(a, 1), lshift(band(self.flags, FLAG_C), 7)), 0xFF)
    self.flags = bor(band(self.flags, bnot(FLAG_C)), band(a, 0x01))
end

opcodes[0x27] = function(self) -- DAA
    local a = self.a
    local flags = self.flags
    local cf = band(flags, FLAG_C)
    local correction = 0
    local lsb = band(a, 0x0F)
    local msb = rshift(a, 4)

    if (band(flags, FLAG_A) ~= 0) or (lsb > 9) then
        correction = correction + 0x06
    end

    if (cf ~= 0) or (msb > 9) or ((msb >= 9) and (lsb > 9)) then
        correction = correction + 0x60
        cf = FLAG_C
    end

    cpu_add(self, correction, 0)
    self.flags = bor(band(self.flags, bnot(FLAG_C)), cf)
end

opcodes[0x2F] = function(self) -- CMA
    self.a = band(bnot(self.a), 0xFF)
end

opcodes[0x3F] = function(self) -- CMC
    self.flags = bxor(self.flags, FLAG_C)
end

opcodes[0x37] = function(self) -- STC
    self.flags = bor(self.flags, FLAG_C)
end

local function gen_alu_r(opcode, operation)
    for i = opcode, opcode + 0x07, 1 do
        local src = REGS[band(i, 0x07)]

        opcodes[i] = load(string.format([[
        local band, bor, lshift, rshift, cpu_add, cpu_sub, cpu_ana, cpu_xra, cpu_ora, cpu_cmp = ...
        return function(self)
            %s
        end
        ]], string.format(operation, src)), "=i8080.lua-alu_r", "t")(band, bor, lshift, rshift, cpu_add, cpu_sub, cpu_ana, cpu_xra, cpu_ora, cpu_cmp)
    end
end

gen_alu_r(0x80, "cpu_add(self, self.%s, 0)")
gen_alu_r(0x88, "cpu_add(self, self.%s, band(self.flags, 0x01))")
gen_alu_r(0x90, "cpu_sub(self, self.%s, 0)")
gen_alu_r(0x98, "cpu_sub(self, self.%s, band(self.flags, 0x01))")
gen_alu_r(0xA0, "cpu_ana(self, self.%s)")
gen_alu_r(0xA8, "cpu_xra(self, self.%s)")
gen_alu_r(0xB0, "cpu_ora(self, self.%s)")
gen_alu_r(0xB8, "cpu_cmp(self, self.%s)")

opcodes[0xC6] = function(self) -- ADI N
    cpu_add(self, fetch_byte(self), 0)
end

opcodes[0xD6] = function(self) -- SUI N
    cpu_sub(self, fetch_byte(self), 0)
end

opcodes[0xE6] = function(self) -- ANI N
    cpu_ana(self, fetch_byte(self))
end

opcodes[0xF6] = function(self) -- ORI N
    cpu_ora(self, fetch_byte(self))
end

opcodes[0xCE] = function(self) -- ACI N
    cpu_add(self, fetch_byte(self), band(self.flags, FLAG_C))
end

opcodes[0xDE] = function(self) -- SBI N
    cpu_sub(self, fetch_byte(self), band(self.flags, FLAG_C))
end

opcodes[0xEE] = function(self) -- XRI N
    cpu_xra(self, fetch_byte(self))
end

opcodes[0xFE] = function(self) -- CPI N
    cpu_cmp(self, fetch_byte(self))
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 16 Bit Arithmetic/Logical Instructions.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

opcodes[0x03] = function(self) -- INX B
    set_bc(self, band(get_bc(self) + 1, 0xFFFF))
end

opcodes[0x13] = function(self) -- INX D
    set_de(self, band(get_de(self) + 1, 0xFFFF))
end

opcodes[0x23] = function(self) -- INX H
    set_hl(self, band(get_hl(self) + 1, 0xFFFF))
end

opcodes[0x33] = function(self) -- INX SP
    self.sp = band(self.sp + 1, 0xFFFF)
end


opcodes[0x0B] = function(self) -- DCX BC
    set_bc(self, band(get_bc(self) - 1, 0xFFFF))
end

opcodes[0x1B] = function(self) -- DCX DE
    set_de(self, band(get_de(self) - 1, 0xFFFF))
end

opcodes[0x2B] = function(self) -- DCX HL
    set_hl(self, band(get_hl(self) - 1, 0xFFFF))
end

opcodes[0x3B] = function(self) -- DCX SP
    self.sp = band(self.sp - 1, 0xFFFF)
end

opcodes[0x09] = function(self) -- DAD BC
    cpu_dad(self, get_bc(self))
end

opcodes[0x19] = function(self) -- DAD DE
    cpu_dad(self, get_de(self))
end

opcodes[0x29] = function(self) -- DAD HL
    cpu_dad(self, get_hl(self))
end

opcodes[0x39] = function(self) -- DAD SP
    cpu_dad(self, self.sp)
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Jumps/Calls Instructions.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function gen_rc(opcode, flag, clear)
    opcodes[opcode] = load(string.format([[
    local band, pop = ...
    return function(self)
        if band(self.flags, %s) %s= 0 then
            self.pc = pop(self)
            self.cycles = self.cycles - 6
        end
    end
    ]], flag, clear and "=" or "~"), "=i8080.lua-rc", "t")(band, pop)
end

gen_rc(0xC0, FLAG_Z, true)
gen_rc(0xD0, FLAG_C, true)
gen_rc(0xE0, FLAG_P, true)
gen_rc(0xF0, FLAG_S, true)

gen_rc(0xC8, FLAG_Z, false)
gen_rc(0xD8, FLAG_C, false)
gen_rc(0xE8, FLAG_P, false)
gen_rc(0xF8, FLAG_S, false)

local function gen_jc(opcode, flag, clear)
    opcodes[opcode] = load(string.format([[
    local band, fetch_word = ...
    return function(self)
        local addr = fetch_word(self)

        if band(self.flags, %s) %s= 0 then
            self.pc = addr
        end
    end
    ]], flag, clear and "=" or "~"), "=i8080.lua-jc", "t")(band, fetch_word)
end

gen_jc(0xC2, FLAG_Z, true)
gen_jc(0xD2, FLAG_C, true)
gen_jc(0xE2, FLAG_P, true)
gen_jc(0xF2, FLAG_S, true)

gen_jc(0xCA, FLAG_Z, false)
gen_jc(0xDA, FLAG_C, false)
gen_jc(0xEA, FLAG_P, false)
gen_jc(0xFA, FLAG_S, false)

local function gen_cc(opcode, flag, clear)
    opcodes[opcode] = load(string.format([[
    local band, push, fetch_word = ...
    return function(self)
        local addr = fetch_word(self)

        if band(self.flags, %d) %s= 0 then
            push(self, self.pc)

            self.pc = addr
            self.cycles = self.cycles - 6
        end
    end
    ]], flag, clear and "=" or "~"), "=i8080.lua-cc", "t")(band, push, fetch_word)
end

gen_cc(0xC4, FLAG_Z, true)
gen_cc(0xD4, FLAG_C, true)
gen_cc(0xE4, FLAG_P, true)
gen_cc(0xF4, FLAG_S, true)

gen_cc(0xCC, FLAG_Z, false)
gen_cc(0xDC, FLAG_C, false)
gen_cc(0xEC, FLAG_P, false)
gen_cc(0xFC, FLAG_S, false)

local function gen_rst_n(opcode, addr)
    opcodes[opcode] = load(string.format([[
    local push = ...
    return function(self)
        push(self, self.pc)
        self.pc = %s
    end
    ]], addr))(push)
end

gen_rst_n(0xC7, 0x0000)
gen_rst_n(0xD7, 0x0010)
gen_rst_n(0xE7, 0x0020)
gen_rst_n(0xF7, 0x0030)

gen_rst_n(0xCF, 0x0008)
gen_rst_n(0xDF, 0x0018)
gen_rst_n(0xEF, 0x0028)
gen_rst_n(0xFF, 0x0038)

opcodes[0xC9] = function(self) -- RET
    self.pc = pop(self)
end
opcodes[0xD9] = opcodes[0xC9]

opcodes[0xC3] = function(self) -- JMP NN
    self.pc = fetch_word(self)
end
opcodes[0xCB] = opcodes[0xC3]

opcodes[0xCD] = function(self) -- CALL NN
    local addr = fetch_word(self)

    push(self, self.pc)
    self.pc = addr
end
opcodes[0xDD] = opcodes[0xCD]
opcodes[0xED] = opcodes[0xCD]
opcodes[0xFD] = opcodes[0xCD]

opcodes[0xE9] = function(self) -- PCHL
    self.pc = bor(self.l, lshift(self.h, 8))
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Misc Instructions.
------------------------------------------------------------------------------------------------------------------------------------------------------------------------

opcodes[0x00] = function(self) -- NOP
end
opcodes[0x08] = opcodes[0x00]
opcodes[0x10] = opcodes[0x00]
opcodes[0x18] = opcodes[0x00]
opcodes[0x20] = opcodes[0x00]
opcodes[0x28] = opcodes[0x00]
opcodes[0x30] = opcodes[0x00]
opcodes[0x38] = opcodes[0x00]


opcodes[0xD3] = function(self) -- OUT N
    self.io:out_port(fetch_byte(self), self.a)
end

opcodes[0xF3] = function(self) -- DI
    self.iff = false
end

opcodes[0x76] = function(self) -- HALT
    self.halted = true
end

opcodes[0xDB] = function(self) -- IN N
    self.a = band(self.io:in_port(fetch_byte(self)), 0xFF)
end

opcodes[0xFB] = function(self) -- EI
    self.iff = true
    self.interrupt_delay = 1
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function step(self)
    local opcode

    self.cycles_start = self.cycles

    if self.int_pending and self.iff and (self.interrupt_delay == 0) then
        self.interrupt_delay = 0
        self.iff = false
        self.halted = false
        self.cycles = self.cycles - 4

        opcode = self.interrupt_opcode
    elseif not self.halted then
        opcode = fetch_byte(self)
    else
        opcode = 0x76
    end

    self.cycles = self.cycles - opcode_cycles[opcode]

    if self.interrupt_delay > 0 then
        self.interrupt_delay = self.interrupt_delay - 1
    end

    opcodes[opcode](self)

    self.scheduler.clock = self.scheduler.clock + (self.cycles_start - self.cycles) * self.multi

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

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local function call_interrupt(self, vector)
    self.interrupt_opcode = interrupt_vectors[band(vector, 0x07)]
    self.int_pending = true
end

local function get_cycles(self)
    return self.cycles
end

local function get_io(self)
    return self.io
end

local function get_scheduler(self)
    return self.scheduler
end

local function is_halted(self)
    return self.halted
end

local function set_reset_vector(self, pc)
    self.reset_vector = pc
end

local function get_reg(self, name)
    if name == "AF" then
        return bor(self.flags, lshift(self.a, 8))
    elseif name == "DE" then
        return get_de(self)
    elseif name == "HL" then
        return get_hl(self)
    elseif name == "BC" then
        return get_bc(self)
    elseif name == "SP" then
        return self.sp
    elseif name == "PC" then
        return self.pc
    end

    error("invalid register: " .. name)
end

local function set_reg(self, name, val)
    if name == "AF" then
        self.flags = band(val, 0xFF)
        self.flags = band(rshift(val, 8), 0xFF)
    elseif name == "DE" then
        set_de(self, val)
    elseif name == "HL" then
        set_hl(self, val)
    elseif name == "BC" then
        set_bc(self, val)
    elseif name == "SP" then
        self.sp = band(val, 0xFFFF)
    elseif name == "PC" then
        self.pc = band(val, 0xFFFF)
    else
        error("invalid register: " .. name)
    end
end

local function reset(self)
    self.a = 0x00
    self.b = 0x00
    self.c = 0x00
    self.d = 0x00
    self.e = 0x00
    self.flags = 0x00
    self.h = 0x00
    self.l = 0x00
    self.sp = 0x0000
    self.pc = self.reset_vector
    self.cycles_start = 0
    self.cycles = 0
    self.interrupt_delay = 0
    self.interrupt_opcode = 0
    self.iff = false
    self.halted = false
    self.int_pending = false
end

------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function cpu.new(memory, multiplier)
    local self = {
        memory = memory,
        scheduler = scheduler.new(),
        multi = multiplier or 1,
        a = 0x00,
        b = 0x00,
        c = 0x00,
        d = 0x00,
        e = 0x00,
        flags = 0x00,
        h = 0x00,
        l = 0x00,
        sp = 0x0000, -- Stack Pointer
        pc = 0x0000, -- Program Counter
        cycles_start = 0,
        cycles = 0,
        interrupt_delay = 0,
        interrupt_opcode = 0,
        reset_vector = 0x0000,
        iff = false,
        halted = false,
        int_pending = false,
        get_cycles = get_cycles,
        get_scheduler = get_scheduler,
        get_io = get_io,
        get_reg = get_reg,
        set_reg = set_reg,
        is_halted = is_halted,
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
