local async = require("async")
local t = require("testcases.testlib")

local h = t.makeHarness(async)

h.reset()
t.expectError(function()
  async.sleep(0.1)
end, "sleep inside async only")

h.reset()
local before, after = 0, 0
async(function()
  before = before + 1
  async.sleep(1.0)
  after = after + 1
end)
h.step(0)
t.assertEq(before, 1, "task should run before sleeping")
t.assertEq(after, 0, "task should not continue before wake time")
h.step(0.5)
t.assertEq(after, 0, "task should still be sleeping")
h.step(0.5)
t.assertEq(after, 1, "task should resume after wake time")

h.reset()
local ran = false
local sleeper = async(function()
  async.sleep(10.0)
  ran = true
end)
h.step(0)
t.assertEq(async.getTaskCount(), 1, "one sleeping task expected")
sleeper:stop()
h.step(0)
t.assertEq(async.getTaskCount(), 0, "stopped sleeper should be removed")
t.assertEq(ran, false, "stopped sleeper should not resume")

h.reset()
local timedOut = false
local caught
local tmo = async(function()
  async.sleep(999)
  timedOut = true
end):setTimeout(1.0):catch(function(e)
  caught = e
end)
h.step(0)
t.assertTrue(tmo:isRunning(), "timeout task should start pending/running")
h.step(1.0)
t.assertTrue(tmo:isErrored(), "timeout should error task")
t.assertMatch(tostring(caught), "timeout", "timeout should propagate error")
t.assertEq(timedOut, false, "timed out task should not reach body after sleep")
