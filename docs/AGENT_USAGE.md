# Agent Library Usage Guide

## 1. Overview

This document is the practical usage guide for the agent library implemented in:

- `examples/agent/init.lua`

If you only read one document to use the library, read this one.

This guide covers:

- module entry points,
- required client contract,
- tool registration,
- planning and execution,
- multi-turn sessions,
- structured memory,
- scene profiles,
- profile routing,
- session persistence,
- common patterns,
- common pitfalls.

The library is designed for Lua applications that want a tool-using agent with optional:

- planning,
- multi-turn conversation,
- context compaction,
- durable memory,
- scene-specific tool exposure,
- route-based scene switching.

## 2. What the library exports

The module exports seven public objects:

- `ToolRegistry`
- `Agent`
- `MemoryStore`
- `MemoryExtractor`
- `SceneProfile`
- `ProfileRouter`
- `Session`

Typical import styles:

```lua
local agent = require("examples.agent")
```

or, if your package path is configured accordingly:

```lua
local agent = require("agent")
```

The rest of this document uses:

```lua
local agent = require("examples.agent")
```

## 3. Runtime model

The library is built on the repository's async task model.

That means:

- `Agent:plan(...)` returns an async task
- `Agent:run(...)` returns an async task
- `Session:plan(...)` returns an async task
- `Session:ask(...)` returns an async task

To get results, use `async.await(...)` inside an async context.

Example:

```lua
local async = require("async")
local agent = require("examples.agent")

local task = async(function()
  local result = async.await(session:ask("Hello"))
  print(result.text)
end)
```

## 4. The required LLM client contract

The agent does not require a specific LLM client implementation, but it does require a specific client interface.

Your client must provide:

- `client.provider`
- `client:chat(opts)`

Where:

- `client.provider` is `"openai"` or `"anthropic"`
- `client:chat(opts)` returns an async task

The async task should resolve to a table with at least:

- `text`
- `json`

Minimal client contract example:

```lua
local client = {
  provider = "openai",
  chat = function(self, opts)
    return async(function()
      return {
        text = "hello",
        json = {
          choices = {
            {
              message = {
                role = "assistant",
                content = "hello"
              }
            }
          }
        }
      }
    end)
  end
}
```

For OpenAI-compatible tool calling, `json` must contain `choices[1].message.tool_calls`.

For Anthropic tool calling, `json` must contain `content` blocks with `type = "tool_use"`.

## 5. Quick start

The smallest practical setup is:

1. create a client,
2. create a tool registry,
3. register tools,
4. create an agent,
5. create a session,
6. ask a question.

Example:

```lua
local async = require("async")
local agent = require("examples.agent")

local registry = agent.ToolRegistry.new()
registry:register({
  name = "add",
  description = "Add two numbers.",
  tags = { "math" },
  schema = {
    type = "object",
    properties = {
      a = { type = "number" },
      b = { type = "number" }
    },
    required = { "a", "b" },
    additionalProperties = false
  },
  handler = function(input)
    return {
      result = tonumber(input.a) + tonumber(input.b)
    }
  end
})

local a = agent.Agent.new({
  client = client,
  registry = registry,
  system = "You are a helpful agent.",
  withPlan = true
})

local session = agent.Session.new({
  agent = a
})

local task = async(function()
  local result = async.await(session:ask("Add 2 and 3"))
  print(result.text)
end)
```

If you want a deterministic local example with no API key, see:

- `examples/agent/quickstart.lua`

## 6. ToolRegistry

### 6.1 Create a registry

```lua
local registry = agent.ToolRegistry.new()
```

### 6.2 Register a tool

Every tool should include:

- `name`
- `description`
- `schema`
- `handler`

Optional:

- `tags`

Example:

```lua
registry:register({
  name = "http_get",
  description = "Fetch a URL and return a compact response body.",
  tags = { "web" },
  schema = {
    type = "object",
    properties = {
      url = { type = "string" },
      max_len = { type = "number" }
    },
    required = { "url" },
    additionalProperties = false
  },
  handler = function(input, ctx)
    return {
      url = input.url,
      status = 200,
      body = "..."
    }
  end
})
```

### 6.3 Tool handler contract

The handler receives:

- `input`
- `ctx`

Where `ctx` contains:

- `goal`
- `step`
- `toolIndex`
- `provider`

The handler may return:

- a plain Lua value
- an async task

If the handler returns an async task, the agent will await it automatically.

### 6.4 Tool registry methods

Useful methods:

- `registry:register(tool)`
- `registry:get(name)`
- `registry:list(opts)`
- `registry:openaiTools(opts)`
- `registry:anthropicTools(opts)`

Tool filtering options for `list` / `openaiTools` / `anthropicTools`:

- `toolNames`
- `toolTags`
- `tags`
- `toolFilter`
- `filter`
- `maxTools`

Example:

```lua
local webTools = registry:list({
  toolTags = { "web" }
})
```

## 7. Agent

`Agent` is the stateless executor.

Use it when you want direct control over planning and execution.

### 7.1 Create an agent

```lua
local a = agent.Agent.new({
  client = client,
  registry = registry,
  system = "You are a helpful agent.",
  instructions = {
    "Prefer tools over guessing."
  },
  constraints = {
    "Only use the available tools."
  },
  planGuidelines = {
    "Prefer short plans."
  },
  toolTags = { "web", "math" },
  maxSteps = 12,
  withPlan = true,
  model = "deepseek-chat",
  temperature = 0.2,
  planToolLimit = 8,
  maxHistoryMessages = 8,
  maxHistorySummaryChars = 1200
})
```

### 7.2 `Agent.new` options

- `client`  
  Required. Must implement the client contract.

- `provider`  
  Optional. `"openai"` or `"anthropic"`. If omitted, uses `client.provider`.

- `registry`  
  Optional. Defaults to a new empty `ToolRegistry`.

- `system`  
  Base system instruction string.

- `instructions`  
  Additional instruction list.

- `constraints`  
  Additional constraint list.

- `planGuidelines`  
  Additional planning rules.

- `toolNames`  
  Restrict tools by exact names.

- `toolTags`  
  Restrict tools by tags.

- `toolSelector`  
  Function that dynamically selects tools per request.

- `maxSteps`  
  Maximum tool-calling loop iterations.

- `withPlan`  
  Whether `run` should plan by default.

- `model`  
  Default model.

- `temperature`  
  Default temperature.

- `planToolLimit`  
  Maximum number of tools advertised in the planning prompt summary.

- `maxHistoryMessages`  
  Maximum number of raw recent history messages to keep.

- `maxHistorySummaryChars`  
  Maximum summary length for compacted older history.

### 7.3 Dynamic tool selection with `toolSelector`

`toolSelector(ctx)` receives:

- `goal`
- `phase`
- `provider`
- `registry`

It may return any tool filter options:

```lua
local a = agent.Agent.new({
  client = client,
  registry = registry,
  toolSelector = function(ctx)
    local goal = string.lower(tostring(ctx.goal or ""))
    if goal:find("http", 1, true) then
      return { toolTags = { "web" } }
    end
    if goal:find("add", 1, true) then
      return { toolTags = { "math" } }
    end
  end
})
```

### 7.4 Create a plan

Use `Agent:plan(goal, opts)` when you want the plan itself.

```lua
local task = a:plan("Fetch https://example.com and summarize it.")
local plan = async.await(task)
```

Returned value:

- a table of strings

Important options:

- `model`
- `temperature`
- `timeout`
- `system`
- `instructions`
- `constraints`
- `memory`
- `planGuidelines`
- `toolNames`
- `toolTags`
- `toolSelector`
- `planToolLimit`
- `extra`

### 7.5 Run the agent

Use `Agent:run(goal, opts)` for one execution.

```lua
local task = a:run("Add 2 and 3.")
local result = async.await(task)
print(result.text)
```

Returned value:

```lua
{
  ok = true,
  plan = { ... } or nil,
  text = "...",
  raw = resultFromClient
}
```

Important run options:

- `model`
- `temperature`
- `timeout`
- `system`
- `instructions`
- `constraints`
- `memory`
- `history`
- `plan`
- `withPlan`
- `maxSteps`
- `maxMessages`
- `maxToolOutputChars`
- `maxHistoryMessages`
- `maxHistorySummaryChars`
- `toolNames`
- `toolTags`
- `toolSelector`
- `planGuidelines`
- `planToolLimit`
- `extra`

### 7.6 `history` format

History must be an array of message objects.

Minimal supported form:

```lua
{
  { role = "user", content = "Hello" },
  { role = "assistant", content = "Hi" }
}
```

The library will compact older history into a summary if it exceeds the configured raw window.

## 8. Session

`Session` is the preferred interface for real applications.

It owns:

- history,
- session memory,
- workspace memory,
- global memory,
- structured memory per scope,
- optional memory extraction policy,
- profile,
- router,
- persistence state.

### 8.1 Create a session

```lua
local session = agent.Session.new({
  agent = a
})
```

Or create it directly from agent constructor options:

```lua
local session = agent.Session.new({
  client = client,
  registry = registry,
  system = "You are a helpful agent."
})
```

### 8.2 `Session.new` options

- `agent`
- `profile`
- `router`
- `history`
- `memory`
- `memoryStore`
- `workspaceMemory`
- `workspaceMemoryStore`
- `globalMemory`
- `globalMemoryStore`
- `memoryExtractor`
- `maxPlanningHistoryMessages`
- `maxPlanningHistoryChars`

### 8.3 Ask a question

```lua
local task = session:ask("What is my name?")
local result = async.await(task)
print(result.text)
```

By default, `Session:ask(...)`:

- resolves profile and router,
- optionally creates a plan,
- runs the agent,
- appends the user and assistant turns back into history,
- optionally runs post-turn memory extraction.

### 8.4 Append history automatically

Successful calls to `session:ask(...)` append:

- `{ role = "user", content = goal }`
- `{ role = "assistant", content = result.text }`

If you do not want that:

```lua
local result = async.await(session:ask("Hello", {
  appendHistory = false
}))
```

### 8.5 Session methods

- `session:ask(goal, opts)`
- `session:plan(goal, opts)`
- `session:add(role, content)`
- `session:getHistory()`
- `session:setHistory(history)`
- `session:clear()`
- `session:setMemory(memory, scope?)`
- `session:getMemory(scope?, opts?)`
- `session:setMemoryStore(store, scope?)`
- `session:getMemoryStore(scope?)`
- `session:remember(section, value, scope?)`
- `session:forget(section, value, scope?)`
- `session:clearMemory(section?, scope?)`
- `session:setMemoryExtractor(extractor)`
- `session:getMemoryExtractor()`
- `session:runMemoryExtraction(goal, answer, opts?)`
- `session:setProfile(profile)`
- `session:getProfile()`
- `session:setRouter(router)`
- `session:getRouter()`
- `session:exportState(opts)`
- `session:exportJson(opts)`
- `session:importState(state)`

### 8.6 Manual history control

If you want to preload context:

```lua
session:setHistory({
  { role = "user", content = "My name is Alice." },
  { role = "assistant", content = "I will remember that." }
})
```

Or append manually:

```lua
session:add("user", "My favorite color is blue.")
session:add("assistant", "I will remember that.")
```

### 8.7 Scoped memory example

```lua
local session = agent.Session.new({
  agent = a,
  memory = "Session-only reminder.",
  workspaceMemory = "This workspace is a Lua project.",
  globalMemory = "The user prefers concise answers."
})

print(session:getMemory("session"))
print(session:getMemory("workspace"))
print(session:getMemory("global"))

local combined = session:getMemory({
  includeGlobalMemory = false,
  includeWorkspaceMemory = true,
  includeSessionMemory = true
})
print(combined)
```

## 9. MemoryStore

`MemoryStore` is for durable structured memory.

It is not a replacement for recent raw history.

### 9.1 Create a memory store

```lua
local store = agent.MemoryStore.new({
  summary = "Remember durable user context.",
  facts = {
    "The user's name is Alice."
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
})
```

### 9.2 Attach it to a session

```lua
local session = agent.Session.new({
  agent = a,
  memoryStore = store
})
```

### 9.3 Update memory during runtime

```lua
session:remember("facts", "The user is evaluating the agent framework.")
session:remember("preferences", "The user prefers concise answers.")
session:forget("goals", "Old goal")
session:clearMemory("notes")
```

### 9.4 Memory store methods

- `MemoryStore.new(opts)`
- `store:clone()`
- `store:get(section)`
- `store:set(section, value)`
- `store:add(section, value)`
- `store:remove(section, value)`
- `store:clear(section)`
- `store:exportState()`
- `store:render()`

Supported sections:

- `summary`
- `facts`
- `preferences`
- `goals`
- `notes`

## 10. MemoryExtractor

`MemoryExtractor` is an optional post-turn writer for durable memory.

It is intentionally separate from the main answer path. Its job is to inspect a completed turn and return a strict JSON object describing memory updates for:

- `session`
- `workspace`
- `global`

### 10.1 Create an extractor

```lua
local extractor = agent.MemoryExtractor.new({
  client = client,
  scopes = { "session", "workspace" },
  maxHistoryMessages = 4,
  maxHistoryChars = 180
})
```

### 10.2 Attach it to a session

```lua
local session = agent.Session.new({
  agent = a,
  memoryExtractor = extractor
})
```

### 10.3 Extraction timing

`Session:ask(...)` performs memory extraction after a successful answer unless you disable it per call:

```lua
local result = async.await(session:ask("Hello", {
  skipMemoryExtraction = true
}))
```

This design keeps:

- routing and tool selection in the fast pre-send path,
- durable memory writes in the post-turn path,
- extracted memory grounded in both the user message and the assistant answer.

### 10.4 Run extraction manually

```lua
local updates = async.await(session:runMemoryExtraction(
  "Hello, my name is Alice.",
  "Nice to meet you, Alice."
))
```

### 10.5 Scope policy

Recommended default policy:

- use `session` for temporary task or conversation facts,
- use `workspace` for repository or project context,
- keep `global` opt-in.

## 11. SceneProfile

`SceneProfile` is reusable scene policy.

Use it when a whole class of requests should share:

- instructions,
- constraints,
- memory,
- tool filters,
- phase-specific defaults.

### 10.1 Create a profile

```lua
local profile = agent.SceneProfile.new({
  name = "web",
  instructions = {
    "Prefer tools when external data is needed."
  },
  constraints = {
    "Use only web tools in this scene."
  },
  planGuidelines = {
    "Prefer short plans."
  },
  memory = "This scene is about web browsing.",
  toolTags = { "web" }
})
```

### 10.2 Phase-specific profile defaults

You can provide:

- `defaults`
- `plan`
- `run`

Example:

```lua
local profile = agent.SceneProfile.new({
  defaults = {
    instructions = { "Answer clearly." }
  },
  plan = {
    planGuidelines = { "Prefer very short plans." }
  },
  run = {
    constraints = { "Do not invent tool results." }
  }
})
```

### 10.3 Apply a profile

```lua
local session = agent.Session.new({
  agent = a,
  profile = profile
})
```

## 12. ProfileRouter

`ProfileRouter` chooses a scene dynamically for each turn.

### 12.1 Create a router

```lua
local router = agent.ProfileRouter.new({
  name = "default_router",
  routes = {
    {
      name = "math",
      match = function(ctx)
        local goal = string.lower(tostring(ctx.goal or ""))
        return goal:find("add", 1, true) ~= nil
      end,
      profile = {
        memory = "This turn is about arithmetic.",
        toolTags = { "math" }
      }
    },
    {
      name = "web",
      match = function(ctx)
        local goal = string.lower(tostring(ctx.goal or ""))
        return goal:find("http", 1, true) ~= nil
      end,
      profile = {
        memory = "This turn is about web lookup.",
        toolTags = { "web" }
      }
    }
  }
})
```

### 12.2 Attach it to a session

```lua
local session = agent.Session.new({
  agent = a,
  router = router
})
```

### 12.3 Router context

`match(ctx)` and `selector(ctx)` may inspect:

- `goal`
- `phase`
- `session`
- `history`
- `memory`
- `memoryStore`
- `workspaceMemory`
- `workspaceMemoryStore`
- `globalMemory`
- `globalMemoryStore`
- `profile`

### 12.4 Router API

- `ProfileRouter.new(opts)`
- `router:select(goal, phase, ctx)`
- `router:resolve(goal, phase, ctx)`

## 13. Planning strategy

The library supports both:

- explicit planning,
- run-time planning.

Use explicit planning when:

- you want to show the plan to users,
- you want to store or inspect the plan,
- you want to reuse a generated plan.

Example:

```lua
local plan = async.await(session:plan("Fetch https://example.com"))
local result = async.await(session:ask("Fetch https://example.com", {
  withPlan = false,
  plan = plan
}))
```

Use implicit planning when:

- you only care about the final answer,
- the default run flow is enough.

## 14. Session persistence

Use session persistence to save and restore conversation state.

### 14.1 Export to Lua state

```lua
local state = session:exportState()
```

### 14.2 Export to JSON

```lua
local json = session:exportJson()
```

### 14.3 Import from state or JSON

```lua
session:importState(state)
session:importState(json)
```

### 14.4 What is persisted

Persisted:

- `history`
- `memory`
- `memoryStore`
- `workspaceMemory`
- `workspaceMemoryStore`
- `globalMemory`
- `globalMemoryStore`
- `metadata`

Not persisted:

- tool handlers
- client implementation
- router functions
- profile functions
- agent instance

Correct restore pattern:

1. rebuild runtime objects in code,
2. construct a new session,
3. import the saved state.

## 15. Recommended usage patterns

### 15.1 Best default pattern

For most real applications, prefer:

- one shared `ToolRegistry`,
- one configured `Agent`,
- one `Session` per user or conversation,
- optional `SceneProfile`,
- optional `ProfileRouter`,
- optional scoped `MemoryStore`,
- optional `MemoryExtractor`.

### 15.2 When to use `Agent` directly

Use `Agent` directly when:

- you are building low-level infrastructure,
- you want full control over history and memory,
- you are testing planner behavior.

### 15.3 When to use `Session`

Use `Session` when:

- you want multi-turn chat,
- you want persistence,
- you want memory,
- you want scene profiles and routing.

In practice, most application code should use `Session`.

### 15.4 Keep recent history raw

Do not replace recent raw history with only memory extraction.

Best practice:

- recent messages stay in `history`,
- durable facts go to `MemoryStore`,
- older history can be summarized automatically by the library.

## 16. Error handling

Common failure modes:

- invalid client contract
- invalid tool schema
- invalid tool arguments JSON
- tool handler error
- plan parse failure
- max steps reached
- invalid session state JSON

Typical pattern:

```lua
local task = session:ask("Hello")
local result, err = async.await(task)
if not result then
  print("agent error:", err)
  return
end
print(result.text)
```

If you use the wrapper async style from examples, remember to inspect both task state and await results.

## 17. Common pitfalls

### 17.1 Exposing all tools

Problem:

- prompt grows,
- tool selection gets worse.

Fix:

- use `toolTags`,
- use `toolSelector`,
- use `SceneProfile`,
- use `ProfileRouter`.

### 17.2 Treating memory as history

Problem:

- precision drops,
- follow-up quality drops.

Fix:

- keep recent history raw,
- store only durable facts in `MemoryStore`.

### 17.3 Treating all durable memory as global

Problem:

- unrelated tasks contaminate each other,
- prompt relevance drops,
- user expectations become harder to manage.

Fix:

- prefer `session` scope first,
- use `workspace` scope for project context,
- keep `global` opt-in.

### 17.4 Forgetting async execution

Problem:

- calling `:plan()` or `:ask()` and expecting an immediate table.

Fix:

- these return async tasks,
- await them.

### 17.5 Putting scene logic into `Agent`

Problem:

- hard to maintain,
- hard to extend.

Fix:

- move static policy to `SceneProfile`,
- move dynamic policy to `ProfileRouter`.

## 18. API reference summary

### ToolRegistry

- `ToolRegistry.new()`
- `registry:register(tool)`
- `registry:get(name)`
- `registry:list(opts)`
- `registry:openaiTools(opts)`
- `registry:anthropicTools(opts)`

### Agent

- `Agent.new(opts)`
- `agent:plan(goal, opts)`
- `agent:run(goal, opts)`

### MemoryStore

- `MemoryStore.new(opts)`
- `store:clone()`
- `store:get(section)`
- `store:set(section, value)`
- `store:add(section, value)`
- `store:remove(section, value)`
- `store:clear(section)`
- `store:exportState()`
- `store:render()`

### MemoryExtractor

- `MemoryExtractor.new(opts)`
- `extractor:extract(opts)`

### SceneProfile

- `SceneProfile.new(opts)`
- `profile:resolve(goal, phase, opts)`

### ProfileRouter

- `ProfileRouter.new(opts)`
- `router:select(goal, phase, ctx)`
- `router:resolve(goal, phase, ctx)`

### Session

- `Session.new(opts)`
- `session:getHistory()`
- `session:setHistory(history)`
- `session:clear()`
- `session:setMemory(memory, scope?)`
- `session:getMemory(scope?, opts?)`
- `session:setMemoryStore(store, scope?)`
- `session:getMemoryStore(scope?)`
- `session:remember(section, value, scope?)`
- `session:forget(section, value, scope?)`
- `session:clearMemory(section?, scope?)`
- `session:setMemoryExtractor(extractor)`
- `session:getMemoryExtractor()`
- `session:runMemoryExtraction(goal, answer, opts?)`
- `session:setProfile(profile)`
- `session:getProfile()`
- `session:setRouter(router)`
- `session:getRouter()`
- `session:add(role, content)`
- `session:plan(goal, opts)`
- `session:ask(goal, opts)`
- `session:exportState(opts)`
- `session:exportJson(opts)`
- `session:importState(state)`

## 19. Suggested learning order

If you are new to the library, follow this order:

1. run `examples/agent/quickstart.lua`
2. create one tool in a local script
3. create one `Agent`
4. wrap it in one `Session`
5. add one `MemoryStore`
6. add one `SceneProfile`
7. add one `ProfileRouter`
8. try the LÖVE demo in `examples/love/agent`

## 20. Final recommendation

If you want a robust application integration, use this shape:

```lua
local registry = agent.ToolRegistry.new()
-- register tools

local baseAgent = agent.Agent.new({
  client = client,
  registry = registry,
  system = "You are a helpful agent."
})

local session = agent.Session.new({
  agent = baseAgent,
  profile = profile,
  router = router,
  memoryStore = memoryStore,
  workspaceMemoryStore = workspaceMemoryStore,
  memoryExtractor = memoryExtractor
})
```

Then call:

```lua
local result = async.await(session:ask(userInput))
```

This gives you:

- tool use,
- planning,
- context management,
- scene policy,
- routing,
- durable memory,
- scoped memory extraction,
- persistence.
