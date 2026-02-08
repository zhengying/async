local M = {}

function M.assertTrue(value, message)
  if not value then
    error(message or "assertTrue failed", 2)
  end
end

function M.assertEq(actual, expected, message)
  if actual ~= expected then
    error(message or ("assertEq failed: expected " .. tostring(expected) .. " got " .. tostring(actual)), 2)
  end
end

function M.assertMatch(text, pattern, message)
  if type(text) ~= "string" then
    error(message or ("assertMatch failed: text is not a string: " .. tostring(text)), 2)
  end
  if not string.match(text, pattern) then
    error(message or ("assertMatch failed: '" .. text .. "' does not match '" .. pattern .. "'"), 2)
  end
end

function M.expectError(fn, pattern)
  local ok, err = pcall(fn)
  if ok then
    error("expected error, got success", 2)
  end
  if pattern then
    M.assertMatch(tostring(err), pattern, "error message did not match pattern")
  end
  return tostring(err)
end

function M.makeHarness(async)
  local now = 0

  local function reset()
    async.clear()
    now = 0
    async.gettime = function()
      return now
    end
  end

  local function step(dt, n)
    n = n or 1
    for _ = 1, n do
      now = now + (dt or 0)
      async.update(dt)
    end
  end

  local function runUntil(predicate, opts)
    opts = opts or {}
    local dt = opts.dt or 0.01
    local maxSteps = opts.maxSteps or 10000
    for _ = 1, maxSteps do
      if predicate() then
        return true
      end
      step(dt, 1)
    end
    return false, "runUntil maxSteps reached"
  end

  reset()

  return {
    reset = reset,
    step = step,
    runUntil = runUntil,
    getTime = function()
      return now
    end
  }
end

return M
