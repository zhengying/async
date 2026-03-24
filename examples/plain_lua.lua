package.path = "../?.lua;../?/init.lua;" .. package.path

local async = require("async")

local now = 0
async.gettime = function()
  return now
end

local function step(dt)
  now = now + dt
  async.update(dt)
end

local logEvents = {}
async.setLogSink(function(e)
  logEvents[#logEvents + 1] = e
end)
async.setLogLevel("debug")
async.setLogEnabled(true)

async(function()
  print("A")
  async.sleep(0.5)
  print("B")

  local v = async.await(function()
    async.sleep(0.5)
    return "C"
  end)
  print(v)
end)

async(function()
  async.sleep(999)
end):setTimeout(0.2):catch(function(err)
  print("timeout caught:", err)
end)

while async.getTaskCount() > 0 do
  step(1 / 60)
end

async.setLogEnabled(false)
print("log events:", #logEvents)
