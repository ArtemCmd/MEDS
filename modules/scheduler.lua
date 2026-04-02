-- =====================================================================================================================================================================
-- Timer System.
-- Ported from https://github.com/86Box/86Box/blob/master/src/timer.c
-- =====================================================================================================================================================================

local logger = require("dave_logger:logger")("MEDS")

local scheduler = {}

local function timer_disable(self)
    if not self.enabled then
        return
    end

    if (not self.next) and (not self.prev) and (self ~= self.scheduler.head) then
        error("invalid timer")
    end

    self.enabled = false
    self.in_callback = false

    if self.prev then
        self.prev.next = self.next
    else
        self.scheduler.head = self.next
    end

    if self.next then
        self.next.prev = self.prev
    end

    self.next = nil
    self.prev = nil
end

local function timer_enable(self)
    timer_disable(self)

    if self.next or self.prev then
        error("invalid timer")
    end

    self.enabled = true

    if not self.scheduler.head then
        self.next = nil
        self.prev = nil
        self.scheduler.head = self
        self.scheduler.target = self.clock
        return
    end

    local node = self.scheduler.head

    while true do
        if (self.clock - node.clock) <= 0 then
            self.next = node
            self.prev = node.prev

            node.prev = self

            if self.prev then
                self.prev.next = self
                return
            end

            self.scheduler.head = self
            self.scheduler.target = self.clock

            return
        end

        if not node.next then
            node.next = self
            self.prev = node
            break
        end

        node = node.next
    end
end

local function timer_advance(self, delay)
    self.clock = self.clock + math.abs(delay)
    timer_enable(self)
end

local function timer_set_delay(self, delay)
    self.clock = self.scheduler.clock + delay
    timer_enable(self)
end

local function timer_period_start(self, period)
    if period <= 0.0 then
        timer_disable(self)

        self.period = 0.0
        self.periodic = false
        self.in_callback = false

        return
    end

    if period > 1000000.0 then
        if (self.period <= 0.0) and not self.in_callback then
            timer_set_delay(self, math.floor(1000000 * self.scheduler.NANOSECOND))
        else
            timer_advance(self, math.floor(1000000 * self.scheduler.NANOSECOND))
        end

        self.period = period - 1000000.0
        self.periodic = true

        return
    end

    if not self.in_callback then
        timer_set_delay(self, math.floor(period * self.scheduler.NANOSECOND))
    else
        timer_advance(self, math.floor(period * self.scheduler.NANOSECOND))
    end

    self.period = 0.0
    self.periodic = false
end

local function timer_get_remaining(self)
    if self.enabled then
        local result = self.clock - self.scheduler.clock

        if result < 0 then
            return 0
        end

        return result
    end

    return 0
end

local function timer_is_enabled_period(self)
    return self.periodic and self.enabled
end

local function timer_set_callback(self, callback)
    self.callback = callback
end

local function timer_reset(self)
    self.clock = 0
end

local function process(self)
    if not self.head then
        return
    end

    -- local clock = os.clock()

    while true do
        local timer = self.head

        if timer.clock > self.clock then
            break
        end

        self.head = timer.next

        if not self.head then
            return
        end

        self.head.prev = nil

        timer.next = nil
        timer.prev = nil
        timer.enabled = false

        if timer.periodic then
            if timer.period > 1000000.0 then
                timer_advance(timer, 1000000 * self.USEC)
                timer.period = timer.period - 1000000.0
                timer.periodic = true
            else
                timer_disable(timer)
                timer.period = 0.0
                timer.periodic = false
            end
        else
            timer.in_callback = true
            timer.callback(timer.arg)
            timer.in_callback = false
        end

        -- if (os.clock() - clock) > 0.5 then
        --     local info = debug.getinfo(timer.callback, "S")
        --     logger:debug("Scheduler: %s(%d/%d)", info.source, info.linedefined, info.lastlinedefined)
        --     clock = os.clock()
        -- end
    end

    self.target = self.head.clock
end

local function add(self, callback, arg, start)
    local timer = {
        clock = 0,
        period = 0.0,
        callback = callback,
        arg = arg,
        enabled = false,
        scheduler = self,
        disable = timer_disable,
        enable = timer_enable,
        advance = timer_advance,
        set_delay = timer_set_delay,
        get_remaining = timer_get_remaining,
        is_enabled_period = timer_is_enabled_period,
        set_callback = timer_set_callback,
        period_start = timer_period_start,
        reset = timer_reset
    }

    if start then
        timer_set_delay(timer, 0)
    end

    return timer
end

local function update_clock(self, time)
    self.clock = self.clock + time
end

local function reset_clock(self)
    self.clock = 0
end

local function reset(self)
    self.target = 0
    self.clock = 0
end

function scheduler.new()
    local self = {
        NANOSECOND = 1,
        MAX_TIME = 1000000,
        clock = 0,
        target = 0,
        add = add,
        process = process,
        update_clock = update_clock,
        reset_clock = reset_clock,
        reset = reset
    }

    return self
end

return scheduler
