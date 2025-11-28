# Synapse

This Phoenix app now hosts **Synapse**, a database-free workflow engine for
LLM-assisted automations with human-in-the-loop support (Phase 1 of the spec).
If you want the full module-by-module breakdown, see [`TECHNICAL.md`](TECHNICAL.md).

## Current progress

- ✅ Workflow DSL (`use Synapse.Workflow`, `step/3`, `commit/0`)
- ✅ In-memory runtime with supervised `Synapse.Runner` processes
- ✅ Suspension + resume API for human involvement
- ✅ LLM abstraction with an OpenAI adapter (extensible later)
- ✅ Test suite covering DSL compilation + runtime execution
- 🔜 Persisted state, UI, distributed execution (future phases)

## Using Synapse locally

1. Install deps: `mix setup`
2. Provide OpenAI credentials (see below)
3. Start the endpoint if you need the Phoenix app running: `mix phx.server`

### Configuring OpenAI credentials

Synapse defaults to the `Synapse.Tools.OpenAI` adapter. Supply an API key in
one of two ways:

1. **Environment variable** (recommended for dev):

   ```bash
   export OPENAI_API_KEY=sk-your-key
   ```

2. **Config override** (for deterministic deployments). In
   `config/dev.exs`/`config/runtime.exs` add:

   ```elixir
   config :synapse, Synapse.Tools.OpenAI,
     api_key: System.fetch_env!("OPENAI_API_KEY"),
     model: "gpt-4o-mini" # or whichever you prefer
   ```

You can also swap adapters by configuring `Synapse.Tools`:

```elixir
config :synapse, Synapse.Tools, llm_adapter: MyCustomAdapter
```

### Configuring agents with custom models

You can define named agents whose model/adapter configuration differs from the
global defaults. Provide agent entries under `Synapse.Tools` and reference
them via the `agent:` option when calling the tools module:

```elixir
config :synapse, Synapse.Tools,
  llm_adapter: Synapse.Tools.OpenAI,
  agents: [
    researcher: [model: "gpt-4o-mini"],
    builder: [model: "o4-mini", temperature: 0.1]
  ]

Synapse.Tools.chat([
  %{role: "system", content: "You are a helpful researcher"},
  %{role: "user", content: "Summarize the doc"}
], agent: :researcher)
```

Agent options are merged with any explicit opts passed to `chat/2`. You can also
specify `adapter:` inside an agent definition if some agents need a different
provider altogether.

### Writing workflows

```elixir
defmodule ExampleFlow do
  use Synapse.Workflow

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

{:ok, run_id} = Synapse.start(ExampleFlow, %{})
Synapse.resume(run_id, %{approved: true})
```

### Dev-only demo workflow

When running with `MIX_ENV=dev`, the module `Synapse.Dev.DemoWorkflow` is loaded
so you can exercise the engine end-to-end without writing your own flow yet. In
one terminal start an IEx shell:

```bash
MIX_ENV=dev iex -S mix
```

Then kick off the sample workflow:

```elixir
{:ok, run_id} = Synapse.start(Synapse.Dev.DemoWorkflow, %{request: "Plan a kickoff"})
Synapse.inspect(run_id)
# => shows :waiting_for_human with the generated plan in metadata

Synapse.resume(run_id, %{approved: true})
Synapse.history(run_id)
```

If no OpenAI credentials are configured the demo automatically falls back to a
canned plan so you can still practice the suspend/resume loop.

### Running tests

Synapse has dedicated tests under `test/synapse`. Run them with:

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

## Original Phoenix quickstart

The app still behaves like a standard Phoenix project:

- `mix setup` – install deps
- `mix phx.server` – start server (`localhost:4000`)

For deployment tips, read the [Phoenix guides](https://hexdocs.pm/phoenix/deployment.html).
