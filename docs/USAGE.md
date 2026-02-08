# async.lua — Technical Documentation & Usage Guide

## 1) What this library is

`async.lua` is a cooperative async runtime built on Lua coroutines:

- Tasks are coroutines scheduled by a single-threaded scheduler.
- You drive the scheduler by calling `async.update(...)` repeatedly (typically once per frame in LÖVE).
- “Async” here means “structured cooperative concurrency”, not OS threads.

It also includes:

- `async.thread(...)`: a simple “run a LÖVE thread file and await its result” helper.
- `threadpool.lua`: a higher-level LÖVE thread pool integration with progress events and cancellation.

## 2) Core mental model

### Scheduler state

The scheduler maintains three internal sets of tasks:

- A “new task” queue (`async.new` puts tasks here).
- A “ready-to-run again” stack (tasks that yielded and should continue next update).
- A sleepers list (tasks waiting for a wake time after `async.sleep`).

On each `async.update(...)` call, the scheduler:

- wakes tasks whose sleep delay elapsed,
- runs ready tasks,
- keeps tasks that are still alive and not sleeping in the ready stack.

### Cooperative means you must yield

If a task runs a long CPU loop and never yields, it blocks everything else. A task yields when it calls:

- `async.sleep(seconds)` (yield + wake later)
- `async.yield()` (yield + continue next update)
- `async.await(...)` / `async.waitfor(...)` (these yield internally)

## 3) Installation / project structure

Copy these files into your Lua module path:

- `async.lua`
- optionally `threadpool.lua` (LÖVE only)

Then:

```lua
local async = require("async")
```

## 4) Driving the scheduler

### LÖVE integration (recommended)

```lua
local async = require("async")

function love.update(dt)
  async.update(dt)
end
```

You do not need to pass `dt` to `async.update`, but it is convenient if you want to forward values into tasks (the scheduler forwards `...` into resumes).

### Plain Lua integration

You must provide a time source and call the scheduler in a loop.

```lua
local async = require("async")

local now = 0
async.gettime = function()
  return now
end

async(function()
  async.sleep(0.5)
  return "done"
end):next(function(result)
  print(result)
end)

while async.getTaskCount() > 0 do
  now = now + 0.016
  async.update(0.016)
end
```

## 5) Creating tasks

### `async.new(fn, ...)` / `async(fn, ...)`

Creates a task from a Lua function and schedules it to run.

```lua
local task = async(function(a, b)
  return a + b, "ok"
end, 2, 3)
```

Return values are stored in `task.result` as a packed table:

- `task.result.n` is the number of returned values.
- `task.result[1..n]` are the values.

### Task state

Each task has a `state`:

- `"pending"`: created, not yet run
- `"running"`: currently executing
- `"completed"`: finished without error
- `"errored"`: failed
- `"stopped"`: canceled by `task:stop()`

Helpers:

- `task:getState()`
- `task:isRunning()`, `task:isCompleted()`, `task:isErrored()`

## 6) Continuations and error handling

### `task:next(fn)`

Runs `fn(...)` after the task completes successfully. The continuation receives the task’s return values.

```lua
async(function()
  return 10, 20
end):next(function(x, y)
  print(x, y)
end)
```

Important detail: continuations are scheduled and will run on a subsequent `async.update()` call (usually the next one).

### `task:catch(fn)`

Runs `fn(err)` if the task errors. If you do not attach a catch handler, the default error handler prints to stderr (or `print` under LÖVE).

```lua
async(function()
  error("boom")
end):catch(function(err)
  print("caught:", err)
end)
```

### Custom error handler

Override `async.errorhandler(task, err)` to integrate with your logging/UI.

### Logging (optional)

This library includes a lightweight event-style logger you can enable and redirect.

By default, logging is disabled (`off`) and has near-zero overhead (early returns).

#### API

- `async.setLogEnabled(true|false)` enables/disables logging.
- `async.setLogLevel(level)` sets the maximum verbosity.
  - `level` can be `"off"|"error"|"warn"|"info"|"debug"|"trace"` or a number `0..5`.
- `async.setLogSink(fnOrNil)` sets a sink callback.
  - If `nil`, a default sink prints to stderr (or `print` under LÖVE).
- `async.log(level, event, fields)` emits a custom log event from inside an async task.

#### Sink entry format

The sink receives a single table:

- `entry.time`: `async.gettime()` at emission time
- `entry.level`: numeric level `0..5`
- `entry.levelName`: string level name
- `entry.event`: short event name string (e.g. `"task_create"`)
- `entry.fields`: optional table of extra fields (may be `nil`)
- `entry.task`: optional task reference (may be `nil`)
  - `{ id, src, line, name, state }`

#### Example: redirect logs into your own system

```lua
local async = require("async")

async.setLogLevel("debug")
async.setLogSink(function(entry)
  -- entry.event / entry.fields / entry.task are designed to be structured and machine-readable
  print(entry.levelName, entry.event, entry.task and entry.task.id)
end)
async.setLogEnabled(true)
```

#### Notes

- When logging is enabled and the level allows it, unhandled task errors are emitted as `"unhandled_error"` events instead of printing via the default `async.errorhandler`.
- `threadpool.lua` also emits events via `async.log(...)` (submit/cancel/progress/result), so enabling logging gives you visibility into both scheduler and thread pool activity.

## 7) Sleeping and yielding

### `async.sleep(seconds)`

Suspends the current task and resumes it after `seconds` have elapsed (based on `async.gettime()`).

```lua
async(function()
  print("A")
  async.sleep(1.0)
  print("B")
end)
```

### `async.yield()`

Yields until the next `async.update()` tick.

## 8) Awaiting other work

### `async.await(task)`

Wait for a task to finish and return its results (or return an error triple on failure).

```lua
async(function()
  local child = async(function()
    async.sleep(0.2)
    return 123
  end)

  local value = async.await(child)
  print(value)
end)
```

### `async.await(fn, ...)`

Create a task from `fn` and await it.

```lua
async(function()
  local v = async.await(function()
    async.sleep(0.1)
    return "ok"
  end)
  print(v)
end)
```

### Task-flattening (power feature)

If the awaited function returns a task as its first return value, `await` will automatically “follow” that task and await it. This makes it easy to return a task from helpers.

```lua
local function fetchLater()
  return async(function()
    async.sleep(0.1)
    return "value"
  end)
end

async(function()
  local v = async.await(fetchLater)
  print(v)
end)
```

### Practical notes

- `async.await(task)` can await an existing task directly. If you already have a task (e.g. returned from `pool:submit(...)`), you do not need to wrap it.
- `async.await(function() return task end)` is useful when you want task-flattening from helper functions, but is not required when you already have a task.
- On success, `await` returns the task’s normal return values (no `state`). On failure / cancellation, it returns `nil, err, state`.

### Await return convention on failure

On failure / cancellation, `await` returns a triple:

- `nil, err, state`

Where `state` is `"errored"` or `"stopped"`.

## 9) Cancellation

### `task:stop()`

Marks a task as stopped; it will not execute further.

If a task is currently awaiting another task through `async.await`, `stop()` also stops the currently awaited task (this is implemented via an internal `_awaiting` link).

Practical pattern:

```lua
local t = async(function()
  async.sleep(10)
  return "never"
end)

t:stop()
```

Cancellation is cooperative: a task will stop when the scheduler regains control (after it yields or returns).

## 10) Timeouts

### `task:setTimeout(seconds)`

Sets a deadline for the task relative to `async.gettime()`. If it exceeds the deadline, it errors with `"timeout"`.

```lua
async(function()
  async.sleep(999)
end):setTimeout(0.5):catch(function(err)
  print(err) -- "timeout"
end)
```

### `async.waitfor(predicate, timeoutSeconds, ...)`

Repeatedly evaluates `predicate(...)` until it returns a truthy first value or the timeout expires.

```lua
async(function()
  local ready = false
  async.delay(function() ready = true end, 0.2)

  local ok, err = async.waitfor(function()
    return ready
  end, 1.0)

  if not ok then
    error(err)
  end
end)
```

## 11) Promise-style helpers

### `async.all({task1, task2, ...})`

Wait for all tasks to complete.

- Returns `results`, a list where `results[i]` is a list of return values for task `i`.
- If any task errors, returns `nil, err`.

### `async.race({task1, task2, ...})`

Wait for the first task to complete or error.

- On success: returns `task.result, winnerIndex, nil`
- On error: returns `nil, winnerIndex, err`

### `async.delay(fn, seconds, ...)`

Schedule `fn(...)` to run after a delay, returning a task.

## 12) LÖVE thread helper (`async.thread`)

`async.thread(threadFile, input, timeout)` runs a *thread file* via `love.thread.newThread(threadFile)` and waits for a single value sent back through a channel.

Requirements:

- Must be called inside an async task.
- `threadFile` must be a file that LÖVE can load (relative to the game source).
- The thread file must read from the input channel and push one result to the output channel.

Example:

Main thread:

```lua
async(function()
  local value, err = async.thread("worker.lua", 21, 5)
  if err then error(err) end
  print("worker returned:", value)
end)
```

`worker.lua`:

```lua
local inName, outName = ...
local inCh = love.thread.getChannel(inName)
local outCh = love.thread.getChannel(outName)

local input = inCh:demand()
outCh:push(input * 2)
```

## 13) ThreadPool (LÖVE only)

`threadpool.lua` provides a pool of worker threads plus an async interface.

```lua
local async = require("async")
local ThreadPool = require("threadpool")

local pool = ThreadPool.new(2)

pool:register("heavy", function(payload, ctx)
  local n = payload.n
  local acc = 0
  for i = 1, n do
    if ctx.canceled() then
      return nil, "canceled"
    end
    acc = acc + math.sqrt(i)
    if i % 10000 == 0 then
      ctx.progress(i / n, { i = i })
    end
  end
  return acc
end)

async(function()
  local task = pool:submit("heavy", { n = 200000 }, { timeout = 5 })
  task:onProgress(function(p, data)
    print("progress:", p, data.i)
  end)

  local result = async.await(function()
    return task
  end)

  print("done:", result)
end)
```

### ThreadPool API

- `ThreadPool.new(size)` -> `pool`
- `pool:register(name, fn)` registers a worker function on all workers
- `pool:submit(name, payload, opts)` -> `task`
  - `opts.timeout` is supported
  - `task:onProgress(handler)` registers a progress callback
  - `task:cancel()` cancels the job (cooperative)
- `pool:await(name, payload, opts)` convenience wrapper returning awaited results

### ThreadPool gotchas (important)

- The worker function is serialized with `string.dump(fn)` and loaded in a worker thread. This means:
  - `fn` must be dumpable (avoid C closures / functions provided by native modules).
  - avoid relying on upvalues; prefer passing everything in `payload`.
- Progress callbacks run on the main thread during `async.update()` ticks (the pool installs an internal async pump task).
- Cancellation is cooperative: your worker function must periodically call `ctx.canceled()` to stop early.
- If your worker does `if ctx.canceled() then return nil, "canceled" end`, that is a normal successful return (not an async error). If you want cancellation to surface as an error/state on the main thread, use `error("canceled")` (or adopt your own tagged-result convention and handle it explicitly).

## 14) Common patterns

### Frame-friendly loops

```lua
async(function()
  while true do
    -- do a small chunk of work
    async.yield()
  end
end)
```

### Structured cancellation

```lua
local parent = async(function()
  local v = async.await(function()
    return async.delay(function()
      return "value"
    end, 10)
  end)
  return v
end)

async.delay(function()
  parent:stop()
end, 1)
```

## 15) Testing

Run:

```bash
luajit testcases/run.lua
```

This runs:

- LuaJIT scheduler tests
- and, if LÖVE is available, the LÖVE thread / threadpool tests
