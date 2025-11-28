# Synapse Technical Overview

This document describes how the Synapse workflow engine is structured inside the
Phoenix app and where to look when extending it.

## Entry point and supervision tree

- `Synapse` (`lib/synapse.ex`) is the public API. It exposes `start/3`,
  `resume/2`, `inspect/1`, `history/1`, and `workflow_definition/1` which all
  delegate to `Synapse.Engine`.
- `Synapse.Application` is the OTP application callback. Its child list starts
  the workflow runtime before any Phoenix components:
  - `Synapse.Registry` – a `Registry` process keyed by run id so `Synapse.Runner`
    processes can be addressed via `{:via, Registry, {Synapse.Registry, run_id}}`.
  - `Synapse.RuntimeSupervisor` – a `DynamicSupervisor` that owns every
    `Synapse.Runner` process. Each workflow run is supervised independently, so a
    crash only restarts that single run.
  - Phoenix telemetry/pubsub/Finch/endpoint services follow afterwards.

## Workflow compilation DSL

- `Synapse.Workflow` is a macro module imported by workflow definitions. It:
  - Registers the accumulating `@synapse_steps` attribute, builds `Step` structs
    via `step/3`, and injects per-step handlers named `__synapse_handle__/2`.
  - Provides `commit/0` for marking the workflow complete and
    `suspend_for_human/2` for pausing.
  - Emits `__synapse_definition__/0`, which returns `%{module: workflow_module,
    steps: [%Synapse.Step{}, ...]}` consumed by the engine.
- `Synapse.Step` defines the struct + helper for calling back into the generated
  handlers.

## Runtime execution

- `Synapse.Engine` is responsible for orchestrating `Synapse.Runner`s:
  - When `Synapse.start/3` is called it fetches the workflow definition,
    generates a run id, and asks `Synapse.RuntimeSupervisor` to start a new
    runner with that definition + initial context.
  - `resume/2`, `inspect/1`, and `history/1` are convenience wrappers around the
    runner GenServer calls. `stop/2` sends a shutdown request so the runner can
    mark itself as `:stopped`, broadcast an event, and terminate cleanly.
- `Synapse.Runner` is a GenServer that owns the mutable workflow state:
  - Holds the definition, context, current step index, status, waiting payload,
    retry budgets, and history timeline.
  - On init it immediately `{:continue, :process_next_step}` so runs execute as
    soon as the child boots.
  - Each step execution happens inside `Task.async/await` so crashes are caught
    and retried via the configured `:retry` budget.
  - Suspension is represented by setting `status: :waiting_for_human` and
    storing `%{step: ..., resume_schema: ...}` in `waiting`. `resume/2` injects a
    `%{human_input: payload}` into context and continues the step loop.
  - Every state transition publishes an event on `Synapse.PubSub` (topic
    `"synapse:run:" <> run_id`) so UIs can observe `:waiting_for_human`,
    `:resumed`, `:step_completed`, `:retrying`, `:failed`, etc. Each event
    contains the `:run_id` and `:current_step`. Consumers call
    `Synapse.subscribe/1` / `Synapse.unsubscribe/1` to manage those listeners.

## Putting it all together (beginner-friendly flow)

1. **You write a workflow module** using `use Synapse.Workflow`. At compile
   time that macro records each `step/3`, creates a `Synapse.Step` struct for it,
   and generates hidden functions (`__synapse_handle__/2` and
   `__synapse_definition__/0`). Nothing is executed yet—you just defined the
   blueprint.
2. **The app boots.** When you run `iex -S mix` or `mix phx.server`,
   `Synapse.Application` spins up the supervision tree (Registry +
   RuntimeSupervisor). They sit idle waiting for workflow runs.
3. **You start a run** (e.g., `Synapse.start(MyWorkflow, %{foo: :bar})`). The
   public API calls into `Synapse.Engine`, which pulls the blueprint from
   `MyWorkflow.__synapse_definition__/0`, generates a run id, and asks
   `Synapse.RuntimeSupervisor` to start a `Synapse.Runner` child with that
   definition + context.
4. **The runner executes steps.** Once the child process starts, it immediately
   begins calling your step handlers in order. Returned maps merge into the
   context, `{:suspend, ...}` pauses the run, and errors trigger retries per the
   step metadata.
5. **You interact with the run** using `Synapse.inspect/1` and `Synapse.history/1`
   (read-only) or `Synapse.resume/2` (writes `human_input` and restarts the loop).

No extra wiring is needed for new workflows—the moment your module is compiled
and available, the runtime can execute it via `Synapse.start/3`.

## Message routing + persistence boundaries

- There is no durable persistence yet. Context/history lives inside each
  `Synapse.Runner` process. Restarting the app clears all runs; this is by design
  for Phase 1.
- Client code can read state via `Synapse.inspect/1` and `Synapse.history/1` to
  build APIs or UIs.

## Tooling and LLM adapters

- `Synapse.Tools` is a thin facade with configurable adapters + agents:
  - Global defaults are configured in `config/config.exs` under `Synapse.Tools`.
  - Named agents can override model/temperature/adapter per workflow via the
    `agent: :name` option.
  - `Synapse.Tools.chat/2` merges options, picks the adapter, and delegates to
    `adapter.chat/2`.
- `Synapse.Tools.OpenAI` is the default adapter. It builds a Finch request with a
  JSON body, sends it via `Synapse.Finch`, and returns either `{:ok, content}` or
  `{:error, reason}`. Lack of an API key raises so misconfiguration fails fast.

## Dev-only demo workflow

- `Synapse.Dev.DemoWorkflow` (`lib/synapse/dev/demo_workflow.ex`) is wrapped in
  `if Mix.env() == :dev` so it only compiles in development. It demonstrates the
  full lifecycle:
  - Collects or defaults a `:request` payload.
  - Calls `Synapse.Tools.chat/2` to draft a plan, falling back to a canned string
    if the adapter errors (e.g., missing `OPENAI_API_KEY`).
  - Suspends for a human approval with the generated plan in metadata.

Use it from `iex -S mix` with:

```elixir
{:ok, run_id} = Synapse.start(Synapse.Dev.DemoWorkflow, %{request: "Plan a kickoff"})
Synapse.inspect(run_id)
Synapse.resume(run_id, %{approved: true})
```

That sample mirrors how real workflows behave and is a good starting point for
experimentation.
