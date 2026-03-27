local async = require("async")
local AsyncHttp = require("async_http")

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

local function mergeHeaders(base, extra)
  local out = shallowCopyTable(base) or {}
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      out[k] = v
    end
  end
  return out
end

local function toLowerAscii(s)
  if type(s) ~= "string" then
    return ""
  end
  return string.lower(s)
end

local function redactHeaders(headers)
  if type(headers) ~= "table" then
    return {}
  end
  local out = {}
  for k, v in pairs(headers) do
    local key = tostring(k)
    local low = toLowerAscii(key)
    if low == "authorization" or low == "proxy-authorization" or low == "x-api-key" or low == "api-key" or low == "anthropic-api-key" then
      out[key] = "<redacted>"
    else
      out[key] = tostring(v)
    end
  end
  return out
end

local function defaultDebugEnabled()
  return tostring(os.getenv("LLM_DEBUG") or "") == "1"
end

local function defaultDebugMaxLen()
  local n = tonumber(os.getenv("LLM_DEBUG_MAX_LEN") or "")
  if type(n) == "number" and n > 0 then
    return n
  end
  return 200000
end

local function debugWriteLines(prefix, payload)
  local s = tostring(payload or "")
  s = s:gsub("\r\n", "\n")
  local header = "[llm][" .. tostring(prefix) .. "]"
  for line in s:gmatch("([^\n]*)\n?") do
    if line == "" and s:sub(-1) ~= "\n" then
      break
    end
    print(header .. " " .. line)
  end
end

local function emitDebugSink(sink, prefix, payload)
  local ok = pcall(sink, prefix, payload)
  return ok
end

local function isArray(t)
  if type(t) ~= "table" then
    return false
  end
  if next(t) == nil then
    return false
  end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k <= 0 or k % 1 ~= 0 then
      return false
    end
    if k > n then
      n = k
    end
  end
  for i = 1, n do
    if rawget(t, i) == nil then
      return false
    end
  end
  return true
end

local function jsonEscapeString(s)
  s = tostring(s)
  local out = {}
  local i = 1
  local len = #s
  local replacement = "\239\191\189"

  local function isContinuation(byte)
    return byte and byte >= 0x80 and byte <= 0xBF
  end

  while i <= len do
    local b1 = s:byte(i)
    if not b1 then
      break
    end
    if b1 < 0x80 then
      out[#out + 1] = string.char(b1)
      i = i + 1
    elseif b1 >= 0xC2 and b1 <= 0xDF then
      local b2 = s:byte(i + 1)
      if isContinuation(b2) then
        out[#out + 1] = s:sub(i, i + 1)
        i = i + 2
      else
        out[#out + 1] = replacement
        i = i + 1
      end
    elseif b1 == 0xE0 then
      local b2 = s:byte(i + 1)
      local b3 = s:byte(i + 2)
      if b2 and b2 >= 0xA0 and b2 <= 0xBF and isContinuation(b3) then
        out[#out + 1] = s:sub(i, i + 2)
        i = i + 3
      else
        out[#out + 1] = replacement
        i = i + 1
      end
    elseif (b1 >= 0xE1 and b1 <= 0xEC) or (b1 >= 0xEE and b1 <= 0xEF) then
      local b2 = s:byte(i + 1)
      local b3 = s:byte(i + 2)
      if isContinuation(b2) and isContinuation(b3) then
        out[#out + 1] = s:sub(i, i + 2)
        i = i + 3
      else
        out[#out + 1] = replacement
        i = i + 1
      end
    elseif b1 == 0xED then
      local b2 = s:byte(i + 1)
      local b3 = s:byte(i + 2)
      if b2 and b2 >= 0x80 and b2 <= 0x9F and isContinuation(b3) then
        out[#out + 1] = s:sub(i, i + 2)
        i = i + 3
      else
        out[#out + 1] = replacement
        i = i + 1
      end
    elseif b1 == 0xF0 then
      local b2 = s:byte(i + 1)
      local b3 = s:byte(i + 2)
      local b4 = s:byte(i + 3)
      if b2 and b2 >= 0x90 and b2 <= 0xBF and isContinuation(b3) and isContinuation(b4) then
        out[#out + 1] = s:sub(i, i + 3)
        i = i + 4
      else
        out[#out + 1] = replacement
        i = i + 1
      end
    elseif b1 >= 0xF1 and b1 <= 0xF3 then
      local b2 = s:byte(i + 1)
      local b3 = s:byte(i + 2)
      local b4 = s:byte(i + 3)
      if isContinuation(b2) and isContinuation(b3) and isContinuation(b4) then
        out[#out + 1] = s:sub(i, i + 3)
        i = i + 4
      else
        out[#out + 1] = replacement
        i = i + 1
      end
    elseif b1 == 0xF4 then
      local b2 = s:byte(i + 1)
      local b3 = s:byte(i + 2)
      local b4 = s:byte(i + 3)
      if b2 and b2 >= 0x80 and b2 <= 0x8F and isContinuation(b3) and isContinuation(b4) then
        out[#out + 1] = s:sub(i, i + 3)
        i = i + 4
      else
        out[#out + 1] = replacement
        i = i + 1
      end
    else
      out[#out + 1] = replacement
      i = i + 1
    end
  end

  s = table.concat(out)
  s = s:gsub("\\", "\\\\")
  s = s:gsub("\"", "\\\"")
  s = s:gsub("\b", "\\b")
  s = s:gsub("\f", "\\f")
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  s = s:gsub("[%z\1-\31]", function(c)
    return string.format("\\u%04X", string.byte(c))
  end)
  return "\"" .. s .. "\""
end

local function jsonEncode(value)
  local t = type(value)
  if value == nil then
    return "null"
  elseif t == "boolean" then
    return value and "true" or "false"
  elseif t == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return "null"
    end
    return tostring(value)
  elseif t == "string" then
    return jsonEscapeString(value)
  elseif t == "table" then
    if isArray(value) then
      local parts = {}
      for i = 1, #value do
        parts[#parts + 1] = jsonEncode(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(value) do
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for i = 1, #keys do
      local k = keys[i]
      local v = value[k]
      if v ~= nil then
        parts[#parts + 1] = jsonEscapeString(k) .. ":" .. jsonEncode(v)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("jsonEncode: unsupported type: " .. t)
end

local function utf8FromCodepoint(cp)
  if cp <= 0x7F then
    return string.char(cp)
  elseif cp <= 0x7FF then
    local b1 = 0xC0 + math.floor(cp / 0x40)
    local b2 = 0x80 + (cp % 0x40)
    return string.char(b1, b2)
  elseif cp <= 0xFFFF then
    local b1 = 0xE0 + math.floor(cp / 0x1000)
    local b2 = 0x80 + (math.floor(cp / 0x40) % 0x40)
    local b3 = 0x80 + (cp % 0x40)
    return string.char(b1, b2, b3)
  elseif cp <= 0x10FFFF then
    local b1 = 0xF0 + math.floor(cp / 0x40000)
    local b2 = 0x80 + (math.floor(cp / 0x1000) % 0x40)
    local b3 = 0x80 + (math.floor(cp / 0x40) % 0x40)
    local b4 = 0x80 + (cp % 0x40)
    return string.char(b1, b2, b3, b4)
  end
  return "\239\191\189"
end

local function jsonDecode(input)
  if type(input) ~= "string" then
    error("jsonDecode expects a string")
  end

  local s = input
  local i = 1
  local len = #s

  local function peek()
    if i > len then
      return nil
    end
    return s:sub(i, i)
  end

  local function nextChar()
    local c = peek()
    i = i + 1
    return c
  end

  local function skipWs()
    while true do
      local c = peek()
      if c == " " or c == "\n" or c == "\r" or c == "\t" then
        i = i + 1
      else
        return
      end
    end
  end

  local function parseLiteral(lit, val)
    if s:sub(i, i + #lit - 1) ~= lit then
      error("invalid token at position " .. tostring(i))
    end
    i = i + #lit
    return val
  end

  local function parseNumber()
    local start = i
    local c = peek()
    if c == "-" then
      i = i + 1
    end
    c = peek()
    if c == "0" then
      i = i + 1
    else
      if not c or not c:match("%d") then
        error("invalid number at position " .. tostring(i))
      end
      while true do
        c = peek()
        if c and c:match("%d") then
          i = i + 1
        else
          break
        end
      end
    end
    c = peek()
    if c == "." then
      i = i + 1
      c = peek()
      if not c or not c:match("%d") then
        error("invalid number fraction at position " .. tostring(i))
      end
      while true do
        c = peek()
        if c and c:match("%d") then
          i = i + 1
        else
          break
        end
      end
    end
    c = peek()
    if c == "e" or c == "E" then
      i = i + 1
      c = peek()
      if c == "+" or c == "-" then
        i = i + 1
      end
      c = peek()
      if not c or not c:match("%d") then
        error("invalid number exponent at position " .. tostring(i))
      end
      while true do
        c = peek()
        if c and c:match("%d") then
          i = i + 1
        else
          break
        end
      end
    end
    local num = tonumber(s:sub(start, i - 1))
    return num
  end

  local function parseString()
    local quote = nextChar()
    if quote ~= "\"" then
      error("expected string at position " .. tostring(i))
    end
    local out = {}
    while true do
      local c = nextChar()
      if c == nil then
        error("unterminated string")
      end
      if c == "\"" then
        break
      end
      if c == "\\" then
        local esc = nextChar()
        if esc == "\"" or esc == "\\" or esc == "/" then
          out[#out + 1] = esc
        elseif esc == "b" then
          out[#out + 1] = "\b"
        elseif esc == "f" then
          out[#out + 1] = "\f"
        elseif esc == "n" then
          out[#out + 1] = "\n"
        elseif esc == "r" then
          out[#out + 1] = "\r"
        elseif esc == "t" then
          out[#out + 1] = "\t"
        elseif esc == "u" then
          local hex = s:sub(i, i + 3)
          if #hex ~= 4 or not hex:match("^[0-9a-fA-F]+$") then
            error("invalid unicode escape at position " .. tostring(i))
          end
          i = i + 4
          local cp = tonumber(hex, 16)
          if cp and cp >= 0xD800 and cp <= 0xDBFF then
            if s:sub(i, i + 1) == "\\u" then
              i = i + 2
              local hex2 = s:sub(i, i + 3)
              if #hex2 == 4 and hex2:match("^[0-9a-fA-F]+$") then
                i = i + 4
                local low = tonumber(hex2, 16)
                if low and low >= 0xDC00 and low <= 0xDFFF then
                  cp = 0x10000 + ((cp - 0xD800) * 0x400) + (low - 0xDC00)
                end
              end
            end
          end
          out[#out + 1] = utf8FromCodepoint(cp or 0xFFFD)
        else
          error("invalid escape at position " .. tostring(i))
        end
      else
        out[#out + 1] = c
      end
    end
    return table.concat(out)
  end

  local parseValue

  local function parseArray()
    local open = nextChar()
    if open ~= "[" then
      error("expected '[' at position " .. tostring(i))
    end
    skipWs()
    local arr = {}
    if peek() == "]" then
      i = i + 1
      return arr
    end
    while true do
      skipWs()
      arr[#arr + 1] = parseValue()
      skipWs()
      local c = nextChar()
      if c == "]" then
        break
      end
      if c ~= "," then
        error("expected ',' or ']' at position " .. tostring(i))
      end
    end
    return arr
  end

  local function parseObject()
    local open = nextChar()
    if open ~= "{" then
      error("expected '{' at position " .. tostring(i))
    end
    skipWs()
    local obj = {}
    if peek() == "}" then
      i = i + 1
      return obj
    end
    while true do
      skipWs()
      local key = parseString()
      skipWs()
      if nextChar() ~= ":" then
        error("expected ':' at position " .. tostring(i))
      end
      skipWs()
      obj[key] = parseValue()
      skipWs()
      local c = nextChar()
      if c == "}" then
        break
      end
      if c ~= "," then
        error("expected ',' or '}' at position " .. tostring(i))
      end
    end
    return obj
  end

  function parseValue()
    skipWs()
    local c = peek()
    if c == nil then
      error("unexpected end of input")
    end
    if c == "\"" then
      return parseString()
    elseif c == "{" then
      return parseObject()
    elseif c == "[" then
      return parseArray()
    elseif c == "t" then
      return parseLiteral("true", true)
    elseif c == "f" then
      return parseLiteral("false", false)
    elseif c == "n" then
      return parseLiteral("null", nil)
    else
      return parseNumber()
    end
  end

  local value = parseValue()
  skipWs()
  if i <= len then
    error("trailing characters at position " .. tostring(i))
  end
  return value
end

local Client = {}
Client.__index = Client

local function normalizeProvider(p)
  if type(p) ~= "string" then
    return nil
  end
  p = string.lower(p)
  if p == "openai" or p == "openai-compatible" or p == "openai_compatible" then
    return "openai"
  end
  if p == "anthropic" then
    return "anthropic"
  end
  return nil
end

local function openaiExtractText(json)
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
  local content = msg.content
  if type(content) == "string" then
    return content
  end
  if type(content) == "table" then
    local parts = {}
    for _, block in ipairs(content) do
      if type(block) == "table" and type(block.text) == "string" then
        parts[#parts + 1] = block.text
      end
    end
    if #parts > 0 then
      return table.concat(parts)
    end
  end
  return nil
end

local function anthropicExtractText(json)
  if type(json) ~= "table" then
    return nil
  end
  local content = json.content
  if type(content) == "table" then
    local parts = {}
    for _, block in ipairs(content) do
      if type(block) == "table" and type(block.text) == "string" then
        parts[#parts + 1] = block.text
      end
    end
    if #parts > 0 then
      return table.concat(parts)
    end
  end
  if type(json.text) == "string" then
    return json.text
  end
  return nil
end

local function extractErrorMessage(provider, json)
  if type(json) ~= "table" then
    return nil
  end
  if provider == "openai" then
    local err = json.error
    if type(err) == "table" then
      if type(err.message) == "string" then
        return err.message
      end
      if type(err.type) == "string" then
        return err.type
      end
    end
  elseif provider == "anthropic" then
    local err = json.error
    if type(err) == "table" and type(err.message) == "string" then
      return err.message
    end
  end
  if type(json.message) == "string" then
    return json.message
  end
  return nil
end

local function defaultHeadersForProvider(provider, apiKey, extra)
  local headers = mergeHeaders({}, extra)
  headers["Content-Type"] = headers["Content-Type"] or "application/json"
  headers["Accept"] = headers["Accept"] or "application/json"
  if provider == "openai" then
    if isNonEmptyString(apiKey) then
      headers["Authorization"] = headers["Authorization"] or ("Bearer " .. apiKey)
    end
  elseif provider == "anthropic" then
    if isNonEmptyString(apiKey) then
      headers["x-api-key"] = headers["x-api-key"] or apiKey
    end
    headers["anthropic-version"] = headers["anthropic-version"] or "2023-06-01"
  end
  return headers
end

local function appendString(base, extra)
  if type(extra) ~= "string" or extra == "" then
    return base
  end
  if type(base) ~= "string" or base == "" then
    return extra
  end
  return base .. extra
end

local function appendTextDelta(streamState, params, delta, meta)
  if type(delta) ~= "string" or delta == "" then
    return
  end
  streamState.text = appendString(streamState.text, delta) or ""
  if type(params.onText) == "function" then
    params.onText(delta, streamState.text, meta)
  end
end

local function copyToolCall(call)
  if type(call) ~= "table" then
    return nil
  end
  local out = {}
  if type(call.id) == "string" then
    out.id = call.id
  end
  if type(call.type) == "string" then
    out.type = call.type
  end
  if type(call["function"]) == "table" then
    out["function"] = {}
    if type(call["function"].name) == "string" then
      out["function"].name = call["function"].name
    end
    if type(call["function"].arguments) == "string" then
      out["function"].arguments = call["function"].arguments
    end
  end
  return out
end

local function compactArray(arr, mapper)
  local out = {}
  if type(arr) ~= "table" then
    return out
  end
  local maxIndex = 0
  for k in pairs(arr) do
    if type(k) == "number" and k > maxIndex then
      maxIndex = k
    end
  end
  for i = 1, maxIndex do
    local value = arr[i]
    if value ~= nil then
      out[#out + 1] = mapper and mapper(value) or value
    end
  end
  return out
end

local function createSseParser()
  return {
    buffer = "",
    eventName = nil,
    dataLines = {}
  }
end

local function dispatchSseEvent(parser, fn)
  if parser.eventName == nil and #parser.dataLines == 0 then
    return
  end
  fn(parser.eventName or "message", table.concat(parser.dataLines, "\n"))
  parser.eventName = nil
  parser.dataLines = {}
end

local function feedSseParser(parser, chunk, fn, flush)
  if type(chunk) == "string" and chunk ~= "" then
    parser.buffer = parser.buffer .. chunk
  end

  while true do
    local idx = parser.buffer:find("\n", 1, true)
    if not idx then
      break
    end
    local line = parser.buffer:sub(1, idx - 1)
    parser.buffer = parser.buffer:sub(idx + 1)
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    if line == "" then
      dispatchSseEvent(parser, fn)
    elseif line:sub(1, 1) ~= ":" then
      local sep = line:find(":", 1, true)
      local field = line
      local value = ""
      if sep then
        field = line:sub(1, sep - 1)
        value = line:sub(sep + 1)
        if value:sub(1, 1) == " " then
          value = value:sub(2)
        end
      end
      if field == "event" then
        parser.eventName = value
      elseif field == "data" then
        parser.dataLines[#parser.dataLines + 1] = value
      end
    end
  end

  if flush == true then
    local tail = parser.buffer
    if tail:sub(-1) == "\r" then
      tail = tail:sub(1, -2)
    end
    if tail ~= "" then
      local sep = tail:find(":", 1, true)
      if sep then
        local field = tail:sub(1, sep - 1)
        local value = tail:sub(sep + 1)
        if value:sub(1, 1) == " " then
          value = value:sub(2)
        end
        if field == "event" then
          parser.eventName = value
        elseif field == "data" then
          parser.dataLines[#parser.dataLines + 1] = value
        end
      end
      parser.buffer = ""
    end
    dispatchSseEvent(parser, fn)
  end
end

local function accumulateOpenAIStream(streamState, params, eventName, json)
  if type(json) ~= "table" then
    return
  end
  local state = streamState.providerState
  state.id = json.id or state.id
  state.object = json.object or state.object
  state.model = json.model or state.model
  state.created = json.created or state.created
  if type(json.usage) == "table" then
    state.usage = json.usage
  end

  local choices = json.choices
  local first = type(choices) == "table" and choices[1] or nil
  if type(first) ~= "table" then
    return
  end

  if first.finish_reason ~= nil then
    state.finishReason = first.finish_reason
  end

  local delta = first.delta
  if type(delta) ~= "table" then
    return
  end

  if type(delta.role) == "string" then
    state.role = delta.role
  end

  if type(delta.content) == "string" then
    appendTextDelta(streamState, params, delta.content, {
      provider = "openai",
      event = eventName,
      json = json
    })
  elseif type(delta.content) == "table" then
    for _, block in ipairs(delta.content) do
      if type(block) == "table" and type(block.text) == "string" then
        appendTextDelta(streamState, params, block.text, {
          provider = "openai",
          event = eventName,
          json = json,
          block = block
        })
      end
    end
  end

  if type(delta.tool_calls) == "table" then
    for _, item in ipairs(delta.tool_calls) do
      if type(item) == "table" then
        local index = tonumber(item.index)
        if type(index) == "number" then
          index = math.floor(index) + 1
        else
          index = #state.toolCalls + 1
        end
        local toolCall = state.toolCalls[index] or { type = "function", ["function"] = { arguments = "" } }
        if type(item.id) == "string" then
          toolCall.id = item.id
        end
        if type(item.type) == "string" then
          toolCall.type = item.type
        end
        if type(item["function"]) == "table" then
          toolCall["function"] = toolCall["function"] or { arguments = "" }
          if type(item["function"].name) == "string" then
            toolCall["function"].name = appendString(toolCall["function"].name, item["function"].name)
          end
          if type(item["function"].arguments) == "string" then
            toolCall["function"].arguments = appendString(toolCall["function"].arguments, item["function"].arguments) or ""
          end
        end
        state.toolCalls[index] = toolCall
      end
    end
  end
end

local function buildOpenAIStreamJson(streamState)
  local state = streamState.providerState
  local message = {
    role = state.role or "assistant"
  }
  if type(streamState.text) == "string" and streamState.text ~= "" then
    message.content = streamState.text
  end

  local toolCalls = compactArray(state.toolCalls, copyToolCall)
  if #toolCalls > 0 then
    message.tool_calls = toolCalls
  end

  return {
    id = state.id,
    object = state.object or "chat.completion",
    created = state.created,
    model = state.model,
    choices = {
      {
        index = 0,
        finish_reason = state.finishReason,
        message = message
      }
    },
    usage = state.usage
  }
end

local function shallowCopyBlock(block)
  local out = {}
  if type(block) ~= "table" then
    return out
  end
  for k, v in pairs(block) do
    if k ~= "_partial_json" then
      out[k] = v
    end
  end
  return out
end

local function finalizeAnthropicToolBlock(block)
  if type(block) ~= "table" then
    return
  end
  if type(block._partial_json) == "string" and block._partial_json ~= "" then
    local ok, decoded = pcall(jsonDecode, block._partial_json)
    if ok then
      block.input = decoded
    end
  end
end

local function accumulateAnthropicStream(streamState, params, eventName, json)
  if type(json) ~= "table" then
    return
  end
  local state = streamState.providerState
  local kind = json.type or eventName

  if kind == "message_start" then
    local message = type(json.message) == "table" and json.message or {}
    state.id = message.id or state.id
    state.model = message.model or state.model
    state.role = message.role or state.role or "assistant"
    state.stopReason = message.stop_reason or state.stopReason
    if type(message.usage) == "table" then
      state.usage = message.usage
    end
  elseif kind == "content_block_start" then
    local index = math.floor(tonumber(json.index) or 0) + 1
    state.blocks[index] = shallowCopyBlock(json.content_block)
  elseif kind == "content_block_delta" then
    local index = math.floor(tonumber(json.index) or 0) + 1
    local block = state.blocks[index] or {}
    state.blocks[index] = block
    local delta = type(json.delta) == "table" and json.delta or {}
    if delta.type == "text_delta" and type(delta.text) == "string" then
      block.type = block.type or "text"
      block.text = appendString(block.text, delta.text) or ""
      appendTextDelta(streamState, params, delta.text, {
        provider = "anthropic",
        event = eventName,
        json = json,
        index = index
      })
    elseif type(delta.partial_json) == "string" then
      block.type = block.type or "tool_use"
      block._partial_json = appendString(block._partial_json, delta.partial_json) or ""
    end
  elseif kind == "content_block_stop" then
    local index = math.floor(tonumber(json.index) or 0) + 1
    finalizeAnthropicToolBlock(state.blocks[index])
  elseif kind == "message_delta" then
    local delta = type(json.delta) == "table" and json.delta or {}
    if delta.stop_reason ~= nil then
      state.stopReason = delta.stop_reason
    end
    if type(json.usage) == "table" then
      state.usage = json.usage
    end
  elseif kind == "message_stop" then
    state.stopped = true
  end
end

local function buildAnthropicStreamJson(streamState)
  local state = streamState.providerState
  local content = compactArray(state.blocks, function(block)
    finalizeAnthropicToolBlock(block)
    return shallowCopyBlock(block)
  end)
  if #content == 0 and type(streamState.text) == "string" and streamState.text ~= "" then
    content[1] = {
      type = "text",
      text = streamState.text
    }
  end
  return {
    id = state.id,
    type = "message",
    role = state.role or "assistant",
    model = state.model,
    content = content,
    stop_reason = state.stopReason,
    usage = state.usage
  }
end

local function streamStateForProvider(provider)
  local state = {
    text = "",
    parser = createSseParser(),
    responseStatus = nil,
    responseHeaders = nil,
    completeErr = nil
  }
  if provider == "openai" then
    state.providerState = {
      role = "assistant",
      toolCalls = {}
    }
  else
    state.providerState = {
      role = "assistant",
      blocks = {}
    }
  end
  return state
end

local function buildStreamJson(provider, streamState)
  if provider == "openai" then
    return buildOpenAIStreamJson(streamState)
  end
  if provider == "anthropic" then
    return buildAnthropicStreamJson(streamState)
  end
  return nil
end

local function processStreamEvent(provider, params, streamState, eventName, data)
  local event = {
    provider = provider,
    event = eventName,
    data = data
  }

  if data == "[DONE]" then
    event.done = true
    if type(params.onEvent) == "function" then
      params.onEvent(event)
    end
    return
  end

  local ok, decodedOrErr = pcall(jsonDecode, data)
  if not ok then
    streamState.parseError = decodedOrErr
    return
  end

  event.json = decodedOrErr
  if type(params.onEvent) == "function" then
    params.onEvent(event)
  end

  if provider == "openai" then
    accumulateOpenAIStream(streamState, params, eventName, decodedOrErr)
  elseif provider == "anthropic" then
    accumulateAnthropicStream(streamState, params, eventName, decodedOrErr)
  end
end

function Client.new(opts)
  opts = opts or {}
  local provider = normalizeProvider(opts.provider)
  if not provider then
    error("opts.provider must be 'openai' or 'anthropic'", 2)
  end

  local self = setmetatable({}, Client)
  self.provider = provider
  self.apiKey = opts.apiKey
  self.baseUrl = opts.baseUrl
  self.model = opts.model
  self.maxTokens = opts.maxTokens
  self.timeout = opts.timeout
  self.headers = defaultHeadersForProvider(provider, self.apiKey, opts.headers)
  if opts.debug == nil then
    self.debug = defaultDebugEnabled()
  else
    self.debug = not not opts.debug
  end
  self.debugMaxLen = tonumber(opts.debugMaxLen) or defaultDebugMaxLen()
  self.debugSink = opts.debugSink
  self.http = AsyncHttp.new({
    poolSize = opts.poolSize,
    timeout = opts.timeout,
    baseUrl = self.baseUrl,
    httpsModule = opts.httpsModule
  })
  return self
end

function Client:destroy()
  if self.http then
    self.http:destroy()
  end
end

function Client:extractText(json)
  if self.provider == "openai" then
    return openaiExtractText(json)
  end
  if self.provider == "anthropic" then
    return anthropicExtractText(json)
  end
  return nil
end

function Client:chat(params)
  params = params or {}
  local provider = self.provider

  local url
  local body = {}

  if provider == "openai" then
    url = params.url or "/chat/completions"
    body.model = params.model or self.model
    body.messages = params.messages
    body.temperature = params.temperature
    body.top_p = params.top_p
    body.max_tokens = params.max_tokens
    body.stream = params.stream
    if body.stream == nil then
      body.stream = false
    end
    if type(params.extra) == "table" then
      for k, v in pairs(params.extra) do
        body[k] = v
      end
    end
  elseif provider == "anthropic" then
    url = params.url or "/v1/messages"
    body.model = params.model or self.model
    body.messages = params.messages
    body.max_tokens = params.max_tokens or self.maxTokens
    body.temperature = params.temperature
    body.top_p = params.top_p
    body.system = params.system
    body.stream = params.stream
    if body.stream == nil then
      body.stream = false
    end
    if type(params.extra) == "table" then
      for k, v in pairs(params.extra) do
        body[k] = v
      end
    end
  else
    error("unsupported provider: " .. tostring(provider), 2)
  end

  if not isNonEmptyString(body.model) then
    error("model is required", 2)
  end
  if type(body.messages) ~= "table" then
    error("messages must be an array table", 2)
  end
  if provider == "anthropic" and (type(body.max_tokens) ~= "number" or body.max_tokens <= 0) then
    error("max_tokens is required for Anthropic Messages API", 2)
  end

  local timeout = params.timeout
  local headers = mergeHeaders(self.headers, params.headers)

  local payload = jsonEncode(body)
  return async(function()
    local streamState = body.stream and streamStateForProvider(provider) or nil
    local sink = type(self.debugSink) == "function" and self.debugSink or debugWriteLines
    if self.debug then
      local req = {
        provider = provider,
        baseUrl = self.baseUrl,
        url = url,
        method = "POST",
        headers = redactHeaders(headers),
        body = body
      }
      emitDebugSink(sink, "request", jsonEncode(req))
    end

    local httpOpts = {
      timeout = timeout,
      headers = headers
    }

    if streamState then
      httpOpts.stream = true
      httpOpts.onResponse = function(status, responseHeaders)
        streamState.responseStatus = status
        streamState.responseHeaders = responseHeaders
        if self.debug then
          emitDebugSink(sink, "response_headers", jsonEncode({
            provider = provider,
            url = url,
            status = status,
            headers = redactHeaders(responseHeaders)
          }))
        end
        if type(params.onResponse) == "function" then
          params.onResponse(status, responseHeaders)
        end
      end
      httpOpts.onData = function(chunk)
        if type(params.onChunk) == "function" then
          params.onChunk(chunk)
        end
        feedSseParser(streamState.parser, chunk, function(eventName, data)
          processStreamEvent(provider, params, streamState, eventName, data)
        end, false)
      end
      httpOpts.onComplete = function(completeErr)
        streamState.completeErr = completeErr
        if self.debug and completeErr ~= nil then
          emitDebugSink(sink, "stream_complete", jsonEncode({
            provider = provider,
            url = url,
            error = tostring(completeErr)
          }))
        end
      end
    end

    local resp, err, extra = async.await(self.http:post(url, payload, httpOpts))
    if type(resp) ~= "table" then
      if self.debug then
        emitDebugSink(sink, "response_error", jsonEncode({ provider = provider, url = url, error = tostring(err), extra = extra }))
      end
      return nil, err, extra
    end

    local bodyStr = tostring(resp.body or "")
    if self.debug then
      local maxLen = tonumber(self.debugMaxLen) or 200000
      local bodyOut = bodyStr
      if type(maxLen) == "number" and maxLen > 0 and #bodyOut > maxLen then
        bodyOut = bodyOut:sub(1, maxLen)
      end
      emitDebugSink(sink, "response", jsonEncode({ provider = provider, url = url, status = resp.status, headers = redactHeaders(resp.headers), body = bodyOut }))
    end

    local ok, decodedOrErr
    local decoded
    if streamState then
      feedSseParser(streamState.parser, "", function(eventName, data)
        processStreamEvent(provider, params, streamState, eventName, data)
      end, true)
      decoded = buildStreamJson(provider, streamState)
      if decoded == nil and streamState.parseError ~= nil then
        return nil, "stream decode failed: " .. tostring(streamState.parseError), {
          status = resp.status,
          headers = resp.headers,
          body = resp.body
        }
      end
      ok = decoded ~= nil
    else
      ok, decodedOrErr = pcall(jsonDecode, bodyStr)
      decoded = ok and decodedOrErr or nil
    end

    if type(resp.status) ~= "number" or resp.status < 200 or resp.status >= 300 then
      local msg = extractErrorMessage(provider, decoded)
      if not isNonEmptyString(msg) then
        msg = ok and ("http " .. tostring(resp.status)) or ("http " .. tostring(resp.status) .. " (json decode failed)")
      end
      return nil, msg, { status = resp.status, headers = resp.headers, body = resp.body, json = decoded }
    end

    if not ok then
      return nil, "json decode failed: " .. tostring(decodedOrErr), { status = resp.status, headers = resp.headers, body = resp.body }
    end

    return {
      ok = true,
      provider = provider,
      status = resp.status,
      headers = resp.headers,
      json = decoded,
      text = streamState and tostring(streamState.text or "") or self:extractText(decoded),
      usage = type(decoded) == "table" and decoded.usage or nil
    }
  end)
end

function Client:chatText(prompt, opts)
  opts = opts or {}
  local messages = { { role = "user", content = tostring(prompt or "") } }
  local params = mergeHeaders({}, opts)
  params.messages = messages
  return self:chat(params)
end

local llm = {}

function llm.openai(opts)
  opts = opts or {}
  local o = shallowCopyTable(opts) or {}
  o.provider = "openai"
  o.baseUrl = o.baseUrl or "https://api.openai.com/v1"
  return Client.new(o)
end

function llm.anthropic(opts)
  opts = opts or {}
  local o = shallowCopyTable(opts) or {}
  o.provider = "anthropic"
  o.baseUrl = o.baseUrl or "https://api.anthropic.com"
  o.maxTokens = o.maxTokens or 512
  return Client.new(o)
end

llm.Client = Client
llm.jsonEncode = jsonEncode
llm.jsonDecode = jsonDecode

return llm
