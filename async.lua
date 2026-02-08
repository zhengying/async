---@meta
--- async.lua — cooperative async scheduler for Lua/LÖVE (fixed version)

---@class Async
local async = {}
async.__index = async

-- Detect LÖVE
local IS_LOVE = type(love) == "table"
    and type(love.timer) == "table"
    and type(love.timer.getTime) == "function"

local has_socket, socket_mod = pcall(require, "socket")
async.gettime = IS_LOVE and love.timer.getTime
             or (has_socket and socket_mod.gettime)
             or os.clock

local CURRENT_TASK = nil

local LOG_LEVELS = { off = 0, error = 1, warn = 2, info = 3, debug = 4, trace = 5 }
local LOG_LEVEL_NAMES = { [0] = "off", [1] = "error", [2] = "warn", [3] = "info", [4] = "debug", [5] = "trace" }

local function normalizeLogLevel(level)
    if type(level) == "number" then
        if level < 0 then return 0 end
        if level > 5 then return 5 end
        return level
    end
    if type(level) == "string" then
        local k = string.lower(level)
        local v = LOG_LEVELS[k]
        if v ~= nil then return v end
        local n = tonumber(level)
        if n ~= nil then return normalizeLogLevel(n) end
    end
    return LOG_LEVELS.info
end

local function defaultLogSink(entry)
    local parts = {
        "[async]",
        "[", entry.levelName or tostring(entry.level), "]",
        "[", tostring(entry.time), "]",
        " ",
        tostring(entry.event)
    }

    local task = entry.task
    if task and (task.id or task.src) then
        parts[#parts + 1] = " task="
        if task.id ~= nil then
            parts[#parts + 1] = tostring(task.id)
        end
        if task.src ~= nil then
            parts[#parts + 1] = " "
            parts[#parts + 1] = tostring(task.src)
            parts[#parts + 1] = ":"
            parts[#parts + 1] = tostring(task.line or 0)
        end
    end

    local fields = entry.fields
    if type(fields) == "table" then
        for k, v in pairs(fields) do
            parts[#parts + 1] = " "
            parts[#parts + 1] = tostring(k)
            parts[#parts + 1] = "="
            parts[#parts + 1] = tostring(v)
        end
    end

    local line = table.concat(parts)
    if IS_LOVE then
        print(line)
    else
        io.stderr:write(line .. "\n")
    end
end

local LOGGER = { enabled = false, level = LOG_LEVELS.off, sink = nil, _inSink = false }

local function taskRef(task)
    if not task then return nil end
    local info = rawget(task, "info") or {}
    return {
        id = rawget(task, "id"),
        src = info.short_src,
        line = info.linedefined,
        name = info.name,
        state = rawget(task, "state")
    }
end

local function emitLog(level, event, fields, task)
    if not LOGGER.enabled then return end

    local nlevel = normalizeLogLevel(level)
    if nlevel == 0 or nlevel > LOGGER.level then return end

    local sink = LOGGER.sink or defaultLogSink
    if LOGGER._inSink then return end

    LOGGER._inSink = true
    local ok, err = pcall(sink, {
        time = async.gettime(),
        level = nlevel,
        levelName = LOG_LEVEL_NAMES[nlevel] or tostring(nlevel),
        event = event,
        fields = fields,
        task = taskRef(task)
    })
    LOGGER._inSink = false

    if not ok then
        LOGGER.enabled = false
        local msg = "[async][error][" .. tostring(async.gettime()) .. "] log sink error: " .. tostring(err) .. "\n"
        if IS_LOVE then
            print(msg)
        else
            io.stderr:write(msg)
        end
    end
end

function async.setLogEnabled(enabled)
    LOGGER.enabled = not not enabled
end

function async.setLogLevel(level)
    LOGGER.level = normalizeLogLevel(level)
end

function async.setLogSink(sink)
    if sink ~= nil and type(sink) ~= "function" then
        error("log sink must be a function or nil", 2)
    end
    LOGGER.sink = sink
end

function async.log(level, event, fields)
    emitLog(level, event, fields, CURRENT_TASK)
end

-- scheduler state
local queue = {}
local stack = {}
local sleepers = {}

-- FIX: track currently running task
local TASK_ID = 0
local MAX_TASK_ID = 2^31

local unpack = unpack or table.unpack
local pack = table.pack or function(...) return { n = select("#", ...), ... } end

local crunning, ccreate = coroutine.running, coroutine.create
local cresume, cyield = coroutine.resume, coroutine.yield
local cstatus = coroutine.status

---@class Async.Task
---@field routine thread
---@field args table|nil
---@field info table|nil
---@field result table|nil
---@field error string|nil
---@field timeout number|nil
---@field stopped boolean
---@field onNext Async.Task[]|nil
---@field onError Async.Task[]|nil
---@field state string
---@field wakeTime number|nil

function async.errorhandler(task, err)
    if LOGGER.enabled and LOGGER.level >= LOG_LEVELS.error then
        emitLog(LOG_LEVELS.error, "unhandled_error", { error = err }, task)
        return
    end
    local msg = string.format("[Async Error] %s\n%s\n", tostring(task), tostring(err))
    if IS_LOVE then print(msg) else io.stderr:write(msg) end
end

-- ==========================================
-- task creation
-- ==========================================

local function createTask(func, ...)
    if type(func) ~= "function" then
        return nil, "function expected"
    end

    local task = setmetatable({}, async)

    local ok, co = pcall(ccreate, func)
    if not ok then return nil, tostring(co) end

    TASK_ID = (TASK_ID + 1) % MAX_TASK_ID
    task.id = TASK_ID
    task.routine = co
    task.args = pack(...)
    task.result = nil
    task.error = nil
    task.timeout = nil
    task.stopped = false
    task.onNext = nil
    task.onError = nil
    task.state = "pending"
    task.wakeTime = nil

    if debug and debug.getinfo then
        local ok2, info = pcall(debug.getinfo, func, "nS")
        task.info = ok2 and info or nil
    end

    emitLog(LOG_LEVELS.debug, "task_create", nil, task)
    return task
end

function async.new(func, ...)
    local task, err = createTask(func, ...)
    if not task then return nil, err end
    queue[#queue+1] = task
    emitLog(LOG_LEVELS.debug, "task_enqueue", nil, task)
    return task
end

setmetatable(async, { __call = function(_, ...) return async.new(...) end })

-- ==========================================
-- task execution
-- ==========================================

function async:_perform(...)
    if self.stopped then return end

    if self.timeout and async.gettime() >= self.timeout then
        self.error = "timeout"
        self.state = "errored"
        emitLog(LOG_LEVELS.warn, "task_timeout", nil, self)
        self:_handleError()
        return
    end

    local args = self.args
    self.args = nil
    self.state = "running"

    CURRENT_TASK = self
    emitLog(LOG_LEVELS.trace, "task_resume", nil, self)

    local results
    if args and args.n > 0 then
        results = pack(cresume(self.routine, unpack(args,1,args.n)))
    else
        results = pack(cresume(self.routine, ...))
    end

    CURRENT_TASK = nil

    if not results[1] then
        local err = tostring(results[2])
        if debug and debug.traceback then
            err = err .. "\n" .. debug.traceback(self.routine)
        end
        self.error = err
        self.state = "errored"
        emitLog(LOG_LEVELS.error, "task_error", { error = err }, self)
        self:_handleError()
        return
    end

    if cstatus(self.routine) == "dead" then
        local r = { n = results.n-1 }
        for i=2,results.n do r[i-1]=results[i] end
        self.result = r
        self.state = "completed"
        emitLog(LOG_LEVELS.debug, "task_complete", { results = r.n }, self)

        if self.onNext then
            for _,t in ipairs(self.onNext) do
                t.args = self.result
                queue[#queue+1] = t
            end
        end
    else
        emitLog(LOG_LEVELS.trace, "task_yield", nil, self)
    end
end

function async:_handleError()
    if self.onError and #self.onError>0 then
        for _,t in ipairs(self.onError) do
            t.args = pack(self.error)
            queue[#queue+1] = t
        end
    else
        async.errorhandler(self, self.error)
    end
end

-- ==========================================
-- chaining
-- ==========================================

function async:next(fn)
    local t,err = createTask(fn)
    if not t then error(err,2) end
    self.onNext = self.onNext or {}
    self.onNext[#self.onNext+1] = t
    return t
end

function async:catch(fn)
    local t,err = createTask(fn)
    if not t then error(err,2) end
    self.onError = self.onError or {}
    self.onError[#self.onError+1] = t
    return self
end

function async:stop()
    self.stopped = true
    self.state = "stopped"
    emitLog(LOG_LEVELS.info, "task_stop", nil, self)
    local awaiting = rawget(self, "_awaiting")
    if awaiting and getmetatable(awaiting) == async then
        awaiting:stop()
    end
    self._awaiting = nil
    return self
end

function async:setTimeout(delay)
    self.timeout = async.gettime() + delay
    emitLog(LOG_LEVELS.debug, "task_set_timeout", { timeout = self.timeout }, self)
    return self
end

function async:getState() return self.state end
function async:isCompleted() return self.state=="completed" end
function async:isErrored() return self.state=="errored" end
function async:isRunning() return self.state=="running" or self.state=="pending" end

-- ==========================================
-- scheduler update (FIXED fairness + timeout)
-- ==========================================

function async.update(...)
    local now = async.gettime()
    emitLog(LOG_LEVELS.trace, "tick_begin", { queued = #queue, ready = #stack, sleeping = #sleepers }, CURRENT_TASK)

    local awake = {}
    local still = {}

    for _,task in ipairs(sleepers) do
        if task.stopped or cstatus(task.routine) == "dead" then
            task.wakeTime = nil
            task._inSleepers = nil
        elseif task.timeout and now >= task.timeout then
            task.error="timeout"
            task.state="errored"
            task.wakeTime = nil
            task._inSleepers = nil
            emitLog(LOG_LEVELS.warn, "task_timeout", { timeout = task.timeout }, task)
            task:_handleError()
        elseif now >= task.wakeTime then
            task.wakeTime=nil
            task._inSleepers=nil
            awake[#awake+1]=task
            emitLog(LOG_LEVELS.trace, "task_wake", nil, task)
        else
            still[#still+1]=task
        end
    end

    sleepers = still

    local currentStack = stack
    local currentQueue = queue
    stack = {}
    queue = {}

    local runList = {}
    for _,t in ipairs(awake) do runList[#runList+1]=t end
    for _,t in ipairs(currentQueue) do runList[#runList+1]=t end
    for _,t in ipairs(currentStack) do runList[#runList+1]=t end

    for _,task in ipairs(runList) do
        task:_perform(...)
        if cstatus(task.routine)~="dead" and not task.error and not task.stopped and not task.wakeTime and not task._inSleepers then
            stack[#stack+1]=task
        end
    end

    emitLog(LOG_LEVELS.trace, "tick_end", { queued = #queue, ready = #stack, sleeping = #sleepers }, CURRENT_TASK)
end

-- ==========================================
-- utilities
-- ==========================================

function async.running()
    local co,isMain = crunning()
    return co~=nil and not isMain
end

function async.yield(...)
    return cyield(...)
end

-- FIXED sleep
function async.sleep(delay)
    if not async.running() then error("sleep inside async only",2) end
    local task = CURRENT_TASK
    if not task then error("internal async error",2) end
    task.wakeTime = async.gettime()+delay
    emitLog(LOG_LEVELS.debug, "task_sleep", { delay = delay, wakeTime = task.wakeTime }, task)
    if not task._inSleepers then
        task._inSleepers = true
        sleepers[#sleepers+1]=task
    end
    cyield()
end

-- FIXED await cancellation
function async.await(fn,...)
    if not async.running() then error("await inside async only",2) end
    local parent = CURRENT_TASK
    local t, err
    if getmetatable(fn) == async and type(fn.routine) == "thread" then
        t = fn
    else
        t, err = async.new(fn,...)
        if not t then return nil, err, "errored" end
    end

    if parent and getmetatable(parent) == async then
        parent._awaiting = t
    end
    emitLog(LOG_LEVELS.debug, "await_begin", { awaited = t.id }, parent)

    local function clearAwaiting()
        if parent and getmetatable(parent) == async then
            parent._awaiting = nil
        end
    end

    while true do
        if parent and parent.stopped then
            t:stop()
            clearAwaiting()
            emitLog(LOG_LEVELS.info, "await_cancelled", { awaited = t.id }, parent)
            return nil, "await cancelled", "stopped"
        end

        if t.stopped then
            clearAwaiting()
            emitLog(LOG_LEVELS.info, "await_stopped", { awaited = t.id }, parent)
            return nil, "stopped", "stopped"
        end

        if t.error then
            clearAwaiting()
            emitLog(LOG_LEVELS.error, "await_errored", { awaited = t.id, error = t.error }, parent)
            return nil, t.error, "errored"
        end

        if t.result then
            local first = t.result[1]
            if getmetatable(first) == async and type(first.routine) == "thread" then
                if first == t then
                    clearAwaiting()
                    emitLog(LOG_LEVELS.error, "await_cycle", { awaited = t.id }, parent)
                    return nil, "await cycle", "errored"
                end
                t = first
                if parent and getmetatable(parent) == async then
                    parent._awaiting = t
                end
            else
                clearAwaiting()
                emitLog(LOG_LEVELS.debug, "await_done", { awaited = t.id }, parent)
                return unpack(t.result, 1, t.result.n)
            end
        else
            cyield()
        end
    end
end

function async.waitfor(fn,timeout,...)
    local deadline = timeout and (async.gettime()+timeout)
    while true do
        local r = pack(fn(...))
        if r[1] then return unpack(r,1,r.n) end
        if deadline and async.gettime()>=deadline then
            return nil,"timeout"
        end
        cyield()
    end
end

function async.getTaskCount()
    return #stack + #queue + #sleepers
end

function async.clear()
    stack,queue,sleepers = {},{},{}
end

function async:__tostring()
    local i=self.info or {}
    return string.format("Async<%d %s:%d>", self.id or 0, i.short_src or "?", i.linedefined or 0)
end

-- ==========================================
-- promise helpers
-- ==========================================

function async.all(tasks)
    if not async.running() then error("all inside async only",2) end
    local results={}

    while true do
        local allDone=true
        for i,t in ipairs(tasks) do
            if t:isRunning() then
                allDone=false
            elseif t:isErrored() then
                return nil,t.error
            elseif t:isCompleted() and not results[i] then
                -- FIX: normalized result
                results[i] = { unpack(t.result,1,t.result.n) }
            end
        end
        if allDone then return results end
        cyield()
    end
end

function async.race(tasks)
    while true do
        for i,t in ipairs(tasks) do
            if t:isCompleted() then
                return t.result,i,nil
            elseif t:isErrored() then
                return nil,i,t.error
            end
        end
        cyield()
    end
end

function async.delay(fn,delay,...)
    local a=pack(...)
    return async.new(function()
        async.sleep(delay)
        return fn(unpack(a,1,a.n))
    end)
end

-- ==========================================
-- LÖVE Thread integration
-- ==========================================

local HAS_LOVE_THREAD = IS_LOVE
    and type(love.thread) == "table"
    and type(love.thread.newThread) == "function"

local _threadId = 0
local MAX_THREAD_ID = 2^32

--- Runs a function in a LÖVE thread and awaits the result.
--- Must be called inside an async task.
---@param threadFile string
---@param input any
---@param timeout number|nil
---@return any result
---@return string|nil err
function async.thread(threadFile, input, timeout)
    if not HAS_LOVE_THREAD then
        error("async.thread requires LÖVE thread support", 2)
    end
    if not async.running() then
        error("async.thread must be called inside async function", 2)
    end
    if type(threadFile) ~= "string" then
        error("threadFile must be a string", 2)
    end

    timeout = timeout or 30
    emitLog(LOG_LEVELS.debug, "thread_begin", { file = threadFile, timeout = timeout }, CURRENT_TASK)

    _threadId = (_threadId + 1) % MAX_THREAD_ID
    local inName = "async_in_" .. _threadId
    local outName = "async_out_" .. _threadId

    local thread = love.thread.newThread(threadFile)
    local inCh = love.thread.getChannel(inName)
    local outCh = love.thread.getChannel(outName)

    -- send input before start
    inCh:push(input)
    thread:start(inName, outName)

    local deadline = async.gettime() + timeout

    while true do
        -- parent task cancelled → stop waiting
        if CURRENT_TASK and CURRENT_TASK.stopped then
            inCh:clear()
            outCh:clear()
            emitLog(LOG_LEVELS.info, "thread_cancelled", { file = threadFile }, CURRENT_TASK)
            return nil, "cancelled"
        end

        local terr = thread:getError()
        if terr then
            inCh:clear()
            outCh:clear()
            emitLog(LOG_LEVELS.error, "thread_error", { file = threadFile, error = terr }, CURRENT_TASK)
            return nil, "thread error: " .. tostring(terr)
        end

        local value = outCh:pop()
        if value ~= nil then
            inCh:clear()
            outCh:clear()
            emitLog(LOG_LEVELS.debug, "thread_done", { file = threadFile }, CURRENT_TASK)
            return value, nil
        end

        if async.gettime() >= deadline then
            inCh:clear()
            outCh:clear()
            emitLog(LOG_LEVELS.warn, "thread_timeout", { file = threadFile, timeout = timeout }, CURRENT_TASK)
            return nil, "timeout"
        end

        cyield()
    end
end


return async
