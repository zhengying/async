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
local agent = require("agent")
local TextInput = require("love.ui_text_input")

local clients = {}
local currentProvider = "openai"
local currentTask = nil
local currentAgent = nil
local chat = nil
local inputBox = nil
local history = {}
local statusText = ""
local errorText = ""
local conversationScroll = 0
local followLatest = true
local pendingTurn = nil
local defaultSystemPrompt = "You are a helpful assistant in a single persistent chat context. Treat every message in the current conversation as active context unless the user clears the session."
local systemPrompt = os.getenv("CHAT_AGENT_SYSTEM_PROMPT") or defaultSystemPrompt
local settings = nil
local registry = agent.ToolRegistry.new()
local sessionState = {
  fileName = "chat_agent_session.json",
  loadedSnapshot = nil,
  loadedMessageStats = nil,
  copiedMessageIndex = nil,
  copiedAt = 0
}
local configState = {
  fileName = "chat_agent_config.json",
  isOpen = false,
  selectedProvider = "openai",
  editors = {},
  fieldOrder = { "apiKey", "baseUrl", "model", "maxTokens", "contextWindow", "systemPrompt" },
  layout = {}
}
local debugState = {
  isOpen = false,
  scroll = 0,
  lastPlanText = "",
  lastPlanError = "",
  lastMemoryError = "",
  lastGoal = "",
  lastAnswer = "",
  lastRoute = "none",
  viewer = {
    isOpen = false,
    title = "",
    text = "",
    rect = {
      x = 0,
      y = 0,
      w = 0,
      h = 0
    },
    copiedAt = 0,
    editor = nil
  },
  layout = {
    x = 0,
    y = 0,
    w = 0,
    h = 0,
    bodyHeight = 0,
    maxScroll = 0
  }
}
local logState = {
  entries = {},
  sequence = 0
}
local messageStats = {}

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

local function estimateTokenCount(text)
  local value = tostring(text or "")
  if value == "" then
    return 0
  end
  local normalized = value:gsub("\r\n", "\n")
  local chars = #normalized
  local words = 0
  for _ in normalized:gmatch("%S+") do
    words = words + 1
  end
  local byChars = math.ceil(chars / 4)
  local byWords = math.ceil(words * 1.35)
  return math.max(1, math.max(byChars, byWords))
end

local function normalizeUsage(usage)
  if type(usage) ~= "table" then
    return nil
  end
  local promptTokens = tonumber(usage.prompt_tokens or usage.input_tokens or usage.promptTokens or usage.inputTokens)
  local completionTokens = tonumber(usage.completion_tokens or usage.output_tokens or usage.completionTokens or usage.outputTokens)
  local totalTokens = tonumber(usage.total_tokens or usage.totalTokens)
  if not totalTokens then
    totalTokens = (promptTokens or 0) + (completionTokens or 0)
  end
  if not promptTokens and not completionTokens and not totalTokens then
    return nil
  end
  return {
    prompt = promptTokens,
    completion = completionTokens,
    total = totalTokens
  }
end

local function defaultProviderSettings(provider)
  if provider == "anthropic" then
    return {
      apiKey = os.getenv("ANTHROPIC_API_KEY") or "",
      baseUrl = os.getenv("ANTHROPIC_BASE_URL") or "https://api.anthropic.com",
      model = os.getenv("ANTHROPIC_MODEL") or "claude-3-5-sonnet-20241022",
      maxTokens = tostring(tonumber(os.getenv("ANTHROPIC_MAX_TOKENS") or "") or 1024),
      contextWindow = tostring(tonumber(os.getenv("ANTHROPIC_CONTEXT_WINDOW") or "") or 200000)
    }
  end
  return {
    apiKey = os.getenv("OPENAI_API_KEY") or "",
    baseUrl = os.getenv("OPENAI_BASE_URL") or "https://api.openai.com/v1",
    model = os.getenv("OPENAI_MODEL") or "gpt-4o-mini",
    maxTokens = tostring(tonumber(os.getenv("OPENAI_MAX_TOKENS") or "") or 1024),
    contextWindow = tostring(tonumber(os.getenv("OPENAI_CONTEXT_WINDOW") or "") or 128000)
  }
end

local function copyProviderSettings(value, fallback)
  local defaults = fallback or {}
  return {
    apiKey = tostring((value and value.apiKey) or defaults.apiKey or ""),
    baseUrl = tostring((value and value.baseUrl) or defaults.baseUrl or ""),
    model = tostring((value and value.model) or defaults.model or ""),
    maxTokens = tostring((value and value.maxTokens) or defaults.maxTokens or ""),
    contextWindow = tostring((value and value.contextWindow) or defaults.contextWindow or "")
  }
end

local function defaultLoggingSettings()
  return {
    enabled = tostring(os.getenv("CHAT_AGENT_LOG") or "") == "1",
    level = tostring(os.getenv("CHAT_AGENT_LOG_LEVEL") or "debug"),
    maxEntries = tonumber(os.getenv("CHAT_AGENT_LOG_MAX_ENTRIES") or "") or 200,
    maxPayloadChars = tonumber(os.getenv("CHAT_AGENT_LOG_MAX_PAYLOAD_CHARS") or "") or 4000,
    echoToConsole = tostring(os.getenv("CHAT_AGENT_LOG_ECHO") or "") == "1"
  }
end

local function copyLoggingSettings(value, fallback)
  local defaults = fallback or defaultLoggingSettings()
  return {
    enabled = value and value.enabled == true or defaults.enabled == true,
    level = tostring((value and value.level) or defaults.level or "debug"),
    maxEntries = tonumber((value and value.maxEntries) or defaults.maxEntries) or 200,
    maxPayloadChars = tonumber((value and value.maxPayloadChars) or defaults.maxPayloadChars) or 4000,
    echoToConsole = value and value.echoToConsole == true or defaults.echoToConsole == true
  }
end

local function buildDefaultSettings()
  return {
    selectedProvider = "openai",
    systemPrompt = os.getenv("CHAT_AGENT_SYSTEM_PROMPT") or defaultSystemPrompt,
    logging = copyLoggingSettings(nil, defaultLoggingSettings()),
    providers = {
      openai = copyProviderSettings(nil, defaultProviderSettings("openai")),
      anthropic = copyProviderSettings(nil, defaultProviderSettings("anthropic"))
    }
  }
end

local function normalizeSettings(value)
  local defaults = buildDefaultSettings()
  local normalized = {
    selectedProvider = tostring((value and value.selectedProvider) or defaults.selectedProvider),
    systemPrompt = tostring((value and value.systemPrompt) or defaults.systemPrompt),
    logging = copyLoggingSettings(value and value.logging, defaults.logging),
    providers = {
      openai = copyProviderSettings(value and value.providers and value.providers.openai, defaults.providers.openai),
      anthropic = copyProviderSettings(value and value.providers and value.providers.anthropic, defaults.providers.anthropic)
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

local activeClient
local activeModel
local rebuildAgentSession
local syncMessageStats
local currentLoggingSettings
local addLogEntry
local llmLogSink
local configureClientLogging
local applyLoggingConfig
local sanitizeUtf8Text
local formatRecentLogs

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

local function normalizeSavedSession(value)
  if type(value) ~= "table" then
    return nil
  end
  if type(value.snapshot) ~= "table" then
    return nil
  end
  return {
    snapshot = value.snapshot,
    debug = type(value.debug) == "table" and value.debug or nil,
    messageStats = type(value.messageStats) == "table" and value.messageStats or nil
  }
end

local function loadSessionState()
  if not love.filesystem or type(love.filesystem.getInfo) ~= "function" or not love.filesystem.getInfo(sessionState.fileName) then
    sessionState.loadedSnapshot = nil
    return
  end
  local data, err = love.filesystem.read(sessionState.fileName)
  if type(data) ~= "string" or data == "" then
    sessionState.loadedSnapshot = nil
    if err then
      errorText = "failed to read saved session: " .. tostring(err)
    end
    return
  end
  local ok, decoded = pcall(llm.jsonDecode, data)
  if not ok then
    sessionState.loadedSnapshot = nil
    errorText = "failed to parse saved session: " .. tostring(decoded)
    return
  end
  local normalized = normalizeSavedSession(decoded)
  if not normalized then
    sessionState.loadedSnapshot = nil
    errorText = "saved session has invalid format"
    return
  end
  sessionState.loadedSnapshot = normalized.snapshot
  sessionState.loadedMessageStats = normalized.messageStats
  if normalized.debug then
    debugState.lastPlanText = tostring(normalized.debug.lastPlanText or "")
    debugState.lastPlanError = tostring(normalized.debug.lastPlanError or "")
    debugState.lastMemoryError = tostring(normalized.debug.lastMemoryError or "")
    debugState.lastGoal = tostring(normalized.debug.lastGoal or "")
    debugState.lastAnswer = tostring(normalized.debug.lastAnswer or "")
    debugState.lastRoute = tostring(normalized.debug.lastRoute or "none")
  end
end

local function saveSessionState()
  if not love.filesystem or type(love.filesystem.write) ~= "function" then
    return false, "filesystem write is unavailable"
  end
  local snapshot = chat and chat:exportState({ includeMetadata = true }) or {
    history = {},
    sessionMemory = "",
    workspaceMemory = ""
  }
  local payload = {
    snapshot = snapshot,
    messageStats = messageStats,
    debug = {
      lastPlanText = debugState.lastPlanText,
      lastPlanError = debugState.lastPlanError,
      lastMemoryError = debugState.lastMemoryError,
      lastGoal = debugState.lastGoal,
      lastAnswer = debugState.lastAnswer,
      lastRoute = debugState.lastRoute
    }
  }
  local ok, encoded = pcall(llm.jsonEncode, payload)
  if not ok then
    return false, tostring(encoded)
  end
  local wrote, err = love.filesystem.write(sessionState.fileName, encoded)
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
  local snapshot = chat and chat:exportState({ includeMetadata = true }) or nil
  local logging = currentLoggingSettings()
  destroyClients()
  applyLoggingConfig()

  local openai = activeSettingsFor("openai")
  if trimText(openai.apiKey) ~= "" then
    clients.openai = llm.openai({
      apiKey = trimText(openai.apiKey),
      baseUrl = trimText(openai.baseUrl),
      model = trimText(openai.model),
      debug = logging.enabled,
      debugMaxLen = logging.maxPayloadChars,
      debugSink = llmLogSink,
      timeout = 120,
      poolSize = 4,
      httpsModule = "https"
    })
    configureClientLogging(clients.openai)
  end

  local anthropic = activeSettingsFor("anthropic")
  if trimText(anthropic.apiKey) ~= "" then
    clients.anthropic = llm.anthropic({
      apiKey = trimText(anthropic.apiKey),
      baseUrl = trimText(anthropic.baseUrl),
      model = trimText(anthropic.model),
      maxTokens = tonumber(trimText(anthropic.maxTokens)) or 1024,
      debug = logging.enabled,
      debugMaxLen = logging.maxPayloadChars,
      debugSink = llmLogSink,
      timeout = 120,
      poolSize = 4,
      httpsModule = "https"
    })
    configureClientLogging(clients.anthropic)
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
  addLogEntry("app", "info", "clients_rebuilt", {
    provider = currentProvider,
    openai = clients.openai ~= nil,
    anthropic = clients.anthropic ~= nil,
    logging = logging
  })
  rebuildAgentSession(snapshot)
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
  configState.editors.contextWindow:setText(providerSettings.contextWindow)
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
  providerSettings.contextWindow = trimText(configState.editors.contextWindow:getText())
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
  debugState.isOpen = false
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
  saveSessionState()
  closeProviderConfig()
  statusText = "provider config saved"
  errorText = ""
end

local CHAT_LOG_LEVELS = {
  off = 0,
  error = 1,
  warn = 2,
  info = 3,
  debug = 4,
  trace = 5
}

local CHAT_LOG_LEVEL_ORDER = { "error", "warn", "info", "debug", "trace" }

local function normalizeChatLogLevel(level)
  if type(level) == "number" then
    if level <= 0 then
      return "off"
    end
    for i = 1, #CHAT_LOG_LEVEL_ORDER do
      local name = CHAT_LOG_LEVEL_ORDER[i]
      if CHAT_LOG_LEVELS[name] == level then
        return name
      end
    end
    if level > CHAT_LOG_LEVELS.trace then
      return "trace"
    end
    return "info"
  end
  if type(level) == "string" then
    local name = string.lower(level)
    if CHAT_LOG_LEVELS[name] ~= nil then
      return name
    end
    local asNumber = tonumber(level)
    if asNumber ~= nil then
      return normalizeChatLogLevel(asNumber)
    end
  end
  return "info"
end

currentLoggingSettings = function()
  local state = settings or buildDefaultSettings()
  local logging = state.logging or defaultLoggingSettings()
  logging.level = normalizeChatLogLevel(logging.level)
  logging.maxEntries = clamp(math.floor(tonumber(logging.maxEntries) or 200), 20, 2000)
  logging.maxPayloadChars = clamp(math.floor(tonumber(logging.maxPayloadChars) or 4000), 200, 200000)
  logging.enabled = logging.enabled == true
  logging.echoToConsole = logging.echoToConsole == true
  return logging
end

local function redactLogText(value)
  local text = tostring(value or "")
  text = text:gsub("Bearer%s+[%w%-%._~+/=]+", "Bearer <redacted>")
  text = text:gsub('("apiKey"%s*:%s*")[^"]+(")', '%1<redacted>%2')
  text = text:gsub('("api_key"%s*:%s*")[^"]+(")', '%1<redacted>%2')
  text = text:gsub('("x%-api%-key"%s*:%s*")[^"]+(")', '%1<redacted>%2')
  text = text:gsub('("Authorization"%s*:%s*")Bearer [^"]+(")', '%1Bearer <redacted>%2')
  return text
end

sanitizeUtf8Text = function(value)
  local text = tostring(value or "")
  local out = {}
  local i = 1
  local len = #text

  local function pushByte(byte)
    out[#out + 1] = string.format("\\x%02X", byte)
  end

  local function isContinuation(byte)
    return byte and byte >= 0x80 and byte <= 0xBF
  end

  while i <= len do
    local b1 = text:byte(i)
    if not b1 then
      break
    end

    if b1 == 9 or b1 == 10 or b1 == 13 or (b1 >= 32 and b1 <= 126) then
      out[#out + 1] = string.char(b1)
      i = i + 1
    elseif b1 < 0x80 then
      pushByte(b1)
      i = i + 1
    elseif b1 >= 0xC2 and b1 <= 0xDF then
      local b2 = text:byte(i + 1)
      if isContinuation(b2) then
        out[#out + 1] = text:sub(i, i + 1)
        i = i + 2
      else
        pushByte(b1)
        i = i + 1
      end
    elseif b1 == 0xE0 then
      local b2 = text:byte(i + 1)
      local b3 = text:byte(i + 2)
      if b2 and b2 >= 0xA0 and b2 <= 0xBF and isContinuation(b3) then
        out[#out + 1] = text:sub(i, i + 2)
        i = i + 3
      else
        pushByte(b1)
        i = i + 1
      end
    elseif (b1 >= 0xE1 and b1 <= 0xEC) or (b1 >= 0xEE and b1 <= 0xEF) then
      local b2 = text:byte(i + 1)
      local b3 = text:byte(i + 2)
      if isContinuation(b2) and isContinuation(b3) then
        out[#out + 1] = text:sub(i, i + 2)
        i = i + 3
      else
        pushByte(b1)
        i = i + 1
      end
    elseif b1 == 0xED then
      local b2 = text:byte(i + 1)
      local b3 = text:byte(i + 2)
      if b2 and b2 >= 0x80 and b2 <= 0x9F and isContinuation(b3) then
        out[#out + 1] = text:sub(i, i + 2)
        i = i + 3
      else
        pushByte(b1)
        i = i + 1
      end
    elseif b1 == 0xF0 then
      local b2 = text:byte(i + 1)
      local b3 = text:byte(i + 2)
      local b4 = text:byte(i + 3)
      if b2 and b2 >= 0x90 and b2 <= 0xBF and isContinuation(b3) and isContinuation(b4) then
        out[#out + 1] = text:sub(i, i + 3)
        i = i + 4
      else
        pushByte(b1)
        i = i + 1
      end
    elseif b1 >= 0xF1 and b1 <= 0xF3 then
      local b2 = text:byte(i + 1)
      local b3 = text:byte(i + 2)
      local b4 = text:byte(i + 3)
      if isContinuation(b2) and isContinuation(b3) and isContinuation(b4) then
        out[#out + 1] = text:sub(i, i + 3)
        i = i + 4
      else
        pushByte(b1)
        i = i + 1
      end
    elseif b1 == 0xF4 then
      local b2 = text:byte(i + 1)
      local b3 = text:byte(i + 2)
      local b4 = text:byte(i + 3)
      if b2 and b2 >= 0x80 and b2 <= 0x8F and isContinuation(b3) and isContinuation(b4) then
        out[#out + 1] = text:sub(i, i + 3)
        i = i + 4
      else
        pushByte(b1)
        i = i + 1
      end
    else
      pushByte(b1)
      i = i + 1
    end
  end

  return table.concat(out)
end

local function clipText(value, maxChars)
  local text = sanitizeUtf8Text(value)
  local limit = tonumber(maxChars or 0) or 0
  if limit > 0 and #text > limit then
    return text:sub(1, limit) .. "..."
  end
  return text
end

local function safeJson(value)
  local ok, encoded = pcall(llm.jsonEncode, value)
  if ok and type(encoded) == "string" then
    return encoded
  end
  return tostring(encoded or value)
end

local function sanitizeLogPayload(value, maxChars)
  local payload = value
  if type(value) == "table" then
    payload = safeJson(value)
  end
  payload = redactLogText(payload)
  return clipText(sanitizeUtf8Text(payload), maxChars)
end

addLogEntry = function(source, level, event, fields)
  local logging = currentLoggingSettings()
  if not logging.enabled then
    return
  end

  local levelName = normalizeChatLogLevel(level)
  local threshold = CHAT_LOG_LEVELS[logging.level] or CHAT_LOG_LEVELS.info
  local levelValue = CHAT_LOG_LEVELS[levelName] or CHAT_LOG_LEVELS.info
  if levelValue > threshold then
    return
  end

  logState.sequence = logState.sequence + 1
  local entry = {
    id = logState.sequence,
    time = async.gettime(),
    source = tostring(source or "app"),
    level = levelName,
    event = tostring(event or "event"),
    payload = sanitizeLogPayload(fields or "", logging.maxPayloadChars)
  }
  logState.entries[#logState.entries + 1] = entry

  while #logState.entries > logging.maxEntries do
    table.remove(logState.entries, 1)
  end

  if logging.echoToConsole then
    local line = string.format("[chatAgent][%s][%s][%s] %s", tostring(entry.level), tostring(entry.source), tostring(entry.time), tostring(entry.event))
    if entry.payload ~= "" then
      line = line .. " " .. tostring(entry.payload)
    end
    print(line)
  end
end

llmLogSink = function(prefix, payload)
  local level = prefix == "response_error" and "error" or "debug"
  addLogEntry("llm", level, prefix, payload)
end

local function asyncLogSink(entry)
  if type(entry) ~= "table" then
    return
  end
  addLogEntry("async", entry.levelName or entry.level or "info", entry.event or "event", {
    task = entry.task,
    fields = entry.fields
  })
end

configureClientLogging = function(client)
  if type(client) ~= "table" then
    return
  end
  local logging = currentLoggingSettings()
  client.debug = logging.enabled
  client.debugMaxLen = logging.maxPayloadChars
  client.debugSink = logging.enabled and llmLogSink or nil
end

applyLoggingConfig = function()
  local logging = currentLoggingSettings()
  settings.logging = logging
  async.setLogLevel(logging.level)
  async.setLogSink(logging.enabled and asyncLogSink or nil)
  async.setLogEnabled(logging.enabled)
  for _, client in pairs(clients) do
    configureClientLogging(client)
  end
end

local function clearDebugLogs()
  logState.entries = {}
  logState.sequence = 0
end

local function cycleLoggingLevel()
  local logging = currentLoggingSettings()
  if logging.level == "off" then
    logging.level = "error"
  else
    local index = 1
    for i = 1, #CHAT_LOG_LEVEL_ORDER do
      if CHAT_LOG_LEVEL_ORDER[i] == logging.level then
        index = i
        break
      end
    end
    logging.level = CHAT_LOG_LEVEL_ORDER[(index % #CHAT_LOG_LEVEL_ORDER) + 1]
  end
  settings.logging = logging
  applyLoggingConfig()
  saveSettings()
  statusText = "logging level: " .. tostring(logging.level)
  errorText = ""
  addLogEntry("app", "info", "logging_level_changed", { level = logging.level })
end

local function toggleLogging()
  local logging = currentLoggingSettings()
  logging.enabled = not logging.enabled
  settings.logging = logging
  applyLoggingConfig()
  saveSettings()
  statusText = logging.enabled and ("logging enabled (" .. tostring(logging.level) .. ")") or "logging disabled"
  errorText = ""
  if logging.enabled then
    addLogEntry("app", "info", "logging_enabled", { level = logging.level })
  end
end

formatRecentLogs = function(maxEntries, maxChars)
  local total = #logState.entries
  if total == 0 then
    return "<empty>"
  end
  local count = math.min(total, tonumber(maxEntries or total) or total)
  local startIndex = total - count + 1
  local parts = {}
  for i = startIndex, total do
    local entry = logState.entries[i]
    parts[#parts + 1] = string.format("#%d [%.3f] [%s] [%s] %s", entry.id, tonumber(entry.time) or 0, tostring(entry.level), tostring(entry.source), tostring(entry.event))
    if entry.payload ~= "" then
      parts[#parts + 1] = tostring(entry.payload)
    end
    if i < total then
      parts[#parts + 1] = ""
    end
  end
  return clipText(table.concat(parts, "\n"), maxChars or 12000)
end

local function truncateText(value, maxChars)
  return clipText(value, maxChars)
end

local function syncHistoryFromSession()
  history = chat and chat:getHistory() or {}
end

local function restoreLoadedSession()
  if not chat or not sessionState.loadedSnapshot then
    return
  end
  local ok = pcall(function()
    chat:importState(sessionState.loadedSnapshot)
  end)
  if ok then
    syncHistoryFromSession()
  syncMessageStats()
  end
  if type(sessionState.loadedMessageStats) == "table" then
    messageStats = sessionState.loadedMessageStats
  end
  syncMessageStats()
  sessionState.loadedSnapshot = nil
  sessionState.loadedMessageStats = nil
end

local function normalizeMessageStat(stat, historyItem)
  local text = type(historyItem) == "table" and historyItem.content or ""
  local usage = type(stat) == "table" and normalizeUsage(stat.usage or stat) or nil
  return {
    estimatedTokens = tonumber(type(stat) == "table" and stat.estimatedTokens) or estimateTokenCount(text),
    usage = usage
  }
end

syncMessageStats = function()
  local normalized = {}
  for index = 1, #history do
    normalized[index] = normalizeMessageStat(messageStats[index], history[index])
  end
  messageStats = normalized
end

local function appendTurnStats(userText, answerText, usage)
  messageStats[#messageStats + 1] = {
    estimatedTokens = estimateTokenCount(userText),
    usage = nil
  }
  messageStats[#messageStats + 1] = {
    estimatedTokens = estimateTokenCount(answerText),
    usage = normalizeUsage(usage)
  }
  syncMessageStats()
end

local function currentContextWindow()
  local providerSettings = activeSettingsFor(currentProvider)
  local configured = tonumber(trimText(providerSettings.contextWindow))
  if configured and configured > 0 then
    return configured
  end
  return 128000
end

local function estimatedContextTokens()
  local total = estimateTokenCount(systemPrompt) + 12
  for index = 1, #history do
    local stat = messageStats[index]
    local item = history[index]
    total = total + (stat and stat.estimatedTokens or estimateTokenCount(item and item.content or "")) + 6
  end
  if pendingTurn and pendingTurn.goal then
    total = total + estimateTokenCount(pendingTurn.goal) + 6
  end
  return total
end

local function contextUsageLabel()
  local used = estimatedContextTokens()
  local maxWindow = currentContextWindow()
  return "ctx: " .. tostring(used) .. "/" .. tostring(maxWindow)
end

local function contextRemainLabel()
  local remain = math.max(0, currentContextWindow() - estimatedContextTokens())
  return "remain: " .. tostring(remain)
end

local function tokenLineForMessage(index, item)
  local stat = messageStats[index]
  local estimated = stat and stat.estimatedTokens or estimateTokenCount(item and item.content or "")
  local parts = { "tokens est " .. tostring(estimated) }
  local usage = stat and stat.usage or nil
  if usage and usage.completion then
    parts[#parts + 1] = "out " .. tostring(usage.completion)
  end
  if usage and usage.prompt then
    parts[#parts + 1] = "in " .. tostring(usage.prompt)
  end
  if usage and usage.total then
    parts[#parts + 1] = "total " .. tostring(usage.total)
  end
  return table.concat(parts, " • ")
end

local function currentRouteName(goal)
  if not chat then
    return "none"
  end
  local router = chat:getRouter()
  if type(router) ~= "table" or type(router.select) ~= "function" then
    return "none"
  end
  local _, routeName = router:select(goal or "", "run", {
    session = chat,
    history = chat:getHistory(),
    memory = chat:getMemory(),
    profile = chat:getProfile()
  })
  return tostring(routeName or "none")
end

rebuildAgentSession = function(snapshot)
  local client = activeClient()
  if not client then
    currentAgent = nil
    chat = nil
    history = {}
    return
  end

  currentAgent = agent.Agent.new({
    client = client,
    registry = registry,
    system = systemPrompt,
    withPlan = true,
    maxSteps = 8,
    temperature = 0.3,
    maxHistoryMessages = 8,
    maxHistorySummaryChars = 1200
  })

  chat = agent.Session.new({
    agent = currentAgent,
    profile = agent.SceneProfile.new({
      name = "chat_agent_debug",
      instructions = {
        "Keep answers grounded in the ongoing session.",
        "Prefer memory and prior turns before making new assumptions."
      },
      constraints = {
        "Do not claim memory that is not present in the current session state.",
        "If something is unknown, say so plainly."
      },
      planGuidelines = {
        "Prefer short plans.",
        "Use memory before global assumptions."
      }
    }),
    memory = "Session strategy: keep multi-turn context and preserve durable user facts across this chat.",
    memoryStore = agent.MemoryStore.new({
      facts = {
        "This chat demo is used to test the agent runtime."
      },
      goals = {
        "Expose memory behavior and debug state clearly."
      }
    }),
    workspaceMemory = "Workspace strategy: keep stable repository context that helps explain this async and agent demo.",
    workspaceMemoryStore = agent.MemoryStore.new({
      facts = {
        "The repository demonstrates async Lua primitives, LLM clients, and agent patterns."
      },
      goals = {
        "Support interactive debugging of planning and memory behavior."
      }
    }),
    memoryExtractor = agent.MemoryExtractor.new({
      client = client,
      scopes = { "session", "workspace" },
      maxHistoryMessages = 6,
      maxHistoryChars = 220
    }),
    maxPlanningHistoryMessages = 8,
    maxPlanningHistoryChars = 240
  })

  if snapshot then
    pcall(function()
      chat:importState(snapshot)
    end)
  end
  syncHistoryFromSession()
  restoreLoadedSession()
end

local function debugSections()
  local sections = {}
  local sessionState = chat and chat:exportState({ includeMetadata = true }) or nil
  local sessionStore = chat and chat:getMemoryStore() or nil
  local workspaceStore = chat and chat:getMemoryStore("workspace") or nil
  local profile = chat and chat:getProfile() or nil
  local extractor = chat and chat:getMemoryExtractor() or nil
  local logging = currentLoggingSettings()

  sections[#sections + 1] = {
    title = "Default Strategy",
    text = table.concat({
      "Current demo mode: agent.Session",
      "History strategy: session history is appended turn by turn and passed through Session:ask.",
      "Durable memory: session memory + session MemoryStore.",
      "Workspace memory: workspace memory + workspace MemoryStore.",
      "Extraction strategy: MemoryExtractor runs after each successful assistant answer.",
      "Extractor scopes: session, workspace.",
      "Planning: enabled before run with bounded recent history.",
      "Router: " .. currentRouteName(debugState.lastGoal),
      "Profile: " .. tostring(profile and profile.name or "none"),
      "Memory extractor: " .. tostring(extractor ~= nil)
    }, "\n")
  }

  sections[#sections + 1] = {
    title = "Metrics",
    text = table.concat({
      "provider: " .. tostring(currentProvider),
      "model: " .. tostring(activeModel()),
      "history turns: " .. tostring(#history),
      "pending turn: " .. tostring(pendingTurn ~= nil),
      "logging: " .. (logging.enabled and ("on (" .. tostring(logging.level) .. ")") or "off"),
      "log entries: " .. tostring(#logState.entries),
      "last route: " .. tostring(debugState.lastRoute or "none"),
      "plan status: " .. (debugState.lastPlanText ~= "" and "available" or (debugState.lastPlanError ~= "" and "error" or "empty")),
      "memory error: " .. (debugState.lastMemoryError ~= "" and debugState.lastMemoryError or "<none>"),
      "maxPlanningHistoryMessages: " .. tostring(sessionState and sessionState.metadata and sessionState.metadata.maxPlanningHistoryMessages or "n/a"),
      "maxPlanningHistoryChars: " .. tostring(sessionState and sessionState.metadata and sessionState.metadata.maxPlanningHistoryChars or "n/a")
    }, "\n")
  }

  sections[#sections + 1] = {
    title = "Recent History",
    text = #history > 0 and truncateText(safeJson(history), 6000) or "<empty>"
  }

  sections[#sections + 1] = {
    title = "Session Memory",
    text = chat and (chat:getMemory() or "<empty>") or "<no session>"
  }

  sections[#sections + 1] = {
    title = "Session MemoryStore",
    text = sessionStore and safeJson(sessionStore:exportState()) or "<empty>"
  }

  sections[#sections + 1] = {
    title = "Workspace Memory",
    text = chat and (chat:getMemory("workspace") or "<empty>") or "<no session>"
  }

  sections[#sections + 1] = {
    title = "Workspace MemoryStore",
    text = workspaceStore and safeJson(workspaceStore:exportState()) or "<empty>"
  }

  sections[#sections + 1] = {
    title = "Last Plan",
    text = debugState.lastPlanText ~= "" and debugState.lastPlanText or (debugState.lastPlanError ~= "" and ("plan error: " .. debugState.lastPlanError) or "<empty>")
  }

  sections[#sections + 1] = {
    title = "Logging",
    text = table.concat({
      "enabled: " .. tostring(logging.enabled),
      "level: " .. tostring(logging.level),
      "maxEntries: " .. tostring(logging.maxEntries),
      "maxPayloadChars: " .. tostring(logging.maxPayloadChars),
      "echoToConsole: " .. tostring(logging.echoToConsole),
      "shortcuts: F5 toggle, F6 level, F7 clear"
    }, "\n")
  }

  sections[#sections + 1] = {
    title = "Recent Logs",
    text = formatRecentLogs(80, 16000)
  }

  sections[#sections + 1] = {
    title = "Last Turn",
    text = table.concat({
      "goal:",
      debugState.lastGoal ~= "" and debugState.lastGoal or "<empty>",
      "",
      "answer:",
      debugState.lastAnswer ~= "" and debugState.lastAnswer or "<empty>"
    }, "\n")
  }

  return sections
end

local function openDebugPanel()
  debugState.isOpen = true
  debugState.scroll = 0
  configState.isOpen = false
  statusText = "agent debug panel opened"
  errorText = ""
end

local function ensureDebugViewerEditor()
  if debugState.viewer.editor then
    return debugState.viewer.editor
  end
  local editor = TextInput.new({
    text = "",
    placeholder = "Debug text",
    focused = false,
    softWrap = true,
    paddingX = 14,
    paddingY = 14,
    lineGap = 4
  })
  if ui.fonts and ui.fonts.body then
    editor:setFont(ui.fonts.body)
  end
  debugState.viewer.editor = editor
  return editor
end

local function closeDebugTextViewer()
  debugState.viewer.isOpen = false
  if debugState.viewer.editor then
    debugState.viewer.editor:blur()
  end
end

local function copyTextToClipboard(text, successLabel)
  if not love.system or type(love.system.setClipboardText) ~= "function" then
    statusText = "clipboard unavailable"
    errorText = ""
    return false
  end
  love.system.setClipboardText(tostring(text or ""))
  statusText = successLabel or "copied"
  errorText = ""
  return true
end

local function logsClipboardText()
  local logging = currentLoggingSettings()
  return formatRecentLogs(logging.maxEntries, math.max(16000, logging.maxPayloadChars * logging.maxEntries))
end

local function openDebugTextViewer(title, text)
  local editor = ensureDebugViewerEditor()
  local content = sanitizeUtf8Text(text)
  debugState.viewer.isOpen = true
  debugState.viewer.title = tostring(title or "Viewer")
  debugState.viewer.text = content
  editor:setText(content)
  editor:focus()
  editor:selectAll()
  statusText = tostring(title or "viewer") .. " opened"
  errorText = ""
end

local function closeDebugPanel()
  debugState.isOpen = false
  closeDebugTextViewer()
  if inputBox then
    inputBox:focus()
  end
end

local function copyMessageText(item, index)
  if not item or item.text == "" then
    statusText = "nothing to copy"
    errorText = ""
    return
  end
  if not love.system or type(love.system.setClipboardText) ~= "function" then
    statusText = "clipboard unavailable"
    errorText = ""
    return
  end
  love.system.setClipboardText(item.text)
  sessionState.copiedMessageIndex = index
  sessionState.copiedAt = love.timer and love.timer.getTime and love.timer.getTime() or 0
  statusText = "message copied"
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
  configState.editors.contextWindow = createConfigEditor("Context window", false)
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

activeClient = function()
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

activeModel = function()
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
  if chat then
    chat:clear()
  end
  history = {}
  messageStats = {}
  pendingTurn = nil
  debugState.lastPlanText = ""
  debugState.lastPlanError = ""
  debugState.lastMemoryError = ""
  debugState.lastGoal = ""
  debugState.lastAnswer = ""
  debugState.lastRoute = "none"
  statusText = "conversation cleared"
  errorText = ""
  followLatest = true
  saveSessionState()
end

cancelCurrent = function()
  if not currentTask then
    return
  end
  addLogEntry("app", "warn", "request_cancel", {
    provider = currentProvider,
    pendingTurn = pendingTurn
  })
  if type(currentTask.cancel) == "function" then
    currentTask:cancel()
  else
    currentTask:stop()
  end
  pendingTurn = nil
  statusText = "stopped"
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

local function formatRequestError(err, extra)
  local message = tostring(err or "request failed")
  if type(extra) == "table" and type(extra.body) == "string" then
    local bodyLine = trimText(firstLine(extra.body))
    if bodyLine ~= "" and not message:find(bodyLine, 1, true) then
      message = message .. " | " .. truncateText(bodyLine, 180)
    end
  end
  return message
end

local function shouldRetryWithRawChat(err, extra)
  local statusCode = type(extra) == "table" and tonumber(extra.status) or 0
  if statusCode == 400 then
    return true
  end
  local text = tostring(err or "")
  if text:find("json decode failed", 1, true) ~= nil then
    return true
  end
  if text:find("plan parse failed", 1, true) ~= nil then
    return true
  end
  if text:find("memory extract parse failed", 1, true) ~= nil then
    return true
  end
  if text:find("max steps reached", 1, true) ~= nil then
    return true
  end
  if text:find("tool stopped", 1, true) ~= nil then
    return true
  end
  return false
end

local function runRawChatFallback(prompt, provider, providerSettings, callbacks)
  callbacks = callbacks or {}
  local client = activeClient()
  if not client then
    addLogEntry("app", "error", "fallback_unavailable", {
      provider = provider,
      reason = "no client"
    })
    return nil, "no client", nil
  end
  local messages = buildMessages(provider)
  messages[#messages + 1] = {
    role = "user",
    content = prompt
  }
  local request = {
    model = activeModel(),
    messages = messages,
    temperature = 0.5,
    timeout = 120,
    max_tokens = tonumber(trimText(providerSettings.maxTokens)),
    stream = true,
    onText = callbacks.onText,
    onResponse = callbacks.onResponse,
    onChunk = callbacks.onChunk,
    onEvent = callbacks.onEvent
  }
  if provider == "anthropic" then
    request.system = systemPrompt
    request.max_tokens = tonumber(trimText(providerSettings.maxTokens)) or 1024
  end
  addLogEntry("app", "warn", "fallback_begin", {
    provider = provider,
    model = request.model,
    promptChars = #prompt,
    historyTurns = #history
  })
  return async.await(client:chat(request))
end

local function sendPrompt()
  if not chat or not currentAgent then
    statusText = "no agent session"
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
  local model = activeModel()
  pendingTurn = {
    goal = prompt,
    provider = provider,
    model = model,
    answer = "",
    step = "planning"
  }
  debugState.lastGoal = prompt
  debugState.lastAnswer = ""
  debugState.lastPlanText = ""
  debugState.lastPlanError = ""
  debugState.lastMemoryError = ""
  debugState.lastRoute = currentRouteName(prompt)
  if inputBox and inputBox.setText then
    inputBox:setText("")
    inputBox:focus()
  end
  statusText = "planning + running..."
  errorText = ""
  followLatest = true
  local providerSettings = activeSettingsFor(provider)
  addLogEntry("app", "info", "prompt_submit", {
    provider = provider,
    model = model,
    promptChars = #prompt,
    promptPreview = truncateText(prompt, 240),
    historyTurns = #history
  })

  currentTask = async(function()
    addLogEntry("app", "debug", "plan_begin", {
      provider = provider,
      model = model,
      timeout = 120
    })
    local plan, planErr = async.await(chat:plan(prompt, {
      timeout = 120,
      max_tokens = tonumber(trimText(providerSettings.maxTokens))
    }))
    if type(plan) == "table" then
      debugState.lastPlanText = safeJson(plan)
      debugState.lastPlanError = ""
      addLogEntry("app", "info", "plan_success", {
        provider = provider,
        steps = #plan
      })
    else
      debugState.lastPlanText = ""
      debugState.lastPlanError = planErr and tostring(planErr) or ""
      addLogEntry("app", "warn", "plan_failed", {
        provider = provider,
        error = planErr
      })
    end

    addLogEntry("app", "debug", "ask_begin", {
      provider = provider,
      model = model,
      hasPlan = type(plan) == "table",
      timeout = 120
    })
    local result, err, extra = async.await(chat:ask(prompt, {
      timeout = 120,
      withPlan = false,
      plan = plan,
      max_tokens = tonumber(trimText(providerSettings.maxTokens)),
      stream = true,
      onText = function(_, text, meta)
        if not pendingTurn then
          return
        end
        pendingTurn.answer = tostring(text or "")
        pendingTurn.step = "streaming"
        debugState.lastAnswer = pendingTurn.answer
        statusText = "streaming..."
        errorText = ""
        followLatest = true
        addLogEntry("app", "debug", "stream_text", {
          provider = provider,
          model = model,
          chars = #pendingTurn.answer,
          step = type(meta) == "table" and meta.step or nil
        })
      end
    }))

    currentTask = nil

    if type(result) ~= "table" then
      addLogEntry("app", "warn", "ask_failed", {
        provider = provider,
        model = model,
        error = err,
        extra = extra
      })
      if shouldRetryWithRawChat(err, extra) then
        if pendingTurn then
          pendingTurn.answer = ""
          pendingTurn.step = "fallback"
        end
        local fallbackResult, fallbackErr, fallbackExtra = runRawChatFallback(prompt, provider, providerSettings, {
          onText = function(_, text)
            if not pendingTurn then
              return
            end
            pendingTurn.answer = tostring(text or "")
            pendingTurn.step = "fallback"
            debugState.lastAnswer = pendingTurn.answer
            statusText = "streaming fallback..."
            errorText = ""
            followLatest = true
          end
        })
        if type(fallbackResult) == "table" then
          local reply = tostring(fallbackResult.text or "")
          if reply == "" then
            reply = "<empty response>"
          end
          addLogEntry("app", "info", "fallback_success", {
            provider = provider,
            model = model,
            replyChars = #reply,
            usage = fallbackResult.usage
          })
          chat:add("user", prompt)
          chat:add("assistant", reply)
          local _, memoryErr = async.await(chat:runMemoryExtraction(prompt, reply, {
            history = chat:getHistory()
          }))
          debugState.lastMemoryError = memoryErr and tostring(memoryErr) or ""
          if memoryErr ~= nil then
            addLogEntry("app", "warn", "fallback_memory_error", {
              provider = provider,
              error = memoryErr
            })
          end
          debugState.lastAnswer = reply
          syncHistoryFromSession()
          appendTurnStats(prompt, reply, fallbackResult.usage)
          saveSessionState()
          statusText = "ok via raw fallback (" .. tostring(provider) .. " / " .. tostring(model) .. ")"
          errorText = ""
          return
        end
        addLogEntry("app", "error", "fallback_failed", {
          provider = provider,
          model = model,
          error = fallbackErr,
          extra = fallbackExtra
        })
        err = fallbackErr or err
        extra = fallbackExtra or extra
      end

      local statusCode = type(extra) == "table" and extra.status or 0
      statusText = "failed (status: " .. tostring(statusCode) .. ")"
      errorText = formatRequestError(err, extra)
      pendingTurn = nil
      syncHistoryFromSession()
      saveSessionState()
      return
    end

    debugState.lastMemoryError = tostring(result.memoryError or "")
    addLogEntry("app", "info", "ask_success", {
      provider = provider,
      model = model,
      replyChars = #(tostring(result.text or "")),
      usage = result.raw and result.raw.usage or nil,
      memoryError = result.memoryError
    })
    debugState.lastAnswer = tostring(result.text or "")
    syncHistoryFromSession()
    appendTurnStats(prompt, result.text or "", result.raw and result.raw.usage or nil)
    saveSessionState()
    statusText = "ok (" .. tostring(provider) .. " / " .. tostring(model) .. ")"
    errorText = ""
    pendingTurn = nil
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
  local footerLineHeight = ui.fonts.small:getHeight() + 2
  local cursorY = 6

  local function pushItem(role, text, provider, model, isPending, historyIndex)
    local content = tostring(text or "")
    local maxTextWidth = bubbleMaxWidth - bubblePaddingX * 2
    local lines = wrappedLines(ui.fonts.body, content, maxTextWidth)
    local bubbleWidth = computeBubbleWidth(lines, bubbleMinWidth, bubbleMaxWidth)
    local textWidth = bubbleWidth - bubblePaddingX * 2
    lines = wrappedLines(ui.fonts.body, content, textWidth)
    local copyEnabled = not isPending and content ~= ""
    local copyButtonW = copyEnabled and 48 or 0
    local labelTextWidth = math.max(80, textWidth - (copyEnabled and (copyButtonW + 8) or 0))
    local label = role == "user" and "You" or "Assistant"
    if provider and provider ~= "" then
      label = label .. " • " .. tostring(provider)
    end
    if model and model ~= "" then
      label = label .. " • " .. tostring(model)
    end
    if isPending then
      label = label .. " • " .. tostring((pendingTurn and pendingTurn.step) or "waiting")
    end
    local labelLines = wrappedLines(ui.fonts.small, label, labelTextWidth)
    local labelHeight = #labelLines * metaLineHeight
    local tokenLine = isPending and "tokens pending" or tokenLineForMessage(historyIndex, { content = content })
    local bubbleHeight = bubblePaddingY * 2 + labelHeight + 8 + #lines * lineHeight + 10 + footerLineHeight
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
      labelHeight = labelHeight,
      copyEnabled = copyEnabled,
      copyButtonW = copyButtonW,
      tokenLine = tokenLine
    }
    cursorY = cursorY + bubbleHeight + 16
  end

  for index = 1, #history do
    local item = history[index]
    pushItem(item.role, item.content, item.provider, item.model, false, index)
  end

  if pendingTurn and pendingTurn.goal then
    pushItem("user", pendingTurn.goal, pendingTurn.provider, pendingTurn.model, false, #history + 1)
  end

  if isBusy() then
    local pendingText = pendingTurn and trimText(pendingTurn.answer) or ""
    if pendingText == "" then
      pendingText = "Thinking..."
    end
    pushItem("assistant", pendingText, currentProvider, activeModel(), true, #history + 2)
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
    },
    debug = {
      w = math.min(fullWidth - 20, 980),
      h = math.min(screenHeight - 60, 760)
    }
  }

  ui.layout.config.x = math.floor((screenWidth - ui.layout.config.w) / 2)
  ui.layout.config.y = math.floor((screenHeight - ui.layout.config.h) / 2)
  ui.layout.debug.x = math.floor((screenWidth - ui.layout.debug.w) / 2)
  ui.layout.debug.y = math.floor((screenHeight - ui.layout.debug.h) / 2)
  debugState.layout.x = ui.layout.debug.x
  debugState.layout.y = ui.layout.debug.y
  debugState.layout.w = ui.layout.debug.w
  debugState.layout.h = ui.layout.debug.h

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
      maxTokens = { x = fieldX, y = cursorY + (48 + labelGap + fieldGap) * 3, w = fieldW, h = 48 },
      contextWindow = { x = fieldX, y = cursorY + (48 + labelGap + fieldGap) * 4, w = fieldW, h = 48 }
    }
    local promptY = configState.layout.fields.contextWindow.y + 48 + labelGap + fieldGap
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
  local contextLabel = contextUsageLabel()
  local providerWidth = math.max(108, ui.fonts.small:getWidth(providerLabel) + 22)
  local modelWidth = math.max(168, ui.fonts.small:getWidth(modelLabel) + 22)
  local messageWidth = math.max(118, ui.fonts.small:getWidth(messageLabel) + 22)
  local contextWidth = math.max(148, ui.fonts.small:getWidth(contextLabel) + 22)
  drawPill(providerLabel, infoX, pillY, ui.palette.accent, providerWidth)
  drawPill(modelLabel, infoX + providerWidth + 10, pillY, ui.palette.muted, modelWidth)
  drawPill(messageLabel, infoX + providerWidth + modelWidth + 20, pillY, statusTone(), messageWidth)
  drawPill(contextLabel, infoX + providerWidth + modelWidth + messageWidth + 30, pillY, ui.palette.warn, contextWidth)

  local buttonY = header.y + 20
  local buttonH = 34
  local gap = 10
  local debugW = 84
  local clearW = 78
  local stopW = 78
  local providerW = 96
  local sendW = 96
  local startX = header.x + header.w - (sendW + stopW + clearW + providerW + debugW + gap * 4) - 20
  drawButton("Provider", startX, buttonY, providerW, buttonH, ui.palette.accent, openProviderConfig, false)
  drawButton("Debug", startX + providerW + gap, buttonY, debugW, buttonH, ui.palette.muted, openDebugPanel, false)
  drawButton("Clear", startX + providerW + debugW + gap * 2, buttonY, clearW, buttonH, ui.palette.warn, clearConversation, false)
  drawButton("Stop", startX + providerW + debugW + clearW + gap * 3, buttonY, stopW, buttonH, ui.palette.danger, cancelCurrent, not isBusy())
  drawButton("Send", startX + providerW + debugW + clearW + stopW + gap * 4, buttonY, sendW, buttonH, ui.palette.success, sendPrompt, isBusy())
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
            item.w - 28 - (item.copyEnabled and (item.copyButtonW + 8) or 0),
            item.role == "user" and "right" or "left"
          )
        end

        if item.copyEnabled then
          local messageIndex = index
          local copyX = drawX + item.w - item.copyButtonW - 12
          local copyY = drawY + 10
          local recentlyCopied = sessionState.copiedMessageIndex == messageIndex and (love.timer and love.timer.getTime and (love.timer.getTime() - sessionState.copiedAt) or 99) < 1.8
          local copyTone = recentlyCopied and ui.palette.success or ui.palette.muted
          drawButton(recentlyCopied and "Copied" or "Copy", copyX, copyY, item.copyButtonW, 22, copyTone, function()
            copyMessageText(item, messageIndex)
          end, false)
        end

        love.graphics.setFont(ui.fonts.body)
        setColor(ui.palette.text)
        local textY = drawY + 14 + item.labelHeight + 8
        local bodyLineHeight = ui.fonts.body:getHeight() + 4
        for lineIndex = 1, #item.lines do
          love.graphics.print(item.lines[lineIndex], drawX + 14, textY + (lineIndex - 1) * bodyLineHeight)
        end
        love.graphics.setFont(ui.fonts.small)
        setColor(ui.palette.muted)
        love.graphics.printf(item.tokenLine, drawX + 14, drawY + item.h - 18 - ui.fonts.small:getHeight(), item.w - 28, item.role == "user" and "right" or "left")
      end
    end
  end
  love.graphics.setScissor()
  drawVerticalScrollbar(viewport.x, viewport.y, viewport.w, viewport.h, conversationScroll, contentHeight)
end

local function drawComposer()
  local composer = ui.layout.composer
  local logging = currentLoggingSettings()
  drawPanel(composer.x, composer.y, composer.w, composer.h, ui.palette.panelAlt)

  love.graphics.setFont(ui.fonts.heading)
  setColor(ui.palette.text)
  love.graphics.print("Composer", composer.x + 18, composer.y + 14)

  love.graphics.setFont(ui.fonts.small)
  setColor(ui.palette.muted)
  love.graphics.print("Enter: send   Shift+Enter: newline   F1: clear input   F2: clear chat   F3: provider config   F4: agent debug   F5: logs on/off   F6: log level   F7: clear logs   Esc: quit", composer.x + 18, composer.y + 36)
  local statusX = composer.x + 18
  local statusY = composer.y + 54
  local statusGap = 18
  local rightInfoWidth = math.min(220, math.floor(composer.w * 0.26))
  local statusWidth = composer.w - 36 - rightInfoWidth - statusGap
  setColor(errorText ~= "" and ui.palette.danger or statusTone())
  love.graphics.printf("status: " .. tostring(statusText ~= "" and statusText or "idle"), statusX, statusY, statusWidth, "left")
  if errorText ~= "" then
    love.graphics.setFont(ui.fonts.small)
    setColor(ui.palette.danger)
    love.graphics.printf("error: " .. tostring(firstLine(errorText)), composer.x + composer.w - 18 - rightInfoWidth, statusY, rightInfoWidth, "right")
  else
    setColor(ui.palette.muted)
    love.graphics.printf(contextRemainLabel() .. " | logs: " .. (logging.enabled and logging.level or "off"), composer.x + composer.w - 18 - rightInfoWidth, statusY, rightInfoWidth, "right")
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

local function measureWrappedText(text, width)
  local displayText = sanitizeUtf8Text(text)
  local _, wrapped = ui.fonts.body:getWrap(displayText, width)
  return math.max(1, #wrapped) * (ui.fonts.body:getHeight() + 3)
end

local function drawWrappedText(text, x, y, width, color)
  local displayText = sanitizeUtf8Text(text)
  love.graphics.setFont(ui.fonts.body)
  setColor(color or ui.palette.text)
  love.graphics.printf(displayText, x, y, width, "left")
  return measureWrappedText(displayText, width)
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
  drawConfigField("contextWindow", "Context Window")
  drawConfigField("systemPrompt", "System Prompt")

  local actions = configState.layout.actions
  drawButton("Cancel", actions.cancel.x, actions.cancel.y, actions.cancel.w, actions.cancel.h, ui.palette.muted, closeProviderConfig, false)
  drawButton("Save", actions.save.x, actions.save.y, actions.save.w, actions.save.h, ui.palette.success, saveProviderConfig, false)
end

local function drawDebugModal()
  if not debugState.isOpen then
    return
  end

  local modal = debugState.layout
  local bodyX = modal.x + 20
  local bodyY = modal.y + 106
  local bodyW = modal.w - 40
  local bodyH = modal.h - 132
  local sections = debugSections()
  local contentHeight = 0

  for index = 1, #sections do
    local section = sections[index]
    contentHeight = contentHeight + 22 + measureWrappedText(section.text, bodyW - 18) + 18
  end

  debugState.layout.bodyHeight = contentHeight
  debugState.layout.maxScroll = math.max(0, contentHeight - bodyH)
  debugState.scroll = clamp(debugState.scroll, 0, debugState.layout.maxScroll)

  setColor({ 0.02, 0.03, 0.05, 0.82 })
  love.graphics.rectangle("fill", 0, 0, ui.layout.screenWidth, ui.layout.screenHeight)
  drawPanel(modal.x, modal.y, modal.w, modal.h, ui.palette.panelAlt)

  love.graphics.setFont(ui.fonts.title)
  setColor(ui.palette.text)
  love.graphics.print("Agent Debug", modal.x + 20, modal.y + 16)
  love.graphics.setFont(ui.fonts.small)
  setColor(ui.palette.muted)
  love.graphics.print("Visualize planning, memory strategy, extracted durable memory, and raw session state.", modal.x + 22, modal.y + 42)

  local pillY = modal.y + 68
  drawPill("mode: agent.Session", modal.x + 22, pillY, ui.palette.accent, 152)
  drawPill("plan: on", modal.x + 184, pillY, ui.palette.success, 92)
  drawPill("extractor: on", modal.x + 286, pillY, ui.palette.warn, 118)
  drawPill("route: " .. tostring(debugState.lastRoute or "none"), modal.x + 414, pillY, ui.palette.muted, 148)
  drawButton("Copy Logs", modal.x + modal.w - 324, modal.y + 20, 92, 34, ui.palette.accent, function()
    if copyTextToClipboard(logsClipboardText(), "logs copied") then
      debugState.viewer.copiedAt = love.timer and love.timer.getTime and love.timer.getTime() or 0
    end
  end, false)
  drawButton("Select Logs", modal.x + modal.w - 224, modal.y + 20, 100, 34, ui.palette.success, function()
    openDebugTextViewer("Recent Logs", logsClipboardText())
  end, false)
  drawButton("Close", modal.x + modal.w - 108, modal.y + 20, 84, 34, ui.palette.muted, closeDebugPanel, false)

  love.graphics.setScissor(bodyX, bodyY, bodyW, bodyH)
  local cursorY = bodyY - debugState.scroll
  for index = 1, #sections do
    local section = sections[index]
    love.graphics.setFont(ui.fonts.heading)
    setColor(ui.palette.text)
    love.graphics.print(section.title, bodyX, cursorY)
    cursorY = cursorY + 22
    cursorY = cursorY + drawWrappedText(section.text, bodyX, cursorY, bodyW - 18, ui.palette.muted) + 18
  end
  love.graphics.setScissor()
  drawVerticalScrollbar(bodyX, bodyY, bodyW, bodyH, debugState.scroll, contentHeight)

  if debugState.viewer.isOpen then
    local viewer = debugState.viewer
    local viewerX = modal.x + 36
    local viewerY = modal.y + 88
    local viewerW = modal.w - 72
    local viewerH = modal.h - 124
    viewer.rect.x = viewerX
    viewer.rect.y = viewerY
    viewer.rect.w = viewerW
    viewer.rect.h = viewerH

    setColor({ 0.01, 0.02, 0.04, 0.92 })
    love.graphics.rectangle("fill", viewerX, viewerY, viewerW, viewerH, 16, 16)
    setColor(ui.palette.border)
    love.graphics.rectangle("line", viewerX, viewerY, viewerW, viewerH, 16, 16)

    love.graphics.setFont(ui.fonts.heading)
    setColor(ui.palette.text)
    love.graphics.print(viewer.title, viewerX + 18, viewerY + 16)
    love.graphics.setFont(ui.fonts.small)
    setColor(ui.palette.muted)
    love.graphics.print("Select text with mouse. Use Cmd/Ctrl+A and Cmd/Ctrl+C to copy.", viewerX + 20, viewerY + 42)

    drawButton("Copy", viewerX + viewerW - 196, viewerY + 14, 72, 30, ui.palette.accent, function()
      copyTextToClipboard(viewer.text, "viewer text copied")
    end, false)
    drawButton("Close", viewerX + viewerW - 112, viewerY + 14, 80, 30, ui.palette.muted, closeDebugTextViewer, false)

    local editor = ensureDebugViewerEditor()
    editor:setRect(viewerX + 18, viewerY + 72, viewerW - 36, viewerH - 90)
    editor:draw({
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
  ensureDebugViewerEditor()

  ensureConfigEditors()
  loadSettings()
  applyLoggingConfig()
  addLogEntry("app", "info", "love_load", {
    logging = currentLoggingSettings()
  })
  loadSessionState()
  rebuildClients()

  if not clients.openai and not clients.anthropic then
    statusText = "provider config required"
    errorText = "click Provider to enter and save your API configuration"
  else
    statusText = #history > 0 and ("restored " .. tostring(#history) .. " messages") or "agent session ready"
    errorText = ""
  end

  refreshLayout()
end

function love.update(dt)
  async.update(dt)
  refreshLayout()
end

function love.textinput(text)
  if debugState.isOpen then
    return
  end
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

local function isDebugViewerKeyAllowed(key)
  if type(key) ~= "string" then
    return false
  end
  if key == "left" or key == "right" or key == "up" or key == "down" then
    return true
  end
  if key == "home" or key == "end" or key == "pageup" or key == "pagedown" then
    return true
  end
  if key == "a" or key == "c" then
    return true
  end
  return false
end

function love.keypressed(key)
  if debugState.isOpen then
    if debugState.viewer.isOpen then
      if key == "escape" then
        closeDebugTextViewer()
        statusText = "debug text viewer closed"
        errorText = ""
        return
      end
      local editor = debugState.viewer.editor
      if editor and isDebugViewerKeyAllowed(key) and editor:keypressed(key) then
        return
      end
      return
    end
    if key == "escape" or key == "f4" then
      closeDebugPanel()
      statusText = "agent debug panel closed"
      errorText = ""
      return
    end
  end
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
  if key == "f4" then
    openDebugPanel()
    return
  end
  if key == "f5" then
    toggleLogging()
    return
  end
  if key == "f6" then
    cycleLoggingLevel()
    return
  end
  if key == "f7" then
    clearDebugLogs()
    statusText = "logs cleared"
    errorText = ""
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
  if debugState.isOpen then
    if debugState.viewer.isOpen and debugState.viewer.editor and debugState.viewer.editor:mousepressed(x, y, button) then
      return
    end
    return
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
  if debugState.isOpen then
    if debugState.viewer.isOpen and debugState.viewer.editor then
      debugState.viewer.editor:mousemoved(x, y)
    end
    return
  end
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
  if debugState.isOpen then
    if debugState.viewer.isOpen and debugState.viewer.editor then
      debugState.viewer.editor:mousereleased(x, y, button)
    end
    return
  end
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
  if debugState.isOpen then
    if debugState.viewer.isOpen and debugState.viewer.editor then
      local viewer = debugState.viewer.rect
      local mx, my = love.mouse.getPosition()
      if pointInRect(mx, my, viewer.x, viewer.y, viewer.w, viewer.h) then
        debugState.viewer.editor:wheelmoved(dx, dy)
        return
      end
    end
    local modal = debugState.layout
    local mx, my = love.mouse.getPosition()
    local bodyX = modal.x + 20
    local bodyY = modal.y + 106
    local bodyW = modal.w - 40
    local bodyH = modal.h - 132
    if pointInRect(mx, my, bodyX, bodyY, bodyW, bodyH) and debugState.layout.maxScroll > 0 then
      local step = (ui.fonts.body:getHeight() + 4) * 3
      debugState.scroll = clamp(debugState.scroll - dy * step, 0, debugState.layout.maxScroll)
    end
    return
  end
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
  if configState.isOpen or debugState.isOpen then
    resetHitboxes()
  end
  drawConfigModal()
  drawDebugModal()
end

function love.quit()
  saveSessionState()
  destroyClients()
end
