-- async_threadpool.lua
-- Thread pool + async bridge for LÖVE using async.lua
-- Advanced version: progress events + streaming + cancel + await helpers
-- Requires: async.lua

-- Registered worker functions now receive:
-- 
-- fn(payload, ctx)
-- 
-- Where `ctx` provides:
-- ctx.progress(percent, data)
-- ctx.canceled() -> boolean
-- ---
-- -- example:
-- pool:register("generate_map", function(payload, ctx)
--     local n = payload.steps
--     local acc = 0

--     for i = 1, n do
--         if ctx.canceled() then
--             return "stopped early"
--         end

--         -- heavy work
--         acc = acc + math.sqrt(i)

--         if i % 1000 == 0 then
--             ctx.progress(i / n, { step = i })
--         end
--     end

--     return acc
-- end)

--  Use from async code
-- async(function()

--     local task = pool:submit("generate_map", {steps = 2e6}, {timeout = 10})

--     task:onProgress(function(p, data)
--         print("progress:", p, data.step)
--     end)

--     local result = async.await(function() return task end)

--     print("done:", result)

-- end)

-- Cancel Mid-Flight
-- local t = pool:submit("generate_map", {steps=1e9})

-- async.sleep(1.0)
-- t:cancel()


local async = require("async")
local unpack = unpack or table.unpack

local ThreadPool = {}
ThreadPool.__index = ThreadPool

-- =====================================================
-- Worker bootstrap code
-- =====================================================

local WORKER_CODE = [[
local jobName, resultName, progressName = ...

local jobCh      = love.thread.getChannel(jobName)
local resultCh   = love.thread.getChannel(resultName)
local progressCh = love.thread.getChannel(progressName)

local registry = {}
local loader = loadstring or load
local unpack = unpack or table.unpack
local pack = table.pack or function(...) return { n = select("#", ...), ... } end

local sourceBase = love.filesystem and love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory()
if type(sourceBase) ~= "string" then
    sourceBase = "."
end

local source = love.filesystem and love.filesystem.getSource and love.filesystem.getSource()
local root = sourceBase
if type(source) == "string" and source ~= "" then
    if source:match("%.love$") then
        root = source:match("^(.*)[/\\]") or sourceBase
    else
        root = source
    end
    if not (root:sub(1, 1) == "/" or root:match("^%a:[/\\]")) then
        root = sourceBase .. "/" .. root
    end
end

package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local cpaths = {
    root .. "/https_libs/?.so", root .. "/https_libs/?.dylib", root .. "/https_libs/?.dll",
    root .. "/../https_libs/?.so", root .. "/../https_libs/?.dylib", root .. "/../https_libs/?.dll",
    root .. "/../../https_libs/?.so", root .. "/../../https_libs/?.dylib", root .. "/../../https_libs/?.dll",
    root .. "/../../../https_libs/?.so", root .. "/../../../https_libs/?.dylib", root .. "/../../../https_libs/?.dll",
    root .. "/../../../../https_libs/?.so", root .. "/../../../../https_libs/?.dylib", root .. "/../../../../https_libs/?.dll",
    root .. "/libs/?.so", root .. "/libs/?.dylib", root .. "/libs/?.dll",
    root .. "/?.so", root .. "/?.dylib", root .. "/?.dll"
}
package.cpath = table.concat(cpaths, ";") .. ";" .. package.cpath

local function makeCtx(id, cancelName)
    local cancelCh = love.thread.getChannel(cancelName)
    return {
        canceled = function()
            if cancelCh:getCount() > 0 then
                cancelCh:clear()
                return true
            end
            return false
        end,
        progress = function(p, data)
            progressCh:push({ id = id, p = p, data = data })
        end
    }
end

while true do
    local job = jobCh:demand()

    if job.type == "register" then
        local fn, err = loader(job.code)
        if fn then
            registry[job.name] = fn
        else
            registry[job.name] = nil
            resultCh:push({ id = -1, error = "register failed: " .. tostring(err) })
        end

    elseif job.type == "run" then
        local id = job.id
        local fn = registry[job.name]

        if not fn then
            resultCh:push({ id = id, error = "unknown job: " .. tostring(job.name) })
        elseif job.cancelName and love.thread.getChannel(job.cancelName):getCount() > 0 then
            love.thread.getChannel(job.cancelName):clear()
            resultCh:push({ id = id, canceled = true })
        else
            local ctx = makeCtx(id, job.cancelName)
            local ok, r = pcall(function()
                return pack(fn(job.payload, ctx))
            end)
            if ok then
                resultCh:push({ id = id, ok = true, result = r })
            else
                resultCh:push({ id = id, error = r })
            end
        end
    elseif job.type == "quit" then
        return
    end
end
]]

-- =====================================================
-- ctor
-- =====================================================

function ThreadPool.new(size)
    assert(love and love.thread, "ThreadPool requires LÖVE thread module")

    local self = setmetatable({}, ThreadPool)

    self.size = size or math.max(1, (love.system and love.system.getProcessorCount and love.system.getProcessorCount() or 2) - 1)
    async.log("info", "threadpool_new", { size = self.size })

    ThreadPool._poolSeq = (ThreadPool._poolSeq or 0) + 1
    self.prefix = "tp_" .. tostring(ThreadPool._poolSeq) .. "_" .. tostring(love.timer.getTime()):gsub("%.", "_")

    self.resultName = self.prefix .. "_result"
    self.progressName = self.prefix .. "_progress"
    self.resultCh = love.thread.getChannel(self.resultName)
    self.progressCh = love.thread.getChannel(self.progressName)
    self.resultCh:clear()
    self.progressCh:clear()

    self.nextId = 0
    self.pending = {}
    self.workers = {}
    self.workerJobNames = {}
    self.workerJobCh = {}
    self._rr = 0
    self.destroyed = false

    for i = 1, self.size do
        local jobName = self.prefix .. "_job_" .. i
        self.workerJobNames[i] = jobName
        self.workerJobCh[i] = love.thread.getChannel(jobName)
        self.workerJobCh[i]:clear()

        local th = love.thread.newThread(WORKER_CODE)
        th:start(jobName, self.resultName, self.progressName)
        table.insert(self.workers, th)
    end

    -- async pump
    self._pumpTask = async(function()
        while true do
            self:_pumpResults()
            self:_pumpProgress()
            async.yield()
        end
    end)

    return self
end

-- =====================================================
-- register job
-- fn(payload, ctx) where ctx.progress / ctx.canceled
-- =====================================================

function ThreadPool:register(name, fn)
    assert(not self.destroyed, "ThreadPool is destroyed")
    assert(type(name)=="string")
    assert(type(fn)=="function")

    local payload = {
        type = "register",
        name = name,
        code = string.dump(fn)
    }
    for i = 1, self.size do
        self.workerJobCh[i]:push(payload)
    end
    async.log("debug", "threadpool_register", { name = name })
end

-- =====================================================
-- submit
-- =====================================================

function ThreadPool:_nextId()
    self.nextId = self.nextId + 1
    return self.nextId
end

function ThreadPool:submit(name, payload, opts)
    assert(not self.destroyed, "ThreadPool is destroyed")
    opts = opts or {}
    local pool = self
    local id = self:_nextId()
    async.log("info", "threadpool_submit", { name = name, jobId = id, timeout = opts.timeout })

    local slot = {
        done = false,
        packet = nil,
        progressHandlers = {},
        cancelName = self.prefix .. "_cancel_" .. id
    }
    self.pending[id] = slot
    slot.cancelCh = love.thread.getChannel(slot.cancelName)
    slot.cancelCh:clear()

    local function cleanupPending()
        pool.pending[id] = nil
        if slot.cancelCh then
            slot.cancelCh:clear()
        end
    end

    local task = async(function()
        self._rr = (self._rr % self.size) + 1
        self.workerJobCh[self._rr]:push({
            type = "run",
            id = id,
            name = name,
            payload = payload,
            cancelName = slot.cancelName
        })
        async.log("debug", "threadpool_dispatched", { name = name, jobId = id, worker = self._rr })

        local ok, err = async.waitfor(function()
            return slot.done
        end, opts.timeout)

        if not ok then
            pool:cancel(id)
            async.log("warn", "threadpool_wait_timeout", { name = name, jobId = id, timeout = opts.timeout })
            cleanupPending()
            error(err or "timeout")
        end

        local packet = slot.packet
        pool.pending[id] = nil
        slot.cancelCh:clear()

        if packet.canceled then error("canceled") end
        if packet.error then error(packet.error) end
        if packet.result then
            async.log("debug", "threadpool_done", { name = name, jobId = id, results = packet.result.n })
            return unpack(packet.result, 1, packet.result.n)
        end
    end)

    function task:onProgress(fn)
        table.insert(slot.progressHandlers, fn)
        return task
    end

    function task:cancel()
        pool:cancel(id)
        cleanupPending()
        return async.stop(task)
    end

    function task:stop()
        pool:cancel(id)
        cleanupPending()
        return async.stop(task)
    end

    return task
end

function ThreadPool:destroy()
    if self.destroyed then
        return
    end
    self.destroyed = true

    if self._pumpTask and type(self._pumpTask.stop) == "function" then
        self._pumpTask:stop()
    end

    for id, slot in pairs(self.pending) do
        if slot and slot.cancelCh then
            slot.cancelCh:push(true)
        end
        self.pending[id] = nil
    end

    for i = 1, self.size do
        if self.workerJobCh[i] then
            self.workerJobCh[i]:push({ type = "quit" })
        end
    end

    if self.resultCh then self.resultCh:clear() end
    if self.progressCh then self.progressCh:clear() end
end

-- =====================================================
-- await helper
-- =====================================================

function ThreadPool:await(name, payload, opts)
    return async.await(function()
        return self:submit(name, payload, opts)
    end)
end

-- =====================================================
-- cancel
-- =====================================================

function ThreadPool:cancel(id)
    local slot = self.pending[id]
    if slot and slot.cancelCh then
        slot.cancelCh:push(true)
        async.log("debug", "threadpool_cancel", { jobId = id })
    end
end

-- =====================================================
-- pumps
-- =====================================================

function ThreadPool:_pumpResults()
    while self.resultCh:getCount() > 0 do
        local packet = self.resultCh:pop()
        local slot = self.pending[packet.id]
        if slot then
            slot.packet = packet
            slot.done = true
            async.log("trace", "threadpool_result", { jobId = packet.id, ok = packet.ok, canceled = packet.canceled, hasError = packet.error ~= nil })
        end
    end
end

function ThreadPool:_pumpProgress()
    while self.progressCh:getCount() > 0 do
        local p = self.progressCh:pop()
        local slot = self.pending[p.id]
        if slot then
            async.log("trace", "threadpool_progress", { jobId = p.id, p = p.p })
            for _,fn in ipairs(slot.progressHandlers) do
                fn(p.p, p.data)
            end
        end
    end
end

return ThreadPool
