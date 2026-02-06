---@meta

--- async.lua - A lightweight cooperative multitasking library for Lua and LÖVE.
---
--- Features:
--- * pure Lua with LÖVE optimizations (non-blocking sleep).
--- * Promise-like chaining (:next, :catch).
--- * Async/Await syntax simulation.
--- * robust error handling and coroutine management.
---
--- Usage Example:
--- ```lua
--- local async = require("async")
---
--- -- Start a task
--- async(function()
---     print("Start")
---     async.sleep(1.0) -- Non-blocking wait
---     print("End")
--- end)
---
--- -- Update loop
--- function love.update(dt)
---     async.update()
--- end
--- ```
---
---@class Async
local async = {}
async.__index = async

-- Detect LÖVE environment
local IS_LOVE = love and love.timer and true or false

--- Gets the current time in seconds.
--- Uses `love.timer.getTime` if available, otherwise `os.clock`.
async.gettime = IS_LOVE and love.timer.getTime or os.clock

-- Internal tables (arrays for FIFO order)
local queue = {} -- Tasks waiting to start
local stack = {} -- Active tasks

-- Compatibility
local unpack = unpack or table.unpack
local pack = table.pack or function(...) return {n = select("#", ...), ...} end

local crunning, ccreate = coroutine.running, coroutine.create
local cresume, cyield = coroutine.resume, coroutine.yield
local cstatus = coroutine.status

---@class Async.Task
---@field routine thread The underlying coroutine.
---@field args table|nil Packed arguments to pass on resume.
---@field info debuginfo|nil Debug info about the source function.
---@field result table|nil Packed results (including n) upon completion.
---@field error string|nil Error message if the task crashed or timed out.
---@field timeout number|nil Timestamp when the task should timeout.
---@field stopped boolean Flag indicating if the task was manually stopped.
---@field onNext Async.Task|nil The next task to run after success.
---@field onError Async.Task|nil The task to run on error.
---@field handleError fun(self: Async.Task) Internal error routing.

--- Default error handler. Prints to console/stderr.
--- Can be overwritten: `async.errorhandler = function(task, err) ... end`
---@param task Async.Task The task that failed.
---@param err string The error message.
function async.errorhandler(task, err)
    local msg = string.format("[Async Error] %s\n%s\n", tostring(task), tostring(err))
    if IS_LOVE then print(msg) else io.stderr:write(msg) end
end

-- ==========================================
-- INTERNAL: Create task WITHOUT scheduling
-- ==========================================

--- Internal factory to create a task object safely.
---@param func function The function to run.
---@param ... any Arguments to pass to the function.
---@return Async.Task|nil task The created task object.
---@return string|nil error Error message if creation failed.
local function createTask(func, ...)
    if type(func) ~= "function" then
        return nil, "bad argument #1 (function expected, got " .. type(func) .. ")"
    end

    local task = setmetatable({}, async)
    ---@cast task Async.Task

    local ok, routineOrErr = pcall(ccreate, func)
    if not ok then return nil, tostring(routineOrErr) end
    local routine = routineOrErr
    
    task.routine = routine
    task.args = pack(...)
    if debug and debug.getinfo then
        local infoOk, infoOrErr = pcall(debug.getinfo, func, "nS")
        task.info = infoOk and infoOrErr or nil
    else
        task.info = nil
    end
    task.result = nil
    task.error = nil
    task.timeout = nil
    task.stopped = false
    task.onNext = nil
    task.onError = nil
    
    return task
end

-- ==========================================
-- PUBLIC API: Create and schedule task
-- ==========================================

--- Creates a new async task and schedules it for execution.
--- Can also be called as `async(func, ...)`.
---@param func function The function to execute asynchronously.
---@param ... any Arguments passed to the function.
---@return Async.Task|nil task The created task, or nil on error.
---@return string|nil err Error message if creation failed.
function async.new(func, ...)
    local task, err = createTask(func, ...)
    if not task then return nil, err end
    
    table.insert(queue, task) -- Schedule immediately
    return task
end

setmetatable(async, {__call = function(_, ...) return async.new(...) end})

-- ==========================================
-- Task methods
-- ==========================================

--- Execute one step of the task.
--- Internal method called by async.update().
---@param self Async.Task
function async:perform()
    if self.stopped then return end
    
    -- Check timeout
    if self.timeout and async.gettime() >= self.timeout then
        self.error = "timeout"
        self:handleError()
        return
    end
    
    -- Resume coroutine (capture ALL return values)
    local args = self.args
    self.args = nil
    
    local results
    if args and args.n > 0 then
        results = pack(cresume(self.routine, unpack(args, 1, args.n)))
    else
        results = pack(cresume(self.routine))
    end
    
    local ok = results[1]
    
    -- Handle error
    if not ok then
        local errMsg = tostring(results[2])
        if debug and debug.traceback then
            errMsg = errMsg .. "\n" .. debug.traceback(self.routine)
        end
        self.error = errMsg
        self:handleError()
        return
    end
    
    -- Check if finished (dead) vs yielded
    if cstatus(self.routine) == "dead" then
        -- Task completed - store all return values
        -- We shift values left to remove the boolean 'true' from pcall/resume
        local returnValues = { n = results.n - 1 }
        for i = 2, results.n do
            returnValues[i - 1] = results[i]
        end
        self.result = returnValues
        
        -- Schedule chained task (only NOW, not before)
        if self.onNext then
            self.onNext.args = self.result
            table.insert(queue, self.onNext)
        end
    end
end

--- internal error routing
---@param self Async.Task
function async:handleError()
    if self.onError then
        self.onError.args = pack(self.error)
        table.insert(queue, self.onError)
    else
        async.errorhandler(self, self.error)
    end
end

--- Chains a function to be executed when this task completes successfully.
--- The callback receives the return values of the previous task.
---@param callback function
---@return Async.Task onNext The chained task (not scheduled until parent finishes).
---@param self Async.Task
function async:next(callback)
    local task, err = createTask(callback)
    if not task then error(err, 2) end

    self.onNext = task -- Just create, don't queue yet!
    return task
end

--- Chains a function to be executed if this task fails (error or timeout).
--- The callback receives the error string.
---@param errfunc function
---@return Async.Task self Returns the original task for chaining.
---@param self Async.Task
function async:catch(errfunc)
    local task, err = createTask(errfunc)
    if not task then error(err, 2) end

    self.onError = task -- Just create, don't queue yet!
    return self
end

--- Stops the task. It will be removed from execution on the next update.
---@return Async.Task self
---@param self Async.Task
function async:stop()
    self.stopped = true
    return self
end

--- Sets a timeout for this task.
--- If the task doesn't finish before the delay, it errors with "timeout".
---@param delay number Seconds to wait before timing out.
---@return Async.Task self
---@param self Async.Task
function async:setTimeout(delay)
    if type(delay) ~= "number" then
        error("bad argument #1 to 'setTimeout' (number expected, got " .. type(delay) .. ")", 2)
    end
    self.timeout = async.gettime() + delay
    return self
end

-- ==========================================
-- Main update loop
-- ==========================================

--- Main update loop. Must be called every frame (e.g., in love.update).
--- Handles processing the stack, queue, and transitioning tasks.
function async.update()
    -- 1. Swap stack (double buffering) to allow safe modification during iteration
    local currentStack = stack
    stack = {}
    
    -- 2. Process active tasks
    for _, task in ipairs(currentStack) do
        task:perform()
        -- Re-queue if alive, no error, and not stopped
        if cstatus(task.routine) ~= "dead" and not task.error and not task.stopped then
            table.insert(stack, task)
        end
    end
    
    -- 3. Process new queue (snapshot to prevent infinite recursion of new tasks)
    local currentQueue = queue
    queue = {}
    
    for _, task in ipairs(currentQueue) do
        table.insert(stack, task)
        task:perform()
        -- Optimization: Remove if finished immediately
        if cstatus(task.routine) == "dead" or task.error or task.stopped then
            table.remove(stack)
        end
    end
end

-- ==========================================
-- Utility functions (For use inside async functions)
-- ==========================================

--- Checks if the current code is running inside an async task (coroutine).
---@return boolean
function async.running()
    local co, isMain = crunning()
    return (co ~= nil) and (not isMain)
end

--- Yields execution back to the main loop for one frame.
--- Must be called inside an async function.
---@param ... any Arguments returned to the update loop (usually ignored).
---@return any ... Arguments passed back when resumed (usually nil).
function async.yield(...)
    return cyield(...)
end

--- Pauses the current task for `delay` seconds.
--- Non-blocking (cooperative). Other tasks and the game loop continue running.
---@param delay number Seconds to sleep.
function async.sleep(delay)
    if type(delay) ~= "number" then
        error("bad argument #1 to 'sleep' (number expected, got " .. type(delay) .. ")", 2)
    end
    if not async.running() then
        error("sleep must be called inside async function", 2)
    end
    
    local target = async.gettime() + delay
    while async.gettime() < target do
        cyield()
    end
end

--- Pauses the current task and waits for another async function to complete.
---@param func function The function to await.
---@param ... any Arguments for the function.
---@return ... any The return values of the awaited function.
function async.await(func, ...)
    if not async.running() then
        error("await must be called inside async function", 2)
    end
    if type(func) ~= "function" then
        error("bad argument #1 to 'await' (function expected, got " .. type(func) .. ")", 2)
    end
    
    local task = async.new(func, ...)
    ---@cast task Async.Task
    
    -- Busy wait (yielding) until task is done
    while not task.result and not task.error and not task.stopped do
        cyield()
    end
    
    if task.stopped then return nil, "stopped" end
    if task.error then return nil, task.error end
    local result = task.result
    ---@cast result table
    return unpack(result, 1, result.n)
end

--- Pauses the current task until `func` returns a truthy value or timeout occurs.
--- Useful for polling conditions (e.g., waiting for a file to load).
---@param func function A function that returns true/value when done.
---@param timeout number|nil Max seconds to wait (default: infinite).
---@param ... any Arguments passed to func every tick.
---@return ... any The results from func, or (nil, 'timeout').
function async.waitfor(func, timeout, ...)
    if not async.running() then
        error("waitfor must be called inside async function", 2)
    end
    if type(func) ~= "function" then
        error("bad argument #1 to 'waitfor' (function expected, got " .. type(func) .. ")", 2)
    end
    if timeout ~= nil and type(timeout) ~= "number" then
        error("bad argument #2 to 'waitfor' (number expected, got " .. type(timeout) .. ")", 2)
    end
    
    local deadline = async.gettime() + (timeout or math.huge)
    
    while true do
        local res = pack(func(...))
        if res[1] then
            return unpack(res, 1, res.n)
        end
        
        if async.gettime() > deadline then
            return nil, "timeout"
        end
        
        cyield()
    end
end

--- Returns the total number of active and queued tasks.
---@return number count
function async.getTaskCount()
    return #stack + #queue
end

--- Clears all active and queued tasks immediately.
function async.clear()
    stack = {}
    queue = {}
end

---@return string
---@param self Async.Task
function async:__tostring()
    local info = self.info or {}
    return string.format("Async<%s:%d>", info.short_src or "?", info.linedefined or 0)
end

return async
