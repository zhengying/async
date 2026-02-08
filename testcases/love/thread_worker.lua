local inName, outName = ...

local inCh = love.thread.getChannel(inName)
local outCh = love.thread.getChannel(outName)

local input = inCh:demand()

if input == "FAIL" then
  outCh:push("worker forced failure")
  return
end

if type(input) == "number" then
  outCh:push(input * 2)
else
  outCh:push(input)
end
