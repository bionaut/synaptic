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

### Streaming responses

Synaptic supports streaming LLM responses for real-time content delivery. When
`stream: true` is passed to `Synaptic.Tools.chat/2`, the response is streamed
and PubSub events are emitted for each chunk:

```elixir
step :generate do
  messages = [%{role: "user", content: "Write a story"}]

  case Synaptic.Tools.chat(messages, stream: true) do
    {:ok, full_content} ->
      # Full content is available after streaming completes
      {:ok, %{story: full_content}}

    {:error, reason} ->
      {:error, reason}
  end
end
```

**Subscribing to stream events:**

```elixir
{:ok, run_id} = Synaptic.start(MyWorkflow, %{})
:ok = Synaptic.subscribe(run_id)

# Receive stream chunks in real-time
receive do
  {:synaptic_event, %{event: :stream_chunk, chunk: chunk, accumulated: accumulated}} ->
    IO.puts("New chunk: #{chunk}")
    IO.puts("So far: #{accumulated}")

  {:synaptic_event, %{event: :stream_done, accumulated: full_content}} ->
    IO.puts("Stream complete: #{full_content}")
end
```

**Stream event structure:**

- `:stream_chunk` - Emitted for each content chunk:

  - `chunk` - The new chunk of text
  - `accumulated` - All content received so far
  - `step` - The step name
  - `run_id` - The workflow run ID

- `:stream_done` - Emitted when streaming completes:
  - `accumulated` - The complete response
  - `step` - The step name
  - `run_id` - The workflow run ID

**Important limitations:**

- Streaming automatically falls back to non-streaming mode when tools are
  provided, as OpenAI's streaming API doesn't support tool calling
- Streaming doesn't support `response_format` options (JSON mode)
- The step function still receives the complete accumulated content when
  streaming finishes

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

### Starting at a specific step

For complex workflows, you can start execution at a specific step with pre-populated context. This is useful when you want to skip earlier steps or resume from a checkpoint:

```elixir
# Start at the :finalize step with context that simulates earlier steps
context = %{
  prepared: true,
  approval: true
}

{:ok, run_id} = Synaptic.start(
  ExampleFlow,
  context,
  start_at_step: :finalize
)
```

The `:start_at_step` option accepts a step name (atom). The provided context should contain all data that would have been accumulated up to that step. If the step name doesn't exist in the workflow, `start/3` returns `{:error, :invalid_step}`.

This feature is particularly useful for:

- Testing specific sections of complex workflows
- Resuming workflows from checkpoints
- Debugging by starting at problematic steps
- Replaying workflows with different context

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

### Step-level scorers (quality & evaluation)

Synaptic supports **step-level scorers** that evaluate the outcome of each step
and emit metrics via Telemetry (similar in spirit to Mastra scorers).

- Attach scorers to a step using the `:scorers` option:

  ```elixir
  defmodule MyWorkflow do
    use Synaptic.Workflow

    alias MyApp.Scorers.{UserDataCompleteness, WelcomeEmailTone}

    step :collect_user_data,
      scorers: [UserDataCompleteness] do
      {:ok, %{user: %{name: "Jane", email: "jane@example.com"}}}
    end

    step :send_welcome_email,
      scorers: [{WelcomeEmailTone, model: :gpt_4o_mini}] do
      # your side effects / LLM calls here
      {:ok, %{email_sent?: true}}
    end

    commit()
  end
  ```

- Implement a scorer by conforming to the `Synaptic.Scorer` behaviour:

  ```elixir
  defmodule MyApp.Scorers.UserDataCompleteness do
    @behaviour Synaptic.Scorer

    alias Synaptic.Scorer.{Context, Result}

    @impl true
    def score(%Context{step: step, run_id: run_id, output: output}, _metadata) do
      required = [:user]
      present? = Enum.all?(required, &Map.has_key?(output, &1))

      Result.new(
        name: "user_data_completeness",
        step: step.name,
        run_id: run_id,
        score: if(present?, do: 1.0, else: 0.0),
        reason:
          if present?,
            do: "All required keys present: #{inspect(required)}",
            else: "Missing required keys: #{inspect(required -- Map.keys(output))}"
      )
    end
  end
  ```

Scorers are executed **asynchronously** after each successful step and emit a
Telemetry span under `[:synaptic, :scorer]`. Your application can subscribe to
these events to persist scores (e.g. to Postgres, Prometheus, or Braintrust) or
build dashboards. See `Synaptic.Scorer` and `Synaptic.WorkflowScorerIntegrationTest`
for more detailed examples.

#### Sending scorer metrics to Braintrust

You can forward scorer events directly to Braintrust (or any external eval
service) from your host app by attaching a Telemetry handler:

```elixir
:telemetry.attach(
  "synaptic-braintrust-scorers",
  [:synaptic, :scorer, :stop],
  fn _event, _measurements, metadata, _config ->
    # Example shape – adapt to your Braintrust client / API
    Braintrust.log_score(%{
      run_id: metadata.run_id,
      workflow: inspect(metadata.workflow),
      step: Atom.to_string(metadata.step_name),
      scorer: inspect(metadata.scorer),
      score: metadata.score,
      reason: metadata.reason
    })
  end,
  nil
)
```

As long as your Braintrust client exposes a `log_score/1` (or equivalent)
function, this pattern lets Synaptic remain storage-agnostic while you push
scores into Braintrust for dashboards, model comparisons, or regression tests.

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

You can also start the demo workflow at a specific step:

```elixir
# Start at :generate_learning_plan with pre-answered questions
context = %{
  topic: "Elixir Concurrency",
  clarification_answers: %{
    "q_background" => "I know basic Elixir",
    "q_goal" => "Build distributed systems"
  },
  pending_questions: [],
  current_question: nil,
  question_source: :fallback
}

{:ok, run_id} = Synaptic.start(
  Synaptic.Dev.DemoWorkflow,
  context,
  start_at_step: :generate_learning_plan
)
```

The demo first asks the LLM to suggest 2–3 clarifying questions, then loops
through them (suspending after each) before generating the outline. If no OpenAI
credentials are configured it automatically falls back to canned questions +
plan so you can still practice the suspend/resume loop.

### Telemetry

Synaptic emits Telemetry events for workflow execution so host applications can
collect metrics (e.g. via Phoenix LiveDashboard, Prometheus, StatsD, or custom
handlers). The library focuses on _emitting_ events; your app is responsible for
_attaching_ handlers and exporting them.

#### Step timing

Every workflow step is wrapped in a Telemetry span:

- **Events**
  - `[:synaptic, :step, :start]`
  - `[:synaptic, :step, :stop]`
  - `[:synaptic, :step, :exception]` (if the step crashes)
- **Measurements (on `:stop` / `:exception`)**
  - `:duration` – native units (convert to ms with `System.convert_time_unit/3`
    or via `telemetry_metrics` `unit: {:native, :millisecond}`)
- **Metadata**
  - `:run_id` – workflow run id
  - `:workflow` – workflow module
  - `:step_name` – atom step name
  - `:type` – `:default | :parallel | :async`
  - `:status` – `:ok | :suspend | :error | :unknown`

Example: log all step timings from your host app:

```elixir
:telemetry.attach(
  "synaptic-step-logger",
  [:synaptic, :step, :stop],
  fn _event, measurements, metadata, _config ->
    duration_ms =
      System.convert_time_unit(measurements.duration, :native, :millisecond)

    IO.inspect(
      %{
        workflow: metadata.workflow,
        step: metadata.step_name,
        type: metadata.type,
        status: metadata.status,
        duration_ms: duration_ms
      },
      label: "Synaptic step"
    )
  end,
  nil
)
```

Example: expose a histogram metric (e.g. for LiveDashboard/Prometheus):

```elixir
import Telemetry.Metrics

def metrics do
  [
    summary("synaptic.step.duration",
      event_name: [:synaptic, :step, :stop],
      measurement: :duration,
      unit: {:native, :millisecond},
      tags: [:workflow, :step_name, :type, :status],
      tag_values: fn metadata ->
        %{
          workflow: inspect(metadata.workflow),
          step_name: metadata.step_name,
          type: metadata.type,
          status: metadata.status
        }
      end
    )
  ]
end
```

#### Side-effect metrics

Side effects declared via `side_effect/2` are also instrumented:

- **Run-time events (when the side effect executes)**
  - Span: `[:synaptic, :side_effect]` → `:start`, `:stop`, `:exception`
- **Skip events (when tests set `skip_side_effects: true`)**
  - `[:synaptic, :side_effect, :skip]`
- **Metadata**
  - `:run_id` – workflow run id (when available)
  - `:step_name` – the surrounding step name
  - `:side_effect` – optional identifier from `name:` option (or `nil`)

Example workflow usage:

```elixir
step :save_user do
  side_effect name: :db_insert_user do
    Database.insert(context.user)
  end

  {:ok, %{user_saved: true}}
end
```

Example handler for timing side effects:

```elixir
:telemetry.attach(
  "synaptic-side-effect-logger",
  [:synaptic, :side_effect, :stop],
  fn _event, measurements, metadata, _config ->
    duration_ms =
      System.convert_time_unit(measurements.duration, :native, :millisecond)

    IO.inspect(
      %{
        run_id: metadata.run_id,
        step: metadata.step_name,
        side_effect: metadata.side_effect,
        duration_ms: duration_ms
      },
      label: "Synaptic side effect"
    )
  end,
  nil
)
```

You can turn these into metrics the same way as step timings, e.g. a
`summary("synaptic.side_effect.duration", ...)` with tags `[:step_name, :side_effect]`.

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

### Testing streaming in IEx

The demo workflow now supports streaming in the `:generate_learning_plan` step. Here are IEx commands to test streaming functionality:

**Basic streaming test:**

```elixir
# Start the workflow with a topic
{:ok, run_id} = Synaptic.start(Synaptic.Dev.DemoWorkflow, %{topic: "Elixir Concurrency"})

# Subscribe to events
:ok = Synaptic.subscribe(run_id)

# Answer the questions (if prompted)
Synaptic.inspect(run_id)
# If waiting, resume with answers:
Synaptic.resume(run_id, %{answer: "I know basic Elixir"})
Synaptic.resume(run_id, %{answer: "Build distributed systems"})

# Watch for streaming events
receive do
  {:synaptic_event, %{event: :stream_chunk, chunk: chunk, accumulated: acc, step: step}} ->
    IO.puts("[#{step}] Chunk: #{chunk}")
    IO.puts("[#{step}] Accumulated: #{acc}")
    # Continue listening...
after
  10_000 -> IO.puts("No stream events received")
end
```

**Complete streaming workflow with event loop:**

```elixir
# Start workflow and subscribe
{:ok, run_id} = Synaptic.start(Synaptic.Dev.DemoWorkflow, %{topic: "Phoenix LiveView"})
:ok = Synaptic.subscribe(run_id)

# Helper function to listen for all events
listen_for_events = fn ->
  receive do
    {:synaptic_event, %{event: :stream_chunk, chunk: chunk, step: step}} ->
      IO.write(chunk)
      listen_for_events.()

    {:synaptic_event, %{event: :stream_done, accumulated: full, step: step}} ->
      IO.puts("\n\n[#{step}] Stream complete!")
      IO.puts("Full content:\n#{full}")

    {:synaptic_event, %{event: :waiting_for_human, message: msg, step: step}} ->
      IO.puts("\n[#{step}] Waiting: #{msg}")
      snapshot = Synaptic.inspect(run_id)
      IO.inspect(snapshot.waiting, label: "Waiting details")

    {:synaptic_event, %{event: :step_completed, step: step}} ->
      IO.puts("\n[#{step}] Step completed")

    {:synaptic_event, %{event: :completed}} ->
      IO.puts("\n✓ Workflow completed!")
      snapshot = Synaptic.inspect(run_id)
      IO.inspect(snapshot.context, label: "Final context")

    other ->
      IO.inspect(other, label: "Other event")
      listen_for_events.()
  after
    30_000 ->
      IO.puts("\nTimeout waiting for events")
      snapshot = Synaptic.inspect(run_id)
      IO.inspect(snapshot, label: "Current state")
  end
end

# Start listening
listen_for_events.()
```

**Skip to streaming step directly:**

```elixir
# Start at the streaming step with pre-answered questions
context = %{
  topic: "Elixir Pattern Matching",
  clarification_answers: %{
    "q_background" => "Beginner",
    "q_goal" => "Write cleaner code"
  },
  pending_questions: [],
  current_question: nil,
  question_source: :fallback
}

{:ok, run_id} = Synaptic.start(
  Synaptic.Dev.DemoWorkflow,
  context,
  start_at_step: :generate_learning_plan
)

:ok = Synaptic.subscribe(run_id)

# Watch the stream in real-time
Stream.repeatedly(fn ->
  receive do
    {:synaptic_event, %{event: :stream_chunk, chunk: chunk}} ->
      IO.write(chunk)
      :continue

    {:synaptic_event, %{event: :stream_done}} ->
      IO.puts("\n\n✓ Streaming complete!")
      :done

    other ->
      :continue
  after
    5_000 -> :timeout
  end
end)
|> Enum.take_while(&(&1 != :done))
```

**Monitor all events with a simple loop:**

```elixir
{:ok, run_id} = Synaptic.start(Synaptic.Dev.DemoWorkflow, %{topic: "OTP Behaviours"})
:ok = Synaptic.subscribe(run_id)

# Simple event monitor
monitor = fn ->
  case receive do
    {:synaptic_event, %{event: :stream_chunk, chunk: chunk}} ->
      IO.write(chunk)
      monitor.()

    {:synaptic_event, %{event: event} = payload} ->
      IO.puts("\n[#{event}] #{inspect(payload, pretty: true)}")
      monitor.()

    :stop -> :ok
  after
    60_000 ->
      IO.puts("\nMonitoring timeout")
      :ok
  end
end

# Run monitor in background or interactively
monitor.()
```

**Check workflow status and view history:**

```elixir
# Check current status
snapshot = Synaptic.inspect(run_id)
IO.inspect(snapshot, label: "Workflow snapshot")

# View execution history
history = Synaptic.history(run_id)
IO.inspect(history, label: "Execution history")

# List all running workflows
runs = Synaptic.list_runs()
IO.inspect(runs, label: "Active runs")
```

**Clean up:**

```elixir
# Unsubscribe when done
Synaptic.unsubscribe(run_id)

# Or stop the workflow
Synaptic.stop(run_id, :user_requested)
```

### Quick streaming test scripts

Two test scripts are provided for easy testing of streaming functionality:

**Simple version (recommended for quick tests):**

```bash
# Run with default topic
MIX_ENV=dev mix run scripts/test_streaming_simple.exs

# Run with custom topic
MIX_ENV=dev mix run scripts/test_streaming_simple.exs "Phoenix LiveView"
```

This script skips directly to the streaming step and displays chunks as they arrive.

**Full interactive version:**

```bash
# Run with default topic
MIX_ENV=dev mix run scripts/test_streaming.exs

# Run with custom topic
MIX_ENV=dev mix run scripts/test_streaming.exs "Phoenix LiveView"
```

**Or load in IEx:**

```elixir
# In IEx session
Code.require_file("scripts/test_streaming.exs")
TestStreaming.run("Your Topic Here")
```

The interactive script will:

- Let you choose between full workflow or skip to streaming step
- Subscribe to PubSub events
- Display streaming chunks in real-time as they arrive
- Auto-resume workflow steps for demo purposes
- Show final results and execution history

### Testing Workflows with YAML

Synaptic includes a declarative testing framework that allows non-developers to test workflows using YAML configuration files. This is ideal for AI researchers, management, or anyone who wants to test workflows without writing code.

#### YAML Test Format

Create a YAML file defining your test:

```yaml
name: "My Workflow Test"
workflow: "Synaptic.Dev.DemoWorkflow"
input:
  topic: "Elixir Concurrency"
start_at_step: "generate_learning_plan" # Optional: start at specific step
expectations: # Optional: validate results
  status: "completed"
  context:
    outline: ".*Elixir.*" # Regex pattern matching
    plan_source: "llm|fallback"
```

**Required fields:**

- `workflow`: Module name as string (e.g., `"Synaptic.Dev.DemoWorkflow"`)
- `input`: Map of initial context values

**Optional fields:**

- `name`: Test name for display
- `start_at_step`: Step name (atom as string) to start execution from
- `expectations`: Validation rules
  - `status`: Expected workflow status (`"completed"`, `"failed"`, `"waiting_for_human"`)
  - `context`: Map of field paths to regex patterns for validation

#### Running Tests

Run a test file using the test runner script:

```bash
# Basic usage
mix run scripts/run_tests.exs test/fixtures/demo_workflow_test.yaml

# JSON output only
mix run scripts/run_tests.exs test/fixtures/demo_workflow_test.yaml --format json

# Console output only
mix run scripts/run_tests.exs test/fixtures/demo_workflow_test.yaml --format console

# Custom timeout (default: 60 seconds)
mix run scripts/run_tests.exs test/fixtures/demo_workflow_test.yaml --timeout 120000
```

#### Handling Human Input

When a workflow suspends for human input, the test runner will:

1. Display the waiting message and required fields
2. Prompt you to enter a JSON payload
3. Resume the workflow with your input

Example prompt:

```
Workflow is waiting for human input
====================================

Message: Please approve the prepared payload

Required fields:
  - approved (boolean)

Enter resume payload (JSON format, or 'skip' to skip this test):
> {"approved": true}
```

#### Expectation Validation

The test framework supports optional expectations with regex matching:

- **Status validation**: Exact match (case-insensitive)
- **Context validation**: Regex patterns for field values
- **Nested paths**: Use dot notation (e.g., `"user.name"`)

Example:

```yaml
expectations:
  status: "completed"
  context:
    topic: "Elixir.*" # Regex: starts with "Elixir"
    plan_source: "llm|fallback" # Regex: matches "llm" or "fallback"
    "user.email": ".*@.*" # Nested path with regex
```

#### Skipping Side Effects in Tests

When testing workflows that contain side effects (database mutations, external API calls, file operations), you can skip these side effects using the `side_effect/1` macro in your workflow and the `skip_side_effects: true` option in your YAML test.

**In your workflow**, wrap side effect code with the `side_effect/1` macro:

```elixir
defmodule MyWorkflow do
  use Synaptic.Workflow

  step :create_user do
    user = %{name: context.name, email: context.email}

    side_effect do
      Database.insert(user)
    end

    {:ok, %{user: user}}
  end

  step :send_email do
    side_effect default: {:ok, :sent} do
      EmailService.send(context.user.email, "Welcome!")
    end

    {:ok, %{email_sent: true}}
  end
end
```

**In your YAML test**, add `skip_side_effects: true`:

```yaml
name: "Test user creation"
workflow: "MyWorkflow"
input:
  name: "John Doe"
  email: "john@example.com"
skip_side_effects: true # Skip database and other side effects
expectations:
  status: "completed"
  context:
    user: ".*John.*"
```

When `skip_side_effects: true` is set:

- All `side_effect/1` blocks are skipped
- By default, skipped side effects return `:ok`
- Use the `default:` option to return a specific value when skipped
- Side effects execute normally when the flag is not set

This allows you to test workflow logic and input/output transformations without requiring actual database connections or external services.

#### Example Test Files

Example test files are available in `test/fixtures/`:

- `demo_workflow_test.yaml` - Full workflow execution
- `demo_workflow_test_start_at_step.yaml` - Starting at a specific step
- `simple_workflow_test.yaml` - Minimal test without expectations
- `workflow_with_side_effects_test.yaml` - Example with side effects skipped

#### Output Formats

**Console output** (default) provides human-readable results:

```
================================================================================
Test: Demo Workflow Test
================================================================================

✓ Status: PASSED

Validation Results:
  Status Check: ✓ Status matches: completed
  Context Check: ✓ All context fields match

Final Context:
  topic: Elixir Concurrency
  outline: ...
```

**JSON output** provides structured data for automation:

```json
{
  "test_name": "Demo Workflow Test",
  "workflow": "Synaptic.Dev.DemoWorkflow",
  "run_id": "...",
  "status": "success",
  "validation": { ... },
  "context": { ... },
  "execution_time_ms": 1234
}
```

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
