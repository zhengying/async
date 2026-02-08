local async = require("async")
local ThreadPool = require("threadpool")

local pool
local progressText = ""
local doneText = ""

function love.load()
  pool = ThreadPool.new(2)

  pool:register("heavy", function(payload, ctx)
    local n = payload.n
    local acc = 0
    for i = 1, n do
      if ctx.canceled() then
        return nil, "canceled"
      end
      acc = acc + math.sqrt(i)
      if i % 50000 == 0 then
        ctx.progress(i / n, { i = i })
      end
    end
    return acc
  end)

  async(function()
    local task = pool:submit("heavy", { n = 500000 }, { timeout = 10 })
    task:onProgress(function(p, data)
      progressText = string.format("progress: %.1f%% (i=%d)", p * 100, data.i or 0)
    end)

    local result, err, state = async.await(function()
      return task
    end)

    if state == "errored" then
      doneText = "error: " .. tostring(err)
    elseif state == "stopped" then
      doneText = "stopped"
    else
      doneText = "result: " .. tostring(result)
    end
  end)
end

function love.update(dt)
  async.update(dt)
end

function love.draw()
  love.graphics.print(progressText, 20, 20)
  love.graphics.print(doneText, 20, 40)
  love.graphics.print("Press Esc to quit", 20, 60)
end

function love.keypressed(key)
  if key == "escape" then
    love.event.quit()
  end
end

