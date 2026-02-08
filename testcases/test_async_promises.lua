local async = require("async")
local t = require("testcases.testlib")

local h = t.makeHarness(async)

h.reset()
local t1 = async(function()
  async.sleep(0.2)
  return 1, 2
end)
local t2 = async(function()
  async.sleep(0.1)
  return "a"
end)

local allRes
async(function()
  allRes = async.all({ t1, t2 })
end)

h.step(0)
t.assertEq(allRes, nil, "all should not complete immediately")
h.step(0.2)
t.assertTrue(type(allRes) == "table", "all should return a table")
t.assertEq(allRes[1][1], 1, "all results should preserve ordering")
t.assertEq(allRes[1][2], 2, "all results should preserve multiple returns")
t.assertEq(allRes[2][1], "a", "all results should preserve ordering")

h.reset()
local boom = async(function()
  async.sleep(0.1)
  error("boom")
end):catch(function()
end)
local okTask = async(function()
  async.sleep(0.2)
  return 123
end)

local allOk, allErr
async(function()
  local r, e = async.all({ okTask, boom })
  allOk, allErr = r, e
end)
h.step(0)
h.step(0.2)
t.assertEq(allOk, nil, "all should return nil on error")
t.assertMatch(tostring(allErr), "boom", "all should return error message")

h.reset()
local fast = async(function()
  async.sleep(0.05)
  return "fast"
end)
local slow = async(function()
  async.sleep(0.2)
  return "slow"
end)

local raceResult, raceIndex, raceErr
async(function()
  local r, i, e = async.race({ slow, fast })
  raceResult, raceIndex, raceErr = r, i, e
end)
h.step(0)
h.step(0.05)
t.assertEq(raceIndex, 2, "race should return winner index")
t.assertEq(raceErr, nil, "race should not error")
t.assertEq(raceResult[1], "fast", "race should return winner result pack")

h.reset()
local delayed
async.delay(function(x, y)
  delayed = x .. y
  return delayed
end, 0.1, "a", "b")
h.step(0)
h.step(0.05)
t.assertEq(delayed, nil, "delay should not run early")
h.step(0.05)
t.assertEq(delayed, "ab", "delay should run after delay")
