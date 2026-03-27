local async = require("async")
local llm = require("llm")

local function isNonEmptyString(v)
  return type(v) == "string" and v ~= ""
end

local function shallowCopyTable(t)
  if type(t) ~= "table" then
    return nil
  end
  local out = {}
  for k, v in pairs(t) do
    out[k] = v
  end
  return out
end

local function mergeTables(a, b)
  local out = shallowCopyTable(a) or {}
  if type(b) == "table" then
    for k, v in pairs(b) do
      out[k] = v
    end
  end
  return out
end

local function normalizeStringArray(v)
  if type(v) == "string" then
    return v ~= "" and { v } or nil
  end
  if type(v) ~= "table" then
    return nil
  end
  local out = {}
  for i = 1, #v do
    if isNonEmptyString(v[i]) then
      out[#out + 1] = v[i]
    end
  end
  if #out == 0 then
    return nil
  end
  return out
end

local function concatStringArrays(a, b)
  local aa = normalizeStringArray(a)
  local bb = normalizeStringArray(b)
  if not aa and not bb then
    return nil
  end
  local out = {}
  if aa then
    for i = 1, #aa do
      out[#out + 1] = aa[i]
    end
  end
  if bb then
    for i = 1, #bb do
      out[#out + 1] = bb[i]
    end
  end
  if #out == 0 then
    return nil
  end
  return out
end

local function makeLookup(items)
  if type(items) ~= "table" or #items == 0 then
    return nil
  end
  local out = {}
  for i = 1, #items do
    out[items[i]] = true
  end
  return out
end

local function combinePredicates(a, b)
  if type(a) ~= "function" then
    return b
  end
  if type(b) ~= "function" then
    return a
  end
  return function(...)
    return a(...) and b(...)
  end
end

local function looksLikeAsyncTask(v)
  return type(v) == "table"
      and type(v.isRunning) == "function"
      and type(v.next) == "function"
      and type(v.catch) == "function"
end

local function truncateString(s, maxLen)
  if type(s) ~= "string" then
    s = tostring(s or "")
  end
  maxLen = tonumber(maxLen or 0) or 0
  if maxLen > 0 and #s > maxLen then
    return s:sub(1, maxLen)
  end
  return s
end

local function trimMessageContent(content, maxLen)
  if type(content) == "string" then
    return truncateString(content, maxLen)
  end
  if type(content) ~= "table" then
    return truncateString(tostring(content or ""), maxLen)
  end

  local out = {}
  for i = 1, #content do
    local block = content[i]
    if type(block) == "table" then
      local cloned = shallowCopyTable(block) or {}
      if type(cloned.text) == "string" then
        cloned.text = truncateString(cloned.text, maxLen)
      end
      if type(cloned.content) == "string" then
        cloned.content = truncateString(cloned.content, maxLen)
      end
      out[#out + 1] = cloned
    end
  end
  return out
end

local function messageContentToText(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return tostring(content or "")
  end

  local parts = {}
  for i = 1, #content do
    local block = content[i]
    if type(block) == "table" then
      if type(block.text) == "string" and block.text ~= "" then
        parts[#parts + 1] = block.text
      elseif type(block.content) == "string" and block.content ~= "" then
        parts[#parts + 1] = block.content
      elseif type(block.name) == "string" and block.name ~= "" then
        parts[#parts + 1] = block.name
      end
    end
  end
  if #parts == 0 then
    return ""
  end
  return table.concat(parts, "\n")
end

local function appendSection(lines, title, value)
  if not isNonEmptyString(value) then
    return
  end
  lines[#lines + 1] = title .. ":\n" .. value
end

local function appendBulletSection(lines, title, items)
  local arr = normalizeStringArray(items)
  if not arr then
    return
  end
  local section = { title .. ":" }
  for i = 1, #arr do
    section[#section + 1] = "- " .. arr[i]
  end
  lines[#lines + 1] = table.concat(section, "\n")
end

local function buildSystemText(baseSystem, opts)
  opts = opts or {}
  local lines = {}
  if isNonEmptyString(baseSystem) then
    lines[#lines + 1] = baseSystem
  end
  appendBulletSection(lines, "Instructions", opts.instructions)
  appendBulletSection(lines, "Constraints", opts.constraints)
  appendSection(lines, "Working memory", opts.memory)
  appendSection(lines, "Conversation summary", opts.historySummary)
  appendSection(lines, "Plan", opts.plan)
  return table.concat(lines, "\n\n")
end

local function trimMessages(messages, maxMessages, keepFirst)
  if type(messages) ~= "table" then
    return
  end
  maxMessages = tonumber(maxMessages or 0) or 0
  keepFirst = tonumber(keepFirst or 0) or 0
  if maxMessages <= 0 then
    return
  end
  if #messages <= maxMessages then
    return
  end
  if keepFirst < 0 then
    keepFirst = 0
  end
  if keepFirst > #messages then
    keepFirst = #messages
  end
  while #messages > maxMessages and #messages > keepFirst do
    table.remove(messages, keepFirst + 1)
  end
end

local function contentHasBlockType(content, blockType)
  if type(content) ~= "table" then
    return false
  end
  for i = 1, #content do
    local block = content[i]
    if type(block) == "table" and block.type == blockType then
      return true
    end
  end
  return false
end

local function trimOpenAIToolExchange(messages, keepFirst)
  for i = keepFirst + 1, #messages do
    local msg = messages[i]
    if type(msg) == "table" and msg.role == "assistant" and type(msg.tool_calls) == "table" and #msg.tool_calls > 0 then
      table.remove(messages, i)
      while i <= #messages do
        local nextMsg = messages[i]
        if type(nextMsg) == "table" and nextMsg.role == "tool" then
          table.remove(messages, i)
        else
          break
        end
      end
      return true
    end
  end
  return false
end

local function trimAnthropicToolExchange(messages, keepFirst)
  for i = keepFirst + 1, #messages do
    local msg = messages[i]
    if type(msg) == "table" and msg.role == "assistant" and contentHasBlockType(msg.content, "tool_use") then
      table.remove(messages, i)
      local nextMsg = messages[i]
      if type(nextMsg) == "table" and nextMsg.role == "user" and contentHasBlockType(nextMsg.content, "tool_result") then
        table.remove(messages, i)
      end
      return true
    end
  end
  return false
end

local function trimConversationMessages(messages, provider, maxMessages, keepFirst)
  if type(messages) ~= "table" then
    return
  end
  maxMessages = tonumber(maxMessages or 0) or 0
  keepFirst = tonumber(keepFirst or 0) or 0
  if maxMessages <= 0 or #messages <= maxMessages then
    return
  end
  while #messages > maxMessages and #messages > keepFirst do
    local removed = false
    if provider == "openai" then
      removed = trimOpenAIToolExchange(messages, keepFirst)
    elseif provider == "anthropic" then
      removed = trimAnthropicToolExchange(messages, keepFirst)
    end
    if not removed then
      table.remove(messages, keepFirst + 1)
    end
  end
end

local function validateToolInput(schema, input)
  if type(schema) ~= "table" then
    return nil, "invalid schema"
  end
  if schema.type == "object" then
    if type(input) ~= "table" then
      return nil, "input must be an object"
    end
    local props = type(schema.properties) == "table" and schema.properties or {}
    local required = type(schema.required) == "table" and schema.required or nil
    if required then
      for i = 1, #required do
        local key = required[i]
        if type(key) == "string" and input[key] == nil then
          return nil, "missing field: " .. key
        end
      end
    end
    if schema.additionalProperties == false then
      for k, _ in pairs(input) do
        if props[k] == nil then
          return nil, "unknown field: " .. tostring(k)
        end
      end
    end
    for k, spec in pairs(props) do
      if input[k] ~= nil and type(spec) == "table" and type(spec.type) == "string" then
        local v = input[k]
        local t = spec.type
        if t == "string" then
          if type(v) ~= "string" then
            return nil, "field '" .. tostring(k) .. "' must be a string"
          end
        elseif t == "number" then
          if type(v) ~= "number" and not (type(v) == "string" and tonumber(v) ~= nil) then
            return nil, "field '" .. tostring(k) .. "' must be a number"
          end
        elseif t == "boolean" then
          if type(v) ~= "boolean" then
            return nil, "field '" .. tostring(k) .. "' must be a boolean"
          end
        elseif t == "object" then
          if type(v) ~= "table" then
            return nil, "field '" .. tostring(k) .. "' must be an object"
          end
        elseif t == "array" then
          if type(v) ~= "table" then
            return nil, "field '" .. tostring(k) .. "' must be an array"
          end
        end
      end
    end
  end
  return true, nil
end

local ToolRegistry = {}
ToolRegistry.__index = ToolRegistry

function ToolRegistry.new()
  local self = setmetatable({}, ToolRegistry)
  self._tools = {}
  return self
end

function ToolRegistry:register(tool)
  if type(tool) ~= "table" then
    error("tool must be a table", 2)
  end
  if not isNonEmptyString(tool.name) then
    error("tool.name must be a non-empty string", 2)
  end
  if not isNonEmptyString(tool.description) then
    error("tool.description must be a non-empty string", 2)
  end
  if type(tool.schema) ~= "table" then
    error("tool.schema must be a table (JSON schema)", 2)
  end
  if type(tool.handler) ~= "function" then
    error("tool.handler must be a function", 2)
  end

  self._tools[tool.name] = {
    name = tool.name,
    description = tool.description,
    schema = tool.schema,
    handler = tool.handler,
    tags = normalizeStringArray(tool.tags)
  }
end

function ToolRegistry:get(name)
  return self._tools[name]
end

local function toolMatchesTags(tool, tagLookup)
  if not tagLookup then
    return true
  end
  local tags = type(tool) == "table" and tool.tags or nil
  if type(tags) ~= "table" then
    return false
  end
  for i = 1, #tags do
    if tagLookup[tags[i]] then
      return true
    end
  end
  return false
end

function ToolRegistry:list(opts)
  opts = opts or {}
  local out = {}
  local nameLookup = makeLookup(normalizeStringArray(opts.toolNames))
  local tagLookup = makeLookup(normalizeStringArray(opts.toolTags or opts.tags))
  local filter = opts.toolFilter or opts.filter
  for name, tool in pairs(self._tools) do
    if (not nameLookup or nameLookup[name])
        and toolMatchesTags(tool, tagLookup)
        and (type(filter) ~= "function" or filter(tool, opts) ~= false) then
      out[#out + 1] = {
        name = name,
        description = tool.description,
        schema = tool.schema,
        handler = tool.handler,
        tags = tool.tags
      }
    end
  end
  table.sort(out, function(a, b)
    return tostring(a.name) < tostring(b.name)
  end)
  local maxTools = tonumber(opts.maxTools or 0) or 0
  if maxTools > 0 and #out > maxTools then
    for i = #out, maxTools + 1, -1 do
      out[i] = nil
    end
  end
  return out
end

function ToolRegistry:openaiTools(opts)
  local tools = {}
  local list = self:list(opts)
  for i = 1, #list do
    local t = list[i]
    tools[#tools + 1] = {
      type = "function",
      ["function"] = {
        name = t.name,
        description = t.description,
        parameters = t.schema
      }
    }
  end
  return tools
end

function ToolRegistry:anthropicTools(opts)
  local tools = {}
  local list = self:list(opts)
  for i = 1, #list do
    local t = list[i]
    tools[#tools + 1] = {
      name = t.name,
      description = t.description,
      input_schema = t.schema
    }
  end
  return tools
end

local Agent = {}
Agent.__index = Agent

local function normalizeProvider(p)
  if type(p) ~= "string" then
    return nil
  end
  p = string.lower(p)
  if p == "openai" then
    return "openai"
  end
  if p == "anthropic" then
    return "anthropic"
  end
  return nil
end

function Agent.new(opts)
  opts = opts or {}
  if type(opts.client) ~= "table" or type(opts.client.chat) ~= "function" then
    error("opts.client must be a llm client (with :chat())", 2)
  end

  local provider = normalizeProvider(opts.provider or opts.client.provider)
  if not provider then
    error("opts.provider must be 'openai' or 'anthropic' (or client.provider must be set)", 2)
  end

  local self = setmetatable({}, Agent)
  self.client = opts.client
  self.provider = provider
  self.registry = opts.registry or ToolRegistry.new()
  self.system = opts.system or "You are a helpful agent. Use tools when they help."
  self.instructions = normalizeStringArray(opts.instructions)
  self.constraints = normalizeStringArray(opts.constraints)
  self.planGuidelines = normalizeStringArray(opts.planGuidelines)
  self.toolNames = normalizeStringArray(opts.toolNames)
  self.toolTags = normalizeStringArray(opts.toolTags)
  self.toolSelector = opts.toolSelector
  self.maxSteps = tonumber(opts.maxSteps or 12) or 12
  self.withPlan = opts.withPlan ~= false
  self.model = opts.model
  self.temperature = opts.temperature
  self.planToolLimit = tonumber(opts.planToolLimit or 8) or 8
  self.maxHistoryMessages = tonumber(opts.maxHistoryMessages or 8) or 8
  self.maxHistorySummaryChars = tonumber(opts.maxHistorySummaryChars or 1200) or 1200
  return self
end

local function ensureAnthropicContent(content)
  if type(content) == "string" then
    return { { type = "text", text = content } }
  end
  if type(content) == "table" then
    return content
  end
  return { { type = "text", text = tostring(content) } }
end

local function openaiGetToolCalls(json)
  if type(json) ~= "table" then
    return nil
  end
  local choices = json.choices
  if type(choices) ~= "table" then
    return nil
  end
  local first = choices[1]
  if type(first) ~= "table" then
    return nil
  end
  local msg = first.message
  if type(msg) ~= "table" then
    return nil
  end
  local calls = msg.tool_calls
  if type(calls) ~= "table" or #calls == 0 then
    return nil
  end
  local out = {}
  for i = 1, #calls do
    local c = calls[i]
    if type(c) == "table" and type(c.id) == "string" and type(c["function"]) == "table" then
      local fn = c["function"]
      local name = fn.name
      local args = fn.arguments
      if type(name) == "string" then
        out[#out + 1] = { id = c.id, name = name, arguments = args }
      end
    end
  end
  if #out == 0 then
    return nil
  end
  return out
end

local function anthropicGetToolUses(json)
  if type(json) ~= "table" then
    return nil
  end
  local content = json.content
  if type(content) ~= "table" or #content == 0 then
    return nil
  end
  local out = {}
  for i = 1, #content do
    local block = content[i]
    if type(block) == "table" and block.type == "tool_use" then
      local id = block.id
      local name = block.name
      local input = block.input
      if type(id) == "string" and type(name) == "string" then
        out[#out + 1] = { id = id, name = name, input = input }
      end
    end
  end
  if #out == 0 then
    return nil
  end
  return out
end

local function jsonStringify(v)
  if type(v) == "string" then
    return v
  end
  if type(v) == "table" then
    return llm.jsonEncode(v)
  end
  if v == nil then
    return "null"
  end
  return tostring(v)
end

local function mergeToolOptions(base, extra)
  local out = shallowCopyTable(base) or {}
  if type(extra) ~= "table" then
    return out
  end
  if extra.toolNames ~= nil then
    out.toolNames = normalizeStringArray(extra.toolNames)
  end
  if extra.toolTags ~= nil or extra.tags ~= nil then
    out.toolTags = normalizeStringArray(extra.toolTags or extra.tags)
  end
  if extra.maxTools ~= nil then
    out.maxTools = tonumber(extra.maxTools or 0) or 0
  end
  local filter = extra.toolFilter or extra.filter
  if type(filter) == "function" then
    out.toolFilter = combinePredicates(out.toolFilter, filter)
  end
  return out
end

local function resolveToolOptions(self, goal, opts, phase)
  local resolved = {
    toolNames = self.toolNames,
    toolTags = self.toolTags
  }
  local ctx = {
    goal = goal,
    phase = phase,
    provider = self.provider,
    registry = self.registry
  }
  if type(self.toolSelector) == "function" then
    resolved = mergeToolOptions(resolved, self.toolSelector(ctx))
  end
  if type(opts) == "table" and type(opts.toolSelector) == "function" then
    resolved = mergeToolOptions(resolved, opts.toolSelector(ctx))
  end
  return mergeToolOptions(resolved, opts)
end

local function planToolSummary(registry, toolOpts, maxTools)
  if type(registry) ~= "table" or type(registry.list) ~= "function" then
    return "Available tools:\n- none"
  end

  local list = registry:list(toolOpts)
  if type(list) ~= "table" or #list == 0 then
    return "Available tools:\n- none"
  end

  local lines = { "Available tools:" }
  local shown = #list
  maxTools = tonumber(maxTools or 0) or 0
  if maxTools > 0 and shown > maxTools then
    shown = maxTools
  end
  for i = 1, shown do
    local tool = list[i]
    lines[#lines + 1] = "- " .. tostring(tool.name) .. ": " .. truncateString(tostring(tool.description or ""), 140)
  end
  if shown < #list then
    lines[#lines + 1] = "- ... and " .. tostring(#list - shown) .. " more tools"
  end
  return table.concat(lines, "\n")
end

local function buildPlanPrompt(systemText, registry, toolOpts, planGuidelines, maxTools)
  local lines = {
    "Create a short execution plan for this agent.",
    "Return ONLY a JSON array of strings.",
    "No markdown.",
    "No extra text.",
    "Base the plan on the agent's actual capabilities and available tools.",
    "Do not mention importing libraries, writing Python, or using unsupported runtimes unless the goal explicitly asks for code generation.",
    "When a tool is relevant, refer to it by its exact tool name."
  }
  appendBulletSection(lines, "Plan rules", planGuidelines)
  if isNonEmptyString(systemText) then
    lines[#lines + 1] = "Agent profile:\n" .. systemText
  end
  lines[#lines + 1] = planToolSummary(registry, toolOpts, maxTools)
  return table.concat(lines, "\n")
end

local function compactHistoryMessages(provider, history, maxHistoryMessages, maxSummaryChars)
  if type(history) ~= "table" or #history == 0 then
    return {}, nil
  end

  local normalized = {}
  for i = 1, #history do
    local msg = history[i]
    if type(msg) == "table" then
      if provider == "openai" then
        local copy = shallowCopyTable(msg) or {}
        if copy.content ~= nil then
          copy.content = trimMessageContent(copy.content, 2000)
        end
        normalized[#normalized + 1] = copy
      else
        local role = msg.role == "assistant" and "assistant" or "user"
        normalized[#normalized + 1] = {
          role = role,
          content = ensureAnthropicContent(trimMessageContent(messageContentToText(msg.content), 2000))
        }
      end
    end
  end

  if #normalized == 0 then
    return {}, nil
  end

  maxHistoryMessages = tonumber(maxHistoryMessages or 0) or 0
  if maxHistoryMessages < 0 then
    maxHistoryMessages = 0
  end
  if #normalized <= maxHistoryMessages then
    return normalized, nil
  end

  local splitAt = #normalized - maxHistoryMessages
  local summaryLines = {}
  for i = 1, splitAt do
    local msg = normalized[i]
    local role = tostring(msg.role or "user")
    local text = truncateString(messageContentToText(msg.content), 180)
    if text ~= "" then
      summaryLines[#summaryLines + 1] = role .. ": " .. text
    end
  end

  local summary = nil
  if #summaryLines > 0 then
    summary = truncateString(table.concat(summaryLines, "\n"), tonumber(maxSummaryChars or 0) or 0)
  end

  local recent = {}
  for i = splitAt + 1, #normalized do
    recent[#recent + 1] = normalized[i]
  end
  return recent, summary
end

local function buildRunMessages(provider, systemText, history, goalText)
  local recentHistory = history or {}
  if provider == "openai" then
    local messages = {
      { role = "system", content = systemText }
    }
    for i = 1, #recentHistory do
      messages[#messages + 1] = recentHistory[i]
    end
    messages[#messages + 1] = { role = "user", content = goalText }
    return messages
  end

  local messages = {}
  for i = 1, #recentHistory do
    messages[#messages + 1] = recentHistory[i]
  end
  messages[#messages + 1] = { role = "user", content = ensureAnthropicContent(goalText) }
  return messages
end

local function extractFirstJsonArray(text)
  if type(text) ~= "string" then
    return nil
  end

  local function tryDecode(s)
    local ok, decodedOrErr = pcall(llm.jsonDecode, s)
    if ok and type(decodedOrErr) == "table" then
      return decodedOrErr
    end
    return nil
  end

  local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
  local direct = tryDecode(trimmed)
  if direct then
    return direct
  end

  for block in trimmed:gmatch("```[%w_%-%+]*\n(.-)\n```") do
    local btrim = block:gsub("^%s+", ""):gsub("%s+$", "")
    local decoded = tryDecode(btrim)
    if decoded then
      return decoded
    end
  end

  local len = #trimmed
  local function findArrayFrom(startAt)
    local depth = 0
    local inString = false
    local escaped = false
    for pos = startAt, len do
      local c = trimmed:sub(pos, pos)
      if inString then
        if escaped then
          escaped = false
        elseif c == "\\" then
          escaped = true
        elseif c == "\"" then
          inString = false
        end
      else
        if c == "\"" then
          inString = true
        elseif c == "[" then
          depth = depth + 1
        elseif c == "]" then
          depth = depth - 1
          if depth == 0 then
            return trimmed:sub(startAt, pos)
          end
        end
      end
    end
    return nil
  end

  local start = 1
  while true do
    local sidx = trimmed:find("%[", start)
    if not sidx then
      break
    end
    local sub = findArrayFrom(sidx)
    if sub then
      local decoded = tryDecode(sub)
      if decoded then
        return decoded
      end
    end
    start = sidx + 1
  end

  local lines = {}
  for line in trimmed:gmatch("([^\n\r]+)") do
    lines[#lines + 1] = line
  end
  local items = {}
  for i = 1, #lines do
    local line = lines[i]
    local item = line:match("^%s*[%-%*]%s+(.+)$") or line:match("^%s*%d+[%.)]%s+(.+)$")
    if item then
      item = item:gsub("^%s+", ""):gsub("%s+$", "")
      if item ~= "" then
        items[#items + 1] = item
      end
    end
  end
  if #items > 0 then
    return items
  end

  return nil
end

local function extractFirstJsonObject(text)
  if type(text) ~= "string" then
    return nil
  end

  local function tryDecode(s)
    local ok, decodedOrErr = pcall(llm.jsonDecode, s)
    if ok and type(decodedOrErr) == "table" then
      return decodedOrErr
    end
    return nil
  end

  local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
  local direct = tryDecode(trimmed)
  if direct then
    return direct
  end

  for block in trimmed:gmatch("```[%w_%-%+]*\n(.-)\n```") do
    local btrim = block:gsub("^%s+", ""):gsub("%s+$", "")
    local decoded = tryDecode(btrim)
    if decoded then
      return decoded
    end
  end

  local len = #trimmed
  local function findObjectFrom(startAt)
    local depth = 0
    local inString = false
    local escaped = false
    for pos = startAt, len do
      local c = trimmed:sub(pos, pos)
      if inString then
        if escaped then
          escaped = false
        elseif c == "\\" then
          escaped = true
        elseif c == "\"" then
          inString = false
        end
      else
        if c == "\"" then
          inString = true
        elseif c == "{" then
          depth = depth + 1
        elseif c == "}" then
          depth = depth - 1
          if depth == 0 then
            return trimmed:sub(startAt, pos)
          end
        end
      end
    end
    return nil
  end

  local start = 1
  while true do
    local sidx = trimmed:find("{", start, true)
    if not sidx then
      break
    end
    local sub = findObjectFrom(sidx)
    if sub then
      local decoded = tryDecode(sub)
      if decoded then
        return decoded
      end
    end
    start = sidx + 1
  end

  return nil
end

local function runTool(registry, call, ctx)
  local tool = registry:get(call.name)
  if not tool then
    return nil, "unknown tool: " .. tostring(call.name)
  end
  if call and call._argError then
    return nil, tostring(call._argError)
  end
  local okValidate, validateErr = validateToolInput(tool.schema, call.input or {})
  if not okValidate then
    return nil, tostring(validateErr)
  end

  local ok, result, err = pcall(tool.handler, call.input or {}, ctx)
  if not ok then
    return nil, tostring(result)
  end
  if err ~= nil then
    return nil, tostring(err)
  end

  if looksLikeAsyncTask(result) then
    local resp, asyncErr, extra = async.await(result)
    if extra == "errored" then
      return nil, tostring(asyncErr)
    end
    if extra == "stopped" then
      return nil, "tool stopped"
    end
    if asyncErr ~= nil then
      return nil, tostring(asyncErr)
    end
    return resp, nil
  end

  return result, nil
end

function Agent:plan(goal, opts)
  opts = opts or {}
  local provider = self.provider

  local messages
  local extra = shallowCopyTable(opts.extra) or {}
  local toolOpts = resolveToolOptions(self, goal, opts, "plan")
  local systemText = buildSystemText(opts.system or self.system, {
    instructions = concatStringArrays(self.instructions, opts.instructions),
    constraints = concatStringArrays(self.constraints, opts.constraints),
    memory = opts.memory
  })
  local prompt = buildPlanPrompt(systemText, self.registry, toolOpts, concatStringArrays(self.planGuidelines, opts.planGuidelines), opts.planToolLimit or self.planToolLimit)

  if provider == "openai" then
    messages = {
      { role = "system", content = prompt },
      { role = "user", content = tostring(goal or "") }
    }
  else
    messages = {
      { role = "user", content = ensureAnthropicContent(tostring(goal or "")) }
    }
  end

  local task = self.client:chat({
    model = opts.model or self.model,
    temperature = opts.temperature or self.temperature or 0,
    messages = messages,
    system = provider == "anthropic" and prompt or nil,
    extra = extra,
    timeout = opts.timeout
  })

  return async(function()
    local result, err, extra2 = async.await(task)
    if type(result) ~= "table" then
      return nil, err, extra2
    end
    local text = tostring(result.text or "")
    local plan = extractFirstJsonArray(text)
    if type(plan) ~= "table" then
      return nil, "plan parse failed", { raw = text }
    end
    return plan
  end)
end

function Agent:run(goal, opts)
  opts = opts or {}
  local provider = self.provider
  local maxSteps = tonumber(opts.maxSteps or self.maxSteps) or 12
  local goalText = tostring(goal or "")
  local toolOpts = resolveToolOptions(self, goalText, opts, "run")
  local planOpts = mergeTables(toolOpts, {
    model = opts.model,
    timeout = opts.timeout,
    temperature = opts.temperature,
    system = opts.system,
    instructions = opts.instructions,
    constraints = opts.constraints,
    memory = opts.memory,
    planGuidelines = opts.planGuidelines,
    planToolLimit = opts.planToolLimit
  })

  local planList = nil
  if opts.plan ~= nil then
    if opts.plan == false then
      planList = nil
    elseif type(opts.plan) == "table" then
      planList = opts.plan
    end
  else
    if opts.withPlan == nil then
      if self.withPlan then
        local p = self:plan(goalText, planOpts)
        local planOrNil = async.await(p)
        if type(planOrNil) == "table" then
          planList = planOrNil
        end
      end
    elseif opts.withPlan then
      local p = self:plan(goalText, planOpts)
      local planOrNil = async.await(p)
      if type(planOrNil) == "table" then
        planList = planOrNil
      end
    end
  end

  local historyMessages, historySummary = compactHistoryMessages(
    provider,
    opts.history,
    opts.maxHistoryMessages or self.maxHistoryMessages,
    opts.maxHistorySummaryChars or self.maxHistorySummaryChars
  )
  local systemText = buildSystemText(opts.system or self.system, {
    instructions = concatStringArrays(self.instructions, opts.instructions),
    constraints = concatStringArrays(self.constraints, opts.constraints),
    memory = opts.memory,
    historySummary = historySummary,
    plan = type(planList) == "table" and jsonStringify(planList) or nil
  })
  local messages = buildRunMessages(provider, systemText, historyMessages, goalText)

  return async(function()
    local maxMessages = tonumber(opts.maxMessages or "") or 40
    local maxToolOutputChars = tonumber(opts.maxToolOutputChars or "") or 8000
    local keepFirst = provider == "openai" and 2 or 1
    for step = 1, maxSteps do
      local extra = shallowCopyTable(opts.extra) or {}
      if provider == "openai" then
        local openaiTools = self.registry:openaiTools(toolOpts)
        if #openaiTools > 0 then
          extra.tools = openaiTools
          extra.tool_choice = extra.tool_choice or "auto"
        else
          extra.tools = nil
          extra.tool_choice = nil
        end
      else
        local anthropicTools = self.registry:anthropicTools(toolOpts)
        if #anthropicTools > 0 then
          extra.tools = anthropicTools
        else
          extra.tools = nil
        end
      end

      trimConversationMessages(messages, provider, maxMessages, keepFirst)
      trimMessages(messages, maxMessages, keepFirst)
      local task = self.client:chat({
        model = opts.model or self.model,
        temperature = opts.temperature or self.temperature,
        messages = messages,
        system = provider == "anthropic" and systemText or nil,
        extra = extra,
        timeout = opts.timeout
      })

      local result, err, extra2 = async.await(task)
      if type(result) ~= "table" then
        return nil, err, extra2
      end

      local json = result.json
      if provider == "openai" then
        local toolCalls = openaiGetToolCalls(json)
        if not toolCalls then
          return { ok = true, plan = planList, text = result.text, raw = result }, nil
        end

        local assistantMsg = nil
        if type(json) == "table" and type(json.choices) == "table" and type(json.choices[1]) == "table" then
          assistantMsg = json.choices[1].message
        end
        if type(assistantMsg) == "table" then
          messages[#messages + 1] = assistantMsg
        else
          messages[#messages + 1] = { role = "assistant", content = tostring(result.text or "") }
        end

        for i = 1, #toolCalls do
          local call = toolCalls[i]
          local input = {}
          local argError = nil
          if type(call.arguments) == "string" and call.arguments ~= "" then
            local okArgs, decodedOrErr = pcall(llm.jsonDecode, call.arguments)
            if okArgs and type(decodedOrErr) == "table" then
              input = decodedOrErr
            else
              input = {}
              argError = "invalid tool arguments JSON: " .. tostring(decodedOrErr)
            end
          end
          local out, toolErr = runTool(self.registry, { id = call.id, name = call.name, input = input, _argError = argError }, {
            goal = goalText,
            step = step,
            toolIndex = i,
            provider = provider
          })

          local content
          if toolErr then
            content = "ERROR: " .. tostring(toolErr)
          else
            content = jsonStringify(out)
          end
          content = truncateString(content, maxToolOutputChars)

          messages[#messages + 1] = {
            role = "tool",
            tool_call_id = call.id,
            content = content
          }
        end
      else
        local toolUses = anthropicGetToolUses(json)
        messages[#messages + 1] = { role = "assistant", content = ensureAnthropicContent(type(json) == "table" and json.content or result.text) }
        if not toolUses then
          return { ok = true, plan = planList, text = result.text, raw = result }, nil
        end

        local toolResults = {}
        for i = 1, #toolUses do
          local use = toolUses[i]
          local out, toolErr = runTool(self.registry, { id = use.id, name = use.name, input = use.input or {} }, {
            goal = goalText,
            step = step,
            toolIndex = i,
            provider = provider
          })

          local content
          if toolErr then
            content = "ERROR: " .. tostring(toolErr)
          else
            content = jsonStringify(out)
          end
          content = truncateString(content, maxToolOutputChars)

          toolResults[#toolResults + 1] = {
            type = "tool_result",
            tool_use_id = use.id,
            content = content
          }
        end

        messages[#messages + 1] = { role = "user", content = toolResults }
      end
    end

    return nil, "max steps reached"
  end)
end

local Session = {}
Session.__index = Session

local function concatTextSections(a, b)
  local aa = isNonEmptyString(a) and tostring(a) or nil
  local bb = isNonEmptyString(b) and tostring(b) or nil
  if aa and bb then
    return aa .. "\n\n" .. bb
  end
  return aa or bb
end

local function combineToolSelectors(a, b)
  if type(a) ~= "function" then
    return b
  end
  if type(b) ~= "function" then
    return a
  end
  return function(ctx)
    return mergeToolOptions(a(ctx), b(ctx))
  end
end

local function mergeRequestOptions(base, override)
  local out = shallowCopyTable(base) or {}
  local extra = type(override) == "table" and override or nil
  if not extra then
    return out
  end

  for k, v in pairs(extra) do
    if k ~= "instructions"
        and k ~= "constraints"
        and k ~= "planGuidelines"
        and k ~= "toolNames"
        and k ~= "toolTags"
        and k ~= "tags"
        and k ~= "toolSelector"
        and k ~= "memory"
        and k ~= "extra" then
      out[k] = v
    end
  end

  out.instructions = concatStringArrays(out.instructions, extra.instructions)
  out.constraints = concatStringArrays(out.constraints, extra.constraints)
  out.planGuidelines = concatStringArrays(out.planGuidelines, extra.planGuidelines)
  out.toolNames = concatStringArrays(out.toolNames, extra.toolNames)
  out.toolTags = concatStringArrays(out.toolTags, extra.toolTags or extra.tags)
  out.toolSelector = combineToolSelectors(out.toolSelector, extra.toolSelector)
  out.memory = concatTextSections(out.memory, extra.memory)
  if type(out.extra) == "table" or type(extra.extra) == "table" then
    out.extra = mergeTables(out.extra, extra.extra)
  end
  return out
end

local function concatManyTextSections(...)
  local out = nil
  for i = 1, select("#", ...) do
    out = concatTextSections(out, select(i, ...))
  end
  return out
end

local function normalizeMemoryItems(v)
  if type(v) == "string" then
    local s = v:gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and { s } or {}
  end
  if type(v) ~= "table" then
    return {}
  end
  local out = {}
  for i = 1, #v do
    if isNonEmptyString(v[i]) then
      out[#out + 1] = v[i]
    end
  end
  return out
end

local function cloneStringList(items)
  local out = {}
  if type(items) == "table" then
    for i = 1, #items do
      out[#out + 1] = tostring(items[i])
    end
  end
  return out
end

local function stringListContains(items, value)
  local target = tostring(value or "")
  if target == "" or type(items) ~= "table" then
    return false
  end
  for i = 1, #items do
    if tostring(items[i]) == target then
      return true
    end
  end
  return false
end

local MemoryStore = {}
MemoryStore.__index = MemoryStore

function MemoryStore.new(opts)
  opts = opts or {}
  local self = setmetatable({}, MemoryStore)
  self.summary = isNonEmptyString(opts.summary or opts.text) and tostring(opts.summary or opts.text) or nil
  self.facts = normalizeMemoryItems(opts.facts)
  self.preferences = normalizeMemoryItems(opts.preferences)
  self.goals = normalizeMemoryItems(opts.goals)
  self.notes = normalizeMemoryItems(opts.notes)
  return self
end

function MemoryStore:clone()
  return MemoryStore.new(self:exportState())
end

function MemoryStore:get(section)
  if section == "summary" then
    return self.summary
  end
  if section == "facts" or section == "preferences" or section == "goals" or section == "notes" then
    return cloneStringList(self[section])
  end
  return nil
end

function MemoryStore:set(section, value)
  if section == "summary" then
    self.summary = isNonEmptyString(value) and tostring(value) or nil
    return self
  end
  if section == "facts" or section == "preferences" or section == "goals" or section == "notes" then
    self[section] = normalizeMemoryItems(value)
  end
  return self
end

function MemoryStore:add(section, value)
  if section == "summary" then
    self.summary = concatTextSections(self.summary, value)
    return self
  end
  if section ~= "facts" and section ~= "preferences" and section ~= "goals" and section ~= "notes" then
    return self
  end
  local items = normalizeMemoryItems(value)
  for i = 1, #items do
    if not stringListContains(self[section], items[i]) then
      self[section][#self[section] + 1] = items[i]
    end
  end
  return self
end

function MemoryStore:remove(section, value)
  if section ~= "facts" and section ~= "preferences" and section ~= "goals" and section ~= "notes" then
    return self
  end
  local target = tostring(value or "")
  for i = #self[section], 1, -1 do
    if tostring(self[section][i]) == target then
      table.remove(self[section], i)
    end
  end
  return self
end

function MemoryStore:clear(section)
  if section == nil then
    self.summary = nil
    self.facts = {}
    self.preferences = {}
    self.goals = {}
    self.notes = {}
    return self
  end
  if section == "summary" then
    self.summary = nil
  elseif section == "facts" or section == "preferences" or section == "goals" or section == "notes" then
    self[section] = {}
  end
  return self
end

function MemoryStore:exportState()
  return {
    version = 1,
    summary = self.summary,
    facts = cloneStringList(self.facts),
    preferences = cloneStringList(self.preferences),
    goals = cloneStringList(self.goals),
    notes = cloneStringList(self.notes)
  }
end

function MemoryStore:render()
  local lines = {}
  if isNonEmptyString(self.summary) then
    lines[#lines + 1] = "Summary:\n" .. tostring(self.summary)
  end
  appendBulletSection(lines, "Facts", self.facts)
  appendBulletSection(lines, "Preferences", self.preferences)
  appendBulletSection(lines, "Goals", self.goals)
  appendBulletSection(lines, "Notes", self.notes)
  return #lines > 0 and table.concat(lines, "\n\n") or nil
end

local function coerceMemoryStore(value)
  if type(value) ~= "table" then
    return nil
  end
  if getmetatable(value) == MemoryStore then
    return value:clone()
  end
  if value.summary ~= nil or value.text ~= nil or value.facts ~= nil or value.preferences ~= nil or value.goals ~= nil or value.notes ~= nil then
    return MemoryStore.new(value)
  end
  return nil
end

local function renderMemoryValue(value)
  if type(value) == "table" and getmetatable(value) == MemoryStore then
    return value:render()
  end
  return isNonEmptyString(value) and tostring(value) or nil
end

local function memoryStoreHasContent(store)
  return type(store) == "table"
      and (
        isNonEmptyString(store.summary)
        or (type(store.facts) == "table" and #store.facts > 0)
        or (type(store.preferences) == "table" and #store.preferences > 0)
        or (type(store.goals) == "table" and #store.goals > 0)
        or (type(store.notes) == "table" and #store.notes > 0)
      )
end

local function mergeMemoryStores(base, incoming)
  local out = coerceMemoryStore(base) or MemoryStore.new()
  local update = coerceMemoryStore(incoming)
  if not update then
    return out
  end
  if isNonEmptyString(update.summary) then
    out:set("summary", update.summary)
  end
  out:add("facts", update.facts)
  out:add("preferences", update.preferences)
  out:add("goals", update.goals)
  out:add("notes", update.notes)
  return out
end

local function normalizeMemoryScope(scope)
  if scope == nil or scope == "" or scope == "session" then
    return "session"
  end
  if scope == "workspace" or scope == "global" then
    return scope
  end
  return nil
end

local function memoryScopeTitle(scope)
  if scope == "global" then
    return "Global memory"
  end
  if scope == "workspace" then
    return "Workspace memory"
  end
  return "Session memory"
end

local function getScopedMemoryText(session, scope)
  if scope == "global" then
    return concatManyTextSections(session.globalMemoryStore and session.globalMemoryStore:render() or nil, session.globalMemory)
  end
  if scope == "workspace" then
    return concatManyTextSections(session.workspaceMemoryStore and session.workspaceMemoryStore:render() or nil, session.workspaceMemory)
  end
  return concatManyTextSections(session.memoryStore and session.memoryStore:render() or nil, session.memory)
end

local function buildScopedMemoryText(session, opts)
  opts = opts or {}
  local scopes = {}
  if opts.includeGlobalMemory ~= false then
    scopes[#scopes + 1] = "global"
  end
  if opts.includeWorkspaceMemory ~= false then
    scopes[#scopes + 1] = "workspace"
  end
  if opts.includeSessionMemory ~= false then
    scopes[#scopes + 1] = "session"
  end

  local blocks = {}
  for i = 1, #scopes do
    local scope = scopes[i]
    local text = getScopedMemoryText(session, scope)
    if isNonEmptyString(text) then
      blocks[#blocks + 1] = {
        scope = scope,
        text = text
      }
    end
  end

  if #blocks == 0 then
    return nil
  end
  if #blocks == 1 and blocks[1].scope == "session" then
    return blocks[1].text
  end

  local lines = {}
  for i = 1, #blocks do
    local block = blocks[i]
    lines[#lines + 1] = memoryScopeTitle(block.scope) .. ":\n" .. block.text
  end
  return table.concat(lines, "\n\n")
end

local SceneProfile = {}
SceneProfile.__index = SceneProfile

local function coerceSceneProfile(profile)
  if type(profile) ~= "table" then
    return nil
  end
  if getmetatable(profile) == SceneProfile then
    return profile
  end
  return SceneProfile.new(profile)
end

function SceneProfile.new(opts)
  opts = opts or {}
  local self = setmetatable({}, SceneProfile)
  self.name = opts.name
  self.system = opts.system
  self.instructions = normalizeStringArray(opts.instructions)
  self.constraints = normalizeStringArray(opts.constraints)
  self.planGuidelines = normalizeStringArray(opts.planGuidelines)
  self.memory = renderMemoryValue(coerceMemoryStore(opts.memory) or opts.memory)
  self.toolNames = normalizeStringArray(opts.toolNames)
  self.toolTags = normalizeStringArray(opts.toolTags or opts.tags)
  self.toolSelector = opts.toolSelector
  self.defaults = type(opts.defaults) == "table" and shallowCopyTable(opts.defaults) or nil
  self.plan = type(opts.plan) == "table" and shallowCopyTable(opts.plan) or nil
  self.run = type(opts.run) == "table" and shallowCopyTable(opts.run) or nil
  return self
end

function SceneProfile:resolve(_, phase, opts)
  local out = {
    system = self.system,
    instructions = self.instructions,
    constraints = self.constraints,
    planGuidelines = self.planGuidelines,
    memory = self.memory,
    toolNames = self.toolNames,
    toolTags = self.toolTags,
    toolSelector = self.toolSelector
  }
  out = mergeRequestOptions(out, self.defaults)
  if phase == "plan" then
    out = mergeRequestOptions(out, self.plan)
  elseif phase == "run" then
    out = mergeRequestOptions(out, self.run)
  end
  return mergeRequestOptions(out, opts)
end

local ProfileRouter = {}
ProfileRouter.__index = ProfileRouter

function ProfileRouter.new(opts)
  opts = opts or {}
  local self = setmetatable({}, ProfileRouter)
  self.name = opts.name
  self.selector = opts.selector
  self.defaultProfile = coerceSceneProfile(opts.defaultProfile)
  self.routes = {}
  local routes = type(opts.routes) == "table" and opts.routes or {}
  for i = 1, #routes do
    local route = routes[i]
    if type(route) == "table" then
      self.routes[#self.routes + 1] = {
        name = route.name,
        match = route.match,
        profile = coerceSceneProfile(route.profile)
      }
    end
  end
  return self
end

function ProfileRouter:select(goal, phase, ctx)
  local routeCtx = mergeTables(ctx, {
    goal = goal,
    phase = phase
  })
  if type(self.selector) == "function" then
    local selected = coerceSceneProfile(self.selector(routeCtx))
    if selected then
      return selected, "selector"
    end
  end
  for i = 1, #self.routes do
    local route = self.routes[i]
    if type(route.match) == "function" and route.match(routeCtx) then
      return route.profile, route.name or ("route_" .. tostring(i))
    end
  end
  if self.defaultProfile then
    return self.defaultProfile, "default"
  end
  return nil, nil
end

function ProfileRouter:resolve(goal, phase, ctx)
  local selected, name = self:select(goal, phase, ctx)
  if not selected then
    return nil, name
  end
  return selected:resolve(goal, phase), name
end

local function cloneHistory(history)
  if type(history) ~= "table" then
    return {}
  end
  local out = {}
  for i = 1, #history do
    local item = history[i]
    if type(item) == "table" then
      local copy = shallowCopyTable(item) or {}
      if copy.role == "user" or copy.role == "assistant" then
        out[#out + 1] = copy
      end
    end
  end
  return out
end

local function buildSessionPlanningMemory(memory, history, maxMessages, maxChars)
  local base = isNonEmptyString(memory) and tostring(memory) or ""
  local limit = tonumber(maxMessages or 0) or 0
  local total = type(history) == "table" and #history or 0
  if total == 0 or limit == 0 then
    return base ~= "" and base or nil
  end
  if limit < 0 or limit > total then
    limit = total
  end
  local startIndex = total - limit + 1
  local lines = {}
  for i = startIndex, total do
    local item = history[i]
    if type(item) == "table" then
      local role = item.role == "assistant" and "assistant" or "user"
      local text = truncateString(messageContentToText(item.content), maxChars or 180)
      if text ~= "" then
        lines[#lines + 1] = role .. ": " .. text
      end
    end
  end
  local recent = #lines > 0 and table.concat(lines, "\n") or ""
  if recent == "" then
    return base ~= "" and base or nil
  end
  if base == "" then
    return "Recent conversation:\n" .. recent
  end
  return base .. "\n\nRecent conversation:\n" .. recent
end

local function normalizeScopedMemoryUpdate(value)
  local store = coerceMemoryStore(value)
  if store and memoryStoreHasContent(store) then
    return store
  end
  return nil
end

local MemoryExtractor = {}
MemoryExtractor.__index = MemoryExtractor

function MemoryExtractor.new(opts)
  opts = opts or {}
  local self = setmetatable({}, MemoryExtractor)
  self.client = opts.client
  self.model = opts.model
  self.temperature = opts.temperature
  self.timeout = opts.timeout
  self.system = opts.system
  self.maxHistoryMessages = tonumber(opts.maxHistoryMessages or 6) or 6
  self.maxHistoryChars = tonumber(opts.maxHistoryChars or 240) or 240
  self.scopes = normalizeStringArray(opts.scopes) or { "session" }
  return self
end

function MemoryExtractor:extract(opts)
  opts = opts or {}
  local client = opts.client or self.client
  if type(client) ~= "table" or type(client.chat) ~= "function" then
    return async(function()
      return nil, "memory extractor requires a client"
    end)
  end

  local provider = client.provider
  local allowedScopes = {}
  for i = 1, #self.scopes do
    local scope = normalizeMemoryScope(self.scopes[i])
    if scope then
      allowedScopes[#allowedScopes + 1] = scope
    end
  end
  if #allowedScopes == 0 then
    allowedScopes = { "session" }
  end

  local systemText = table.concat({
    "Extract durable memory candidates from the conversation.",
    "Return ONLY a JSON object.",
    "Use this schema:",
    "{\"session\":{\"summary\":string|null,\"facts\":string[],\"preferences\":string[],\"goals\":string[],\"notes\":string[]},\"workspace\":{...},\"global\":{...}}",
    "Include only scopes from the allowed scopes list.",
    "Only keep stable, useful information.",
    "Do not infer private facts that the user did not explicitly reveal.",
    "Use empty arrays or omit scopes when there is nothing worth saving."
  }, "\n")
  if isNonEmptyString(self.system) then
    systemText = self.system .. "\n\n" .. systemText
  end

  local currentTurn = {
    "Allowed scopes: " .. table.concat(allowedScopes, ", "),
    "User message:\n" .. tostring(opts.goal or ""),
    "Assistant response:\n" .. tostring(opts.answer or "")
  }
  local historyText = buildSessionPlanningMemory(nil, opts.history, self.maxHistoryMessages, self.maxHistoryChars)
  if isNonEmptyString(historyText) then
    currentTurn[#currentTurn + 1] = historyText
  end
  if isNonEmptyString(opts.memoryText) then
    currentTurn[#currentTurn + 1] = "Current memory:\n" .. tostring(opts.memoryText)
  end
  local userText = table.concat(currentTurn, "\n\n")

  local messages
  if provider == "anthropic" then
    messages = {
      { role = "user", content = ensureAnthropicContent(userText) }
    }
  else
    messages = {
      { role = "system", content = systemText },
      { role = "user", content = userText }
    }
  end

  local task = client:chat({
    model = opts.model or self.model,
    temperature = opts.temperature or self.temperature or 0,
    messages = messages,
    system = provider == "anthropic" and systemText or nil,
    timeout = opts.timeout or self.timeout,
    extra = shallowCopyTable(opts.extra)
  })

  return async(function()
    local result, err, extra = async.await(task)
    if type(result) ~= "table" then
      return nil, err, extra
    end
    local decoded = extractFirstJsonObject(result.text or "")
    if type(decoded) ~= "table" then
      return nil, "memory extract parse failed", { raw = result.text }
    end

    local out = {}
    for i = 1, #allowedScopes do
      local scope = allowedScopes[i]
      local normalized = normalizeScopedMemoryUpdate(decoded[scope])
      if normalized then
        out[scope] = normalized
      end
    end
    return out
  end)
end

local function coerceMemoryExtractor(value)
  if type(value) ~= "table" then
    return nil
  end
  if getmetatable(value) == MemoryExtractor then
    return value
  end
  return MemoryExtractor.new(value)
end

local function scopedMemoryKeys(scope)
  if scope == "global" then
    return "globalMemoryStore", "globalMemory"
  end
  if scope == "workspace" then
    return "workspaceMemoryStore", "workspaceMemory"
  end
  return "memoryStore", "memory"
end

local function setScopedMemory(session, scope, memory)
  local storeKey, textKey = scopedMemoryKeys(scope)
  local store = coerceMemoryStore(memory)
  if store then
    session[storeKey] = store
    if storeKey ~= "memoryStore" then
      session[textKey] = nil
    else
      session.memory = nil
    end
    return
  end
  session[textKey] = isNonEmptyString(memory) and tostring(memory) or nil
end

local function setScopedMemoryStore(session, scope, memoryStore)
  local storeKey = scopedMemoryKeys(scope)
  session[storeKey] = coerceMemoryStore(memoryStore)
end

local function getScopedMemoryStore(session, scope)
  local storeKey = scopedMemoryKeys(scope)
  local store = session[storeKey]
  return store and store:clone() or nil
end

local function ensureScopedMemoryStore(session, scope)
  local storeKey = scopedMemoryKeys(scope)
  if not session[storeKey] then
    session[storeKey] = MemoryStore.new()
  end
  return session[storeKey]
end

local function applyScopedMemoryUpdates(session, updates)
  if type(updates) ~= "table" then
    return
  end
  local scopes = { "session", "workspace", "global" }
  for i = 1, #scopes do
    local scope = scopes[i]
    if updates[scope] then
      local storeKey = scopedMemoryKeys(scope)
      session[storeKey] = mergeMemoryStores(session[storeKey], updates[scope])
    end
  end
end

function Session.new(opts)
  opts = opts or {}
  local baseAgent = opts.agent
  if type(baseAgent) ~= "table" then
    baseAgent = Agent.new(opts)
  end
  local self = setmetatable({}, Session)
  self.agent = baseAgent
  local profile = opts.profile
  profile = coerceSceneProfile(profile)
  self.profile = profile
  local router = opts.router
  if type(router) == "table" and getmetatable(router) ~= ProfileRouter then
    router = ProfileRouter.new(router)
  end
  self.router = router
  self.history = cloneHistory(opts.history)
  local initialMemoryStore = coerceMemoryStore(opts.memoryStore)
  if not initialMemoryStore then
    initialMemoryStore = coerceMemoryStore(opts.memory)
  end
  self.memoryStore = initialMemoryStore
  self.memory = isNonEmptyString(opts.memory) and tostring(opts.memory) or nil
  local initialWorkspaceMemoryStore = coerceMemoryStore(opts.workspaceMemoryStore)
  if not initialWorkspaceMemoryStore then
    initialWorkspaceMemoryStore = coerceMemoryStore(opts.workspaceMemory)
  end
  self.workspaceMemoryStore = initialWorkspaceMemoryStore
  self.workspaceMemory = isNonEmptyString(opts.workspaceMemory) and tostring(opts.workspaceMemory) or nil
  local initialGlobalMemoryStore = coerceMemoryStore(opts.globalMemoryStore)
  if not initialGlobalMemoryStore then
    initialGlobalMemoryStore = coerceMemoryStore(opts.globalMemory)
  end
  self.globalMemoryStore = initialGlobalMemoryStore
  self.globalMemory = isNonEmptyString(opts.globalMemory) and tostring(opts.globalMemory) or nil
  self.memoryExtractor = coerceMemoryExtractor(opts.memoryExtractor)
  self.maxPlanningHistoryMessages = tonumber(opts.maxPlanningHistoryMessages or 6) or 6
  self.maxPlanningHistoryChars = tonumber(opts.maxPlanningHistoryChars or 180) or 180
  return self
end

function Session:getHistory()
  return cloneHistory(self.history)
end

function Session:setHistory(history)
  self.history = cloneHistory(history)
end

function Session:clear()
  self.history = {}
end

function Session:setMemory(memory, scope)
  local normalizedScope = normalizeMemoryScope(scope)
  setScopedMemory(self, normalizedScope or "session", memory)
end

function Session:getMemory(scope, opts)
  if type(scope) == "table" and opts == nil then
    opts = scope
    scope = nil
  end
  local normalizedScope = normalizeMemoryScope(scope)
  if normalizedScope then
    return getScopedMemoryText(self, normalizedScope)
  end
  return buildScopedMemoryText(self, opts)
end

function Session:setMemoryStore(memoryStore, scope)
  local normalizedScope = normalizeMemoryScope(scope)
  setScopedMemoryStore(self, normalizedScope or "session", memoryStore)
end

function Session:getMemoryStore(scope)
  local normalizedScope = normalizeMemoryScope(scope)
  return getScopedMemoryStore(self, normalizedScope or "session")
end

function Session:remember(section, value, scope)
  local normalizedScope = normalizeMemoryScope(scope)
  local store = ensureScopedMemoryStore(self, normalizedScope or "session")
  store:add(section, value)
  return self
end

function Session:forget(section, value, scope)
  local normalizedScope = normalizeMemoryScope(scope)
  local storeKey = scopedMemoryKeys(normalizedScope or "session")
  if self[storeKey] then
    self[storeKey]:remove(section, value)
  end
  return self
end

function Session:clearMemory(section, scope)
  local normalizedScope = normalizeMemoryScope(scope)
  local storeKey, textKey = scopedMemoryKeys(normalizedScope or "session")
  if self[storeKey] then
    self[storeKey]:clear(section)
  end
  if section == nil or section == "summary" then
    self[textKey] = nil
  end
  return self
end

function Session:setMemoryExtractor(memoryExtractor)
  self.memoryExtractor = coerceMemoryExtractor(memoryExtractor)
end

function Session:getMemoryExtractor()
  return self.memoryExtractor
end

function Session:setProfile(profile)
  if type(profile) == "table" and getmetatable(profile) ~= SceneProfile then
    profile = SceneProfile.new(profile)
  end
  self.profile = profile
end

function Session:getProfile()
  return self.profile
end

function Session:setRouter(router)
  if type(router) == "table" and getmetatable(router) ~= ProfileRouter then
    router = ProfileRouter.new(router)
  end
  self.router = router
end

function Session:getRouter()
  return self.router
end

local function resolveSessionProfileOptions(session, goal, phase)
  local resolved = nil
  if session.profile then
    resolved = session.profile:resolve(goal, phase)
  end
  if session.router then
    local routed = session.router:resolve(goal, phase, {
      session = session,
      history = session.history,
      memory = session:getMemory(),
      memoryStore = session.memoryStore,
      workspaceMemory = session.workspaceMemory,
      workspaceMemoryStore = session.workspaceMemoryStore,
      globalMemory = session.globalMemory,
      globalMemoryStore = session.globalMemoryStore,
      profile = session.profile
    })
    resolved = mergeRequestOptions(resolved, routed)
  end
  return resolved
end

local function copySerializableValue(value)
  local tv = type(value)
  if tv == "nil" or tv == "string" or tv == "number" or tv == "boolean" then
    return value
  end
  if tv ~= "table" then
    return nil
  end
  local out = {}
  local isArray = true
  local maxIndex = 0
  for k, v in pairs(value) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
      isArray = false
    elseif k > maxIndex then
      maxIndex = k
    end
    out[k] = copySerializableValue(v)
  end
  if isArray then
    for i = 1, maxIndex do
      if out[i] == nil then
        isArray = false
        break
      end
    end
  end
  if isArray then
    local arr = {}
    for i = 1, maxIndex do
      arr[i] = out[i]
    end
    return arr
  end
  return out
end

local function normalizeSessionState(state)
  if type(state) ~= "table" then
    return nil, "session state must be a table"
  end
  local out = {
    version = tonumber(state.version or 1) or 1,
    memory = isNonEmptyString(state.memory) and tostring(state.memory) or nil,
    memoryStore = coerceMemoryStore(state.memoryStore),
    workspaceMemory = isNonEmptyString(state.workspaceMemory) and tostring(state.workspaceMemory) or nil,
    workspaceMemoryStore = coerceMemoryStore(state.workspaceMemoryStore),
    globalMemory = isNonEmptyString(state.globalMemory) and tostring(state.globalMemory) or nil,
    globalMemoryStore = coerceMemoryStore(state.globalMemoryStore),
    history = cloneHistory(state.history),
    metadata = type(state.metadata) == "table" and copySerializableValue(state.metadata) or nil
  }
  return out, nil
end

function Session:add(role, content)
  local text = tostring(content or "")
  if text == "" then
    return
  end
  local normalizedRole = role == "assistant" and "assistant" or "user"
  self.history[#self.history + 1] = {
    role = normalizedRole,
    content = text
  }
end

function Session:runMemoryExtraction(goal, answer, opts)
  opts = opts or {}
  local extractor = opts.memoryExtractor
  if extractor ~= nil then
    extractor = coerceMemoryExtractor(extractor)
  else
    extractor = self.memoryExtractor
  end
  if not extractor then
    return async(function()
      return nil
    end)
  end

  local extractionTask = extractor:extract({
    client = opts.client or self.agent.client,
    goal = goal,
    answer = answer,
    history = opts.history or self.history,
    memoryText = buildScopedMemoryText(self, opts),
    model = opts.memoryModel,
    temperature = opts.memoryTemperature,
    timeout = opts.memoryTimeout,
    extra = opts.memoryExtra
  })

  return async(function()
    local updates, err, extra = async.await(extractionTask)
    if type(updates) ~= "table" then
      return nil, err, extra
    end
    applyScopedMemoryUpdates(self, updates)
    return updates, nil, extra
  end)
end

function Session:plan(goal, opts)
  opts = opts or {}
  local profileOpts = resolveSessionProfileOptions(self, goal, "plan")
  local planOpts = mergeRequestOptions(profileOpts, opts)
  planOpts.memory = buildSessionPlanningMemory(
    concatManyTextSections(planOpts.memory, buildScopedMemoryText(self, planOpts)),
    self.history,
    planOpts.maxPlanningHistoryMessages or self.maxPlanningHistoryMessages,
    planOpts.maxPlanningHistoryChars or self.maxPlanningHistoryChars
  )
  return self.agent:plan(goal, planOpts)
end

function Session:exportState(opts)
  opts = opts or {}
  local state = {
    version = 1,
    memory = self.memory,
    memoryStore = self.memoryStore and self.memoryStore:exportState() or nil,
    workspaceMemory = self.workspaceMemory,
    workspaceMemoryStore = self.workspaceMemoryStore and self.workspaceMemoryStore:exportState() or nil,
    globalMemory = self.globalMemory,
    globalMemoryStore = self.globalMemoryStore and self.globalMemoryStore:exportState() or nil,
    history = cloneHistory(self.history)
  }
  if opts.includeMetadata ~= false then
    local metadata = {}
    if self.profile and isNonEmptyString(self.profile.name) then
      metadata.profile = tostring(self.profile.name)
    end
    if self.router and isNonEmptyString(self.router.name) then
      metadata.router = tostring(self.router.name)
    end
    metadata.maxPlanningHistoryMessages = self.maxPlanningHistoryMessages
    metadata.maxPlanningHistoryChars = self.maxPlanningHistoryChars
    if self.memoryExtractor then
      metadata.memoryExtractor = true
    end
    if type(opts.metadata) == "table" then
      metadata.extra = copySerializableValue(opts.metadata)
    end
    if next(metadata) ~= nil then
      state.metadata = metadata
    end
  end
  return state
end

function Session:exportJson(opts)
  return llm.jsonEncode(self:exportState(opts))
end

function Session:importState(state)
  local decoded = state
  if type(decoded) == "string" then
    local ok, parsedOrErr = pcall(llm.jsonDecode, decoded)
    if not ok then
      error("invalid session state JSON: " .. tostring(parsedOrErr), 2)
    end
    decoded = parsedOrErr
  end
  local normalized, err = normalizeSessionState(decoded)
  if not normalized then
    error(tostring(err), 2)
  end
  self.history = normalized.history
  self.memory = normalized.memory
  self.memoryStore = normalized.memoryStore
  self.workspaceMemory = normalized.workspaceMemory
  self.workspaceMemoryStore = normalized.workspaceMemoryStore
  self.globalMemory = normalized.globalMemory
  self.globalMemoryStore = normalized.globalMemoryStore
  return self
end

function Session:ask(goal, opts)
  opts = opts or {}
  local profileOpts = resolveSessionProfileOptions(self, goal, "run")
  local runOpts = mergeRequestOptions(profileOpts, opts)
  local appendHistory = runOpts.appendHistory ~= false
  runOpts.appendHistory = nil
  runOpts.maxPlanningHistoryMessages = nil
  runOpts.maxPlanningHistoryChars = nil
  if runOpts.history == nil then
    runOpts.history = self.history
  end
  runOpts.memory = concatManyTextSections(runOpts.memory, buildScopedMemoryText(self, runOpts))

  local shouldPlan = false
  if runOpts.plan == nil then
    if runOpts.withPlan == nil then
      shouldPlan = self.agent.withPlan
    else
      shouldPlan = runOpts.withPlan and true or false
    end
  end

  return async(function()
    local planValue = runOpts.plan
    if shouldPlan then
      local planTask = self:plan(goal, opts)
      local planResult = async.await(planTask)
      if type(planResult) == "table" then
        planValue = planResult
      end
      runOpts.withPlan = false
      runOpts.plan = planValue
    end

    local result, err, extra = async.await(self.agent:run(goal, runOpts))
    if type(result) ~= "table" then
      return nil, err, extra
    end
    if appendHistory then
      self:add("user", goal)
      self:add("assistant", result.text or "")
    end
    if runOpts.skipMemoryExtraction ~= true then
      local _, memoryErr = async.await(self:runMemoryExtraction(goal, result.text or "", {
        history = self.history,
        includeGlobalMemory = runOpts.includeGlobalMemory,
        includeWorkspaceMemory = runOpts.includeWorkspaceMemory,
        includeSessionMemory = runOpts.includeSessionMemory,
        memoryModel = runOpts.memoryModel,
        memoryTemperature = runOpts.memoryTemperature,
        memoryTimeout = runOpts.memoryTimeout,
        memoryExtra = runOpts.memoryExtra
      }))
      if memoryErr ~= nil then
        result.memoryError = tostring(memoryErr)
      end
    end
    return result, nil, extra
  end)
end

local agent = {}
agent.ToolRegistry = ToolRegistry
agent.Agent = Agent
agent.MemoryStore = MemoryStore
agent.MemoryExtractor = MemoryExtractor
agent.SceneProfile = SceneProfile
agent.ProfileRouter = ProfileRouter
agent.Session = Session

return agent
