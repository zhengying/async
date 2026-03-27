local async = require("async")
local ThreadPool = require("threadpool")

local AsyncHttp = {}
AsyncHttp.__index = AsyncHttp

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

local function addHandler(list, fn)
  if type(fn) == "function" then
    list[#list + 1] = fn
  end
end

local function emitHandlers(list, ...)
  for i = 1, #list do
    list[i](...)
  end
end

local function urlEncode(s)
  s = tostring(s)
  s = s:gsub("\n", "\r\n")
  s = s:gsub("([^%w%-%_%.%~ ])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return (s:gsub(" ", "+"))
end

local function encodeQuery(q)
  if type(q) ~= "table" then
    return nil
  end

  local keys = {}
  for k in pairs(q) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)

  local parts = {}
  for i = 1, #keys do
    local k = keys[i]
    local v = q[k]
    if v ~= nil then
      if type(v) == "table" then
        for _, item in ipairs(v) do
          parts[#parts + 1] = urlEncode(k) .. "=" .. urlEncode(item)
        end
      else
        parts[#parts + 1] = urlEncode(k) .. "=" .. urlEncode(v)
      end
    end
  end

  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "&")
end

local function appendQuery(url, q)
  local encoded = encodeQuery(q)
  if not isNonEmptyString(encoded) then
    return url
  end
  if url:find("?", 1, true) then
    return url .. "&" .. encoded
  end
  return url .. "?" .. encoded
end

local function resolveUrl(baseUrl, url)
  if not isNonEmptyString(baseUrl) then
    return url
  end
  if url:match("^https?://") then
    return url
  end
  if baseUrl:sub(-1) == "/" and url:sub(1, 1) == "/" then
    return baseUrl:sub(1, -2) .. url
  end
  if baseUrl:sub(-1) ~= "/" and url:sub(1, 1) ~= "/" then
    return baseUrl .. "/" .. url
  end
  return baseUrl .. url
end

local function normalizeMethod(method, hasBody)
  if isNonEmptyString(method) then
    return string.upper(method)
  end
  if hasBody then
    return "POST"
  end
  return "GET"
end

function AsyncHttp.new(opts)
  opts = opts or {}

  local self = setmetatable({}, AsyncHttp)
  self.pool = ThreadPool.new(opts.poolSize)
  self.baseUrl = opts.baseUrl
  self.timeout = opts.timeout
  self.httpsModule = opts.httpsModule
  self.adapter = opts.adapter
  self.defaultHeaders = shallowCopyTable(opts.headers) or {}
  self._registered = false
  self._destroyed = false
  self._adapterCode = nil

  if self.adapter ~= nil and type(self.adapter) ~= "function" then
    error("opts.adapter must be a function or nil", 2)
  end
  if type(self.adapter) == "function" then
    local ok, dumped = pcall(string.dump, self.adapter)
    if not ok or type(dumped) ~= "string" then
      error("failed to dump opts.adapter", 2)
    end
    self._adapterCode = dumped
  end

  self:_ensureRegistered()
  return self
end

function AsyncHttp:_ensureRegistered()
  if self._registered then
    return
  end

  self.pool:register("asynchttp_request", function(payload, ctx)
    local loader = loadstring or load

    local function emitStream(eventName, data)
      if not (type(payload) == "table" and payload.stream == true) then
        return
      end
      if ctx and type(ctx.progress) == "function" then
        ctx.progress(0, {
          type = "http_stream",
          event = eventName,
          data = data
        })
      end
    end

    if type(payload) == "table" and type(payload.adapterCode) == "string" then
      local requestFn, loadErr = loader(payload.adapterCode)
      if not requestFn then
        return nil, "adapter load failed: " .. tostring(loadErr)
      end
      if type(payload.url) ~= "string" then
        return nil, "invalid payload"
      end

      local options = type(payload.options) == "table" and payload.options or nil
      local ok, code, body, headers = pcall(requestFn, payload.url, options, emitStream)
      if not ok then
        return nil, "adapter error: " .. tostring(code)
      end

      code = tonumber(code) or 0
      if code == 0 or body == nil then
        return nil, "request failed", { status = code, body = body, headers = headers }
      end

      return {
        ok = true,
        status = code,
        url = payload.url,
        body = body,
        headers = headers or {}
      }
    end

    local function tryRequire(name)
      if type(name) ~= "string" or name == "" then
        return nil
      end
      local ok, mod = pcall(require, name)
      if ok then
        return mod
      end
      return nil
    end

    local https = nil
    if type(payload) == "table" and type(payload.httpsModule) == "string" then
      https = tryRequire(payload.httpsModule)
    end
    https = https or tryRequire("https")
    if not https or type(https.request) ~= "function" then
      return nil, "https module not found (expected require('https'))"
    end

    if type(payload) ~= "table" or type(payload.url) ~= "string" then
      return nil, "invalid payload"
    end

    local options = nil
    if type(payload.options) == "table" then
      options = payload.options
    end

    local code, body, headers
    if payload.stream == true then
      local state = {
        status = 0,
        headers = nil,
        chunks = {},
        completeErr = nil
      }
      local callbacks = {
        response = function(context, status, responseHeaders)
          context.status = tonumber(status) or 0
          context.headers = responseHeaders or {}
          emitStream("response", {
            status = context.status,
            headers = context.headers
          })
        end,
        body = function(context, chunk)
          chunk = tostring(chunk or "")
          context.chunks[#context.chunks + 1] = chunk
          emitStream("body", { chunk = chunk })
          return true
        end,
        complete = function(context, completeErr)
          context.completeErr = completeErr
          emitStream("complete", { err = completeErr })
        end
      }

      local ok, err = https.request(payload.url, options or {}, callbacks, state)
      if not ok then
        local failedBody = table.concat(state.chunks)
        return nil, tostring(err or "request failed"), {
          status = tonumber(state.status) or 0,
          body = failedBody,
          headers = state.headers or {}
        }
      end

      code = tonumber(state.status) or 0
      body = table.concat(state.chunks)
      headers = state.headers or {}

      if state.completeErr ~= nil then
        return nil, tostring(state.completeErr), {
          status = code,
          body = body,
          headers = headers
        }
      end
    elseif options then
      code, body, headers = https.request(payload.url, options)
    else
      code, body = https.request(payload.url)
      headers = nil
    end

    code = tonumber(code) or 0
    if code == 0 or body == nil then
      return nil, "request failed", { status = code, body = body, headers = headers }
    end

    return {
      ok = true,
      status = code,
      url = payload.url,
      body = body,
      headers = headers or {}
    }
  end)

  self._registered = true
end

function AsyncHttp:destroy()
  if self._destroyed then
    return
  end
  self._destroyed = true
  if self.pool then
    self.pool:destroy()
  end
end

function AsyncHttp:request(req)
  if self._destroyed then
    error("AsyncHttp is destroyed", 2)
  end
  if type(req) ~= "table" then
    error("request expects a table", 2)
  end

  local url = req.url
  if not isNonEmptyString(url) then
    error("request.url must be a non-empty string", 2)
  end

  url = resolveUrl(self.baseUrl, url)
  url = appendQuery(url, req.query)

  local headers = shallowCopyTable(self.defaultHeaders) or {}
  if type(req.headers) == "table" then
    for k, v in pairs(req.headers) do
      headers[k] = v
    end
  end

  local data = req.body
  if data == nil then
    data = req.data
  end
  if data ~= nil then
    data = tostring(data)
  end

  local method = normalizeMethod(req.method, data ~= nil)

  local options = {}
  if data ~= nil then
    options.data = data
  end
  if method ~= nil then
    options.method = method
  end
  if next(headers) ~= nil then
    options.headers = headers
  end

  local streamHandlers = {
    response = {},
    body = {},
    complete = {}
  }
  addHandler(streamHandlers.response, req.onResponse)
  addHandler(streamHandlers.body, req.onData)
  addHandler(streamHandlers.body, req.onBody)
  addHandler(streamHandlers.complete, req.onComplete)
  if type(req.stream) == "table" then
    addHandler(streamHandlers.response, req.stream.response)
    addHandler(streamHandlers.body, req.stream.body)
    addHandler(streamHandlers.complete, req.stream.complete)
  end
  local wantsStream = req.stream == true
    or #streamHandlers.response > 0
    or #streamHandlers.body > 0
    or #streamHandlers.complete > 0

  local payload = {
    url = url,
    options = options,
    httpsModule = self.httpsModule,
    stream = wantsStream
  }
  if self._adapterCode then
    payload.adapterCode = self._adapterCode
  end
  local timeout = req.timeout
  if timeout == nil then
    timeout = self.timeout
  end

  async.log("debug", "http_request_submit", { url = url, method = method, timeout = timeout })
  local task = self.pool:submit("asynchttp_request", payload, { timeout = timeout })

  if wantsStream then
    task:onProgress(function(_, packet)
      if type(packet) ~= "table" or packet.type ~= "http_stream" then
        return
      end
      local dataPacket = type(packet.data) == "table" and packet.data or {}
      if packet.event == "response" then
        emitHandlers(streamHandlers.response, dataPacket.status, dataPacket.headers or {})
      elseif packet.event == "body" then
        emitHandlers(streamHandlers.body, tostring(dataPacket.chunk or ""))
      elseif packet.event == "complete" then
        emitHandlers(streamHandlers.complete, dataPacket.err)
      end
    end)
  end

  function task:onResponse(fn)
    addHandler(streamHandlers.response, fn)
    return task
  end

  function task:onData(fn)
    addHandler(streamHandlers.body, fn)
    return task
  end

  function task:onBody(fn)
    addHandler(streamHandlers.body, fn)
    return task
  end

  function task:onComplete(fn)
    addHandler(streamHandlers.complete, fn)
    return task
  end

  return task
end

function AsyncHttp:get(url, opts)
  opts = opts or {}
  opts.url = url
  opts.method = "GET"
  return self:request(opts)
end

function AsyncHttp:post(url, body, opts)
  opts = opts or {}
  opts.url = url
  opts.method = opts.method or "POST"
  opts.body = body
  return self:request(opts)
end

return AsyncHttp
