local sourceBase = love.filesystem and love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory()
if type(sourceBase) ~= "string" then
  sourceBase = "."
end

local function fileExists(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function parentDir(path)
  if type(path) ~= "string" then
    return nil
  end
  path = path:gsub("[/\\]+$", "")
  local parent = path:match("^(.*)[/\\][^/\\]+$")
  if parent == "" then
    return nil
  end
  return parent
end

local function findRepoRoot(startDir)
  local dir = startDir
  for _ = 1, 12 do
    if type(dir) ~= "string" or dir == "" then
      return nil
    end
    if fileExists(dir .. "/async.lua") and fileExists(dir .. "/async_http.lua") then
      return dir
    end
    local p = parentDir(dir)
    if not p or p == dir then
      break
    end
    dir = p
  end
  return nil
end

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

local workingDir = love.filesystem and love.filesystem.getWorkingDirectory and love.filesystem.getWorkingDirectory()
local repoRoot = findRepoRoot(gameRoot) or findRepoRoot(sourceBase) or findRepoRoot(workingDir) or gameRoot

package.path = repoRoot .. "/?.lua;" .. repoRoot .. "/?/init.lua;" .. repoRoot .. "/examples/?.lua;" .. repoRoot .. "/examples/?/init.lua;" .. package.path
package.cpath = gameRoot .. "/?.so;" .. gameRoot .. "/?.dylib;" .. gameRoot .. "/?.dll;" .. package.cpath
package.cpath = repoRoot .. "/https_libs/?.so;" .. repoRoot .. "/https_libs/?.dylib;" .. repoRoot .. "/https_libs/?.dll;" .. package.cpath

local async = require("async")
local llm = require("llm")

local clients = {}
local currentProvider = "openai"
local currentTask

local inputText = "Say hello in one sentence."
local statusText = ""
local errorText = ""
local replyText = ""

local function firstLine(value)
  local s = tostring(value or "")
  s = s:gsub("\r\n", "\n")
  return s:match("([^\n\r]+)") or s
end

local function providerOrder()
  return { "openai", "anthropic" }
end

local function nextProvider()
  local order = providerOrder()
  for idx = 1, #order do
    if order[idx] == currentProvider then
      return order[(idx % #order) + 1]
    end
  end
  return order[1]
end

local function activeClient()
  return clients[currentProvider]
end

local function cancelCurrent()
  if not currentTask then
    return
  end
  if type(currentTask.cancel) == "function" then
    currentTask:cancel()
  else
    currentTask:stop()
  end
end

local function sendPrompt()
  local client = activeClient()
  if not client then
    statusText = "no client"
    errorText = "missing API key for provider: " .. tostring(currentProvider)
    return
  end

  if currentTask and currentTask:isRunning() and not currentTask.stopped and not currentTask.error and not currentTask.result then
    return
  end

  statusText = "requesting..."
  errorText = ""
  replyText = ""

  local model = client.model
  local maxTokens = currentProvider == "anthropic" and (client.maxTokens or 512) or nil

  currentTask = client:chatText(inputText, {
    max_tokens = maxTokens,
    temperature = 0.2
  })

  async(function()
    local result, err, extra = async.await(currentTask)
    if extra == "errored" then
      statusText = "errored"
      errorText = tostring(err)
      return
    end
    if extra == "stopped" then
      statusText = "stopped"
      return
    end
    if type(result) ~= "table" then
      local status = type(extra) == "table" and extra.status or 0
      statusText = "failed (status: " .. tostring(status) .. ")"
      errorText = tostring(err)
      return
    end
    statusText = "ok (" .. tostring(currentProvider) .. ", model: " .. tostring(model) .. ")"
    replyText = tostring(result.text or "")
  end)
end

function love.load()
  local openaiKey = os.getenv("OPENAI_API_KEY") or "sk-99c30131f4fc4fd6a5dadf287967742d"
  local openaiBase = os.getenv("OPENAI_BASE_URL") or "https://api.deepseek.com/v1"
  local openaiModel = os.getenv("OPENAI_MODEL") or "deepseek-chat"

  local anthropicKey = os.getenv("ANTHROPIC_API_KEY")
  local anthropicBase = os.getenv("ANTHROPIC_BASE_URL") or "https://api.anthropic.com"
  local anthropicModel = os.getenv("ANTHROPIC_MODEL") or "claude-3-5-sonnet-20241022"

  if type(openaiKey) == "string" and openaiKey ~= "" then
    clients.openai = llm.openai({
      apiKey = openaiKey,
      baseUrl = openaiBase,
      model = openaiModel,
      debug = true,
      timeout = 60,
      poolSize = 4,
      httpsModule = "https"
    })
  end

  if type(anthropicKey) == "string" and anthropicKey ~= "" then
    clients.anthropic = llm.anthropic({
      apiKey = anthropicKey,
      baseUrl = anthropicBase,
      model = anthropicModel,
      maxTokens = tonumber(os.getenv("ANTHROPIC_MAX_TOKENS") or "") or 512,
      debug = true,
      timeout = 60,
      poolSize = 4,
      httpsModule = "https"
    })
  end

  if not clients.openai and clients.anthropic then
    currentProvider = "anthropic"
  else
    currentProvider = "openai"
  end

  if not clients.openai and not clients.anthropic then
    statusText = "no API keys"
    errorText = "set OPENAI_API_KEY or ANTHROPIC_API_KEY in env"
  else
    sendPrompt()
  end
end

function love.update(dt)
  async.update(dt)
end

function love.textinput(t)
  inputText = inputText .. tostring(t or "")
end

function love.keypressed(key)
  if key == "escape" then
    love.event.quit()
    return
  end
  if key == "return" or key == "kpenter" then
    sendPrompt()
    return
  end
  if key == "tab" then
    currentProvider = nextProvider()
    statusText = "provider: " .. tostring(currentProvider)
    errorText = ""
    replyText = ""
    return
  end
  if key == "backspace" then
    inputText = inputText:sub(1, #inputText - 1)
    return
  end
  if key == "c" then
    cancelCurrent()
    return
  end
  if key == "f1" then
    inputText = ""
    return
  end
end

function love.draw()
  local x = 20
  local y = 20
  local lh = (love.graphics.getFont() and love.graphics.getFont():getHeight() or 12) + 2

  local function drawTextLines(text)
    local s = tostring(text or "")
    s = s:gsub("\r\n", "\n")
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
      love.graphics.print(line, x, y)
      y = y + lh
    end
  end

  drawTextLines("Enter: send  Tab: switch provider  Backspace: delete  C: cancel  F1: clear  Esc: quit")
  drawTextLines("provider: " .. tostring(currentProvider))
  drawTextLines("prompt: " .. inputText)
  drawTextLines(statusText)
  if errorText ~= "" then
    drawTextLines("error: " .. firstLine(errorText))
  end
  y = y + lh
  drawTextLines(replyText)
end

function love.quit()
  for _, c in pairs(clients) do
    if type(c.destroy) == "function" then
      c:destroy()
    end
  end
end
