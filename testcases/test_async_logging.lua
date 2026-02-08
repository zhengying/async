local async = require("async")
local t = require("testcases.testlib")

local h = t.makeHarness(async)

local function resetAll()
  h.reset()
  async.setLogEnabled(false)
  async.setLogLevel("off")
  async.setLogSink(nil)
end

local function anyEvent(events, name)
  for _, e in ipairs(events) do
    if e.event == name then
      return true
    end
  end
  return false
end

resetAll()
do
  local events = {}
  async.setLogSink(function(e)
    events[#events + 1] = e
  end)
  async.setLogLevel("warn")
  async.setLogEnabled(true)

  async.log("info", "drop_me", { a = 1 })
  async.log("warn", "keep_me", { b = 2 })

  t.assertEq(#events, 1, "warn level should drop info")
  t.assertEq(events[1].event, "keep_me", "warn level should keep warn events")
end

resetAll()
do
  local events = {}
  async.setLogSink(function(e)
    events[#events + 1] = e
  end)
  async.setLogLevel("info")
  async.setLogEnabled(true)

  async.log("info", "shape", { x = 1 })

  t.assertEq(#events, 1, "expected one emitted event")
  local e = events[1]
  t.assertEq(e.event, "shape", "event name mismatch")
  t.assertEq(e.levelName, "info", "levelName mismatch")
  t.assertEq(e.time, 0, "time should use async.gettime")
  t.assertEq(type(e.fields), "table", "fields should be a table")
  t.assertEq(e.fields.x, 1, "fields should preserve values")
  t.assertEq(e.task, nil, "task should be nil outside async task")
end

resetAll()
do
  local events = {}
  async.setLogSink(function(e)
    events[#events + 1] = e
    if e.event == "outer" then
      async.log("info", "inner", { should = "not_emit" })
    end
  end)
  async.setLogLevel("info")
  async.setLogEnabled(true)

  async.log("info", "outer")

  t.assertEq(#events, 1, "re-entrant sink should not emit nested logs")
  t.assertEq(events[1].event, "outer", "outer event missing")
end

resetAll()
do
  local sinkCalled = 0
  async.setLogSink(function()
    sinkCalled = sinkCalled + 1
    error("sink failed")
  end)
  async.setLogLevel("info")
  async.setLogEnabled(true)

  async.log("info", "sink_error")
  t.assertEq(sinkCalled, 1, "sink should be invoked once")

  local events = {}
  async.setLogSink(function(e)
    events[#events + 1] = e
  end)

  async.log("info", "after_sink_error")
  t.assertEq(#events, 0, "logging should be disabled after sink error")

  async.setLogEnabled(true)
  async.log("info", "after_reenable")
  t.assertEq(#events, 1, "logging should work after re-enabling")
end

resetAll()
do
  local events = {}
  async.setLogSink(function(e)
    events[#events + 1] = e
  end)
  async.setLogLevel("error")
  async.setLogEnabled(true)

  async(function()
    error("boom")
  end)

  h.step(0, 2)

  t.assertTrue(anyEvent(events, "task_error"), "expected task_error event")
  t.assertTrue(anyEvent(events, "unhandled_error"), "expected unhandled_error event")
end

resetAll()
do
  local events = {}
  async.setLogSink(function(e)
    events[#events + 1] = e
  end)
  async.setLogLevel("info")
  async.setLogEnabled(true)

  async(function()
    async.log("info", "inside")
  end)

  h.step(0, 1)

  t.assertEq(#events, 1, "expected exactly one custom inside event")
  local e = events[1]
  t.assertEq(e.event, "inside", "inside event missing")
  t.assertTrue(type(e.task) == "table", "expected task reference in entry")
  t.assertTrue(type(e.task.id) == "number", "expected numeric task id in entry")
end

resetAll()
do
  local events = {}
  async.setLogSink(function(e)
    events[#events + 1] = e
  end)
  async.setLogLevel("2")
  async.setLogEnabled(true)

  async.log("warn", "numeric_string_level")

  t.assertEq(#events, 1, "numeric string level should be accepted")
  t.assertEq(events[1].event, "numeric_string_level", "event mismatch")
end

resetAll()
