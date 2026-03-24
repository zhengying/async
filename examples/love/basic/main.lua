local async = require("async")
local ThreadPool = require("threadpool")

local pool
local jobTask
local progressText = ""
local doneText = ""
local helpText = "Space: start  C: cancel  L: log  +/-: level  Esc: quit"

local logEnabled = false
local logLevels = { "off", "error", "warn", "info", "debug", "trace" }
local logLevelIndex = 4
local logLines = {}
local maxLogLines = 14

local function toOneLine(value)
  local s = tostring(value)
  s = s:gsub("\r\n", "\n")
  s = s:gsub("[\r\n]", " \\n ")
  s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

local function firstLine(value)
  local s = tostring(value)
  s = s:gsub("\r\n", "\n")
  return s:match("([^\n\r]+)") or s
end

local function pushLogLine(line)
  logLines[#logLines + 1] = line
  while #logLines > maxLogLines do
    table.remove(logLines, 1)
  end
end

local function formatLogEntry(e)
  local taskPart = ""
  if e.task and e.task.id then
    taskPart = " t=" .. tostring(e.task.id)
  end

  local fieldsPart = ""
  if type(e.fields) == "table" then
    local parts = {}
    for k, v in pairs(e.fields) do
      parts[#parts + 1] = toOneLine(k) .. "=" .. toOneLine(v)
    end
    if #parts > 0 then
      fieldsPart = " " .. table.concat(parts, " ")
    end
  end

  return string.format("%s %s%s%s", toOneLine(e.levelName), toOneLine(e.event), taskPart, fieldsPart)
end

local function applyLogging()
  async.setLogEnabled(false)
  async.setLogSink(nil)
  async.setLogLevel(logLevels[logLevelIndex])

  if not logEnabled then
    pushLogLine("logging disabled")
    return
  end

  async.setLogSink(function(e)
    pushLogLine(formatLogEntry(e))
  end)
  async.setLogEnabled(true)
  pushLogLine("logging enabled level=" .. logLevels[logLevelIndex])
end

local function startJob()
  if jobTask and not jobTask.stopped and not jobTask.error and not jobTask.result then
    return
  end

  progressText = ""
  doneText = ""
  logLines = {}
  applyLogging()

  jobTask = pool:submit("heavy", { n = 250000000 }, { timeout = 5 })
  jobTask:onProgress(function(p, data)
    progressText = string.format("progress: %.1f%% (i=%d)", p * 100, tonumber(data and data.i) or 0)
  end)

  async(function()
    local result, err, state = async.await(jobTask)

    if state == "errored" then
      doneText = "error: " .. firstLine(err)
      pushLogLine("error: " .. toOneLine(err))
    elseif state == "stopped" then
      doneText = "stopped"
    else
      doneText = "result: " .. tostring(result)
    end
  end)
end

local function cancelJob()
  if not jobTask then
    return
  end
  if type(jobTask.cancel) == "function" then
    jobTask:cancel()
    return
  end
  jobTask:stop()
end

function love.load()
  pool = ThreadPool.new(2)

  pool:register("heavy", function(payload, ctx)
    local n = payload.n
    local acc = 0
    for i = 1, n do
      if ctx.canceled() then
        return nil
      end
      acc = acc + math.sqrt(i)
      if i % 25000 == 0 then
        ctx.progress(i / n, { i = i })
      end
    end
    return acc
  end)

  applyLogging()
  startJob()
end

function love.update(dt)
  async.update(dt)
end

function love.draw()
  local x = 20
  local y = 20
  local lh = (love.graphics.getFont() and love.graphics.getFont():getHeight() or 12) + 2

  local function drawTextLines(text)
    local s = tostring(text or "")
    s = s:gsub("\r\n", "\n")
    for line in s:gmatch("([^\n]*)\n?") do
      if line == "" and s:sub(-1) ~= "\n" then
        break
      end
      love.graphics.print(line, x, y)
      y = y + lh
    end
  end

  drawTextLines(helpText)
  drawTextLines(progressText)
  drawTextLines(doneText)

  y = y + lh
  for i = 1, #logLines do
    love.graphics.print(logLines[i], x, y)
    y = y + lh
  end
end

function love.keypressed(key)
  if key == "escape" then
    love.event.quit()
  elseif key == "space" then
    startJob()
  elseif key == "c" then
    cancelJob()
  elseif key == "l" then
    logEnabled = not logEnabled
    applyLogging()
  elseif key == "+" or key == "kp+" or key == "=" then
    logLevelIndex = math.min(#logLevels, logLevelIndex + 1)
    applyLogging()
  elseif key == "-" or key == "kp-" then
    logLevelIndex = math.max(1, logLevelIndex - 1)
    applyLogging()
  end
end
