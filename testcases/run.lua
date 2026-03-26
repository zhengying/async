local function dirname(path)
  if type(path) ~= "string" then
    return "."
  end
  local dir = path:match("^(.*)[/\\]") or "."
  if dir == "" then
    return "."
  end
  return dir
end

local baseDir = dirname((arg and arg[0]) or "")
local rootDir = baseDir .. "/.."

package.path = rootDir .. "/?.lua;" .. rootDir .. "/?/init.lua;" .. package.path

local files = {
  rootDir .. "/testcases/test_async_core.lua",
  rootDir .. "/testcases/test_async_logging.lua",
  rootDir .. "/testcases/test_async_sleep_timeout.lua",
  rootDir .. "/testcases/test_async_await_waitfor.lua",
  rootDir .. "/testcases/test_async_promises.lua",
  rootDir .. "/testcases/test_threadpool.lua",
  rootDir .. "/testcases/test_agent.lua"
}

local total = 0
local failed = 0

local function fileExists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function runCommand(name, cmd)
  total = total + 1
  io.stdout:write("[RUN ] " .. name .. "\n")
  local a, b, c = os.execute(cmd)
  local ok = false
  if type(a) == "number" then
    ok = (a == 0)
  elseif type(a) == "boolean" then
    ok = a and (c == 0 or c == nil)
  end
  if ok then
    io.stdout:write("[PASS] " .. name .. "\n")
    return true
  end
  failed = failed + 1
  io.stdout:write("[FAIL] " .. name .. "\n")
  io.stdout:write("Command: " .. cmd .. "\n")
  return false
end

local function runFile(path)
  total = total + 1
  local ok, err = xpcall(function()
    dofile(path)
  end, function(e)
    local tb = debug and debug.traceback and debug.traceback(e, 2)
    return tb or tostring(e)
  end)

  if ok then
    io.stdout:write("[PASS] " .. path .. "\n")
    return true
  end

  failed = failed + 1
  io.stdout:write("[FAIL] " .. path .. "\n")
  io.stdout:write(tostring(err) .. "\n")
  return false
end

for _, path in ipairs(files) do
  runFile(path)
end

do
  local envLoveBin = os.getenv("LOVE_BIN")
  local loveBin = envLoveBin or "/Applications/love.app/Contents/MacOS/love"
  local loveProject = rootDir .. "/testcases/love"
  if envLoveBin ~= nil or fileExists(loveBin) then
    local cmd = shellQuote(loveBin) .. " " .. shellQuote(loveProject)
    runCommand("love2d tests", cmd)

    if tostring(os.getenv("ASYNC_HTTP_REAL") or "") == "1" then
      local httpProject = rootDir .. "/examples/love/https"
      local prefix = "ASYNC_HTTP_TEST=1"
      if package.config:sub(1, 1) == "\\" then
        prefix = "set ASYNC_HTTP_TEST=1 &&"
      end
      local httpCmd = prefix .. " " .. shellQuote(loveBin) .. " " .. shellQuote(httpProject)
      runCommand("async_http real integration (network)", httpCmd)
    end
  else
    io.stdout:write("[SKIP] love2d tests (LOVE_BIN not found)\n")
  end
end

io.stdout:write(string.format("Total: %d, Failed: %d\n", total, failed))

if failed > 0 then
  os.exit(1)
end
