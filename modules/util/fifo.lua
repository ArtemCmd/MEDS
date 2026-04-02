local fifo = {}

local function get_count(self)
    if self.position_end == self.position_start then
        if self.full then
            return self.length
        end

        return 0
    end

    return math.abs(self.position_end - self.position_start)
end

local function pop(self, val)
    if self.empty then
        return 0x00
    end

    local result = self.buffer[self.position_start]
    self.position_start = (self.position_start + 1) % self.length
    self.full = false
    self.empty = get_count(self) == 0

    return result
end

local function push(self, val)
    if self.full then
        self.overrun = true
        return
    end

    self.buffer[self.position_end] = val
    self.position_end = (self.position_end + 1) % self.length
    self.full = self.position_end == self.position_start
    self.empty = false
end

local function is_empty(self)
    return self.empty
end

local function is_full(self)
    return self.full
end

local function reset(self)
    self.position_start = 0
    self.position_end = 0
    self.empty = true
    self.ready = false
    self.full = false
end

function fifo.new(length)
    local self = {
        buffer = {},
        length = length,
        position_start = 0,
        position_end = 0,
        full = false,
        empty = false,
        get_count = get_count,
        is_empty = is_empty,
        is_full = is_full,
        pop = pop,
        push = push,
        reset = reset
    }

    return self
end

return fifo
