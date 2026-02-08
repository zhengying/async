local function assertTrue(v, msg)
  if not v then
    error(msg or "assertTrue failed", 2)
  end
end

local function assertEq(a, b, msg)
  if a ~= b then
    error(msg or ("assertEq failed: expected " .. tostring(b) .. " got " .. tostring(a)), 2)
  end
end

local function assertMatch(text, pattern, msg)
  if type(text) ~= "string" then
    error(msg or "assertMatch failed: not string", 2)
  end
  if not string.match(text, pattern) then
    error(msg or ("assertMatch failed: '" .. text .. "' does not match '" .. pattern .. "'"), 2)
  end
end

local sourceBase = love.filesystem and love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory()
if type(sourceBase) ~= "string" then
  sourceBase = "."
end
local repoRoot = sourceBase .. "/../.."
package.path = repoRoot .. "/?.lua;" .. repoRoot .. "/?/init.lua;" .. package.path

local async = require("async")
local ThreadPool = require("threadpool")

local results = {}
local failed = 0
local total = 0

local function record(ok, name, err)
  total = total + 1
  if ok then
    results[#results + 1] = "[PASS] " .. name
  else
    failed = failed + 1
    results[#results + 1] = "[FAIL] " .. name .. " :: " .. tostring(err)
  end
end

local function runTest(name, fn)
  local ok, err = xpcall(fn, function(e)
    local tb = debug and debug.traceback and debug.traceback(e, 2)
    return tb or tostring(e)
  end)
  record(ok, name, err)
end

local now = 0
async.gettime = function()
  return now
end

local function step(dt)
  now = now + dt
  async.update(dt)
end

local function runFrames(maxSeconds)
  local deadline = now + (maxSeconds or 5)
  while now < deadline and async.getTaskCount() > 0 do
    step(1 / 60)
  end
end

local function threadFile()
  return "thread_worker.lua"
end

function love.load()
  runTest("love.thread available", function()
    assertTrue(type(love) == "table" and type(love.thread) == "table", "love.thread missing")
    assertTrue(type(love.thread.newThread) == "function", "love.thread.newThread missing")
  end)

  runTest("async.thread returns value", function()
    async.clear()
    local got, err
    async(function()
      got, err = async.thread(threadFile(), 21, 5)
    end)
    runFrames(5)
    assertEq(err, nil, "async.thread should not error; err=" .. tostring(err))
    assertEq(got, 42, "async.thread result mismatch; got=" .. tostring(got) .. " type=" .. type(got))
  end)

  runTest("async.thread returns structured error", function()
    async.clear()
    local got, err
    async(function()
      got, err = async.thread(threadFile(), "FAIL", 5)
    end)
    runFrames(5)
    assertEq(err, nil, "async.thread should not error for structured worker error; err=" .. tostring(err))
    assertTrue(type(got) == "string", "async.thread should return a string; got=" .. tostring(got) .. " type=" .. type(got))
    assertMatch(got, "worker forced failure", "structured error should include message")
  end)

  runTest("ThreadPool submit/await works", function()
    async.clear()
    async.setLogEnabled(false)
    async.setLogLevel("off")
    async.setLogSink(nil)

    local logEvents = {}
    async.setLogSink(function(e)
      logEvents[#logEvents + 1] = e
    end)
    async.setLogLevel("trace")
    async.setLogEnabled(true)

    local pool = ThreadPool.new(1)

    pool:register("double", function(payload, ctx)
      ctx.progress(0.5, { step = "half" })
      return payload.n * 2
    end)

    local gotProgress = false
    local out

    async(function()
      local task = pool:submit("double", { n = 12 }, { timeout = 2 })
      task:onProgress(function(p, data)
        if p == 0.5 and data and data.step == "half" then
          gotProgress = true
        end
      end)

      out = async.await(function()
        return task
      end)
    end)

    runFrames(3)

    assertTrue(gotProgress, "expected progress callback")
    assertEq(out, 24, "threadpool result mismatch")
    local gotSubmit, gotProgressEvent, gotResult = false, false, false
    for _, e in ipairs(logEvents) do
      if e.event == "threadpool_submit" then gotSubmit = true end
      if e.event == "threadpool_progress" then gotProgressEvent = true end
      if e.event == "threadpool_result" then gotResult = true end
    end
    assertTrue(gotSubmit, "expected threadpool_submit log event")
    assertTrue(gotProgressEvent, "expected threadpool_progress log event")
    assertTrue(gotResult, "expected threadpool_result log event")
  end)

  for _, line in ipairs(results) do
    print(line)
  end
  print(string.format("Total: %d, Failed: %d", total, failed))

  if failed > 0 then
    error("Love tests failed")
  end

  love.event.quit()
end

function love.update(dt)
end
