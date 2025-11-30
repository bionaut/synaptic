# Synaptic

This repository hosts **Synaptic**, a database-free workflow engine for
LLM-assisted automations with human-in-the-loop support (Phase 1 of the spec).
If you want the full module-by-module breakdown, see [`TECHNICAL.md`](TECHNICAL.md).

## Current progress

- ✅ Workflow DSL (`use Synaptic.Workflow`, `step/3`, `commit/0`)
- ✅ In-memory runtime with supervised `Synaptic.Runner` processes
- ✅ Suspension + resume API for human involvement
- ✅ LLM abstraction with an OpenAI adapter (extensible later)
- ✅ Test suite covering DSL compilation + runtime execution
- 🔜 Persisted state, UI, distributed execution (future phases)

## Using Synaptic locally

1. Install deps: `mix deps.get`
2. Provide OpenAI credentials (see below)
3. Start an interactive shell when you want to run workflows locally: `iex -S mix`

### Configuring OpenAI credentials

Synaptic defaults to the `Synaptic.Tools.OpenAI` adapter. Supply an API key in
one of two ways:

1. **Environment variable** (recommended for dev):

   ```bash
   export OPENAI_API_KEY=sk-your-key
   ```

2. **Config override** (for deterministic deployments). In
   `config/dev.exs`/`config/runtime.exs` add:

   ```elixir
   config :synaptic, Synaptic.Tools.OpenAI,
     api_key: System.fetch_env!("OPENAI_API_KEY"),
     model: "gpt-4o-mini" # or whichever you prefer
   ```

You can also swap adapters by configuring `Synaptic.Tools`:

```elixir
config :synaptic, Synaptic.Tools, llm_adapter: MyCustomAdapter
```

### Using different models per step

Synaptic supports two ways to specify which model to use for each LLM call:

#### Option 1: Named agents (recommended for reusable configurations)

Define named agents in your config with their model and other settings, then reference them by name:

```elixir
# In config/config.exs
config :synaptic, Synaptic.Tools,
  llm_adapter: Synaptic.Tools.OpenAI,
  agents: [
    # Fast, cost-effective model for simple tasks
    mini: [model: "gpt-4o-mini", temperature: 0.3],
    # More capable model for complex reasoning
    turbo: [model: "gpt-4o-turbo", temperature: 0.7],
    # Most capable model for critical tasks
    o1: [model: "o1-preview", temperature: 0.1]
  ]

# In your workflow - use the agent name
Synaptic.Tools.chat(messages, agent: :mini, tools: [tool])
Synaptic.Tools.chat(messages, agent: :turbo, tools: [tool])
```

Benefits of named agents:

- **Semantic names**: `agent: :mini` is clearer than `model: "gpt-4o-mini"`
- **Bundle multiple settings**: model, temperature, adapter, etc. in one place
- **Centralized configuration**: change the model in config, not scattered across code
- **Reusable**: define once, use throughout your workflows

#### Option 2: Direct model specification

Pass the model name directly to `chat/2` for one-off usage:

```elixir
# Use a specific model directly
Synaptic.Tools.chat(messages, model: "gpt-4o-mini", tools: [tool])
Synaptic.Tools.chat(messages, model: "gpt-4o-turbo", temperature: 0.8, tools: [tool])
```

#### Model resolution priority

When both are specified, the system resolves options in this order:

1. Direct options passed to `chat/2` (e.g., `model:`, `temperature:`)
2. Options from the named agent (if `agent:` is specified)
3. Global defaults from `Synaptic.Tools.OpenAI` config
4. Hardcoded fallback: `"gpt-4o-mini"`

This means you can override agent settings per call:

```elixir
# Uses "gpt-4o-turbo" from :turbo agent, but overrides temperature to 0.5
Synaptic.Tools.chat(messages, agent: :turbo, temperature: 0.5)
```

You can also specify `adapter:` inside an agent definition if some agents need a different provider altogether.

### Tool calling

Synaptic exposes a thin wrapper around OpenAI-style tool calling. Define one or
more `%Synaptic.Tools.Tool{}` structs (or pass a map/keyword with `:name`,
`:description`, `:schema`, and a one-arity `:handler`), then pass them via the
`tools:` option:

```elixir
tool = %Synaptic.Tools.Tool{
  name: "lookup",
  description: "Looks up docs",
  schema: %{type: "object", properties: %{topic: %{type: "string"}}, required: ["topic"]},
  handler: fn %{"topic" => topic} -> Docs.search(topic) end
}

{:ok, response} = Synaptic.Tools.chat(messages, tools: [tool])
```

When the LLM requests a tool (via `function_call`/`tool_calls`), Synaptic invokes
the handler, appends the tool response to the conversation, and re-issues the
chat request until the model produces a final assistant message.

### Structured JSON responses

OpenAI's `response_format: %{type: "json_object"}` (and compatible JSON schema
formats) are supported end-to-end. Pass the option through `Synaptic.Tools.chat/2`
and the OpenAI adapter will add it to the upstream payload and automatically
decode the assistant response:

```elixir
{:ok, %{"summary" => summary}} =
  Synaptic.Tools.chat(messages, agent: :mini, response_format: :json_object)
```

If the model returns invalid JSON while JSON mode is enabled, the call fails
with `{:error, :invalid_json_response}` so workflows can retry or surface the
failure.

### Writing workflows

```elixir
defmodule ExampleFlow do
  use Synaptic.Workflow

  step :greet do
    {:ok, %{message: "Hello"}}
  end

  step :review, suspend: true, resume_schema: %{approved: :boolean} do
    case get_in(context, [:human_input, :approved]) do
      nil -> suspend_for_human("Approve greeting?")
      true -> {:ok, %{status: :approved}}
      false -> {:error, :rejected}
    end
  end

  commit()
end

{:ok, run_id} = Synaptic.start(ExampleFlow, %{})
Synaptic.resume(run_id, %{approved: true})
```

### Parallel steps

Use `parallel_step/3` when you want to fan out work, wait for all tasks, and
continue once every branch returns. The block must return a list of functions
that accept the current `context`:

```elixir
parallel_step :generate_initial_content do
  [
    fn ctx -> TitleDescriptionSteps.generate_and_update(ctx) end,
    fn ctx -> MetadataSteps.generate_and_update(ctx) end,
    fn ctx -> ConceptOutlinerSteps.execute(ctx) end
  ]
end

step :persist_concepts do
  PersistenceSteps.persist_concepts(context)
end
```

Each parallel task returns `{:ok, map}` or `{:error, reason}`. Synaptic runs the
tasks concurrently and merges their maps into the workflow context before
continuing to the next `step/3`.

### Async steps

Use `async_step/3` to trigger a task and immediately continue with the rest of
the workflow. Async steps execute in the background with the same retry and
error semantics as regular steps. Their return values are merged into the
context once they finish, and the workflow completes after every async task
has resolved:

```elixir
async_step :notify_observers do
  Notifications.deliver(context)
  {:ok, %{notifications_sent: true}}
end

step :persist_final_state do
  {:ok, %{status: :saved}}
end
```

If an async step fails, Synaptic applies the configured `:retry` budget. Once
retries are exhausted the workflow transitions to `:failed`, even if later
steps already ran.

### Stopping a run

To cancel a workflow early (for example, if a human rejected it out-of-band),
call:

```elixir
Synaptic.stop(run_id, :user_cancelled)
```

The optional second argument becomes the `:reason` in the PubSub event and
history entry. `Synaptic.stop/2` returns `:ok` if the run was alive and
`{:error, :not_found}` otherwise.

### Dev-only demo workflow

When running with `MIX_ENV=dev`, the module `Synaptic.Dev.DemoWorkflow` is loaded
so you can exercise the engine end-to-end without writing your own flow yet. In
one terminal start an IEx shell:

```bash
MIX_ENV=dev iex -S mix
```

Then kick off the sample workflow:

```elixir
{:ok, run_id} = Synaptic.start(Synaptic.Dev.DemoWorkflow, %{topic: "Intro to GenServers"})
Synaptic.inspect(run_id)
# => prompts you (twice) for learner info before producing an outline

Synaptic.resume(run_id, %{approved: true})
Synaptic.history(run_id)
```

The demo first asks the LLM to suggest 2–3 clarifying questions, then loops
through them (suspending after each) before generating the outline. If no OpenAI
credentials are configured it automatically falls back to canned questions +
plan so you can still practice the suspend/resume loop.

### Observing runs via PubSub

Subscribe to a run to receive lifecycle events from `Synaptic.PubSub`:

```elixir
:ok = Synaptic.subscribe(run_id)

receive do
  {:synaptic_event, %{event: :waiting_for_human, message: msg}} -> IO.puts("Waiting: #{msg}")
  {:synaptic_event, %{event: :step_completed, step: step}} -> IO.puts("Finished #{step}")
after
  5_000 -> IO.puts("no events yet")
end

Synaptic.unsubscribe(run_id)
```

Events include `:waiting_for_human`, `:resumed`, `:step_completed`, `:retrying`,
`:step_error`, `:failed`, `:stopped`, and `:completed`. Each payload also
contains `:run_id` and `:current_step`, so LiveView processes can map events to
the UI state they represent.

### Running tests

Synaptic has dedicated tests under `test/synaptic`. Run them with:

```bash
mix test
```

> `mix test` needs to open local sockets (Phoenix/Mix.PubSub). If you run in a
> sandboxed environment, allow network loopback access.

## What’s next

1. Add persistence (DB/Ecto) so runs survive VM restarts
2. Build basic UI/endpoints for human approvals + observability
3. Introduce additional adapters (Anthropic, local models, tooling APIs)
4. Explore distributed execution + versioning (Phase 2 roadmap)
