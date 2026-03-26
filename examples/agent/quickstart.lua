package.path = "./?.lua;./?/init.lua;./examples/?.lua;./examples/?/init.lua;" .. package.path

local async = require("async")
local agent = require("examples.agent")
local llm = require("llm")

local now = 0
async.gettime = function()
  return now
end

local function stepUntilIdle()
  local guard = 0
  while async.getTaskCount() > 0 do
    guard = guard + 1
    if guard > 1000 then
      error("async loop guard reached")
    end
    now = now + 0.016
    async.update(0.016)
  end
end

local function firstUserMessage(messages)
  if type(messages) ~= "table" then
    return ""
  end
  for i = #messages, 1, -1 do
    local msg = messages[i]
    if type(msg) == "table" and msg.role == "user" and type(msg.content) == "string" then
      return msg.content
    end
  end
  return ""
end

local function findRememberedName(messages)
  if type(messages) ~= "table" then
    return nil
  end
  for i = #messages, 1, -1 do
    local msg = messages[i]
    if type(msg) == "table" and msg.role == "user" and type(msg.content) == "string" then
      local name = msg.content:match("[Mm]y name is%s+([A-Za-z]+)")
      if name then
        return name
      end
    end
  end
  return nil
end

local function lastToolResult(messages)
  if type(messages) ~= "table" then
    return nil
  end
  for i = #messages, 1, -1 do
    local msg = messages[i]
    if type(msg) == "table" and msg.role == "tool" and type(msg.content) == "string" then
      local ok, decoded = pcall(llm.jsonDecode, msg.content)
      if ok and type(decoded) == "table" then
        return decoded
      end
    end
  end
  return nil
end

local function makePlanResponse(goal)
  local plan
  if goal:lower():find("add", 1, true) then
    plan = {
      "Read the user's request",
      "Use add to compute the result",
      "Return a concise answer"
    }
  elseif goal:lower():find("name", 1, true) then
    plan = {
      "Inspect recent conversation history",
      "Find the remembered user name",
      "Reply with the stored fact"
    }
  else
    plan = {
      "Read the request",
      "Answer directly"
    }
  end
  local text = llm.jsonEncode(plan)
  return {
    text = text,
    json = {
      choices = {
        {
          message = {
            role = "assistant",
            content = text
          }
        }
      }
    }
  }
end

local function makeFinalResponse(text)
  return {
    text = text,
    json = {
      choices = {
        {
          message = {
            role = "assistant",
            content = text
          }
        }
      }
    }
  }
end

local fakeClient = {
  provider = "openai",
  chat = function(_, params)
    return async(function()
      local messages = params.messages or {}
      local systemText = type(messages[1]) == "table" and tostring(messages[1].content or "") or ""
      local goal = firstUserMessage(messages)
      if systemText:find("Create a short execution plan", 1, true) then
        return makePlanResponse(goal)
      end

      local toolResult = lastToolResult(messages)
      if toolResult and toolResult.result ~= nil then
        return makeFinalResponse("The result is " .. tostring(toolResult.result) .. ".")
      end

      if goal:lower():find("add", 1, true) then
        local a, b = goal:match("(%-?%d+)%D+(%-?%d+)")
        return {
          text = "",
          json = {
            choices = {
              {
                message = {
                  role = "assistant",
                  content = "",
                  tool_calls = {
                    {
                      id = "call_add_1",
                      type = "function",
                      ["function"] = {
                        name = "add",
                        arguments = llm.jsonEncode({
                          a = tonumber(a),
                          b = tonumber(b)
                        })
                      }
                    }
                  }
                }
              }
            }
          }
        }
      end

      local name = findRememberedName(messages)
      if goal:lower():find("what is my name", 1, true) and name then
        return makeFinalResponse("Your name is " .. tostring(name) .. ".")
      end

      if goal:lower():find("what do you know about me", 1, true) then
        return makeFinalResponse("I know your name from the conversation and I should answer concisely.")
      end

      return makeFinalResponse("I heard: " .. tostring(goal))
    end)
  end
}

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
    local a = tonumber(type(input) == "table" and input.a or nil)
    local b = tonumber(type(input) == "table" and input.b or nil)
    if not a or not b then
      return nil, "invalid numbers"
    end
    return { result = a + b }
  end
})

local profile = agent.SceneProfile.new({
  name = "quickstart",
  instructions = {
    "Answer clearly and briefly."
  },
  constraints = {
    "Use only the tools available in this quickstart demo."
  },
  planGuidelines = {
    "Prefer short plans."
  },
  toolTags = { "math" }
})

local session = agent.Session.new({
  agent = agent.Agent.new({
    client = fakeClient,
    registry = registry,
    system = "You are a helpful demo agent.",
    withPlan = true
  }),
  profile = profile,
  memoryStore = agent.MemoryStore.new({
    preferences = {
      "The user prefers concise answers."
    }
  })
})

local function runTurn(label, input)
  print("")
  print("== " .. tostring(label) .. " ==")
  print("user:", input)
  local task = session:ask(input)
  stepUntilIdle()
  if task.error then
    error(tostring(task.error))
  end
  local result = task.result and task.result[1] or nil
  print("assistant:", result and result.text or "<nil>")
  print("history size:", #session:getHistory())
end

print("Agent quickstart demo")
print("This script shows ToolRegistry, Agent, Session, SceneProfile, MemoryStore, and session persistence.")

runTurn("Turn 1", "My name is Alice.")
runTurn("Turn 2", "What is my name?")
runTurn("Turn 3", "Add 7 and 5.")

local snapshot = session:exportJson()
print("")
print("saved snapshot bytes:", #snapshot)

session:clear()
print("history after clear:", #session:getHistory())

session:importState(snapshot)
print("history after restore:", #session:getHistory())

runTurn("Turn 4", "What do you know about me?")
