# Synaptic Technical Overview

This document describes how the Synaptic workflow engine is structured inside the
OTP application and where to look when extending it.

## Entry point and supervision tree

- `Synaptic` (`lib/synaptic.ex`) is the public API. It exposes `start/3`,
  `resume/2`, `inspect/1`, `history/1`, and `workflow_definition/1` which all
  delegate to `Synaptic.Engine`.
- `Synaptic.Application` is the OTP application callback. Its child list starts
  the workflow runtime before any Phoenix components:
  - `Synaptic.Registry` – a `Registry` process keyed by run id so `Synaptic.Runner`
    processes can be addressed via `{:via, Registry, {Synaptic.Registry, run_id}}`.
  - `Synaptic.RuntimeSupervisor` – a `DynamicSupervisor` that owns every
    `Synaptic.Runner` process. Each workflow run is supervised independently, so a
    crash only restarts that single run.
  - Phoenix telemetry/pubsub/Finch/endpoint services follow afterwards.

## Workflow compilation DSL

- `Synaptic.Workflow` is a macro module imported by workflow definitions. It:
  - Registers the accumulating `@synaptic_steps` attribute, builds `Step` structs
    via `step/3`, and injects per-step handlers named `__synaptic_handle__/2`.
  - Provides `commit/0` for marking the workflow complete and
    `suspend_for_human/2` for pausing.
  - Emits `__synaptic_definition__/0`, which returns `%{module: workflow_module,
steps: [%Synaptic.Step{}, ...]}` consumed by the engine.
- `Synaptic.Step` defines the struct + helper for calling back into the generated
  handlers.

## Runtime execution

- `Synaptic.Engine` is responsible for orchestrating `Synaptic.Runner`s:
  - When `Synaptic.start/3` is called it fetches the workflow definition,
    generates a run id, and asks `Synaptic.RuntimeSupervisor` to start a new
    runner with that definition + initial context.
  - The `:start_at_step` option allows starting execution at a specific step by
    name. The engine validates the step exists, finds its index in the steps
    list, and passes `start_at_step_index` to the runner. Invalid step names
    return `{:error, :invalid_step}`.
  - `resume/2`, `inspect/1`, and `history/1` are convenience wrappers around the
    runner GenServer calls. `stop/2` sends a shutdown request so the runner can
    mark itself as `:stopped`, broadcast an event, and terminate cleanly.
- `Synaptic.Runner` is a GenServer that owns the mutable workflow state:
  - Holds the definition, context, current step index, status, waiting payload,
    retry budgets, and history timeline.
  - On init it accepts an optional `:start_at_step_index` option. If provided,
    the runner initializes `current_step_index` to that value instead of 0,
    allowing execution to begin at a specific step. The provided context should
    contain all data that would have been accumulated up to that step.
  - On init it immediately `{:continue, :process_next_step}` so runs execute as
    soon as the child boots.
  - Each step execution happens inside `Task.async/await` so crashes are caught
    and retried via the configured `:retry` budget.
  - Suspension is represented by setting `status: :waiting_for_human` and
    storing `%{step: ..., resume_schema: ...}` in `waiting`. `resume/2` injects a
    `%{human_input: payload}` into context and continues the step loop.
  - Every state transition publishes an event on `Synaptic.PubSub` (topic
    `"synaptic:run:" <> run_id`) so UIs can observe `:waiting_for_human`,
    `:resumed`, `:step_completed`, `:retrying`, `:failed`, etc. Each event
    contains the `:run_id` and `:current_step`. Consumers call
    `Synaptic.subscribe/1` / `Synaptic.unsubscribe/1` to manage those listeners.

## Putting it all together (beginner-friendly flow)

1. **You write a workflow module** using `use Synaptic.Workflow`. At compile
   time that macro records each `step/3`, creates a `Synaptic.Step` struct for it,
   and generates hidden functions (`__synaptic_handle__/2` and
   `__synaptic_definition__/0`). Nothing is executed yet—you just defined the
   blueprint.
2. **The app boots.** When you run `iex -S mix`,
   `Synaptic.Application` spins up the supervision tree (Registry +
   RuntimeSupervisor). They sit idle waiting for workflow runs.
3. **You start a run** (e.g., `Synaptic.start(MyWorkflow, %{foo: :bar})`). The
   public API calls into `Synaptic.Engine`, which pulls the blueprint from
   `MyWorkflow.__synaptic_definition__/0`, generates a run id, and asks
   `Synaptic.RuntimeSupervisor` to start a `Synaptic.Runner` child with that
   definition + context. Optionally, you can pass `start_at_step: :step_name` to
   begin execution at a specific step; the engine validates the step exists and
   finds its index before starting the runner.
4. **The runner executes steps.** Once the child process starts, it immediately
   begins calling your step handlers in order. Returned maps merge into the
   context, `{:suspend, ...}` pauses the run, and errors trigger retries per the
   step metadata.
5. **You interact with the run** using `Synaptic.inspect/1` and `Synaptic.history/1`
   (read-only) or `Synaptic.resume/2` (writes `human_input` and restarts the loop).

No extra wiring is needed for new workflows—the moment your module is compiled
and available, the runtime can execute it via `Synaptic.start/3`.

## Message routing + persistence boundaries

- There is no durable persistence yet. Context/history lives inside each
  `Synaptic.Runner` process. Restarting the app clears all runs; this is by design
  for Phase 1.
- Client code can read state via `Synaptic.inspect/1` and `Synaptic.history/1` to
  build APIs or UIs.

## Tooling and LLM adapters

- `Synaptic.Tools` is a thin facade with configurable adapters + agents:
  - Global defaults are configured in `config/config.exs` under `Synaptic.Tools`.
  - Named agents can override model/temperature/adapter per workflow via the
    `agent: :name` option.
  - `Synaptic.Tools.chat/2` merges options, picks the adapter, and delegates to
    `adapter.chat/2`. Pass `tools: [...]` with `%Synaptic.Tools.Tool{}` structs to
    enable OpenAI-style tool calling; the helper will execute the tool handlers
    whenever the model emits `tool_calls` and continue the conversation until a
    final assistant response is produced.
- `Synaptic.Tools.OpenAI` is the default adapter. It builds a Finch request with a
  JSON body, sends it via `Synaptic.Finch`, and returns either `{:ok, content}` or
  `{:ok, content, %{usage: %{...}}}` (with usage metrics). Lack of an API key raises
  so misconfiguration fails fast. When `stream: true` is passed, it uses
  `Finch.stream/4` to handle Server-Sent Events (SSE) from OpenAI, parsing chunks
  and accumulating content. Streaming automatically falls back to non-streaming when
  tools are provided.
- **Usage metrics**: Adapters can optionally return usage information (token counts,
  cost, etc.) in a third tuple element: `{:ok, content, %{usage: %{...}}}`. The
  OpenAI adapter automatically extracts `prompt_tokens`, `completion_tokens`, and
  `total_tokens` from API responses. This information is included in Telemetry events
  and can be used by eval integrations.
- **Telemetry**: All LLM calls are instrumented with Telemetry spans under
  `[:synaptic, :llm]`, emitting `:start`, `:stop`, and `:exception` events with
  metadata including `run_id`, `step_name`, `adapter`, `model`, `stream`, and
  optional `usage` metrics.

## Streaming implementation

- **SSE parsing**: OpenAI streaming responses use Server-Sent Events format. Each
  event is a line starting with `data: ` followed by JSON (or `[DONE]` to signal
  completion). The adapter splits on `\n\n`, extracts JSON, and parses
  `choices[0].delta.content` from each chunk.
- **Content accumulation**: Chunks are accumulated incrementally. The `on_chunk`
  callback receives both the new chunk and the accumulated content so far.
- **PubSub integration**: `Synaptic.Tools` publishes `:stream_chunk` events for each
  chunk and `:stream_done` when streaming completes. The Runner injects `run_id`
  and `step_name` into the process dictionary so Tools can access them for event
  publishing.
- **Limitations**: Streaming doesn't support tool calling (auto fallback) or
  `response_format` options. The step function still receives the complete
  accumulated content when streaming finishes.

## Dev-only demo workflow

- `Synaptic.Dev.DemoWorkflow` (`lib/synaptic/dev/demo_workflow.ex`) is wrapped in
  `if Mix.env() == :dev` so it only compiles in development. It demonstrates the
  full lifecycle:
  - Collects or defaults a `:request` payload.
  - Calls `Synaptic.Tools.chat/2` to draft a plan, falling back to a canned string
    if the adapter errors (e.g., missing `OPENAI_API_KEY`).
  - Suspends for a human approval with the generated plan in metadata.

Use it from `iex -S mix` with:

```elixir
{:ok, run_id} = Synaptic.start(Synaptic.Dev.DemoWorkflow, %{request: "Plan a kickoff"})
Synaptic.inspect(run_id)
Synaptic.resume(run_id, %{approved: true})
```

That sample mirrors how real workflows behave and is a good starting point for
experimentation.

## Eval integrations

- `Synaptic.Eval.Integration` is a behaviour for integrating with 3rd party eval
  services (Braintrust, LangSmith, etc.). Implementations observe LLM calls and
  scorer results via Telemetry events and can combine them into complete eval records.
- The integration behaviour provides optional callbacks:
  - `on_llm_call/4` - called when an LLM call completes (via `[:synaptic, :llm, :stop]`)
  - `on_scorer_result/4` - called when a scorer completes (via `[:synaptic, :scorer, :stop]`)
  - `on_step_complete/4` - called when a step completes (via `[:synaptic, :step, :stop]`)
- Use `Synaptic.Eval.Integration.attach/2` to set up Telemetry handlers that call
  your integration's callbacks. This allows users to implement their own eval
  integrations without modifying Synaptic core.
- LLM call metadata includes usage metrics (token counts) when available from
  adapters, allowing eval services to track costs and usage alongside quality scores.
