local sourceBase = love.filesystem and love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory()
if type(sourceBase) ~= "string" then
  sourceBase = "."
end
local repoRoot = sourceBase .. "/../../.."
package.path = repoRoot .. "/?.lua;" .. repoRoot .. "/?/init.lua;" .. package.path

local source = love.filesystem and love.filesystem.getSource and love.filesystem.getSource()
local gameRoot = sourceBase
if type(source) == "string" and source ~= "" then
  if source:match("%.love$") then
    gameRoot = source:match("^(.*)[/\\]") or sourceBase
  else
    gameRoot = source
  end
  if not (gameRoot:sub(1, 1) == "/" or gameRoot:match("^%a:[/\\]")) then
    gameRoot = sourceBase .. "/" .. gameRoot
  end
end
package.cpath = gameRoot .. "/?.so;" .. gameRoot .. "/?.dylib;" .. gameRoot .. "/?.dll;" .. package.cpath
package.cpath = repoRoot .. "/https_libs/?.so;" .. repoRoot .. "/https_libs/?.dylib;" .. repoRoot .. "/https_libs/?.dll;" .. package.cpath

local async = require("async")
local AsyncHttp = require("async_http")

local client
local currentTask

local helpText = "Space: await request  N: next request  C: cancel  Esc: quit"
local statusText = ""
local errorText = ""
local bodyText = ""
local isTestMode = tostring(os.getenv("ASYNC_HTTP_TEST") or "") == "1"
local testFailed = false
local testErrorMsg = ""

local function firstLine(value)
  local s = tostring(value)
  s = s:gsub("\r\n", "\n")
  return s:match("([^\n\r]+)") or s
end

local function startRequestAwait()
  if currentTask and currentTask:isRunning() and not currentTask.stopped and not currentTask.error and not currentTask.result then
    return
  end

  statusText = "requesting..."
  errorText = ""
  bodyText = ""

  currentTask = client:get("https://baidu.com", { timeout = 10 })

  async(function()
    local a, b, c = async.await(currentTask)

    if c == "errored" then
      statusText = "errored"
      errorText = tostring(b)
      if isTestMode then
        testFailed = true
        testErrorMsg = "request errored: " .. tostring(b)
        love.event.quit()
      end
      return
    end
    if c == "stopped" then
      statusText = "stopped"
      if isTestMode then
        testFailed = true
        testErrorMsg = "request stopped"
        love.event.quit()
      end
      return
    end

    local resp = a
    local err = b
    local extra = c

    if type(resp) == "table" then
      statusText = "status: " .. tostring(resp.status)
      bodyText = tostring(resp.body or "")
      bodyText = bodyText:sub(1, 4000)
      if isTestMode then
        if type(resp.status) ~= "number" or resp.status <= 0 then
          testFailed = true
          testErrorMsg = "invalid status: " .. tostring(resp.status)
        end
        love.event.quit()
      end
      return
    end

    local status = type(extra) == "table" and extra.status or 0
    statusText = "failed (status: " .. tostring(status) .. ")"
    errorText = tostring(err)
    if isTestMode then
      testFailed = true
      testErrorMsg = "request failed: " .. tostring(err)
      love.event.quit()
    end
  end)
end

local function startRequestNext()
  if currentTask and currentTask:isRunning() and not currentTask.stopped and not currentTask.error and not currentTask.result then
    return
  end

  statusText = "requesting..."
  errorText = ""
  bodyText = ""

  local task = client:get("https://baidu.com", { timeout = 10 })
  currentTask = task

  task:next(function(resp, err, extra)
    if type(resp) == "table" then
      statusText = "status: " .. tostring(resp.status)
      bodyText = tostring(resp.body or "")
      bodyText = bodyText:sub(1, 4000)
      return
    end

    local status = type(extra) == "table" and extra.status or 0
    statusText = "failed (status: " .. tostring(status) .. ")"
    errorText = tostring(err)
  end)

  task:catch(function(err)
    statusText = "errored"
    errorText = tostring(err)
  end)
end

local function cancelRequest()
  if not currentTask then
    return
  end
  if type(currentTask.cancel) == "function" then
    currentTask:cancel()
  else
    currentTask:stop()
  end
end

function love.load()
  if isTestMode then
    local ok, mod = pcall(require, "https")
    if not ok or type(mod) ~= "table" or type(mod.request) ~= "function" then
      testFailed = true
      testErrorMsg = "require('https') failed: " .. tostring(mod)
      love.event.quit()
      return
    end
  end

  client = AsyncHttp.new({
    poolSize = 4,
    timeout = 10,
    httpsModule = "https"
  })

  startRequestAwait()
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
  drawTextLines(statusText)
  if errorText ~= "" then
    drawTextLines("error: " .. firstLine(errorText))
  end
  y = y + lh
  drawTextLines(bodyText)
end

function love.keypressed(key)
  if key == "escape" then
    love.event.quit()
  elseif key == "space" then
    startRequestAwait()
  elseif key == "n" then
    startRequestNext()
  elseif key == "c" then
    cancelRequest()
  end
end

function love.quit()
  if client then
    client:destroy()
  end

  if isTestMode then
    if testFailed then
      io.stderr:write((testErrorMsg ~= "" and testErrorMsg or "async_http real integration test failed") .. "\n")
      os.exit(1)
    else
      os.exit(0)
    end
  end
end
