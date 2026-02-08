local async = require("async")
local t = require("testcases.testlib")

local h = t.makeHarness(async)

h.reset()
t.expectError(function()
  async.await(function()
    return 1
  end)
end, "await inside async only")

h.reset()
local child = async(function()
  async.sleep(1.0)
  return 42
end)

local got
async(function()
  got = async.await(function()
    return child
  end)
end)
h.step(0)
t.assertEq(got, nil, "await should not complete immediately")
h.step(1.0)
t.assertEq(got, 42, "await should return child result")

h.reset()
local child2 = async(function()
  async.sleep(1.0)
  return "ok"
end)

local got2
async(function()
  got2 = async.await(child2)
end)
h.step(0)
t.assertEq(got2, nil, "await(task) should not complete immediately")
h.step(1.0)
t.assertEq(got2, "ok", "await(task) should return task result")

h.reset()
local child3 = async(function()
  async.sleep(10.0)
  return "never"
end)

local parent = async(function()
  local v, err, state = async.await(child3)
  return v, err, state
end)

h.step(0)
parent:stop()
h.step(0)
t.assertTrue(child3.stopped, "await cancellation should stop awaited task")
t.assertEq(parent:getState(), "stopped", "parent state should be stopped after stop()")

h.reset()
local ready = false
async(function()
  async.delay(function()
    ready = true
  end, 0.5)
  local ok = async.waitfor(function()
    return ready
  end, 2.0)
  t.assertTrue(ok, "waitfor should return true when predicate becomes true")
end)
h.step(0, 2)
t.assertEq(ready, false, "ready should not be true at start")
h.step(0.5)
t.assertEq(ready, true, "delay should flip ready")

h.reset()
local okFlag, errMsg
async(function()
  local ok, err = async.waitfor(function()
    return false
  end, 0.2)
  okFlag, errMsg = ok, err
end)
h.step(0)
h.step(0.25)
t.assertEq(okFlag, nil, "waitfor should return nil on timeout")
t.assertMatch(tostring(errMsg), "timeout", "waitfor should report timeout")
