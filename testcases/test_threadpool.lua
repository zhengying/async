local t = require("testcases.testlib")

local async = require("async")
local ThreadPool = require("threadpool")

t.assertTrue(type(ThreadPool) == "table", "threadpool module should load")
t.assertTrue(type(ThreadPool.new) == "function", "ThreadPool.new should exist")

local hasLoveThread = type(love) == "table"
  and type(love.thread) == "table"
  and type(love.thread.newThread) == "function"

if not hasLoveThread then
  t.expectError(function()
    ThreadPool.new(1)
  end, "ThreadPool requires LÖVE thread module")
else
  local pool = ThreadPool.new(1)
  t.assertTrue(type(pool.submit) == "function", "pool.submit should exist")
  t.assertTrue(type(pool.register) == "function", "pool.register should exist")
  t.assertTrue(type(pool.await) == "function", "pool.await should exist")

  pool:register("echo", function(payload, ctx)
    ctx.progress(0.5, { msg = "half" })
    return payload
  end)

  local gotProgress = false
  local h = t.makeHarness(async)
  h.reset()

  local result
  async(function()
    local task = pool:submit("echo", { a = 1 }, { timeout = 2 })
    task:onProgress(function(p, data)
      if p == 0.5 and data and data.msg == "half" then
        gotProgress = true
      end
    end)
    result = async.await(function()
      return task
    end)
  end)

  local ok, err = h.runUntil(function()
    return result ~= nil and gotProgress
  end, { dt = 0.01, maxSteps = 2000 })
  t.assertTrue(ok, err or "threadpool test did not complete")
  t.assertTrue(type(result) == "table" and result.a == 1, "threadpool echo should return payload")
end
