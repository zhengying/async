# Agent System Design

## 1. Purpose

This document describes the design of the agent system implemented in:

- `examples/agent/init.lua`
- `examples/love/agent/main.lua`
- `testcases/test_agent.lua`

The goal is to make the agent easy to extend, safe to evolve, and maintainable by both humans and AI assistants.

The current design solves four problems at the same time:

1. tool-based execution,
2. multi-turn conversation,
3. scene-specific constraints and tool exposure,
4. memory and session persistence.

The design intentionally separates these concerns into distinct layers instead of mixing them into one large prompt builder.

## 2. Design goals

The system is designed around the following goals:

- Keep the execution engine small and provider-agnostic.
- Make scene adaptation cheap by composing configuration instead of rewriting logic.
- Preserve recent conversation exactly while compressing older context.
- Avoid prompt explosion by exposing only relevant tools and constraints per turn.
- Support session persistence without serializing runtime functions.
- Keep durable memory separate from recent conversational context.
- Support optional memory scopes instead of forcing one global memory bucket.
- Keep memory extraction policy separate from the main answer path.
- Make future features additive rather than invasive.

## 3. Layered architecture

The system has five main layers.

### 3.1 ToolRegistry

`ToolRegistry` owns registered tools and provider-specific tool schema conversion.

Responsibilities:

- validate tool definitions,
- store handlers,
- filter tools by:
  - exact names,
  - tags,
  - custom predicate,
- produce OpenAI-compatible or Anthropic-compatible tool payloads.

This layer answers the question:

> Which tools exist, and which subset should this request see?

### 3.2 Agent

`Agent` is the execution engine.

Responsibilities:

- plan generation,
- prompt assembly for one request,
- iterative tool calling loop,
- provider normalization for OpenAI / Anthropic,
- message trimming and tool exchange trimming,
- execution result return.

This layer answers the question:

> Given a goal, constraints, memory, history, and tools, how do we execute it?

`Agent` should remain stateless with respect to conversation ownership. It may receive history and memory, but it does not own long-lived session state.

### 3.3 SceneProfile

`SceneProfile` is a reusable scene policy object.

Responsibilities:

- define scene-level instructions,
- define scene-level constraints,
- define plan guidelines,
- define scene memory,
- define allowed tools or tool routing hints,
- optionally split defaults between plan and run phases.

This layer answers the question:

> In this scene, what should the model be allowed or encouraged to do?

### 3.4 ProfileRouter

`ProfileRouter` is a dynamic scene selector.

Responsibilities:

- examine the current turn goal,
- optionally inspect session state,
- choose the most relevant profile for this turn,
- let the chosen profile constrain plan and run behavior.

This layer answers the question:

> For this specific turn, which scene policy should be active?

### 3.5 Session

`Session` owns long-lived conversational state.

Responsibilities:

- store history,
- store scoped memory,
- own structured memory,
- optionally run memory extraction after successful turns,
- coordinate with profile and router,
- expose `ask`, `plan`, export, and import,
- append successful turns back into history.

This layer answers the question:

> Across many turns, what state should persist, and how is it applied?

## 4. Mental model

The intended mental model is:

- `ToolRegistry` = capability store
- `Agent` = executor
- `SceneProfile` = static scene policy
- `ProfileRouter` = dynamic scene policy chooser
- `Session` = conversation container
- `MemoryStore` = durable structured memory
- `MemoryExtractor` = post-turn durable memory writer

The system is intentionally compositional:

- one registry can serve many agents,
- one agent can be used by many sessions,
- one session can use one base profile plus one router,
- the router can activate different profiles on different turns.

## 5. Execution flow

### 5.1 Single-turn flow

For a normal `session:ask(goal, opts)` call, the effective flow is:

1. Resolve base profile for the run phase.
2. Resolve routed profile for the run phase, if any.
3. Merge enabled memory scopes into one prompt-facing memory view.
4. Decide whether planning is needed.
5. If planning is enabled:
   - resolve plan profile and router profile,
   - build planning memory,
   - call `agent:plan(...)`.
6. Call `agent:run(...)`.
7. If execution succeeds:
   - append user turn to history,
   - append assistant turn to history,
   - optionally run post-turn memory extraction,
   - merge extracted memory into enabled scopes.

### 5.2 Planning flow

Planning is intentionally separate from run execution.

Planning prompt includes:

- the agent profile,
- planning rules,
- selected tools,
- optionally recent conversation summary,
- optionally scoped memory.

Planning does not own session history. It consumes a reduced planning view prepared by `Session`.

### 5.3 Run flow

Run prompt includes:

- system text assembled from:
  - base system,
  - instructions,
  - constraints,
  - scoped memory,
  - conversation summary,
  - plan,
- recent history as raw messages,
- current user goal.

The execution loop then:

- sends messages to the provider,
- inspects whether tool calls were requested,
- runs tool handlers,
- appends tool results,
- continues until final text is returned or max steps is reached.

### 5.4 Extraction flow

When `Session` has a `MemoryExtractor`, extraction runs after a successful answer.

The extractor receives:

- the current user goal,
- the assistant answer,
- a bounded recent-history window,
- the current combined memory view,
- the allowed scopes for extraction.

The extractor returns a JSON object keyed by scope:

- `session`
- `workspace`
- `global`

Each scope may contain a standard `MemoryStore`-shaped object:

- `summary`
- `facts`
- `preferences`
- `goals`
- `notes`

The returned data is then merged into the corresponding in-memory stores.

## 6. Context strategy

This is one of the most important design choices.

### 6.1 Recent context must remain raw

Recent conversation is preserved as raw messages.

Reason:

- it has the highest precision,
- it preserves phrasing and exact constraints,
- it is the best source for short-range reasoning.

The system should not replace recent context with memory extraction.

### 6.2 Older context may be compressed

When history grows, older messages are compacted into a summary.

This summary is intentionally lossy and is used only to preserve broad continuity.

### 6.3 Durable memory is separate

Durable memory is not a replacement for recent context.

Durable memory is for:

- explicit user facts,
- long-term preferences,
- stable goals,
- sticky notes.

Durable memory is represented by `MemoryStore`.

### 6.4 Memory is now scoped

The system supports three logical durable-memory scopes:

- `session`: useful only for the current conversation,
- `workspace`: useful for the current project or environment,
- `global`: useful across conversations.

Recommended default policy:

- enable `session` by default,
- enable `workspace` only when the application has a clear project boundary,
- keep `global` opt-in.

### 6.5 Why extraction happens after the answer

The implemented design prefers post-turn extraction over pre-send extraction.

Reasons:

- the assistant answer provides extra evidence about what mattered in the turn,
- the system avoids persisting speculative intent before the task is complete,
- routing and tool selection should stay fast and focused on the current goal,
- durable memory writes are safer when based on a completed interaction.

Pre-send analysis is still useful for:

- router selection,
- tool exposure,
- safety gating,
- fast intent classification.

It is not the preferred place to write durable memory.

### 6.6 Why not extract memory every turn

The system should not assume that every turn needs automatic extraction.

Reasons:

- it increases latency,
- it increases token cost,
- it introduces lossy abstraction on every turn,
- extraction errors become persistent errors,
- recent history already covers most short-term needs.

Recommended policy:

- keep recent history raw,
- use durable memory for stable facts,
- prefer post-turn extraction,
- allow extraction to be disabled per session or per request,
- keep `global` memory opt-in.

## 7. Prompt composition strategy

Prompt composition is intentionally structured.

The system prompt is assembled from multiple logical sections:

- base system,
- instructions,
- constraints,
- working memory,
- conversation summary,
- plan.

This is better than storing a monolithic prompt because:

- each concern stays isolated,
- scene-level overrides are composable,
- future features can be inserted without rewriting large strings.

## 8. Tool exposure strategy

The system avoids prompt explosion by never assuming all tools should be visible all the time.

Available filtering mechanisms:

- `toolNames`
- `toolTags`
- `toolFilter`
- `toolSelector`
- `SceneProfile`
- `ProfileRouter`

The intended order of sophistication is:

1. simple scenes: static `toolTags`,
2. medium scenes: `SceneProfile`,
3. dynamic scenes: `ProfileRouter`,
4. advanced scenes: custom `toolSelector`.

Key rule:

> Prefer narrowing tools before adding more prompt instructions.

If a tool should not be used in a scene, hide it instead of explaining in prose why it should not be used.

## 9. Provider model

The agent supports two providers:

- OpenAI-style chat completions
- Anthropic messages API

The agent normalizes around a common flow:

- build messages,
- attach tools,
- call the provider,
- inspect provider-specific tool request structures,
- run tools,
- continue the loop.

Provider differences are intentionally isolated inside `Agent`.

The rest of the architecture should remain provider-neutral.

## 10. Memory model

### 10.1 String memory

Simple memory remains supported as a plain string.

Use this for:

- bootstrapping,
- demos,
- simple stable reminders,
- compatibility with earlier code.

### 10.2 Structured memory

`MemoryStore` supports:

- `summary`
- `facts`
- `preferences`
- `goals`
- `notes`

Recommended meaning of each section:

- `summary`: compact overview of stable context
- `facts`: explicit durable facts
- `preferences`: user style or behavior preferences
- `goals`: long-running objectives
- `notes`: low-confidence or operational reminders

### 10.3 Scoped memory

`Session` now supports three durable-memory scopes in parallel:

- session memory
- workspace memory
- global memory

Each scope can contain:

- plain string memory
- structured `MemoryStore`

Prompt composition can include or exclude each scope independently.

Typical policy:

- session memory for temporary user/task facts,
- workspace memory for repository or environment context,
- global memory for explicit long-term preferences only.

### 10.4 Section semantics

Use these rules when writing memory:

- Put explicit user statements into `facts`.
- Put stable presentation style into `preferences`.
- Put active task intent into `goals`.
- Put tentative or operational reminders into `notes`.
- Keep `summary` short and high-value.

### 10.5 Memory mutation API

Current session-side helpers:

- `session:setMemory(value, scope?)`
- `session:getMemory(scope?, opts?)`
- `session:setMemoryStore(value, scope?)`
- `session:getMemoryStore(scope?)`
- `session:remember(section, value, scope?)`
- `session:forget(section, value, scope?)`
- `session:clearMemory(section?, scope?)`
- `session:setMemoryExtractor(...)`
- `session:getMemoryExtractor()`
- `session:runMemoryExtraction(goal, answer, opts?)`

These methods are intentionally explicit. They let applications choose between:

- no durable extraction,
- session-only extraction,
- session + workspace extraction,
- fully scoped extraction including global memory.

### 10.6 Memory extraction model

`MemoryExtractor` is a dedicated post-turn component.

Responsibilities:

- run a separate extraction prompt,
- request strict JSON output,
- limit extraction to allowed scopes,
- return `MemoryStore`-compatible data,
- stay separate from routing and tool execution.

This keeps the write path for durable memory:

- explicit,
- inspectable,
- replaceable,
- optional.

## 11. Session persistence

`Session` supports export and import.

Persisted state includes:

- version,
- history,
- session string memory,
- session structured memory,
- workspace string memory,
- workspace structured memory,
- global string memory,
- global structured memory,
- metadata.

Persisted state intentionally does not include:

- tool handlers,
- profile functions,
- router functions,
- the agent instance,
- provider clients.

Reason:

- runtime closures are not safely serializable,
- code and state should stay separate.

The correct recovery model is:

1. reconstruct runtime objects in code,
2. import the saved session state into the new session.

## 12. Scene configuration strategy

The recommended setup for real usage is:

- one registry with well-tagged tools,
- one base profile for general rules,
- one router for dynamic scene selection,
- one session per user/conversation,
- one scoped memory policy per application,
- optional memory extractor for post-turn writes.

Example:

- base profile defines safety and answer style,
- router selects:
  - web profile,
  - math profile,
  - time profile,
- session holds history and scoped memory,
- memory stores keep facts and preferences at the correct scope,
- extractor writes durable memory after successful turns.

## 13. Extension guidelines

### 13.1 Adding a new tool

When adding a tool:

1. give it a clear name,
2. write a precise description,
3. keep schema strict,
4. assign tags,
5. keep output compact,
6. avoid returning irrelevant noise.

Prefer narrow tools over one overly generic tool.

### 13.2 Adding a new scene

Prefer:

- new `SceneProfile`,
- optional new route in `ProfileRouter`.

Do not hardcode scene logic inside `Agent`.

### 13.3 Adding a new provider

Provider-specific logic belongs inside `Agent` provider normalization and tool parsing paths.

Do not leak provider-specific requirements into `Session`, `SceneProfile`, or `MemoryStore`.

### 13.4 Adding or changing memory extraction

Prefer a dedicated `MemoryExtractor` instead of mixing extraction into `Agent:run(...)`.

Recommended rules:

- keep extraction post-turn,
- keep extraction optional,
- keep `global` extraction opt-in,
- make scope selection explicit,
- write into `MemoryStore`-compatible structures,
- never replace recent history with extracted memory.

If you need a more advanced policy later, evolve:

- extraction trigger policy,
- scope policy,
- merge policy,
- validation policy.

## 14. Maintenance rules

When modifying the agent system, preserve these invariants:

- `Agent` stays stateless with respect to long-lived conversation ownership.
- `Session` remains the owner of persistent conversation state.
- recent history remains more authoritative than summaries and memory.
- durable memory remains additive, not substitutive.
- global memory remains optional, not mandatory.
- tool visibility is controlled structurally, not mainly by prose instructions.
- persisted session state remains runtime-independent.

If a change violates one of these, it should be treated as an architectural change, not a small patch.

## 15. Common pitfalls

### Pitfall 1: putting everything into `system`

Problem:

- prompt becomes long and hard to maintain,
- scene logic becomes tangled.

Correct approach:

- move stable scene rules into `SceneProfile`,
- move session data into `Session`,
- move durable state into `MemoryStore`.

### Pitfall 2: exposing all tools all the time

Problem:

- prompt explosion,
- bad tool selection,
- more hallucinated tool use.

Correct approach:

- use tags, profiles, and routing.

### Pitfall 3: using memory as a replacement for raw history

Problem:

- short-range precision drops,
- conversation grounding weakens.

Correct approach:

- keep recent history raw,
- use memory for stable durable information only.

### Pitfall 4: serializing runtime code

Problem:

- hard-to-debug restore behavior,
- unsafe persistence model.

Correct approach:

- serialize state only,
- reconstruct runtime objects in code.

### Pitfall 5: treating all durable memory as global

Problem:

- temporary task state leaks across unrelated work,
- prompt relevance drops,
- privacy and surprise costs increase.

Correct approach:

- prefer session scope first,
- use workspace scope for project context,
- reserve global scope for explicit long-term preferences or facts.

## 16. Current demo coverage

The repository currently contains:

- a plain Lua quickstart demo:
  - `examples/agent/quickstart.lua`
  - deterministic fake client,
  - one tool,
  - one scene profile,
  - one session,
  - structured memory,
  - save / restore example
- a LÖVE agent demo with:
  - guided demo scenarios,
  - tool use,
  - multi-turn conversation,
  - profile routing,
  - session save/restore,
  - structured memory,
  - live inspection of route, memory, and session state
- tests covering:
  - tool filtering,
  - history compaction,
  - session state,
  - scene profiles,
  - profile routing,
  - structured memory,
  - persistence

### 16.1 Demo walkthrough

Start with the quickstart demo if you want the smallest working example:

- `luajit examples/agent/quickstart.lua`

This quickstart is intentionally deterministic and does not require API keys.

It demonstrates:

- `ToolRegistry`,
- `Agent`,
- `SceneProfile`,
- `Session`,
- `MemoryStore`,
- session persistence.

Use the LÖVE demo when you want the full interactive lab.

The main interactive demo is:

- `examples/love/agent/main.lua`

This demo is intended to be both:

- a developer onboarding tool,
- and a manual test harness.

The demo exposes a set of numbered scenarios:

1. multi-turn session memory,
2. structured memory store,
3. router + math tool,
4. router + web tool,
5. router + time tool,
6. session persistence.

The demo UI also exposes:

- current provider,
- current routed scene,
- current input,
- walkthrough instructions,
- session statistics,
- memory preview,
- plan output,
- last answer,
- recent conversation.

Important controls:

- `1..6`: load a specific demo scenario,
- `Enter`: send the current request,
- `Tab`: switch provider,
- `F2`: clear current chat history,
- `F3`: save a session snapshot,
- `F4`: restore the saved session snapshot,
- `F5`: cycle to the next demo scenario.

Recommended onboarding order:

1. run the multi-turn scenario,
2. inspect the conversation panel,
3. run the math scenario and observe routing,
4. run the web scenario and inspect tool-bound execution,
5. run the structured memory scenario,
6. test persistence with save / clear / restore.

This sequence demonstrates almost every important architectural layer without requiring code edits.

## 17. Recommended next steps

The current architecture is strong enough for extension.

The next high-value features should be:

1. triggered memory extraction policy,
2. memory item provenance and confidence,
3. token-budget-aware history compaction,
4. optional retrieval over external memory storage,
5. richer route matching and diagnostics.

These should be added without collapsing the current layer boundaries.

## 18. Summary

The core design principle of this agent system is:

> Separate execution, session state, scene policy, routing, and durable memory.

That separation is what keeps the system maintainable.

If future changes keep those boundaries intact, the agent can evolve significantly without becoming fragile.
