# async.lua (cooperative async for Lua / LÖVE)

This repository provides:

- `async.lua`: a cooperative coroutine scheduler with `sleep`, `await`, timeouts, cancellation, and promise-style helpers.
- `threadpool.lua`: a LÖVE-only thread pool that integrates with `async.lua` (submit/await, progress callbacks, cancel).

## Quickstart (LÖVE)

Drop `async.lua` into your project and call the scheduler once per frame.

```lua
local async = require("async")

function love.update(dt)
  async.update(dt)
end

async(function()
  print("start")
  async.sleep(1.0)
  print("after 1s")
end)
```

## Quickstart (plain Lua)

You must drive the scheduler yourself (e.g. in your main loop). If you want real wall-clock time, provide your own `async.gettime`.

```lua
local async = require("async")

local now = 0
async.gettime = function()
  return now
end

async(function()
  print("tick")
  async.sleep(1.0)
  print("tock")
end)

while async.getTaskCount() > 0 do
  now = now + 0.016
  async.update(0.016)
end
```

## Documentation

- Full usage guide: [docs/USAGE.md](file:///Users/zhengying/Library/Application%20Support/alma/workspaces/temp-mlaz9dqtazwxf5kzwhl/async/docs/USAGE.md)

## Tests

Run all tests (LuaJIT tests + LÖVE tests if available):

```bash
luajit testcases/run.lua
```

If LÖVE is not installed at the default path, set `LOVE_BIN`:

```bash
LOVE_BIN=love luajit testcases/run.lua
```

