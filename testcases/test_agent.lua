local async = require("async")
local T = require("testcases.testlib")

local function isArray(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
    if k > n then
      n = k
    end
  end
  return n == #t
end

local function jsonEncode(v)
  local tv = type(v)
  if tv == "string" then
    return string.format("%q", v)
  end
  if tv == "number" or tv == "boolean" then
    return tostring(v)
  end
  if tv ~= "table" then
    return "null"
  end
  if isArray(v) then
    local parts = {}
    for i = 1, #v do
      parts[#parts + 1] = jsonEncode(v[i])
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k, _ in pairs(v) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)
  local parts = {}
  for i = 1, #keys do
    local key = keys[i]
    parts[#parts + 1] = string.format("%q", key) .. ":" .. jsonEncode(v[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deepCopy(v)
  end
  return out
end

local decodeFixtures = {
  ["[]"] = {},
  ["[\"use http_get\"]"] = { "use http_get" }
}

package.preload["llm"] = function()
  return {
    jsonEncode = jsonEncode,
    jsonDecode = function(text)
      if decodeFixtures[text] ~= nil then
        return deepCopy(decodeFixtures[text])
      end
      error("unsupported json in test: " .. tostring(text))
    end
  }
end

package.loaded["examples.agent"] = nil
local agent = require("examples.agent")
local harness = T.makeHarness(async)

local function makeChatTask(payload)
  return async(function()
    return payload
  end)
end

do
  harness.reset()

  local captured = {}
  local responses = {
    { text = "[\"use http_get\"]", json = { choices = { { message = { role = "assistant", content = "[\"use http_get\"]" } } } } },
    { text = "done", json = { choices = { { message = { role = "assistant", content = "done" } } } } }
  }
  local client = {
    provider = "openai",
    chat = function(_, params)
      captured[#captured + 1] = params
      return makeChatTask(table.remove(responses, 1))
    end
  }
  local registry = agent.ToolRegistry.new()
  registry:register({
    name = "http_get",
    description = "Fetch a URL.",
    schema = { type = "object", properties = {}, additionalProperties = false },
    handler = function()
      return { ok = true }
    end,
    tags = { "web" }
  })
  registry:register({
    name = "add",
    description = "Add numbers.",
    schema = { type = "object", properties = {}, additionalProperties = false },
    handler = function()
      return { ok = true }
    end,
    tags = { "math" }
  })

  local a = agent.Agent.new({
    client = client,
    registry = registry,
    toolSelector = function(ctx)
      if ctx.goal == "fetch url" then
        return { toolTags = { "web" } }
      end
    end
  })

  local task = async(function()
    local plan = async.await(a:plan("fetch url"))
    T.assertEq(plan[1], "use http_get")
    local result = async.await(a:run("fetch url", { withPlan = false }))
    T.assertEq(result.text, "done")
  end)
  local ok, err = harness.runUntil(function()
    return task.result ~= nil or task.error ~= nil
  end, { maxSteps = 1000 })
  T.assertTrue(ok, err)
  T.assertTrue(task.error == nil, tostring(task.error))
  T.assertMatch(captured[1].messages[1].content, "http_get", "plan prompt should mention filtered tool")
  T.assertTrue(not string.find(captured[1].messages[1].content, "Add numbers", 1, true), "plan prompt should omit unrelated tools")
  T.assertEq(#captured[2].extra.tools, 1, "run should only expose selected tools")
  T.assertEq(captured[2].extra.tools[1]["function"].name, "http_get", "run should expose the filtered tool")
end

do
  harness.reset()

  local captured = {}
  local client = {
    provider = "openai",
    chat = function(_, params)
      captured[#captured + 1] = params
      return makeChatTask({
        text = "done",
        json = { choices = { { message = { role = "assistant", content = "done" } } } }
      })
    end
  }

  local a = agent.Agent.new({
    client = client,
    maxHistoryMessages = 2,
    withPlan = false
  })

  local history = {
    { role = "user", content = "turn 1 user" },
    { role = "assistant", content = "turn 1 assistant" },
    { role = "user", content = "turn 2 user" },
    { role = "assistant", content = "turn 2 assistant" }
  }

  local task = async(function()
    local result = async.await(a:run("current question", {
      withPlan = false,
      history = history,
      memory = "user prefers concise answers"
    }))
    T.assertEq(result.text, "done")
  end)
  local ok, err = harness.runUntil(function()
    return task.result ~= nil or task.error ~= nil
  end, { maxSteps = 1000 })
  T.assertTrue(ok, err)
  T.assertTrue(task.error == nil, tostring(task.error))
  T.assertEq(#captured[1].messages, 4, "run should keep system, recent history, and current user")
  T.assertEq(captured[1].messages[2].content, "turn 2 user")
  T.assertEq(captured[1].messages[3].content, "turn 2 assistant")
  T.assertEq(captured[1].messages[4].content, "current question")
  T.assertMatch(captured[1].messages[1].content, "Conversation summary", "system prompt should contain history summary")
  T.assertMatch(captured[1].messages[1].content, "turn 1 user", "older history should move into summary")
  T.assertMatch(captured[1].messages[1].content, "user prefers concise answers", "memory should be included in system prompt")
end

do
  harness.reset()

  local captured = {}
  local responses = {
    { text = "[\"use http_get\"]", json = { choices = { { message = { role = "assistant", content = "[\"use http_get\"]" } } } } },
    { text = "I will remember that.", json = { choices = { { message = { role = "assistant", content = "I will remember that." } } } } },
    { text = "[\"use http_get\"]", json = { choices = { { message = { role = "assistant", content = "[\"use http_get\"]" } } } } },
    { text = "Your name is Alice.", json = { choices = { { message = { role = "assistant", content = "Your name is Alice." } } } } }
  }
  local client = {
    provider = "openai",
    chat = function(_, params)
      captured[#captured + 1] = params
      return makeChatTask(table.remove(responses, 1))
    end
  }

  local a = agent.Agent.new({
    client = client,
    withPlan = true
  })
  local session = agent.Session.new({
    agent = a,
    memory = "Keep track of user facts."
  })

  local task = async(function()
    local first = async.await(session:ask("My name is Alice."))
    T.assertEq(first.text, "I will remember that.")
    local second = async.await(session:ask("What is my name?"))
    T.assertEq(second.text, "Your name is Alice.")
  end)
  local ok, err = harness.runUntil(function()
    return task.result ~= nil or task.error ~= nil
  end, { maxSteps = 1000 })
  T.assertTrue(ok, err)
  T.assertTrue(task.error == nil, tostring(task.error))
  local history = session:getHistory()
  T.assertEq(#history, 4, "session should append both user and assistant turns")
  T.assertEq(history[1].content, "My name is Alice.")
  T.assertEq(history[4].content, "Your name is Alice.")
  T.assertMatch(captured[3].messages[1].content, "Recent conversation", "session plan should include recent conversation")
  T.assertMatch(captured[3].messages[1].content, "Alice", "session plan should include prior turn context")
  session:clear()
  T.assertEq(#session:getHistory(), 0, "session clear should remove history")
end

do
  harness.reset()

  local captured = {}
  local responses = {
    { text = "[\"use http_get\"]", json = { choices = { { message = { role = "assistant", content = "[\"use http_get\"]" } } } } },
    { text = "Fetched the web page.", json = { choices = { { message = { role = "assistant", content = "Fetched the web page." } } } } }
  }
  local client = {
    provider = "openai",
    chat = function(_, params)
      captured[#captured + 1] = params
      return makeChatTask(table.remove(responses, 1))
    end
  }
  local registry = agent.ToolRegistry.new()
  registry:register({
    name = "http_get",
    description = "Fetch a URL.",
    schema = { type = "object", properties = {}, additionalProperties = false },
    handler = function()
      return { ok = true }
    end,
    tags = { "web" }
  })
  registry:register({
    name = "add",
    description = "Add numbers.",
    schema = { type = "object", properties = {}, additionalProperties = false },
    handler = function()
      return { ok = true }
    end,
    tags = { "math" }
  })

  local profile = agent.SceneProfile.new({
    memory = "Web browsing scene.",
    instructions = { "Answer briefly." },
    constraints = { "Use only web tools in this scene." },
    toolTags = { "web" }
  })

  local a = agent.Agent.new({
    client = client,
    registry = registry,
    withPlan = true
  })
  local session = agent.Session.new({
    agent = a,
    profile = profile,
    memory = "Remember the current user goal."
  })

  local task = async(function()
    local result = async.await(session:ask("Fetch example.com"))
    T.assertEq(result.text, "Fetched the web page.")
  end)
  local ok, err = harness.runUntil(function()
    return task.result ~= nil or task.error ~= nil
  end, { maxSteps = 1000 })
  T.assertTrue(ok, err)
  T.assertTrue(task.error == nil, tostring(task.error))
  T.assertMatch(captured[1].messages[1].content, "Web browsing scene", "profile memory should be included in planning")
  T.assertMatch(captured[1].messages[1].content, "Answer briefly", "profile instructions should be included in planning")
  T.assertTrue(not string.find(captured[1].messages[1].content, "Add numbers", 1, true), "profile tool tags should filter planning tools")
  T.assertMatch(captured[2].messages[1].content, "Remember the current user goal", "session memory should be included in run prompt")
  T.assertEq(#captured[2].extra.tools, 1, "profile should filter run tools")
  T.assertEq(captured[2].extra.tools[1]["function"].name, "http_get", "profile should expose the selected tool")
end

do
  harness.reset()

  local captured = {}
  local responses = {
    { text = "[\"use add\"]", json = { choices = { { message = { role = "assistant", content = "[\"use add\"]" } } } } },
    { text = "The sum is 5.", json = { choices = { { message = { role = "assistant", content = "The sum is 5." } } } } }
  }
  local client = {
    provider = "openai",
    chat = function(_, params)
      captured[#captured + 1] = params
      return makeChatTask(table.remove(responses, 1))
    end
  }
  local registry = agent.ToolRegistry.new()
  registry:register({
    name = "http_get",
    description = "Fetch a URL.",
    schema = { type = "object", properties = {}, additionalProperties = false },
    handler = function()
      return { ok = true }
    end,
    tags = { "web" }
  })
  registry:register({
    name = "add",
    description = "Add numbers.",
    schema = { type = "object", properties = {}, additionalProperties = false },
    handler = function()
      return { ok = true }
    end,
    tags = { "math" }
  })

  local router = agent.ProfileRouter.new({
    routes = {
      {
        name = "math",
        match = function(ctx)
          return string.find(string.lower(tostring(ctx.goal or "")), "add", 1, true) ~= nil
        end,
        profile = {
          memory = "Math route selected.",
          toolTags = { "math" }
        }
      },
      {
        name = "web",
        match = function(ctx)
          return string.find(string.lower(tostring(ctx.goal or "")), "http", 1, true) ~= nil
        end,
        profile = {
          memory = "Web route selected.",
          toolTags = { "web" }
        }
      }
    }
  })

  local a = agent.Agent.new({
    client = client,
    registry = registry,
    withPlan = true
  })
  local session = agent.Session.new({
    agent = a,
    router = router
  })

  local task = async(function()
    local result = async.await(session:ask("Add 2 and 3"))
    T.assertEq(result.text, "The sum is 5.")
  end)
  local ok, err = harness.runUntil(function()
    return task.result ~= nil or task.error ~= nil
  end, { maxSteps = 1000 })
  T.assertTrue(ok, err)
  T.assertTrue(task.error == nil, tostring(task.error))
  T.assertMatch(captured[1].messages[1].content, "Math route selected", "router should inject matched profile memory into planning")
  T.assertTrue(not string.find(captured[1].messages[1].content, "Fetch a URL", 1, true), "router should filter planning tools")
  T.assertEq(#captured[2].extra.tools, 1, "router should filter run tools")
  T.assertEq(captured[2].extra.tools[1]["function"].name, "add", "router should select math tool")
end

do
  harness.reset()

  local captured = {}
  local deltas = {}
  local snapshots = {}
  local client = {
    provider = "openai",
    chat = function(_, params)
      captured[#captured + 1] = params
      return async(function()
        if type(params.onText) == "function" then
          params.onText("Hel", "Hel", { provider = "openai" })
          params.onText("lo", "Hello", { provider = "openai" })
        end
        return {
          text = "Hello",
          json = { choices = { { message = { role = "assistant", content = "Hello" } } } }
        }
      end)
    end
  }

  local session = agent.Session.new({
    agent = agent.Agent.new({
      client = client,
      withPlan = false
    })
  })

  local task = async(function()
    local result = async.await(session:ask("Say hello", {
      stream = true,
      onText = function(delta, text, meta)
        deltas[#deltas + 1] = delta
        snapshots[#snapshots + 1] = {
          text = text,
          step = meta and meta.step or nil,
          provider = meta and meta.provider or nil
        }
      end
    }))
    T.assertEq(result.text, "Hello")
  end)
  local ok, err = harness.runUntil(function()
    return task.result ~= nil or task.error ~= nil
  end, { maxSteps = 1000 })
  T.assertTrue(ok, err)
  T.assertTrue(task.error == nil, tostring(task.error))
  T.assertEq(captured[1].stream, true, "session ask should enable client streaming")
  T.assertEq(table.concat(deltas), "Hello", "session ask should forward streamed deltas")
  T.assertEq(snapshots[#snapshots].text, "Hello", "session ask should forward the latest streamed text")
  T.assertEq(snapshots[1].step, 1, "session ask should annotate stream step")
  T.assertEq(snapshots[1].provider, "openai", "session ask should annotate provider")
end

do
  harness.reset()

  local client = {
    provider = "openai",
    chat = function()
      return makeChatTask({
        text = "unused",
        json = { choices = { { message = { role = "assistant", content = "unused" } } } }
      })
    end
  }

  local session = agent.Session.new({
    agent = agent.Agent.new({
      client = client,
      withPlan = false
    }),
    profile = agent.SceneProfile.new({
      name = "chat_profile"
    }),
    router = agent.ProfileRouter.new({
      name = "chat_router"
    }),
    memory = "Persist this memory."
  })
  session:add("user", "hello")
  session:add("assistant", "hi there")

  local snapshot = session:exportState({
    metadata = {
      label = "demo"
    }
  })
  T.assertEq(snapshot.memory, "Persist this memory.")
  T.assertEq(#snapshot.history, 2)
  T.assertEq(snapshot.metadata.profile, "chat_profile")
  T.assertEq(snapshot.metadata.router, "chat_router")
  T.assertEq(snapshot.metadata.extra.label, "demo")

  session:clear()
  session:setMemory("Changed memory.")
  session:importState(snapshot)
  T.assertEq(session:getMemory(), "Persist this memory.")
  local history = session:getHistory()
  T.assertEq(#history, 2)
  T.assertEq(history[1].content, "hello")
  T.assertEq(history[2].content, "hi there")
end

do
  harness.reset()

  local captured = {}
  local client = {
    provider = "openai",
    chat = function(_, params)
      captured[#captured + 1] = params
      return makeChatTask({
        text = "done",
        json = { choices = { { message = { role = "assistant", content = "done" } } } }
      })
    end
  }

  local store = agent.MemoryStore.new({
    summary = "Remember durable user context.",
    facts = { "The user's name is Alice." },
    preferences = { "The user prefers concise answers." },
    goals = { "Keep the conversation coherent." }
  })

  local session = agent.Session.new({
    agent = agent.Agent.new({
      client = client,
      withPlan = false
    }),
    memory = "Temporary session note.",
    memoryStore = store
  })
  session:remember("notes", "Mention prior facts when relevant.")
  session:forget("goals", "Keep the conversation coherent.")

  local task = async(function()
    local result = async.await(session:ask("What do you know about me?", {
      withPlan = false
    }))
    T.assertEq(result.text, "done")
  end)
  local ok, err = harness.runUntil(function()
    return task.result ~= nil or task.error ~= nil
  end, { maxSteps = 1000 })
  T.assertTrue(ok, err)
  T.assertTrue(task.error == nil, tostring(task.error))
  T.assertMatch(captured[1].messages[1].content, "The user's name is Alice", "structured facts should be rendered into memory")
  T.assertMatch(captured[1].messages[1].content, "The user prefers concise answers", "structured preferences should be rendered into memory")
  T.assertMatch(captured[1].messages[1].content, "Temporary session note", "string memory should remain supported")
  T.assertMatch(captured[1].messages[1].content, "Mention prior facts when relevant", "notes should be rendered into memory")
  T.assertTrue(not string.find(captured[1].messages[1].content, "Keep the conversation coherent", 1, true), "removed goals should not remain in memory")

  local snapshot = session:exportState()
  T.assertEq(snapshot.memoryStore.facts[1], "The user's name is Alice.")
  T.assertEq(snapshot.memoryStore.preferences[1], "The user prefers concise answers.")
  T.assertEq(snapshot.memoryStore.notes[1], "Mention prior facts when relevant.")

  session:clearMemory()
  session:importState(snapshot)
  T.assertMatch(session:getMemory(), "The user's name is Alice", "imported memory store should restore renderable memory")
end

do
  harness.reset()

  local captured = {}
  local client = {
    provider = "openai",
    chat = function(_, params)
      captured[#captured + 1] = params
      return makeChatTask({
        text = "done",
        json = { choices = { { message = { role = "assistant", content = "done" } } } }
      })
    end
  }

  local session = agent.Session.new({
    agent = agent.Agent.new({
      client = client,
      withPlan = false
    }),
    memory = "Session note.",
    workspaceMemory = "Workspace note.",
    globalMemory = "Global note."
  })

  local task = async(function()
    local result = async.await(session:ask("use memory", {
      withPlan = false,
      skipMemoryExtraction = true
    }))
    T.assertEq(result.text, "done")
  end)
  local ok, err = harness.runUntil(function()
    return task.result ~= nil or task.error ~= nil
  end, { maxSteps = 1000 })
  T.assertTrue(ok, err)
  T.assertTrue(task.error == nil, tostring(task.error))
  T.assertMatch(captured[1].messages[1].content, "Session note", "session memory should be included in run prompt")
  T.assertMatch(captured[1].messages[1].content, "Workspace memory", "workspace memory should be labeled in combined prompt")
  T.assertMatch(captured[1].messages[1].content, "Workspace note", "workspace memory should be included in run prompt")
  T.assertMatch(captured[1].messages[1].content, "Global note", "global memory should be included in run prompt")

  local snapshot = session:exportState()
  T.assertEq(snapshot.workspaceMemory, "Workspace note.")
  T.assertEq(snapshot.globalMemory, "Global note.")

  session:clearMemory(nil, "workspace")
  session:clearMemory(nil, "global")
  session:importState(snapshot)
  T.assertEq(session:getMemory("workspace"), "Workspace note.")
  T.assertEq(session:getMemory("global"), "Global note.")
end

do
  harness.reset()

  local captured = {}
  local client = {
    provider = "openai",
    chat = function(_, params)
      captured[#captured + 1] = params
      return makeChatTask({
        text = "done",
        json = { choices = { { message = { role = "assistant", content = "done" } } } }
      })
    end
  }

  local a = agent.Agent.new({
    client = client,
    registry = agent.ToolRegistry.new(),
    withPlan = false
  })

  local task = async(function()
    local result = async.await(a:run("latest news", {
      withPlan = false
    }))
    T.assertEq(result.text, "done")
  end)
  local ok, err = harness.runUntil(function()
    return task.result ~= nil or task.error ~= nil
  end, { maxSteps = 1000 })
  T.assertTrue(ok, err)
  T.assertTrue(task.error == nil, tostring(task.error))
  T.assertTrue(captured[1].extra.tools == nil, "empty registry should omit tools field")
  T.assertTrue(captured[1].extra.tool_choice == nil, "empty registry should omit tool_choice")
end

do
  harness.reset()

  local extracted = {
    session = {
      facts = { "The user's name is Alice." },
      preferences = { "The user prefers concise answers." }
    },
    workspace = {
      goals = { "Finish the LOVE chatbox demo." }
    }
  }
  local extractedJson = jsonEncode(extracted)
  decodeFixtures[extractedJson] = extracted

  local responses = {
    { text = "I will remember that.", json = { choices = { { message = { role = "assistant", content = "I will remember that." } } } } },
    { text = extractedJson, json = { choices = { { message = { role = "assistant", content = extractedJson } } } } }
  }
  local client = {
    provider = "openai",
    chat = function()
      return makeChatTask(table.remove(responses, 1))
    end
  }

  local session = agent.Session.new({
    agent = agent.Agent.new({
      client = client,
      withPlan = false
    }),
    memoryExtractor = agent.MemoryExtractor.new({
      client = client,
      scopes = { "session", "workspace" }
    })
  })

  local task = async(function()
    local result = async.await(session:ask("Hello, my name is Alice and I prefer concise answers.", {
      withPlan = false
    }))
    T.assertEq(result.text, "I will remember that.")
  end)
  local ok, err = harness.runUntil(function()
    return task.result ~= nil or task.error ~= nil
  end, { maxSteps = 1000 })
  T.assertTrue(ok, err)
  T.assertTrue(task.error == nil, tostring(task.error))
  T.assertMatch(session:getMemory("session"), "The user's name is Alice", "extractor should store session facts")
  T.assertMatch(session:getMemory("session"), "The user prefers concise answers", "extractor should store session preferences")
  T.assertMatch(session:getMemory("workspace"), "Finish the LOVE chatbox demo", "extractor should store workspace goals")
end
