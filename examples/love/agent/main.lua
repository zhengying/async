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
local agent = require("agent")
local AsyncHttp = require("async_http")
local TextInput = require("love.ui_text_input")

local clients = {}
local currentProvider = "openai"

local registry = agent.ToolRegistry.new()
local a = nil
local chat = nil
local httpClient = nil
local inputBox = nil

local goalText = "Hello, my name is Alice. Please remember it for later in this chat."
local statusText = ""
local errorText = ""
local planText = ""
local answerText = ""
local runningTask = nil
local sessionMemory = "This is a multi-turn chat. Keep track of user preferences and facts that matter later in the conversation."
local workspaceMemory = "This workspace contains a Lua and LÖVE agent demo. Keep answers grounded in the current project before using global assumptions."
local savedSessionState = nil
local currentDemoIndex = 1
local ui = {
  fonts = {},
  hitboxes = {},
  scrollRegions = {},
  scrollOffsets = {
    leftPanel = 0,
    rightPanel = 0
  },
  palette = {
    bg = { 0.06, 0.08, 0.11, 1 },
    sidebar = { 0.09, 0.11, 0.15, 1 },
    panel = { 0.11, 0.14, 0.19, 0.96 },
    panelAlt = { 0.13, 0.17, 0.23, 0.96 },
    border = { 0.24, 0.31, 0.42, 1 },
    text = { 0.93, 0.96, 1, 1 },
    muted = { 0.67, 0.74, 0.84, 1 },
    accent = { 0.39, 0.67, 1, 1 },
    accentSoft = { 0.19, 0.31, 0.5, 1 },
    success = { 0.30, 0.82, 0.56, 1 },
    warn = { 0.96, 0.72, 0.32, 1 },
    danger = { 0.96, 0.39, 0.39, 1 }
  }
}
local demoScenarios = {
  {
    key = "1",
    name = "multi_turn",
    title = "Multi-turn session memory",
    prompt = "Hello, my name is Alice. Please remember it for later in this chat.",
    description = "Shows Session history. Run once, then ask 'What is my name?' or 'What have I told you about me?' to verify that recent context is preserved.",
    walkthrough = {
      "Send the seeded prompt.",
      "Ask a follow-up that depends on the previous turn.",
      "Observe that the conversation panel keeps raw recent turns."
    }
  },
  {
    key = "2",
    name = "structured_memory",
    title = "Structured memory store",
    prompt = "What durable things do you already know about this user?",
    description = "Shows MemoryStore. This scenario seeds facts, preferences, goals, and notes before the request so the prompt includes structured durable memory.",
    prepare = function(session)
      session:setMemoryStore(agent.MemoryStore.new({
        summary = "This session demonstrates durable memory.",
        facts = {
          "The user is evaluating the agent framework."
        },
        preferences = {
          "The user prefers concise answers."
        },
        goals = {
          "Explain the system clearly."
        },
        notes = {
          "Mention durable memory separately from recent chat."
        }
      }))
    end,
    walkthrough = {
      "Load the scenario.",
      "Send the seeded question.",
      "Observe the memory preview panel and how durable memory differs from recent conversation."
    }
  },
  {
    key = "3",
    name = "math_route",
    title = "Router + math tool",
    prompt = "Add 12 and 30, then explain which tool you used.",
    description = "Shows ProfileRouter selecting the math scene. Only math tools should be exposed, reducing prompt size and improving reliability.",
    walkthrough = {
      "Load the math scenario.",
      "Send the request.",
      "Observe the route label switch to the math route and the generated plan mention the add tool."
    }
  },
  {
    key = "4",
    name = "web_route",
    title = "Router + web tool",
    prompt = "Fetch https://example.com and summarize the first 200 characters.",
    description = "Shows tool routing for external lookup. The web route exposes only the HTTP tool, which also makes the demo good for integration testing.",
    walkthrough = {
      "Load the web scenario.",
      "Send the request.",
      "Observe the web route, the plan, and the answer derived from tool output."
    }
  },
  {
    key = "5",
    name = "time_route",
    title = "Router + time tool",
    prompt = "What time is it now in UTC? Mention the tool you used.",
    description = "Shows a lightweight local tool route. This is a quick sanity check when you want a fast demo with no network dependency.",
    walkthrough = {
      "Load the time scenario.",
      "Send the request.",
      "Observe the route label switch to time and the answer use the now tool."
    }
  },
  {
    key = "6",
    name = "persistence",
    title = "Session persistence",
    prompt = "Summarize the current conversation state in one sentence.",
    description = "Shows session export/import. Use F3 to save a snapshot, F2 to clear the session, and F4 to restore it. This is useful for testing persistence.",
    prepare = function(session)
      session:add("user", "Earlier I said my name is Alice.")
      session:add("assistant", "I will remember that your name is Alice.")
      session:remember("facts", "The user's name is Alice.")
    end,
    walkthrough = {
      "Load the persistence scenario.",
      "Press F3 to save a snapshot.",
      "Press F2 to clear the chat and then F4 to restore it."
    }
  }
}

local function firstLine(value)
  local s = tostring(value or "")
  s = s:gsub("\r\n", "\n")
  return s:match("([^\n\r]+)") or s
end

local function printBlock(tag, text)
  local s = tostring(text or "")
  s = s:gsub("\r\n", "\n")
  local prefix = "[agent][" .. tostring(tag) .. "]"
  for line in s:gmatch("([^\n]*)\n?") do
    if line == "" and s:sub(-1) ~= "\n" then
      break
    end
    print(prefix .. " " .. line)
  end
end

local function truncateText(value, maxLen)
  local s = tostring(value or "")
  local n = tonumber(maxLen or 0) or 0
  if n > 0 and #s > n then
    return s:sub(1, n) .. "..."
  end
  return s
end

local function currentGoalText()
  if inputBox and type(inputBox.getText) == "function" then
    return inputBox:getText()
  end
  return tostring(goalText or "")
end

local function setGoalText(value)
  goalText = tostring(value or "")
  if inputBox and type(inputBox.setText) == "function" then
    inputBox:setText(goalText)
  end
end

local function setColor(rgba)
  love.graphics.setColor(rgba[1], rgba[2], rgba[3], rgba[4] or 1)
end

local function pointInRect(px, py, x, y, w, h)
  return px >= x and px <= x + w and py >= y and py <= y + h
end

local function resetHitboxes()
  ui.hitboxes = {}
  ui.scrollRegions = {}
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

local function statusTone()
  if errorText ~= "" then
    return ui.palette.danger
  end
  if runningTask and runningTask.isRunning and runningTask:isRunning() then
    return ui.palette.warn
  end
  if answerText ~= "" then
    return ui.palette.success
  end
  return ui.palette.accent
end

local function routeTone(routeName)
  if routeName == "web" then
    return ui.palette.accent
  end
  if routeName == "math" then
    return ui.palette.success
  end
  if routeName == "time" then
    return ui.palette.warn
  end
  return ui.palette.muted
end

local function currentDemo()
  return demoScenarios[currentDemoIndex]
end

local function memoryPreviewText()
  if not chat then
    return "memory: <no session>"
  end
  return "memory:\n" .. truncateText(chat:getMemory() or "<empty>", 800)
end

local function sessionStatsText()
  if not chat then
    return "session: <no session>"
  end
  local state = chat:exportState({ includeMetadata = true })
  local stats = {
    "history turns: " .. tostring(#(state.history or {})),
    "has string memory: " .. tostring(state.memory ~= nil and state.memory ~= ""),
    "has structured memory: " .. tostring(state.memoryStore ~= nil),
    "saved snapshot: " .. tostring(savedSessionState ~= nil)
  }
  if type(state.metadata) == "table" then
    if state.metadata.profile then
      stats[#stats + 1] = "profile: " .. tostring(state.metadata.profile)
    end
    if state.metadata.router then
      stats[#stats + 1] = "router: " .. tostring(state.metadata.router)
    end
  end
  return table.concat(stats, "\n")
end

local function activeRouteLabel()
  if not chat then
    return "route: <no session>"
  end
  local router = chat:getRouter()
  if type(router) ~= "table" or type(router.select) ~= "function" then
    return "route: <none>"
  end
  local _, routeName = router:select(currentGoalText(), "run", {
    session = chat,
    history = chat:getHistory(),
    memory = chat:getMemory(),
    profile = chat:getProfile()
  })
  return "route: " .. tostring(routeName or "none")
end

local function activeRouteName()
  if not chat then
    return "none"
  end
  local router = chat:getRouter()
  if type(router) ~= "table" or type(router.select) ~= "function" then
    return "none"
  end
  local _, routeName = router:select(currentGoalText(), "run", {
    session = chat,
    history = chat:getHistory(),
    memory = chat:getMemory(),
    profile = chat:getProfile()
  })
  return tostring(routeName or "none")
end

local function walkthroughText()
  local demo = currentDemo()
  if type(demo) ~= "table" or type(demo.walkthrough) ~= "table" or #demo.walkthrough == 0 then
    return "walkthrough: <none>"
  end
  local lines = { "walkthrough:" }
  for i = 1, #demo.walkthrough do
    lines[#lines + 1] = tostring(i) .. ". " .. tostring(demo.walkthrough[i])
  end
  return table.concat(lines, "\n")
end

local function demoMenuText()
  local lines = { "demo scenarios:" }
  for i = 1, #demoScenarios do
    local demo = demoScenarios[i]
    local prefix = i == currentDemoIndex and "> " or "  "
    lines[#lines + 1] = prefix .. tostring(demo.key) .. ". " .. tostring(demo.title or demo.name or i)
  end
  return table.concat(lines, "\n")
end

local function visibleConversationText(maxMessages, maxChars)
  local history = chat and chat:getHistory() or {}
  local limit = tonumber(maxMessages or 0) or 0
  local total = #history
  if total == 0 then
    return "conversation: <empty>"
  end
  if limit <= 0 or limit > total then
    limit = total
  end
  local startIndex = total - limit + 1
  local lines = { "conversation:" }
  for i = startIndex, total do
    local item = history[i]
    if type(item) == "table" then
      lines[#lines + 1] = tostring(item.role or "user") .. ": " .. truncateText(item.content or "", maxChars or 220)
    end
  end
  return table.concat(lines, "\n")
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

local function resetAgent()
  local client = activeClient()
  if not client then
    a = nil
    chat = nil
    return
  end
  a = agent.Agent.new({
    client = client,
    registry = registry,
    system = "You are a general-purpose agent. Think step by step. Use tools when needed. When you are done, return a final answer for the user.",
    withPlan = true,
    maxSteps = 10,
    temperature = 0.2
  })
  chat = agent.Session.new({
    agent = a,
    profile = agent.SceneProfile.new({
      name = "base_chat",
      instructions = {
        "Prefer using tools when the user asks for external data or calculation.",
        "Keep answers grounded in the conversation when the user asks follow-up questions."
      },
      constraints = {
        "Do not invent tool results.",
        "Use only the tools available in this scene."
      },
      planGuidelines = {
        "Prefer short plans.",
        "If the user asks about a previously mentioned fact, answer from conversation context before using tools."
      }
    }),
    router = agent.ProfileRouter.new({
      name = "demo_router",
      routes = {
        {
          name = "web",
          match = function(ctx)
            local goal = string.lower(tostring(ctx.goal or ""))
            return goal:find("http", 1, true) or goal:find("url", 1, true) or goal:find("website", 1, true)
          end,
          profile = {
            memory = "This turn is about web lookup.",
            toolTags = { "web" }
          }
        },
        {
          name = "math",
          match = function(ctx)
            local goal = string.lower(tostring(ctx.goal or ""))
            return goal:find("sum", 1, true) or goal:find("add", 1, true) or goal:find("plus", 1, true)
          end,
          profile = {
            memory = "This turn is about arithmetic.",
            toolTags = { "math" }
          }
        },
        {
          name = "time",
          match = function(ctx)
            local goal = string.lower(tostring(ctx.goal or ""))
            return goal:find("time", 1, true) or goal:find("date", 1, true) or goal:find("now", 1, true)
          end,
          profile = {
            memory = "This turn is about time lookup.",
            toolTags = { "time" }
          }
        }
      }
    }),
    memory = sessionMemory,
    memoryStore = agent.MemoryStore.new({
      facts = {
        "The user may ask follow-up questions that depend on prior answers."
      },
      preferences = {
        "Prefer concise answers unless the user asks for more detail."
      },
      goals = {
        "Preserve enough context for multi-turn chat."
      }
    }),
    workspaceMemory = workspaceMemory,
    workspaceMemoryStore = agent.MemoryStore.new({
      facts = {
        "This repository demonstrates async Lua primitives and agent patterns."
      },
      goals = {
        "Explain the active LOVE demo clearly."
      }
    }),
    memoryExtractor = agent.MemoryExtractor.new({
      client = client,
      scopes = { "session", "workspace" },
      maxHistoryMessages = 4,
      maxHistoryChars = 180
    }),
    maxPlanningHistoryMessages = 6,
    maxPlanningHistoryChars = 180
  })
end

local function loadDemo(index)
  local idx = tonumber(index or 1) or 1
  if idx < 1 then
    idx = 1
  end
  if idx > #demoScenarios then
    idx = #demoScenarios
  end
  currentDemoIndex = idx
  savedSessionState = nil
  resetAgent()
  local demo = currentDemo()
  setGoalText(type(demo) == "table" and tostring(demo.prompt or "") or "")
  planText = ""
  answerText = ""
  errorText = ""
  if chat and type(demo) == "table" and type(demo.prepare) == "function" then
    demo.prepare(chat)
  end
  statusText = type(demo) == "table" and ("loaded demo: " .. tostring(demo.title or demo.name or idx)) or "loaded demo"
end

local function cancelRun()
  if not runningTask then
    return
  end
  if type(runningTask.cancel) == "function" then
    runningTask:cancel()
  else
    runningTask:stop()
  end
end

local function runGoal()
  if not chat then
    statusText = "no client"
    errorText = "set OPENAI_API_KEY or ANTHROPIC_API_KEY"
    return
  end

  if runningTask and runningTask:isRunning() and not runningTask.stopped and not runningTask.error and not runningTask.result then
    return
  end

  local turnText = currentGoalText()
  if turnText == "" then
    statusText = "empty input"
    errorText = ""
    return
  end

  statusText = "planning + running..."
  errorText = ""
  planText = ""
  answerText = ""

  runningTask = async(function()
    local planTask = chat:plan(turnText, { timeout = 60 })
    local plan, planErr = async.await(planTask)
    if type(plan) == "table" then
      planText = llm.jsonEncode(plan)
      printBlock("plan", planText)
    else
      planText = ""
      if planErr then
        errorText = "plan failed: " .. tostring(planErr)
        printBlock("error", errorText)
      end
    end

    local result, err = async.await(chat:ask(turnText, {
      timeout = 60,
      withPlan = false,
      plan = plan
    }))
    if type(result) ~= "table" then
      statusText = "failed"
      errorText = tostring(err)
      printBlock("error", errorText)
      return
    end

    statusText = "ok (" .. tostring(currentProvider) .. ", model: " .. tostring(activeClient().model) .. ")"
    answerText = tostring(result.text or "")
    printBlock("answer", answerText)
  end)
end

function love.load()
  love.window.setMode(1480, 960, {
    resizable = true,
    minwidth = 1120,
    minheight = 760
  })
  ui.fonts.title = love.graphics.newFont(28)
  ui.fonts.heading = love.graphics.newFont(16)
  ui.fonts.body = love.graphics.newFont(13)
  ui.fonts.small = love.graphics.newFont(11)
  love.graphics.setFont(ui.fonts.body)
  inputBox = TextInput.new({
    text = goalText,
    placeholder = "Type a goal or follow-up question...",
    focused = true,
    font = ui.fonts.body,
    softWrap = true,
    tabString = "  "
  })

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

  httpClient = AsyncHttp.new({ poolSize = 4, timeout = 20, httpsModule = "https" })

  registry:register({
    name = "now",
    description = "Get the current local time (RFC3339-like).",
    schema = { type = "object", properties = {}, additionalProperties = false },
    tags = { "time" },
    handler = function()
      return os.date("!%Y-%m-%dT%H:%M:%SZ")
    end
  })

  registry:register({
    name = "add",
    description = "Add two numbers.",
    schema = {
      type = "object",
      properties = {
        a = { type = "number" },
        b = { type = "number" }
      },
      required = { "a", "b" },
      additionalProperties = false
    },
    tags = { "math" },
    handler = function(input)
      local aNum = tonumber(type(input) == "table" and input.a or nil)
      local bNum = tonumber(type(input) == "table" and input.b or nil)
      if not aNum or not bNum then
        return nil, "invalid numbers"
      end
      return { result = aNum + bNum }
    end
  })

  registry:register({
    name = "http_get",
    description = "Fetch a URL and return status + truncated body.",
    schema = {
      type = "object",
      properties = {
        url = { type = "string" },
        max_len = { type = "number" }
      },
      required = { "url" },
      additionalProperties = false
    },
    tags = { "web" },
    handler = function(input)
      local function normalizeUrl(v)
        if type(v) ~= "string" then
          return nil
        end
        local function trim(s)
          return s:gsub("^%s+", ""):gsub("%s+$", "")
        end

        local function stripControlChars(s)
          return s:gsub("[%z\1-\31]", " ")
        end

        local function stripOuterPairs(s)
          s = trim(s)
          local pairs = {
            { "`", "`" },
            { "\"", "\"" },
            { "'", "'" },
            { "<", ">" },
            { "(", ")" },
            { "[", "]" },
            { "{", "}" }
          }
          local changed = true
          while changed do
            changed = false
            for i = 1, #pairs do
              local a = pairs[i][1]
              local b = pairs[i][2]
              if s:sub(1, 1) == a and s:sub(-1) == b and #s >= 2 then
                s = trim(s:sub(2, -2))
                changed = true
              end
            end
          end
          return s
        end

        local function stripTrailingJunk(s)
          s = s:gsub("\\+$", "")
          s = s:gsub("[%)%]%}%>%\"%'%`%.,;:!%?]+$", "")
          s = s:gsub("\\+$", "")
          return trim(s)
        end

        local s = stripControlChars(v)
        s = trim(s)

        local httpUrl = s:match("(https?://%S+)")
        if httpUrl then
          s = httpUrl
        end

        s = stripOuterPairs(s)
        s = stripTrailingJunk(s)

        if not s:match("^https?://") then
          return nil
        end
        return s
      end

      local url = type(input) == "table" and normalizeUrl(input.url) or nil
      local maxLen = tonumber(type(input) == "table" and input.max_len or nil) or 2000
      if type(url) ~= "string" or url == "" then
        return nil, "url is required"
      end
      if maxLen < 1 then
        maxLen = 1
      end
      if maxLen > 20000 then
        maxLen = 20000
      end
      return async(function()
        local resp, err, extra = async.await(httpClient:get(url, { timeout = 20 }))
        if type(resp) ~= "table" then
          local status = type(extra) == "table" and extra.status or 0
          return { ok = false, status = status, error = tostring(err) }
        end
        local body = tostring(resp.body or "")
        return { ok = true, status = resp.status, body = body:sub(1, maxLen) }
      end)
    end
  })

  loadDemo(currentDemoIndex)

  if not clients.openai and not clients.anthropic then
    statusText = "no API keys"
    errorText = "set OPENAI_API_KEY or ANTHROPIC_API_KEY in env"
  end
end

function love.update(dt)
  async.update(dt)
end

function love.textinput(t)
  if inputBox and inputBox:textinput(t) then
    goalText = inputBox:getText()
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
  local inputFocused = inputBox and inputBox.focused
  if key == "escape" then
    love.event.quit()
    return
  end
  if key == "return" or key == "kpenter" then
    local shift = love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
    if shift and inputBox and inputBox:keypressed(key) then
      goalText = inputBox:getText()
      return
    end
    runGoal()
    return
  end
  if inputFocused and inputBox and inputBox:keypressed(key) then
    goalText = inputBox:getText()
    return
  end
  if inputFocused and isEditorTextEntryKey(key) then
    return
  end
  for i = 1, #demoScenarios do
    if key == demoScenarios[i].key then
      loadDemo(i)
      return
    end
  end
  if key == "tab" then
    currentProvider = nextProvider()
    loadDemo(currentDemoIndex)
    statusText = "provider switched to " .. tostring(currentProvider)
    return
  end
  if key == "c" then
    cancelRun()
    return
  end
  if key == "f1" then
    setGoalText("")
    return
  end
  if key == "f2" then
    if chat then
      chat:clear()
    end
    planText = ""
    answerText = ""
    statusText = "conversation cleared"
    errorText = ""
    return
  end
  if key == "f3" then
    if chat then
      savedSessionState = chat:exportState()
      statusText = "session snapshot saved"
      errorText = ""
    end
    return
  end
  if key == "f4" then
    if chat and savedSessionState then
      chat:importState(savedSessionState)
      statusText = "session snapshot restored"
      errorText = ""
      planText = ""
      answerText = ""
    else
      statusText = "no saved snapshot"
      errorText = ""
    end
    return
  end
  if key == "f5" then
    local nextIndex = currentDemoIndex + 1
    if nextIndex > #demoScenarios then
      nextIndex = 1
    end
    loadDemo(nextIndex)
    return
  end
  if inputBox and inputBox:keypressed(key) then
    goalText = inputBox:getText()
    return
  end
end

function love.mousepressed(x, y, button)
  if inputBox and inputBox:mousepressed(x, y, button) then
    goalText = inputBox:getText()
    return
  end
  if button ~= 1 then
    return
  end
  for i = #ui.hitboxes, 1, -1 do
    local hitbox = ui.hitboxes[i]
    if pointInRect(x, y, hitbox.x, hitbox.y, hitbox.w, hitbox.h) then
      if type(hitbox.onClick) == "function" then
        hitbox.onClick()
      end
      return
    end
  end
end

function love.mousemoved(x, y)
  if inputBox and inputBox:mousemoved(x, y) then
    goalText = inputBox:getText()
  end
end

function love.mousereleased(x, y, button)
  if inputBox then
    inputBox:mousereleased(x, y, button)
  end
end

function love.wheelmoved(dx, dy)
  local mx, my = love.mouse.getPosition()
  for i = #ui.scrollRegions, 1, -1 do
    local region = ui.scrollRegions[i]
    if pointInRect(mx, my, region.x, region.y, region.w, region.h) and region.maxScroll > 0 then
      local step = ui.fonts.body:getHeight() * 3
      local nextOffset = (ui.scrollOffsets[region.id] or 0) - dy * step
      ui.scrollOffsets[region.id] = math.min(math.max(nextOffset, 0), region.maxScroll)
      return
    end
  end
  if inputBox and inputBox:wheelmoved(dx, dy) then
    goalText = inputBox:getText()
  end
end

local function drawPanel(x, y, w, h, tone)
  setColor(tone or ui.palette.panel)
  love.graphics.rectangle("fill", x, y, w, h, 14, 14)
  setColor(ui.palette.border)
  love.graphics.rectangle("line", x, y, w, h, 14, 14)
end

local function drawPanelTitle(title, subtitle, x, y, w)
  love.graphics.setFont(ui.fonts.heading)
  setColor(ui.palette.text)
  love.graphics.printf(title, x + 16, y + 14, w - 32, "left")
  if subtitle and subtitle ~= "" then
    love.graphics.setFont(ui.fonts.small)
    setColor(ui.palette.muted)
    love.graphics.printf(subtitle, x + 16, y + 36, w - 32, "left")
  end
  love.graphics.setFont(ui.fonts.body)
end

local function drawWrappedText(text, x, y, w, color)
  love.graphics.setFont(ui.fonts.body)
  setColor(color or ui.palette.text)
  love.graphics.printf(tostring(text or ""), x, y, w, "left")
  local _, wrapped = ui.fonts.body:getWrap(tostring(text or ""), w)
  return #wrapped * (ui.fonts.body:getHeight() + 3)
end

local function measureWrappedText(text, width)
  local _, wrapped = ui.fonts.body:getWrap(tostring(text or ""), width)
  return #wrapped * (ui.fonts.body:getHeight() + 3)
end

local function registerScrollRegion(id, x, y, w, h, contentHeight)
  local viewportHeight = math.max(1, h)
  local maxScroll = math.max(0, contentHeight - viewportHeight)
  ui.scrollOffsets[id] = math.min(math.max(ui.scrollOffsets[id] or 0, 0), maxScroll)
  ui.scrollRegions[#ui.scrollRegions + 1] = {
    id = id,
    x = x,
    y = y,
    w = w,
    h = h,
    contentHeight = contentHeight,
    maxScroll = maxScroll
  }
  return ui.scrollOffsets[id]
end

local function drawVerticalScrollbar(x, y, w, h, offset, contentHeight)
  if contentHeight <= h then
    return
  end
  local trackInset = 2
  local trackX = x + w - 10
  local trackY = y + trackInset
  local trackW = 6
  local trackH = h - trackInset * 2
  local thumbH = math.max(28, trackH * (h / contentHeight))
  local maxScroll = math.max(1, contentHeight - h)
  local thumbY = trackY + (trackH - thumbH) * (offset / maxScroll)
  setColor({ ui.palette.border[1], ui.palette.border[2], ui.palette.border[3], 0.9 })
  love.graphics.rectangle("fill", trackX, trackY, trackW, trackH, 4, 4)
  setColor(ui.palette.accent)
  love.graphics.rectangle("fill", trackX, thumbY, trackW, thumbH, 4, 4)
end

local function drawPill(label, x, y, tone, w)
  local width = w or (ui.fonts.small:getWidth(label) + 22)
  local height = ui.fonts.small:getHeight() + 10
  setColor({ tone[1], tone[2], tone[3], 0.18 })
  love.graphics.rectangle("fill", x, y, width, height, 999, 999)
  setColor(tone)
  love.graphics.rectangle("line", x, y, width, height, 999, 999)
  love.graphics.setFont(ui.fonts.small)
  setColor(tone)
  love.graphics.printf(label, x, y + 4, width, "center")
  love.graphics.setFont(ui.fonts.body)
  return width, height
end

local function drawButton(label, x, y, w, h, tone, onClick)
  local mx, my = love.mouse.getPosition()
  local hovered = pointInRect(mx, my, x, y, w, h)
  local fill = { tone[1], tone[2], tone[3], hovered and 0.28 or 0.18 }
  setColor(fill)
  love.graphics.rectangle("fill", x, y, w, h, 10, 10)
  setColor(tone)
  love.graphics.rectangle("line", x, y, w, h, 10, 10)
  love.graphics.setFont(ui.fonts.small)
  setColor(tone)
  love.graphics.printf(label, x, y + math.floor((h - ui.fonts.small:getHeight()) / 2), w, "center")
  love.graphics.setFont(ui.fonts.body)
  pushHitbox(x, y, w, h, onClick)
end

function love.draw()
  resetHitboxes()
  local screenWidth = love.graphics.getWidth and love.graphics.getWidth() or 1480
  local screenHeight = love.graphics.getHeight and love.graphics.getHeight() or 960
  local margin = 18
  local gutter = 18
  local sidebarWidth = math.max(320, math.floor(screenWidth * 0.25))
  local contentX = margin + sidebarWidth + gutter
  local contentWidth = screenWidth - contentX - margin
  local headerHeight = 88
  local metricsHeight = 124
  local topY = margin
  local contentTop = margin + headerHeight + gutter + metricsHeight + gutter
  local lowerHeight = screenHeight - contentTop - margin
  local lowerLeftWidth = math.floor(contentWidth * 0.44)
  local lowerRightWidth = contentWidth - gutter - lowerLeftWidth
  local routeName = activeRouteName()

  setColor(ui.palette.bg)
  love.graphics.rectangle("fill", 0, 0, screenWidth, screenHeight)

  drawPanel(margin, margin, sidebarWidth, screenHeight - margin * 2, ui.palette.sidebar)
  drawPanel(contentX, topY, contentWidth, headerHeight, ui.palette.panelAlt)
  drawPanel(contentX, topY + headerHeight + gutter, contentWidth, metricsHeight, ui.palette.panel)
  drawPanel(contentX, contentTop, lowerLeftWidth, lowerHeight, ui.palette.panel)
  drawPanel(contentX + lowerLeftWidth + gutter, contentTop, lowerRightWidth, lowerHeight, ui.palette.panel)

  love.graphics.setFont(ui.fonts.title)
  setColor(ui.palette.text)
  love.graphics.printf("Agent Lab", contentX + 20, topY + 14, contentWidth - 40, "left")
  love.graphics.setFont(ui.fonts.body)
  setColor(ui.palette.muted)
  love.graphics.printf("Explore tools, planning, sessions, routing, memory, and persistence in one interactive demo.", contentX + 22, topY + 50, contentWidth - 380, "left")

  local buttonY = topY + 22
  local buttonW = 82
  local buttonH = 34
  local buttonGap = 10
  local buttonX = contentX + contentWidth - (buttonW * 5 + buttonGap * 4) - 18
  drawButton("Send", buttonX, buttonY, buttonW, buttonH, ui.palette.success, runGoal)
  drawButton("Clear", buttonX + (buttonW + buttonGap), buttonY, buttonW, buttonH, ui.palette.warn, function()
    if chat then
      chat:clear()
    end
    planText = ""
    answerText = ""
    errorText = ""
    statusText = "conversation cleared"
  end)
  drawButton("Save", buttonX + (buttonW + buttonGap) * 2, buttonY, buttonW, buttonH, ui.palette.accent, function()
    if chat then
      savedSessionState = chat:exportState()
      statusText = "session snapshot saved"
      errorText = ""
    end
  end)
  drawButton("Restore", buttonX + (buttonW + buttonGap) * 3, buttonY, buttonW, buttonH, ui.palette.accent, function()
    if chat and savedSessionState then
      chat:importState(savedSessionState)
      planText = ""
      answerText = ""
      errorText = ""
      statusText = "session snapshot restored"
    else
      statusText = "no saved snapshot"
      errorText = ""
    end
  end)
  drawButton("Next", buttonX + (buttonW + buttonGap) * 4, buttonY, buttonW, buttonH, ui.palette.accent, function()
    local nextIndex = currentDemoIndex + 1
    if nextIndex > #demoScenarios then
      nextIndex = 1
    end
    loadDemo(nextIndex)
  end)

  local chipY = topY + headerHeight + gutter + 12
  local chipX = contentX + 20
  local chipW
  chipW = select(1, drawPill("provider: " .. tostring(currentProvider), chipX, chipY, ui.palette.accent))
  chipX = chipX + chipW + 10
  chipW = select(1, drawPill("route: " .. routeName, chipX, chipY, routeTone(routeName)))
  chipX = chipX + chipW + 10
  chipW = select(1, drawPill("status", chipX, chipY, statusTone(), 74))
  setColor(ui.palette.text)
  love.graphics.setFont(ui.fonts.body)
  love.graphics.printf(tostring(statusText), chipX + chipW + 14, chipY + 3, contentWidth - (chipX - contentX) - chipW - 40, "left")
  love.graphics.setFont(ui.fonts.body)

  local metrics = {
    { title = "History", value = tostring(chat and #chat:getHistory() or 0), tone = ui.palette.accent, subtitle = "raw turns" },
    { title = "Memory", value = tostring(chat and (chat:getMemoryStore() and "structured" or "string") or "none"), tone = ui.palette.success, subtitle = "active mode" },
    { title = "Snapshot", value = savedSessionState and "saved" or "empty", tone = savedSessionState and ui.palette.warn or ui.palette.muted, subtitle = "session state" },
    { title = "Scenario", value = tostring(currentDemoIndex), tone = ui.palette.accent, subtitle = currentDemo().key .. " selected" }
  }
  local metricWidth = math.floor((contentWidth - 20 * 2 - 12 * 3) / 4)
  for i = 1, #metrics do
    local cardX = contentX + 20 + (i - 1) * (metricWidth + 12)
    local cardY = topY + headerHeight + gutter + 48
    local metric = metrics[i]
    setColor({ metric.tone[1], metric.tone[2], metric.tone[3], 0.12 })
    love.graphics.rectangle("fill", cardX, cardY, metricWidth, 58, 12, 12)
    setColor({ metric.tone[1], metric.tone[2], metric.tone[3], 0.75 })
    love.graphics.rectangle("line", cardX, cardY, metricWidth, 58, 12, 12)
    love.graphics.setFont(ui.fonts.small)
    setColor(ui.palette.muted)
    love.graphics.printf(metric.title, cardX + 12, cardY + 8, metricWidth - 24, "left")
    love.graphics.setFont(ui.fonts.heading)
    setColor(ui.palette.text)
    love.graphics.printf(metric.value, cardX + 12, cardY + 24, metricWidth - 24, "left")
    love.graphics.setFont(ui.fonts.small)
    setColor(metric.tone)
    love.graphics.printf(metric.subtitle, cardX + 12, cardY + 42, metricWidth - 24, "left")
  end
  love.graphics.setFont(ui.fonts.body)

  local sidebarX = margin + 16
  local sidebarY = margin + 16
  love.graphics.setFont(ui.fonts.heading)
  setColor(ui.palette.text)
  love.graphics.printf("Demo scenarios", sidebarX, sidebarY, sidebarWidth - 32, "left")
  love.graphics.setFont(ui.fonts.small)
  setColor(ui.palette.muted)
  love.graphics.printf("Click a scenario or press 1-6", sidebarX, sidebarY + 24, sidebarWidth - 32, "left")
  sidebarY = sidebarY + 54

  for i = 1, #demoScenarios do
    local demo = demoScenarios[i]
    local cardH = 76
    local cardX = margin + 12
    local cardY = sidebarY + (i - 1) * (cardH + 10)
    local cardW = sidebarWidth - 24
    local active = i == currentDemoIndex
    local mx, my = love.mouse.getPosition()
    local hovered = pointInRect(mx, my, cardX, cardY, cardW, cardH)
    local tone = active and ui.palette.accent or ui.palette.border
    local fill = active and ui.palette.panelAlt or ui.palette.panel
    if hovered and not active then
      fill = ui.palette.panelAlt
    end
    drawPanel(cardX, cardY, cardW, cardH, fill)
    setColor(tone)
    love.graphics.rectangle("line", cardX, cardY, cardW, cardH, 14, 14)
    drawPill(tostring(demo.key), cardX + 12, cardY + 12, active and ui.palette.accent or ui.palette.muted, 28)
    love.graphics.setFont(ui.fonts.heading)
    setColor(ui.palette.text)
    love.graphics.printf(tostring(demo.title), cardX + 48, cardY + 10, cardW - 60, "left")
    love.graphics.setFont(ui.fonts.small)
    setColor(ui.palette.muted)
    love.graphics.printf(truncateText(demo.description, 118), cardX + 12, cardY + 36, cardW - 24, "left")
    pushHitbox(cardX, cardY, cardW, cardH, function()
      loadDemo(i)
    end)
  end

  local footerHeight = 118
  local footerY = screenHeight - margin - footerHeight
  if footerY > sidebarY + (#demoScenarios * 86) then
    drawPanel(margin + 12, footerY, sidebarWidth - 24, footerHeight, ui.palette.panel)
    drawPanelTitle("Controls", "", margin + 12, footerY, sidebarWidth - 24)
    love.graphics.setFont(ui.fonts.small)
    setColor(ui.palette.muted)
    love.graphics.printf("Enter send   Shift+Enter newline   Cmd/Ctrl+Z undo\nCmd/Ctrl+Shift+Z redo   double click select word", margin + 28, footerY + 48, sidebarWidth - 56, "left")
    love.graphics.setFont(ui.fonts.body)
  end

  local leftPanelX = contentX + 16
  local leftPanelY = contentTop + 14
  local leftPanelW = lowerLeftWidth - 32
  drawPanelTitle("Session + input", "Edit the prompt, inspect memory, then run the agent.", contentX, contentTop, lowerLeftWidth)
  local inputBoxY = leftPanelY + 42
  if inputBox then
    inputBox:setFont(ui.fonts.body)
    inputBox:setRect(leftPanelX, inputBoxY, leftPanelW, 148)
    inputBox:draw({
      bg = ui.palette.panelAlt,
      border = ui.palette.border,
      accent = ui.palette.accent,
      text = ui.palette.text,
      muted = ui.palette.muted,
      selection = { ui.palette.accent[1], ui.palette.accent[2], ui.palette.accent[3], 0.24 },
      cursor = ui.palette.text,
      placeholder = ui.palette.muted
    })
  end
  local leftContentX = leftPanelX
  local leftContentY = inputBoxY + 164
  local leftContentW = leftPanelW - 14
  local leftViewportH = lowerHeight - (leftContentY - contentTop) - 18
  local walkthroughBody = walkthroughText()
  local memoryBody = memoryPreviewText()
  local leftContentHeight = 0
  leftContentHeight = leftContentHeight + 22 + measureWrappedText(walkthroughBody, leftContentW) + 18
  leftContentHeight = leftContentHeight + 22 + measureWrappedText(memoryBody, leftContentW) + 12
  local leftScroll = registerScrollRegion("leftPanel", leftContentX, leftContentY, leftContentW, leftViewportH, leftContentHeight)
  love.graphics.setScissor(leftContentX, leftContentY, leftContentW, leftViewportH)
  local leftDrawY = leftContentY - leftScroll
  drawWrappedText("Walkthrough", leftContentX, leftDrawY, leftContentW, ui.palette.text)
  leftDrawY = leftDrawY + 22
  leftDrawY = leftDrawY + drawWrappedText(walkthroughBody, leftContentX, leftDrawY, leftContentW, ui.palette.muted) + 18
  drawWrappedText("Memory preview", leftContentX, leftDrawY, leftContentW, ui.palette.text)
  leftDrawY = leftDrawY + 22
  drawWrappedText(memoryBody, leftContentX, leftDrawY, leftContentW, ui.palette.muted)
  love.graphics.setScissor()
  drawVerticalScrollbar(leftContentX, leftContentY, leftPanelW, leftViewportH, leftScroll, leftContentHeight)

  local rightPanelX = contentX + lowerLeftWidth + gutter + 16
  local rightPanelY = contentTop + 14
  local rightPanelW = lowerRightWidth - 32
  drawPanelTitle("Execution trace", "Read plan, answer, and recent conversation in one place.", contentX + lowerLeftWidth + gutter, contentTop, lowerRightWidth)
  local traceViewportX = rightPanelX
  local traceViewportY = rightPanelY + 42
  local traceViewportW = rightPanelW - 14
  local traceViewportH = lowerHeight - (traceViewportY - contentTop) - 18
  local traceContentHeight = 0
  if planText ~= "" then
    traceContentHeight = traceContentHeight + 22 + measureWrappedText(planText, traceViewportW) + 14
  end
  if answerText ~= "" then
    traceContentHeight = traceContentHeight + 22 + measureWrappedText(answerText, traceViewportW) + 14
  end
  if errorText ~= "" then
    traceContentHeight = traceContentHeight + 22 + measureWrappedText(firstLine(errorText), traceViewportW) + 14
  end
  local recentConversationBody = visibleConversationText(8, 220)
  traceContentHeight = traceContentHeight + 22 + measureWrappedText(recentConversationBody, traceViewportW) + 12
  local traceScroll = registerScrollRegion("rightPanel", traceViewportX, traceViewportY, traceViewportW, traceViewportH, traceContentHeight)
  love.graphics.setScissor(traceViewportX, traceViewportY, traceViewportW, traceViewportH)
  local traceY = traceViewportY - traceScroll
  if planText ~= "" then
    drawWrappedText("Plan", traceViewportX, traceY, traceViewportW, ui.palette.text)
    traceY = traceY + 22
    traceY = traceY + drawWrappedText(planText, traceViewportX, traceY, traceViewportW, ui.palette.muted) + 14
  end
  if answerText ~= "" then
    drawWrappedText("Last answer", traceViewportX, traceY, traceViewportW, ui.palette.text)
    traceY = traceY + 22
    traceY = traceY + drawWrappedText(answerText, traceViewportX, traceY, traceViewportW, ui.palette.text) + 14
  end
  if errorText ~= "" then
    drawWrappedText("Error", traceViewportX, traceY, traceViewportW, ui.palette.danger)
    traceY = traceY + 22
    traceY = traceY + drawWrappedText(firstLine(errorText), traceViewportX, traceY, traceViewportW, ui.palette.danger) + 14
  end
  drawWrappedText("Recent conversation", traceViewportX, traceY, traceViewportW, ui.palette.text)
  traceY = traceY + 22
  drawWrappedText(recentConversationBody, traceViewportX, traceY, traceViewportW, ui.palette.muted)
  love.graphics.setScissor()
  drawVerticalScrollbar(traceViewportX, traceViewportY, rightPanelW, traceViewportH, traceScroll, traceContentHeight)
end

function love.quit()
  if httpClient then
    httpClient:destroy()
  end
  for _, c in pairs(clients) do
    if type(c.destroy) == "function" then
      c:destroy()
    end
  end
end
