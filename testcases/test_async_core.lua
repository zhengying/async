local async = require("async")
local t = require("testcases.testlib")

local h = t.makeHarness(async)

h.reset()

t.assertEq(select(1, async.new("not a function")), nil, "async.new should reject non-function")

h.reset()
local called = 0
async(function()
  called = called + 1
end)
h.step(0)
t.assertEq(called, 1, "async() should schedule a task")

h.reset()
local a, b, c
local task = async(function(x, y)
  a = x
  b = y
  return x + y, "ok"
end, 2, 3)
h.step(0)
t.assertEq(a, 2, "task should receive arguments")
t.assertEq(b, 3, "task should receive arguments")
t.assertTrue(task:isCompleted(), "task should complete")
t.assertEq(task:getState(), "completed", "state should be completed")
t.assertEq(task.result.n, 2, "result should preserve arity")
t.assertEq(task.result[1], 5, "result[1] should match")
t.assertEq(task.result[2], "ok", "result[2] should match")
c = true
t.assertTrue(c, "sanity")

h.reset()
local nextA, nextB
local t1 = async(function()
  return 10, 20
end)
t1:next(function(x, y)
  nextA, nextB = x, y
end)
h.step(0, 2)
t.assertEq(nextA, 10, "next should receive returned values")
t.assertEq(nextB, 20, "next should receive returned values")

h.reset()
local caught
local t2 = async(function()
  error("boom")
end)
t2:catch(function(e)
  caught = e
end)
h.step(0, 2)
t.assertTrue(t2:isErrored(), "task should be errored")
t.assertTrue(type(caught) == "string", "catch should receive an error string")
t.assertMatch(caught, "boom", "catch error should include message")

h.reset()
local ran = false
local t3 = async(function()
  ran = true
end)
t3:stop()
h.step(0)
t.assertEq(ran, false, "stopped task should not run")
t.assertEq(t3:getState(), "stopped", "stopped task should have stopped state")

h.reset()
local events = {}
async.setLogSink(function(e)
  events[#events + 1] = e
end)
async.setLogLevel("debug")
async.setLogEnabled(true)

async(function()
  async.sleep(0)
end)
h.step(0, 2)
t.assertTrue(#events > 0, "enabled logging should emit events")

events = {}
async.setLogEnabled(false)
async(function()
  async.sleep(0)
end)
h.step(0, 2)
t.assertEq(#events, 0, "disabled logging should not emit events")

async.setLogLevel("off")
async.setLogSink(nil)
async.setLogEnabled(false)

h.reset()
t.assertEq(async.getTaskCount(), 0, "clear should reset queues")
