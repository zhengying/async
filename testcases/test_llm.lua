local async = require("async")
local T = require("testcases.testlib")

local plannedResponses = {}
local capturedRequests = {}

package.loaded["examples.llm"] = nil
package.loaded["async_http"] = nil
package.preload["async_http"] = function()
  return {
    new = function()
      return {
        post = function(_, url, payload, opts)
          local plan = table.remove(plannedResponses, 1)
          capturedRequests[#capturedRequests + 1] = {
            url = url,
            payload = payload,
            opts = opts
          }
          return async(function()
            local status = type(plan) == "table" and plan.status or 200
            local headers = type(plan) == "table" and plan.headers or { ["content-type"] = "text/event-stream" }
            local chunks = type(plan) == "table" and plan.chunks or {}
            if type(opts.onResponse) == "function" then
              opts.onResponse(status, headers)
            end
            for i = 1, #chunks do
              if type(opts.onData) == "function" then
                opts.onData(chunks[i])
              end
              async.sleep(0.01)
            end
            if type(opts.onComplete) == "function" then
              opts.onComplete(type(plan) == "table" and plan.completeErr or nil)
            end
            return {
              status = status,
              headers = headers,
              body = table.concat(chunks)
            }
          end)
        end,
        destroy = function()
        end
      }
    end
  }
end

local llm = require("examples.llm")
local h = T.makeHarness(async)

do
  h.reset()
  plannedResponses = {
    {
      chunks = {
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",",
        "\"model\":\"gpt-test\",\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"Hel\"},\"finish_reason\":null}]}\n\n",
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"model\":\"gpt-test\",\"choices\":[{\"delta\":{\"content\":\"lo\"},\"finish_reason\":\"stop\"}],\"usage\":{\"completion_tokens\":2}}\n\n",
        "data: [DONE]\n\n"
      }
    }
  }
  capturedRequests = {}

  local deltas = {}
  local responseStatus = nil
  local responseContentType = nil
  local result, err, state
  local done = false

  local client = llm.openai({
    apiKey = "test-key",
    model = "gpt-test"
  })

  async(function()
    result, err, state = async.await(client:chat({
      model = "gpt-test",
      messages = {
        { role = "user", content = "hello" }
      },
      stream = true,
      onResponse = function(status, headers)
        responseStatus = status
        responseContentType = headers and headers["content-type"] or nil
      end,
      onText = function(delta)
        deltas[#deltas + 1] = delta
      end
    }))
    done = true
  end)

  local okRun, runErr = h.runUntil(function()
    return done
  end, { dt = 0.01, maxSteps = 1000 })
  T.assertTrue(okRun, runErr or "openai stream task did not finish")
  T.assertEq(err, nil, "openai stream should not error")
  T.assertEq(state, nil, "openai stream should not return an error state")
  T.assertTrue(type(result) == "table", "openai stream should return a result table")
  T.assertEq(result.text, "Hello", "openai stream text mismatch")
  T.assertEq(table.concat(deltas), "Hello", "openai stream deltas mismatch")
  T.assertEq(responseStatus, 200, "openai stream response status mismatch")
  T.assertEq(responseContentType, "text/event-stream", "openai stream content-type mismatch")
  T.assertEq(result.json.choices[1].message.content, "Hello", "openai stream final json content mismatch")
  T.assertEq(result.json.usage.completion_tokens, 2, "openai stream usage mismatch")

  local requestPayload = llm.jsonDecode(capturedRequests[1].payload)
  T.assertTrue(capturedRequests[1].opts.stream == true, "openai request should enable http streaming")
  T.assertEq(requestPayload.stream, true, "openai request body should enable stream")

  client:destroy()
end

do
  h.reset()
  plannedResponses = {
    {
      headers = { ["content-type"] = "application/json" },
      chunks = {
        "{\"id\":\"chatcmpl-3\",\"object\":\"chat.completion\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}"
      }
    }
  }
  capturedRequests = {}

  local result, err, state
  local done = false
  local invalidText = "bad" .. string.char(255)
  local replacement = "bad" .. string.char(239, 191, 189)

  local client = llm.openai({
    apiKey = "test-key",
    model = "gpt-test"
  })

  async(function()
    result, err, state = async.await(client:chat({
      model = "gpt-test",
      messages = {
        { role = "user", content = invalidText }
      }
    }))
    done = true
  end)

  local okRun, runErr = h.runUntil(function()
    return done
  end, { dt = 0.01, maxSteps = 1000 })
  T.assertTrue(okRun, runErr or "invalid utf8 payload test did not finish")
  T.assertEq(err, nil, "invalid utf8 payload should not error")
  T.assertEq(state, nil, "invalid utf8 payload should not return an error state")
  T.assertTrue(type(result) == "table", "invalid utf8 payload should still return a result table")
  T.assertTrue(type(capturedRequests[1]) == "table", "invalid utf8 payload should send a request")
  T.assertTrue(capturedRequests[1].payload:find(string.char(255), 1, true) == nil, "payload should not contain raw invalid utf8 bytes")

  local requestPayload = llm.jsonDecode(capturedRequests[1].payload)
  T.assertEq(requestPayload.messages[1].content, replacement, "invalid utf8 bytes should be replaced before json encoding")

  client:destroy()
end

do
  h.reset()
  plannedResponses = {
    {
      chunks = {
        "data: {\"id\":\"chatcmpl-2\",\"object\":\"chat.completion.chunk\",\"model\":\"gpt-test\",\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\n",
        "data: [DONE]\n\n"
      }
    }
  }
  capturedRequests = {}

  local sinkCalls = 0
  local result, err, state
  local done = false

  local client = llm.openai({
    apiKey = "test-key",
    model = "gpt-test",
    debug = true,
    debugSink = function()
      sinkCalls = sinkCalls + 1
      error("sink failed")
    end
  })

  async(function()
    result, err, state = async.await(client:chat({
      model = "gpt-test",
      messages = {
        { role = "user", content = "hello" }
      },
      stream = true
    }))
    done = true
  end)

  local okRun, runErr = h.runUntil(function()
    return done
  end, { dt = 0.01, maxSteps = 1000 })
  T.assertTrue(okRun, runErr or "debug sink failure test did not finish")
  T.assertTrue(sinkCalls > 0, "debug sink should have been called")
  T.assertEq(err, nil, "debug sink errors should not fail chat")
  T.assertEq(state, nil, "debug sink errors should not produce error state")
  T.assertTrue(type(result) == "table", "debug sink failure should still return a result table")
  T.assertEq(result.text, "ok", "debug sink failure should preserve response text")

  client:destroy()
end

do
  h.reset()
  plannedResponses = {
    {
      chunks = {
        "event: message_start\n",
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-test\",\"content\":[]}}\n\n",
        "event: content_block_start\n",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
        "event: content_block_delta\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\n",
        "event: content_block_delta\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" there\"}}\n\n",
        "event: message_delta\n",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n",
        "event: message_stop\n",
        "data: {\"type\":\"message_stop\"}\n\n"
      }
    }
  }
  capturedRequests = {}

  local aggregated = {}
  local result, err, state
  local done = false

  local client = llm.anthropic({
    apiKey = "test-key",
    model = "claude-test",
    maxTokens = 128
  })

  async(function()
    result, err, state = async.await(client:chat({
      model = "claude-test",
      max_tokens = 128,
      messages = {
        { role = "user", content = "hello" }
      },
      stream = true,
      onText = function(_, text)
        aggregated[#aggregated + 1] = text
      end
    }))
    done = true
  end)

  local okRun, runErr = h.runUntil(function()
    return done
  end, { dt = 0.01, maxSteps = 1000 })
  T.assertTrue(okRun, runErr or "anthropic stream task did not finish")
  T.assertEq(err, nil, "anthropic stream should not error")
  T.assertEq(state, nil, "anthropic stream should not return an error state")
  T.assertTrue(type(result) == "table", "anthropic stream should return a result table")
  T.assertEq(result.text, "Hi there", "anthropic stream text mismatch")
  T.assertEq(aggregated[#aggregated], "Hi there", "anthropic stream aggregated text mismatch")
  T.assertEq(result.json.content[1].text, "Hi there", "anthropic stream final json content mismatch")
  T.assertEq(result.json.stop_reason, "end_turn", "anthropic stream stop reason mismatch")
  T.assertEq(result.json.usage.output_tokens, 2, "anthropic stream usage mismatch")

  local requestPayload = llm.jsonDecode(capturedRequests[1].payload)
  T.assertTrue(capturedRequests[1].opts.stream == true, "anthropic request should enable http streaming")
  T.assertEq(requestPayload.stream, true, "anthropic request body should enable stream")

  client:destroy()
end
