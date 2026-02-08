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

while async.getTaskCount() > 0 do
  step(1 / 60)
end

