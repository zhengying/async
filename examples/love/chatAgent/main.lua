local sourceBase = love.filesystem and love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory()
if type(sourceBase) ~= "string" then
  sourceBase = "."
end

local function fileExists(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local file = io.open(path, "rb")
  if file then
    file:close()
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
    local nextDir = parentDir(dir)
    if not nextDir or nextDir == dir then
      break
    end
    dir = nextDir
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
local TextInput = require("love.ui_text_input")

local clients = {}
local currentProvider = "openai"
local currentTask = nil
local inputBox = nil
local history = {}
local statusText = ""
local errorText = ""
local conversationScroll = 0
local followLatest = true
local defaultSystemPrompt = "You are a helpful assistant in a single persistent chat context. Treat every message in the current conversation as active context unless the user clears the session."
local systemPrompt = os.getenv("CHAT_AGENT_SYSTEM_PROMPT") or defaultSystemPrompt
local settings = nil
local configState = {
  fileName = "chat_agent_config.json",
  isOpen = false,
  selectedProvider = "openai",
  editors = {},
  fieldOrder = { "apiKey", "baseUrl", "model", "maxTokens", "systemPrompt" },
  layout = {}
}

local ui = {
  fonts = {},
  hitboxes = {},
  layout = {},
  chatState = {
    x = 0,
    y = 0,
    w = 0,
    h = 0,
    contentHeight = 0,
    maxScroll = 0
  },
  palette = {
    bg = { 0.05, 0.07, 0.10, 1 },
    panel = { 0.10, 0.13, 0.18, 0.98 },
    panelAlt = { 0.13, 0.17, 0.23, 0.98 },
    border = { 0.24, 0.31, 0.42, 1 },
    text = { 0.93, 0.96, 1, 1 },
    muted = { 0.67, 0.74, 0.84, 1 },
    accent = { 0.39, 0.67, 1, 1 },
    accentSoft = { 0.18, 0.28, 0.44, 1 },
    success = { 0.30, 0.82, 0.56, 1 },
    warn = { 0.96, 0.72, 0.32, 1 },
    danger = { 0.96, 0.39, 0.39, 1 },
    userFill = { 0.16, 0.27, 0.42, 0.95 },
    assistantFill = { 0.14, 0.17, 0.24, 0.96 }
  }
}

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local function firstLine(value)
  local text = tostring(value or "")
  text = text:gsub("\r\n", "\n")
  return text:match("([^\n\r]+)") or text
end

local function trimText(value)
  local text = tostring(value or "")
  text = text:gsub("^%s+", "")
  text = text:gsub("%s+$", "")
  return text
end

local function defaultProviderSettings(provider)
  if provider == "anthropic" then
    return {
      apiKey = os.getenv("ANTHROPIC_API_KEY") or "",
      baseUrl = os.getenv("ANTHROPIC_BASE_URL") or "https://api.anthropic.com",
      model = os.getenv("ANTHROPIC_MODEL") or "claude-3-5-sonnet-20241022",
      maxTokens = tostring(tonumber(os.getenv("ANTHROPIC_MAX_TOKENS") or "") or 1024)
    }
  end
  return {
    apiKey = os.getenv("OPENAI_API_KEY") or "",
    baseUrl = os.getenv("OPENAI_BASE_URL") or "https://api.openai.com/v1",
    model = os.getenv("OPENAI_MODEL") or "gpt-4o-mini",
    maxTokens = tostring(tonumber(os.getenv("OPENAI_MAX_TOKENS") or "") or 1024)
  }
end

local function copyProviderSettings(value, fallback)
  local defaults = fallback or {}
  return {
    apiKey = tostring((value and value.apiKey) or defaults.apiKey or ""),
    baseUrl = tostring((value and value.baseUrl) or defaults.baseUrl or ""),
    model = tostring((value and value.model) or defaults.model or ""),
    maxTokens = tostring((value and value.maxTokens) or defaults.maxTokens or "")
  }
end

local function buildDefaultSettings()
  return {
    selectedProvider = "openai",
    systemPrompt = os.getenv("CHAT_AGENT_SYSTEM_PROMPT") or defaultSystemPrompt,
    providers = {
      openai = copyProviderSettings(nil, defaultProviderSettings("openai")),
      anthropic = copyProviderSettings(nil, defaultProviderSettings("anthropic"))
    }
  }
end

local function normalizeSettings(source)
  local defaults = buildDefaultSettings()
  local normalized = {
    selectedProvider = tostring((source and source.selectedProvider) or defaults.selectedProvider),
    systemPrompt = tostring((source and source.systemPrompt) or defaults.systemPrompt),
    providers = {
      openai = copyProviderSettings(source and source.providers and source.providers.openai, defaults.providers.openai),
      anthropic = copyProviderSettings(source and source.providers and source.providers.anthropic, defaults.providers.anthropic)
    }
  }
  if normalized.selectedProvider ~= "anthropic" then
    normalized.selectedProvider = "openai"
  end
  return normalized
end

local function activeSettingsFor(provider)
  local state = settings or buildDefaultSettings()
  local name = provider == "anthropic" and "anthropic" or "openai"
  return state.providers[name]
end

local function setColor(rgba)
  love.graphics.setColor(rgba[1], rgba[2], rgba[3], rgba[4] or 1)
end

local function pointInRect(px, py, x, y, w, h)
  return px >= x and px <= x + w and py >= y and py <= y + h
end

local function resetHitboxes()
  ui.hitboxes = {}
end

local function pushHitbox(x, y, w, h, onClick)
  ui.hitboxes[#ui.hitboxes + 1] = {
    x = x,
    y = y,
    w = w,
    h = h,
    onClick = onClick
  }
end

local function destroyClients()
  for _, client in pairs(clients) do
    if client and type(client.destroy) == "function" then
      client:destroy()
    end
  end
  clients = {}
end

local function saveSettings()
  if not love.filesystem or type(love.filesystem.write) ~= "function" then
    return false, "filesystem write is unavailable"
  end
  local ok, payload = pcall(llm.jsonEncode, settings)
  if not ok then
    return false, tostring(payload)
  end
  local wrote, err = love.filesystem.write(configState.fileName, payload)
  if wrote == nil or wrote == false then
    return false, tostring(err or "write failed")
  end
  return true
end

local function loadSettings()
  local loaded = nil
  if love.filesystem and type(love.filesystem.getInfo) == "function" and love.filesystem.getInfo(configState.fileName) then
    local data, err = love.filesystem.read(configState.fileName)
    if type(data) == "string" and data ~= "" then
      local ok, decoded = pcall(llm.jsonDecode, data)
      if ok and type(decoded) == "table" then
        loaded = decoded
      else
        errorText = "failed to parse saved config: " .. tostring(decoded or err or "")
      end
    elseif err then
      errorText = "failed to read saved config: " .. tostring(err)
    end
  end
  settings = normalizeSettings(loaded)
  systemPrompt = settings.systemPrompt
end

local function rebuildClients()
  destroyClients()

  local openai = activeSettingsFor("openai")
  if trimText(openai.apiKey) ~= "" then
    clients.openai = llm.openai({
      apiKey = trimText(openai.apiKey),
      baseUrl = trimText(openai.baseUrl),
      model = trimText(openai.model),
      timeout = 120,
      poolSize = 4,
      httpsModule = "https"
    })
  end

  local anthropic = activeSettingsFor("anthropic")
  if trimText(anthropic.apiKey) ~= "" then
    clients.anthropic = llm.anthropic({
      apiKey = trimText(anthropic.apiKey),
      baseUrl = trimText(anthropic.baseUrl),
      model = trimText(anthropic.model),
      maxTokens = tonumber(trimText(anthropic.maxTokens)) or 1024,
      timeout = 120,
      poolSize = 4,
      httpsModule = "https"
    })
  end

  local currentSettings = settings or buildDefaultSettings()
  currentProvider = currentSettings.selectedProvider
  if not clients[currentProvider] then
    if clients.openai then
      currentProvider = "openai"
    elseif clients.anthropic then
      currentProvider = "anthropic"
    end
  end
end

local function focusEditor(name)
  for key, editor in pairs(configState.editors) do
    if key == name then
      editor:focus()
    else
      editor:blur()
    end
  end
end

local function activeConfigProvider()
  return configState.selectedProvider == "anthropic" and "anthropic" or "openai"
end

local function syncEditorsFromSettings()
  if not settings then
    return
  end
  local provider = activeConfigProvider()
  local providerSettings = settings.providers[provider]
  configState.editors.apiKey:setText(providerSettings.apiKey)
  configState.editors.baseUrl:setText(providerSettings.baseUrl)
  configState.editors.model:setText(providerSettings.model)
  configState.editors.maxTokens:setText(providerSettings.maxTokens)
  configState.editors.systemPrompt:setText(settings.systemPrompt)
end

local function syncSettingsFromEditors()
  if not settings then
    settings = buildDefaultSettings()
  end
  local provider = activeConfigProvider()
  local providerSettings = settings.providers[provider]
  providerSettings.apiKey = trimText(configState.editors.apiKey:getText())
  providerSettings.baseUrl = trimText(configState.editors.baseUrl:getText())
  providerSettings.model = trimText(configState.editors.model:getText())
  providerSettings.maxTokens = trimText(configState.editors.maxTokens:getText())
  settings.systemPrompt = trimText(configState.editors.systemPrompt:getText())
  settings.selectedProvider = provider
  systemPrompt = settings.systemPrompt ~= "" and settings.systemPrompt or defaultSystemPrompt
  settings.systemPrompt = systemPrompt
end

local isBusy

local function openProviderConfig()
  if isBusy() then
    statusText = "stop the current request before changing provider config"
    errorText = ""
    return
  end
  configState.isOpen = true
  configState.selectedProvider = settings and settings.selectedProvider or currentProvider
  syncEditorsFromSettings()
  focusEditor("apiKey")
  statusText = "editing provider config"
  errorText = ""
end

local function closeProviderConfig()
  configState.isOpen = false
  for _, editor in pairs(configState.editors) do
    editor:blur()
  end
  if inputBox then
    inputBox:focus()
  end
end

local function saveProviderConfig()
  syncSettingsFromEditors()
  local ok, err = saveSettings()
  if not ok then
    statusText = "save failed"
    errorText = tostring(err)
    return
  end
  rebuildClients()
  closeProviderConfig()
  statusText = "provider config saved"
  errorText = ""
end

local function createConfigEditor(placeholder, softWrap)
  local editor = TextInput.new({
    text = "",
    placeholder = placeholder,
    focused = false,
    softWrap = softWrap ~= false,
    paddingX = 12,
    paddingY = 10,
    lineGap = 3
  })
  editor:setFont(ui.fonts.body)
  return editor
end

local function ensureConfigEditors()
  if next(configState.editors) ~= nil then
    return
  end
  configState.editors.apiKey = createConfigEditor("API key", false)
  configState.editors.baseUrl = createConfigEditor("Base URL", false)
  configState.editors.model = createConfigEditor("Model", false)
  configState.editors.maxTokens = createConfigEditor("Max tokens", false)
  configState.editors.systemPrompt = createConfigEditor("System prompt", true)
end

local function focusedConfigField()
  for _, name in ipairs(configState.fieldOrder) do
    local editor = configState.editors[name]
    if editor and editor.focused then
      return name
    end
  end
  return nil
end

local function focusNextConfigField(direction)
  local current = focusedConfigField()
  local index = 1
  for i = 1, #configState.fieldOrder do
    if configState.fieldOrder[i] == current then
      index = i
      break
    end
  end
  local step = direction or 1
  local nextIndex = ((index - 1 + step) % #configState.fieldOrder) + 1
  focusEditor(configState.fieldOrder[nextIndex])
end

local function selectConfigProvider(provider)
  syncSettingsFromEditors()
  configState.selectedProvider = provider == "anthropic" and "anthropic" or "openai"
  syncEditorsFromSettings()
  focusEditor("apiKey")
end

local function providerOrder()
  return { "openai", "anthropic" }
end

local function activeClient()
  return clients[currentProvider]
end

local availableProviderCount

local function activeProviderLabel()
  if activeClient() then
    return tostring(currentProvider)
  end
  if availableProviderCount() == 0 then
    return "no key"
  end
  return tostring(currentProvider)
end

local function activeModel()
  local client = activeClient()
  if type(client) == "table" and type(client.model) == "string" and client.model ~= "" then
    return client.model
  end
  if availableProviderCount() == 0 then
    return "set API key"
  end
  return "unavailable"
end

availableProviderCount = function()
  local count = 0
  for _, name in ipairs(providerOrder()) do
    if clients[name] then
      count = count + 1
    end
  end
  return count
end

isBusy = function()
  return currentTask and currentTask.isRunning and currentTask:isRunning() and not currentTask.stopped and not currentTask.error and not currentTask.result
end

local function appendMessage(role, content, meta)
  history[#history + 1] = {
    role = tostring(role or "assistant"),
    content = tostring(content or ""),
    provider = meta and meta.provider or nil,
    model = meta and meta.model or nil,
    usage = meta and meta.usage or nil
  }
  followLatest = true
end

local cancelCurrent

local function clearConversation()
  if currentTask then
    cancelCurrent()
    currentTask = nil
  end
  history = {}
  statusText = "conversation cleared"
  errorText = ""
  followLatest = true
end

cancelCurrent = function()
  if not currentTask then
    return
  end
  if type(currentTask.cancel) == "function" then
    currentTask:cancel()
  else
    currentTask:stop()
  end
end

local function buildMessages(provider)
  local messages = {}
  if provider == "openai" then
    messages[#messages + 1] = {
      role = "system",
      content = systemPrompt
    }
  end
  for index = 1, #history do
    local item = history[index]
    messages[#messages + 1] = {
      role = item.role,
      content = item.content
    }
  end
  return messages
end

local function sendPrompt()
  local client = activeClient()
  if not client then
    statusText = "no client"
    errorText = "open provider settings and save a valid API key first"
    return
  end
  if isBusy() then
    return
  end
  local text = inputBox and inputBox.getText and inputBox:getText() or ""
  local prompt = trimText(text)
  if prompt == "" then
    statusText = "empty input"
    errorText = ""
    return
  end

  local provider = currentProvider
  local model = client.model
  local providerSettings = activeSettingsFor(provider)
  appendMessage("user", prompt, {
    provider = provider,
    model = model
  })
  if inputBox and inputBox.setText then
    inputBox:setText("")
    inputBox:focus()
  end
  statusText = "requesting..."
  errorText = ""
  followLatest = true

  local request = {
    model = model,
    messages = buildMessages(provider),
    temperature = 0.5,
    timeout = 120,
    max_tokens = tonumber(trimText(providerSettings.maxTokens))
  }
  if provider == "anthropic" then
    request.system = systemPrompt
    request.max_tokens = tonumber(trimText(providerSettings.maxTokens)) or client.maxTokens or 1024
  end

  currentTask = client:chat(request)
  local taskRef = currentTask

  async(function()
    local result, err, extra = async.await(taskRef)
    if taskRef ~= currentTask then
      return
    end
    currentTask = nil
    if extra == "stopped" then
      statusText = "stopped"
      return
    end
    if extra == "errored" then
      statusText = "errored"
      errorText = tostring(err)
      return
    end
    if type(result) ~= "table" then
      local statusCode = type(extra) == "table" and extra.status or 0
      statusText = "failed (status: " .. tostring(statusCode) .. ")"
      errorText = tostring(err)
      return
    end
    local reply = tostring(result.text or "")
    if reply == "" then
      reply = "<empty response>"
    end
    appendMessage("assistant", reply, {
      provider = provider,
      model = model,
      usage = result.usage
    })
    statusText = "ok (" .. tostring(provider) .. " / " .. tostring(model) .. ")"
    errorText = ""
  end)
end

local function drawPanel(x, y, w, h, tone)
  setColor(tone or ui.palette.panel)
  love.graphics.rectangle("fill", x, y, w, h, 16, 16)
  setColor(ui.palette.border)
  love.graphics.rectangle("line", x, y, w, h, 16, 16)
end

local function drawButton(label, x, y, w, h, tone, onClick, muted)
  local mx, my = love.mouse.getPosition()
  local hovered = pointInRect(mx, my, x, y, w, h)
  local alpha = muted and 0.10 or (hovered and 0.28 or 0.18)
  setColor({ tone[1], tone[2], tone[3], alpha })
  love.graphics.rectangle("fill", x, y, w, h, 10, 10)
  setColor(muted and ui.palette.muted or tone)
  love.graphics.rectangle("line", x, y, w, h, 10, 10)
  love.graphics.setFont(ui.fonts.small)
  setColor(muted and ui.palette.muted or tone)
  love.graphics.printf(label, x, y + math.floor((h - ui.fonts.small:getHeight()) / 2), w, "center")
  if not muted then
    pushHitbox(x, y, w, h, onClick)
  end
end

local function drawPill(label, x, y, tone, width)
  local w = width or (ui.fonts.small:getWidth(label) + 20)
  local h = ui.fonts.small:getHeight() + 10
  setColor({ tone[1], tone[2], tone[3], 0.16 })
  love.graphics.rectangle("fill", x, y, w, h, 999, 999)
  setColor(tone)
  love.graphics.rectangle("line", x, y, w, h, 999, 999)
  love.graphics.setFont(ui.fonts.small)
  love.graphics.printf(label, x, y + 4, w, "center")
  return w, h
end

local function wrappedLines(font, text, width)
  local _, lines = font:getWrap(tostring(text or ""), width)
  if type(lines) ~= "table" or #lines == 0 then
    lines = { tostring(text or "") }
  end
  return lines
end

local function computeBubbleWidth(lines, minWidth, maxWidth)
  local width = minWidth
  for index = 1, #lines do
    width = math.max(width, ui.fonts.body:getWidth(lines[index]) + 28)
  end
  return clamp(width, minWidth, maxWidth)
end

local function layoutMessages(viewportWidth)
  local items = {}
  local bubbleMaxWidth = math.max(260, math.min(math.floor(viewportWidth * 0.74), viewportWidth - 30))
  local bubbleMinWidth = math.min(220, bubbleMaxWidth)
  local bubblePaddingX = 14
  local bubblePaddingY = 12
  local metaLineHeight = ui.fonts.small:getHeight() + 2
  local lineHeight = ui.fonts.body:getHeight() + 4
  local cursorY = 6

  local function pushItem(role, text, provider, model, isPending)
    local content = tostring(text or "")
    local maxTextWidth = bubbleMaxWidth - bubblePaddingX * 2
    local lines = wrappedLines(ui.fonts.body, content, maxTextWidth)
    local bubbleWidth = computeBubbleWidth(lines, bubbleMinWidth, bubbleMaxWidth)
    local textWidth = bubbleWidth - bubblePaddingX * 2
    lines = wrappedLines(ui.fonts.body, content, textWidth)
    local label = role == "user" and "You" or "Assistant"
    if provider and provider ~= "" then
      label = label .. " • " .. tostring(provider)
    end
    if model and model ~= "" then
      label = label .. " • " .. tostring(model)
    end
    if isPending then
      label = label .. " • waiting"
    end
    local labelLines = wrappedLines(ui.fonts.small, label, textWidth)
    local labelHeight = #labelLines * metaLineHeight
    local bubbleHeight = bubblePaddingY * 2 + labelHeight + 8 + #lines * lineHeight
    local alignRight = role == "user"
    items[#items + 1] = {
      role = role,
      text = content,
      label = label,
      provider = provider,
      model = model,
      isPending = isPending == true,
      x = alignRight and (viewportWidth - bubbleWidth - 10) or 10,
      y = cursorY,
      w = bubbleWidth,
      h = bubbleHeight,
      lines = lines,
      labelLines = labelLines,
      labelHeight = labelHeight
    }
    cursorY = cursorY + bubbleHeight + 16
  end

  for index = 1, #history do
    local item = history[index]
    pushItem(item.role, item.content, item.provider, item.model, false)
  end

  if isBusy() then
    pushItem("assistant", "Thinking...", currentProvider, activeModel(), true)
  end

  return items, cursorY
end

local function drawVerticalScrollbar(x, y, w, h, offset, contentHeight)
  if contentHeight <= h then
    return
  end
  local trackX = x + w - 10
  local trackY = y + 4
  local trackW = 6
  local trackH = h - 8
  local thumbH = math.max(28, trackH * (h / contentHeight))
  local maxScroll = math.max(1, contentHeight - h)
  local thumbY = trackY + (trackH - thumbH) * (offset / maxScroll)
  setColor({ ui.palette.border[1], ui.palette.border[2], ui.palette.border[3], 0.9 })
  love.graphics.rectangle("fill", trackX, trackY, trackW, trackH, 4, 4)
  setColor(ui.palette.accent)
  love.graphics.rectangle("fill", trackX, thumbY, trackW, thumbH, 4, 4)
end

local function statusTone()
  if errorText ~= "" then
    return ui.palette.danger
  end
  if isBusy() then
    return ui.palette.warn
  end
  if #history > 0 then
    return ui.palette.success
  end
  return ui.palette.accent
end

local function refreshLayout()
  local screenWidth = love.graphics.getWidth and love.graphics.getWidth() or 1440
  local screenHeight = love.graphics.getHeight and love.graphics.getHeight() or 960
  local margin = 18
  local gap = 16
  local headerHeight = 112
  local composerHeight = math.max(220, math.floor(screenHeight * 0.27))
  local fullWidth = screenWidth - margin * 2
  local headerY = margin
  local chatY = headerY + headerHeight + gap
  local composerY = screenHeight - margin - composerHeight
  local chatHeight = composerY - chatY - gap

  ui.layout = {
    screenWidth = screenWidth,
    screenHeight = screenHeight,
    margin = margin,
    gap = gap,
    header = {
      x = margin,
      y = headerY,
      w = fullWidth,
      h = headerHeight
    },
    chat = {
      x = margin,
      y = chatY,
      w = fullWidth,
      h = chatHeight
    },
    composer = {
      x = margin,
      y = composerY,
      w = fullWidth,
      h = composerHeight
    },
    config = {
      w = math.min(fullWidth - 40, 860),
      h = math.min(screenHeight - 80, 620)
    }
  }

  ui.layout.config.x = math.floor((screenWidth - ui.layout.config.w) / 2)
  ui.layout.config.y = math.floor((screenHeight - ui.layout.config.h) / 2)

  if inputBox then
    inputBox:setRect(
      ui.layout.composer.x + 18,
      ui.layout.composer.y + 78,
      ui.layout.composer.w - 36,
      ui.layout.composer.h - 96
    )
  end

  if next(configState.editors) ~= nil then
    local modal = ui.layout.config
    local fieldX = modal.x + 22
    local fieldW = modal.w - 44
    local cursorY = modal.y + 118
    local labelGap = 20
    local fieldGap = 14
    configState.layout.providerButtons = {
      openai = { x = modal.x + 22, y = modal.y + 62, w = 118, h = 34 },
      anthropic = { x = modal.x + 150, y = modal.y + 62, w = 118, h = 34 }
    }
    configState.layout.fields = {
      apiKey = { x = fieldX, y = cursorY, w = fieldW, h = 48 },
      baseUrl = { x = fieldX, y = cursorY + (48 + labelGap + fieldGap), w = fieldW, h = 48 },
      model = { x = fieldX, y = cursorY + (48 + labelGap + fieldGap) * 2, w = fieldW, h = 48 },
      maxTokens = { x = fieldX, y = cursorY + (48 + labelGap + fieldGap) * 3, w = fieldW, h = 48 }
    }
    local promptY = configState.layout.fields.maxTokens.y + 48 + labelGap + fieldGap
    local promptH = modal.y + modal.h - 84 - promptY
    configState.layout.fields.systemPrompt = { x = fieldX, y = promptY, w = fieldW, h = math.max(88, promptH) }
    configState.layout.actions = {
      cancel = { x = modal.x + modal.w - 210, y = modal.y + modal.h - 52, w = 88, h = 34 },
      save = { x = modal.x + modal.w - 112, y = modal.y + modal.h - 52, w = 88, h = 34 }
    }
    for name, rect in pairs(configState.layout.fields) do
      configState.editors[name]:setRect(rect.x, rect.y, rect.w, rect.h)
    end
  end
end

local function drawHeader()
  local header = ui.layout.header
  drawPanel(header.x, header.y, header.w, header.h, ui.palette.panelAlt)

  love.graphics.setFont(ui.fonts.title)
  setColor(ui.palette.text)
  love.graphics.print("Chat Agent", header.x + 20, header.y + 16)

  love.graphics.setFont(ui.fonts.body)
  setColor(ui.palette.muted)
  love.graphics.print("Single persistent context chat. Every turn is sent with the same conversation history.", header.x + 22, header.y + 50)

  local infoX = header.x + 22
  local pillY = header.y + 78
  love.graphics.setFont(ui.fonts.small)
  local providerLabel = "provider: " .. tostring(activeProviderLabel())
  local modelLabel = "model: " .. tostring(activeModel())
  local messageLabel = "messages: " .. tostring(#history)
  local providerWidth = math.max(108, ui.fonts.small:getWidth(providerLabel) + 22)
  local modelWidth = math.max(168, ui.fonts.small:getWidth(modelLabel) + 22)
  local messageWidth = math.max(118, ui.fonts.small:getWidth(messageLabel) + 22)
  drawPill(providerLabel, infoX, pillY, ui.palette.accent, providerWidth)
  drawPill(modelLabel, infoX + providerWidth + 10, pillY, ui.palette.muted, modelWidth)
  drawPill(messageLabel, infoX + providerWidth + modelWidth + 20, pillY, statusTone(), messageWidth)

  local buttonY = header.y + 20
  local buttonH = 34
  local gap = 10
  local clearW = 78
  local stopW = 78
  local providerW = 96
  local sendW = 96
  local startX = header.x + header.w - (sendW + stopW + clearW + providerW + gap * 3) - 20
  drawButton("Provider", startX, buttonY, providerW, buttonH, ui.palette.accent, openProviderConfig, false)
  drawButton("Clear", startX + providerW + gap, buttonY, clearW, buttonH, ui.palette.warn, clearConversation, false)
  drawButton("Stop", startX + providerW + clearW + gap * 2, buttonY, stopW, buttonH, ui.palette.danger, cancelCurrent, not isBusy())
  drawButton("Send", startX + providerW + clearW + stopW + gap * 3, buttonY, sendW, buttonH, ui.palette.success, sendPrompt, isBusy())
end

local function drawEmptyConversation(chat)
  love.graphics.setFont(ui.fonts.body)
  setColor(ui.palette.muted)
  love.graphics.printf(
    "No messages yet.\nType in the composer below and press Enter to send.\nUse Shift+Enter for a newline.",
    chat.x + 32,
    chat.y + 46,
    chat.w - 64,
    "center"
  )
end

local function drawConversation()
  local panel = ui.layout.chat
  drawPanel(panel.x, panel.y, panel.w, panel.h, ui.palette.panel)

  love.graphics.setFont(ui.fonts.heading)
  setColor(ui.palette.text)
  love.graphics.print("Conversation", panel.x + 18, panel.y + 14)
  love.graphics.setFont(ui.fonts.small)
  setColor(ui.palette.muted)
  love.graphics.print("All turns stay in one context until you clear the conversation.", panel.x + 18, panel.y + 40)

  local viewport = {
    x = panel.x + 14,
    y = panel.y + 68,
    w = panel.w - 28,
    h = panel.h - 82
  }

  local items, contentHeight = layoutMessages(viewport.w - 12)
  local maxScroll = math.max(0, contentHeight - viewport.h)
  if followLatest then
    conversationScroll = maxScroll
  else
    conversationScroll = clamp(conversationScroll, 0, maxScroll)
  end

  ui.chatState.x = viewport.x
  ui.chatState.y = viewport.y
  ui.chatState.w = viewport.w
  ui.chatState.h = viewport.h
  ui.chatState.contentHeight = contentHeight
  ui.chatState.maxScroll = maxScroll

  love.graphics.setScissor(viewport.x, viewport.y, viewport.w, viewport.h)
  if #items == 0 then
    drawEmptyConversation(viewport)
  else
    for index = 1, #items do
      local item = items[index]
      local drawX = viewport.x + item.x
      local drawY = viewport.y + item.y - conversationScroll
      if drawY + item.h >= viewport.y and drawY <= viewport.y + viewport.h then
        local fill = item.role == "user" and ui.palette.userFill or ui.palette.assistantFill
        local border = item.role == "user" and ui.palette.accent or ui.palette.border
        setColor(fill)
        love.graphics.rectangle("fill", drawX, drawY, item.w, item.h, 16, 16)
        setColor(border)
        love.graphics.rectangle("line", drawX, drawY, item.w, item.h, 16, 16)

        love.graphics.setFont(ui.fonts.small)
        setColor(item.role == "user" and ui.palette.accent or ui.palette.muted)
        local labelY = drawY + 10
        local labelLineHeight = ui.fonts.small:getHeight() + 2
        for lineIndex = 1, #item.labelLines do
          love.graphics.printf(
            item.labelLines[lineIndex],
            drawX + 14,
            labelY + (lineIndex - 1) * labelLineHeight,
            item.w - 28,
            item.role == "user" and "right" or "left"
          )
        end

        love.graphics.setFont(ui.fonts.body)
        setColor(ui.palette.text)
        local textY = drawY + 14 + item.labelHeight + 8
        love.graphics.printf(item.text, drawX + 14, textY, item.w - 28, "left")
      end
    end
  end
  love.graphics.setScissor()
  drawVerticalScrollbar(viewport.x, viewport.y, viewport.w, viewport.h, conversationScroll, contentHeight)
end

local function drawComposer()
  local composer = ui.layout.composer
  drawPanel(composer.x, composer.y, composer.w, composer.h, ui.palette.panelAlt)

  love.graphics.setFont(ui.fonts.heading)
  setColor(ui.palette.text)
  love.graphics.print("Composer", composer.x + 18, composer.y + 14)

  love.graphics.setFont(ui.fonts.small)
  setColor(ui.palette.muted)
  love.graphics.print("Enter: send   Shift+Enter: newline   F1: clear input   F2: clear chat   F3: provider config   Esc: quit", composer.x + 18, composer.y + 36)
  setColor(errorText ~= "" and ui.palette.danger or statusTone())
  love.graphics.print("status: " .. tostring(statusText ~= "" and statusText or "idle"), composer.x + 18, composer.y + 54)
  if errorText ~= "" then
    love.graphics.setFont(ui.fonts.small)
    setColor(ui.palette.danger)
    love.graphics.printf("error: " .. tostring(firstLine(errorText)), composer.x + 180, composer.y + 54, composer.w - 198, "left")
  end

  if inputBox then
    inputBox:draw({
      bg = ui.palette.panel,
      border = ui.palette.border,
      accent = ui.palette.accent,
      text = ui.palette.text,
      muted = ui.palette.muted,
      selection = { ui.palette.accent[1], ui.palette.accent[2], ui.palette.accent[3], 0.24 },
      cursor = ui.palette.accent,
      placeholder = ui.palette.muted
    })
  end
end

local function drawConfigField(name, label)
  local rect = configState.layout.fields[name]
  love.graphics.setFont(ui.fonts.small)
  setColor(ui.palette.muted)
  love.graphics.print(label, rect.x, rect.y - 16)
  configState.editors[name]:draw({
    bg = ui.palette.panel,
    border = ui.palette.border,
    accent = ui.palette.accent,
    text = ui.palette.text,
    muted = ui.palette.muted,
    selection = { ui.palette.accent[1], ui.palette.accent[2], ui.palette.accent[3], 0.24 },
    cursor = ui.palette.accent,
    placeholder = ui.palette.muted
  })
end

local function drawConfigModal()
  if not configState.isOpen then
    return
  end

  local modal = ui.layout.config
  setColor({ 0.02, 0.03, 0.05, 0.78 })
  love.graphics.rectangle("fill", 0, 0, ui.layout.screenWidth, ui.layout.screenHeight)
  drawPanel(modal.x, modal.y, modal.w, modal.h, ui.palette.panelAlt)

  love.graphics.setFont(ui.fonts.title)
  setColor(ui.palette.text)
  love.graphics.print("Provider Config", modal.x + 20, modal.y + 16)
  love.graphics.setFont(ui.fonts.small)
  setColor(ui.palette.muted)
  love.graphics.print("Save provider, base URL, model, token limit, and system prompt to the local LÖVE save directory.", modal.x + 22, modal.y + 42)

  local openaiTone = activeConfigProvider() == "openai" and ui.palette.accent or ui.palette.muted
  local anthropicTone = activeConfigProvider() == "anthropic" and ui.palette.accent or ui.palette.muted
  local providerButtons = configState.layout.providerButtons
  drawButton("OpenAI", providerButtons.openai.x, providerButtons.openai.y, providerButtons.openai.w, providerButtons.openai.h, openaiTone, function()
    selectConfigProvider("openai")
  end, false)
  drawButton("Anthropic", providerButtons.anthropic.x, providerButtons.anthropic.y, providerButtons.anthropic.w, providerButtons.anthropic.h, anthropicTone, function()
    selectConfigProvider("anthropic")
  end, false)

  drawConfigField("apiKey", "API Key")
  drawConfigField("baseUrl", "Base URL")
  drawConfigField("model", "Model")
  drawConfigField("maxTokens", "Max Tokens")
  drawConfigField("systemPrompt", "System Prompt")

  local actions = configState.layout.actions
  drawButton("Cancel", actions.cancel.x, actions.cancel.y, actions.cancel.w, actions.cancel.h, ui.palette.muted, closeProviderConfig, false)
  drawButton("Save", actions.save.x, actions.save.y, actions.save.w, actions.save.h, ui.palette.success, saveProviderConfig, false)
end

function love.load()
  love.graphics.setBackgroundColor(ui.palette.bg)

  ui.fonts.title = love.graphics.newFont(26)
  ui.fonts.heading = love.graphics.newFont(18)
  ui.fonts.body = love.graphics.newFont(15)
  ui.fonts.small = love.graphics.newFont(12)
  love.graphics.setFont(ui.fonts.body)

  inputBox = TextInput.new({
    text = "",
    placeholder = "Ask anything. This chat stays in one shared context until you clear it.",
    focused = true,
    softWrap = true,
    paddingX = 14,
    paddingY = 14,
    lineGap = 4
  })
  inputBox:setFont(ui.fonts.body)
  inputBox:focus()

  ensureConfigEditors()
  loadSettings()
  rebuildClients()

  if not clients.openai and not clients.anthropic then
    statusText = "provider config required"
    errorText = "click Provider to enter and save your API configuration"
  else
    statusText = "ready"
    errorText = ""
  end

  refreshLayout()
end

function love.update(dt)
  async.update(dt)
  refreshLayout()
end

function love.textinput(text)
  if configState.isOpen then
    for _, name in ipairs(configState.fieldOrder) do
      local editor = configState.editors[name]
      if editor and editor:textinput(text) then
        return
      end
    end
    return
  end
  if inputBox and inputBox:textinput(text) then
    return
  end
end

local function isEditorTextEntryKey(key)
  if type(key) ~= "string" or key == "" then
    return false
  end
  if #key == 1 then
    return true
  end
  if key == "space" then
    return true
  end
  if key:match("^kp%d$") then
    return true
  end
  return false
end

function love.keypressed(key)
  if configState.isOpen then
    local shift = love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
    local mod = love.keyboard.isDown("lgui") or love.keyboard.isDown("rgui") or love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")
    if key == "escape" then
      closeProviderConfig()
      statusText = "provider config closed"
      errorText = ""
      return
    end
    if mod and key == "s" then
      saveProviderConfig()
      return
    end
    if key == "tab" then
      focusNextConfigField(shift and -1 or 1)
      return
    end
    local focused = focusedConfigField()
    if (key == "return" or key == "kpenter") and focused and focused ~= "systemPrompt" then
      focusNextConfigField(1)
      return
    end
    for _, name in ipairs(configState.fieldOrder) do
      local editor = configState.editors[name]
      if editor and editor.focused and editor:keypressed(key) then
        return
      end
    end
    if isEditorTextEntryKey(key) then
      return
    end
  end

  local inputFocused = inputBox and inputBox.focused
  if key == "escape" then
    love.event.quit()
    return
  end
  if key == "return" or key == "kpenter" then
    local shift = love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
    if shift and inputBox and inputBox:keypressed(key) then
      return
    end
    sendPrompt()
    return
  end
  if inputFocused and inputBox and inputBox:keypressed(key) then
    return
  end
  if inputFocused and isEditorTextEntryKey(key) then
    return
  end
  if key == "f1" then
    if inputBox then
      inputBox:setText("")
      inputBox:focus()
    end
    statusText = "input cleared"
    errorText = ""
    return
  end
  if key == "f2" then
    clearConversation()
    return
  end
  if key == "f3" then
    openProviderConfig()
    return
  end
  if key == "c" then
    cancelCurrent()
    return
  end
end

function love.mousepressed(x, y, button)
  for index = #ui.hitboxes, 1, -1 do
    local hitbox = ui.hitboxes[index]
    if pointInRect(x, y, hitbox.x, hitbox.y, hitbox.w, hitbox.h) then
      hitbox.onClick()
      return
    end
  end
  if configState.isOpen then
    for _, name in ipairs(configState.fieldOrder) do
      local editor = configState.editors[name]
      if editor and editor:mousepressed(x, y, button) then
        return
      end
    end
    return
  end
  if inputBox and inputBox:mousepressed(x, y, button) then
    return
  end
end

function love.mousemoved(x, y)
  if configState.isOpen then
    for _, name in ipairs(configState.fieldOrder) do
      local editor = configState.editors[name]
      if editor then
        editor:mousemoved(x, y)
      end
    end
    return
  end
  if inputBox then
    inputBox:mousemoved(x, y)
  end
end

function love.mousereleased(x, y, button)
  if configState.isOpen then
    for _, name in ipairs(configState.fieldOrder) do
      local editor = configState.editors[name]
      if editor then
        editor:mousereleased(x, y, button)
      end
    end
    return
  end
  if inputBox then
    inputBox:mousereleased(x, y, button)
  end
end

function love.wheelmoved(dx, dy)
  if configState.isOpen then
    local mx, my = love.mouse.getPosition()
    for _, name in ipairs(configState.fieldOrder) do
      local editor = configState.editors[name]
      if editor and pointInRect(mx, my, editor.rect.x, editor.rect.y, editor.rect.w, editor.rect.h) then
        editor:wheelmoved(dx, dy)
        return
      end
    end
    return
  end
  local mx, my = love.mouse.getPosition()
  if inputBox and pointInRect(mx, my, inputBox.rect.x, inputBox.rect.y, inputBox.rect.w, inputBox.rect.h) then
    inputBox:wheelmoved(dx, dy)
    return
  end
  local chat = ui.chatState
  if pointInRect(mx, my, chat.x, chat.y, chat.w, chat.h) and chat.maxScroll > 0 then
    local step = (ui.fonts.body:getHeight() + 4) * 3
    conversationScroll = clamp(conversationScroll - dy * step, 0, chat.maxScroll)
    followLatest = conversationScroll >= chat.maxScroll - 4
  end
end

function love.draw()
  refreshLayout()
  resetHitboxes()

  setColor(ui.palette.bg)
  love.graphics.rectangle("fill", 0, 0, ui.layout.screenWidth, ui.layout.screenHeight)

  drawHeader()
  drawConversation()
  drawComposer()
  if configState.isOpen then
    resetHitboxes()
  end
  drawConfigModal()
end

function love.quit()
  destroyClients()
end
