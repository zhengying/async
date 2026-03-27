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
local AsyncHttp = require("async_http")

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

local function step(dt)
  async.update(dt)
  if love and love.timer and type(love.timer.sleep) == "function" then
    love.timer.sleep(0.001)
  end
end

local function runFrames(maxSeconds)
  local getTime = love and love.timer and love.timer.getTime
  local start = getTime and getTime() or os.clock()
  local deadline = start + (maxSeconds or 5)
  while (getTime and getTime() or os.clock()) < deadline and async.getTaskCount() > 0 do
    step(1 / 60)
  end
end

local function threadFile()
  return "thread_worker.lua"
end

local function httpAdapter(url, options, emit)
  options = options or {}

  local method = tostring(options.method or "GET")
  local data = options.data
  if data ~= nil then
    data = tostring(data)
  end

  local requestHeaders = options.headers or {}
  local responseHeaders = {
    ["X-Mock"] = "1",
    ["X-Method"] = method,
    ["X-URL"] = tostring(url or "")
  }

  if tostring(url or ""):find("/fail", 1, true) then
    return 0, nil, responseHeaders
  end

  if tostring(url or ""):find("/slow", 1, true) then
    if love and love.timer and type(love.timer.sleep) == "function" then
      love.timer.sleep(0.2)
    end
    return 200, "slow", responseHeaders
  end

  if tostring(url or ""):find("/stream", 1, true) then
    if type(emit) == "function" then
      emit("response", {
        status = 200,
        headers = responseHeaders
      })
      emit("body", { chunk = "hel" })
      emit("body", { chunk = "lo" })
      emit("complete", { err = nil })
    end
    return 200, "hello", responseHeaders
  end

  local body = {
    "ok",
    "url=" .. tostring(url or ""),
    "method=" .. method,
    "data=" .. tostring(data),
    "header_x_test=" .. tostring(requestHeaders["X-Test"])
  }

  return 200, table.concat(body, "\n"), responseHeaders
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

  runTest("ThreadPool timeout and cancel cleanup", function()
    async.clear()
    async.setLogEnabled(false)
    async.setLogLevel("off")
    async.setLogSink(nil)

    local pool = ThreadPool.new(1)

    pool:register("spin", function(payload, ctx)
      local n = payload.n or 1000000000
      for i = 1, n do
        if ctx.canceled() then
          return "canceled"
        end
      end
      return "done"
    end)

    local timeoutErr, timeoutState
    async(function()
      local task = pool:submit("spin", { n = 1000000000 }, { timeout = 0 })
      local id = pool.nextId
      local _, err, state = async.await(task)
      timeoutErr, timeoutState = err, state
      assertTrue(pool.pending[id] == nil, "pending slot should be cleaned on timeout")
    end)

    runFrames(1)
    assertEq(timeoutState, "errored", "expected errored state on timeout")
    assertTrue(type(timeoutErr) == "string" and timeoutErr:match("timeout"), "expected timeout error")

    local cancelState
    async(function()
      local task = pool:submit("spin", { n = 1000000000 })
      local id = pool.nextId
      task:cancel()
      local _, _, state = async.await(task)
      cancelState = state
      assertTrue(pool.pending[id] == nil, "pending slot should be cleaned on cancel")
    end)

    runFrames(1)
    assertEq(cancelState, "stopped", "expected stopped state on cancel")
  end)

  runTest("AsyncHttp builds url and passes options", function()
    async.clear()

    local client = AsyncHttp.new({
      poolSize = 1,
      baseUrl = "https://unit.test/api",
      timeout = 2,
      adapter = httpAdapter,
      headers = { ["X-Test"] = "default" }
    })

    local resp
    async(function()
      resp = async.await(client:get("/ok", {
        query = { b = "2", a = "1" },
        headers = { ["X-Test"] = "override" }
      }))
    end)

    runFrames(5)

    assertTrue(type(resp) == "table", "expected response table")
    assertEq(resp.status, 200, "status mismatch")
    assertMatch(resp.body, "url=https://unit%.test/api/ok%?a=1&b=2", "url mismatch")
    assertMatch(resp.body, "method=GET", "method mismatch")
    assertMatch(resp.body, "header_x_test=override", "header mismatch")

    client:destroy()
  end)

  runTest("AsyncHttp request failure returns nil and extra", function()
    async.clear()

    local client = AsyncHttp.new({
      poolSize = 1,
      baseUrl = "https://unit.test",
      timeout = 2,
      adapter = httpAdapter
    })

    local a, b, c
    async(function()
      a, b, c = async.await(client:get("/fail"))
    end)

    runFrames(5)

    assertEq(a, nil, "expected nil result on failure")
    assertEq(b, "request failed", "expected request failed error; got=" .. tostring(b))
    assertTrue(type(c) == "table", "expected extra table")
    assertEq(c.status, 0, "expected status 0 on failure")

    client:destroy()
  end)

  runTest("AsyncHttp timeout surfaces as errored state", function()
    async.clear()

    local client = AsyncHttp.new({
      poolSize = 1,
      baseUrl = "https://unit.test",
      timeout = 2,
      adapter = httpAdapter
    })

    local err, state
    async(function()
      local _, e, s = async.await(client:get("/slow", { timeout = 0 }))
      err, state = e, s
    end)

    runFrames(1)

    assertEq(state, "errored", "expected errored state on timeout")
    assertTrue(type(err) == "string" and err:match("timeout"), "expected timeout error")

    client:destroy()
  end)

  runTest("AsyncHttp next/catch works", function()
    async.clear()

    local client = AsyncHttp.new({
      poolSize = 1,
      baseUrl = "https://unit.test/api",
      timeout = 2,
      adapter = httpAdapter
    })

    local gotResp = nil
    local gotErr = nil

    local task = client:get("/ok", {
      query = { a = "1" }
    })

    task:next(function(resp)
      gotResp = resp
    end)
    task:catch(function(err)
      gotErr = err
    end)

    runFrames(5)

    assertTrue(gotErr == nil, "unexpected error: " .. tostring(gotErr))
    assertTrue(type(gotResp) == "table", "expected response table")
    assertEq(gotResp.status, 200, "status mismatch")

    client:destroy()
  end)

  runTest("AsyncHttp stream callbacks receive response chunks", function()
    async.clear()

    local client = AsyncHttp.new({
      poolSize = 1,
      baseUrl = "https://unit.test/api",
      timeout = 2,
      adapter = httpAdapter
    })

    local responseStatus = nil
    local responseHeader = nil
    local chunks = {}
    local completeErr = "pending"
    local result = nil

    async(function()
      local task = client:get("/stream", {
        stream = true,
        onResponse = function(status, headers)
          responseStatus = status
          responseHeader = headers and headers["X-Mock"] or nil
        end
      })
      task:onData(function(chunk)
        chunks[#chunks + 1] = chunk
      end)
      task:onComplete(function(err)
        completeErr = err
      end)
      result = async.await(task)
    end)

    runFrames(5)

    assertEq(responseStatus, 200, "stream response status mismatch")
    assertEq(responseHeader, "1", "stream response header mismatch")
    assertEq(table.concat(chunks), "hello", "stream chunks mismatch")
    assertEq(completeErr, nil, "stream complete error mismatch")
    assertTrue(type(result) == "table", "stream result should be a table")
    assertEq(result.body, "hello", "stream final body mismatch")

    client:destroy()
  end)

  runTest("AsyncHttp catch fires on timeout", function()
    async.clear()

    local client = AsyncHttp.new({
      poolSize = 1,
      baseUrl = "https://unit.test",
      timeout = 2,
      adapter = httpAdapter
    })

    local gotErr = nil
    local gotNext = false

    local task = client:get("/slow", { timeout = 0 })

    task:next(function()
      gotNext = true
    end)
    task:catch(function(err)
      gotErr = err
    end)

    runFrames(2)

    assertTrue(gotNext == false, "next should not run on timeout")
    assertTrue(type(gotErr) == "string" and gotErr:match("timeout"), "expected timeout error")

    client:destroy()
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
