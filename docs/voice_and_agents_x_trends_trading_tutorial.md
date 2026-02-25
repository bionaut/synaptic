# Tutorial: Voice Agent + 3 Specialized Agents (X Trends and Trading)

This tutorial shows a practical multi-agent pattern in Synaptic using the new Agent Directory + Router control plane.

We will model a voice-facing coordinator agent that can talk to three specialized agents:

- `x.trends.research` - gathers trend signals (topics, hashtags, themes)
- `x.sentiment.analysis` - summarizes sentiment/risk tone from collected posts/data
- `trading.plan.risk` - proposes a risk-scoped trading plan (not execution)

The goal is to demonstrate:

- agent-to-agent communication through `Synaptic.agent_call/3`
- explicit service registration via the Agent Directory
- task references for recovery after the caller loses state
- a practical orchestration flow that is not voice-specific (voice is just one agent)

## Important Scope Notes

- This is a framework tutorial, not financial advice.
- The `trading.plan.risk` agent should produce a **plan** (sizing, risk, invalidation ideas), not place trades.
- Task references are **structured memory**. Synaptic stores task facts; your voice/LLM agent translates natural language into structured queries.

## Architecture (What Talks to What)

- `voice.command` (coordinator)
  - calls `x.trends.research`
  - calls `x.sentiment.analysis`
  - calls `trading.plan.risk`
  - may re-query/recover any of them using task references

This uses Synaptic's control-plane pieces under the hood:

- `Synaptic.AgentDirectory` (service/instance/task-reference records)
- `Synaptic.AgentRouter` (authorized invocation)
- `Synaptic.WorkloadManager` (spawn/reuse of workflow-backed agents)

## 1. Register the Agents (Services)

Register each specialized workflow as a service. These can be normal Synaptic workflows you already have.

```elixir
# Example workflow modules (you create these)
alias MyApp.Agents.{XTrendsResearchWorkflow, XSentimentAnalysisWorkflow, TradingPlanRiskWorkflow}

# Voice-facing coordinator identity is usually passed in caller_ctx; it does not have to be a service.
# But you can also register a voice service if you want agents to call it back.

{:ok, _} =
  Synaptic.register_agent_service(
    "x.trends.research",
    %{
      kind: :workflow,
      capabilities: ["x.trends.research"],
      visibility: :tenant,
      lifecycle_mode: :spawn_on_demand,
      provider: {:workflow_module, XTrendsResearchWorkflow}
    }
  )

{:ok, _} =
  Synaptic.register_agent_service(
    "x.sentiment.analysis",
    %{
      kind: :workflow,
      capabilities: ["x.sentiment.analysis"],
      visibility: :tenant,
      lifecycle_mode: :spawn_on_demand,
      provider: {:workflow_module, XSentimentAnalysisWorkflow}
    }
  )

{:ok, _} =
  Synaptic.register_agent_service(
    "trading.plan.risk",
    %{
      kind: :workflow,
      capabilities: ["trading.plan.risk"],
      visibility: :tenant,
      lifecycle_mode: :spawn_on_demand,
      provider: {:workflow_module, TradingPlanRiskWorkflow}
    }
  )
```

### Why explicit registration?

Registration makes each agent discoverable/addressable through the directory and router.

It also lets you control:

- visibility (`:private`, `:tenant`, `:public`)
- lifecycle mode (`:spawn_on_demand`, `:persistent`, etc.)
- capabilities (used later for task recovery/search)

## 2. Define the Voice Agent Caller Context

The voice agent (or any coordinator agent) should pass a stable `caller_ctx` on every router call.

```elixir
caller_ctx = %{
  tenant_id: "default",
  user_id: "user_42",
  caller_agent_id: "voice.command",
  session_id: "voice_session_abc123"
}
```

This context is used for:

- policy checks (authorization)
- visibility filtering
- instance scoping/reuse
- task reference ownership and recovery

## 3. Start a Research Task Through the Router

The voice agent receives a request like:

> "Analyze what's trending on X about AI chips and give me a risk-aware trading setup idea."

It starts the first specialized agent through the router:

```elixir
{:ok, trends_result} =
  Synaptic.agent_call(
    "x.trends.research",
    %{
      topic: "AI chips",
      market_symbol: "NVDA",
      timeframe: "24h",
      purpose: "x_trends_trading_assist"
    },
    caller_ctx: caller_ctx,
    aliases: ["last_x_trends"],
    timeout: 10_000
  )
```

What comes back (shape varies by workflow state):

- `handle` (`%Synaptic.AgentHandle{}`)
- `instance` (instance record)
- `task_reference` (structured task memory record)
- `run_id`
- `snapshot` (workflow state; may be `:completed` or `:waiting_for_human`)

### Why aliases matter

We passed `aliases: ["last_x_trends"]` so the voice agent can recover this task later even if it loses local memory.

## 4. Chain to the Sentiment Agent

If the trends workflow completes and returns trend artifacts in its snapshot context, the coordinator can pass those outputs to the sentiment agent.

```elixir
trend_summary = get_in(trends_result, [:snapshot, :context, :trend_summary])
trend_items = get_in(trends_result, [:snapshot, :context, :trend_items]) || []

{:ok, sentiment_result} =
  Synaptic.agent_call(
    "x.sentiment.analysis",
    %{
      topic: "AI chips",
      market_symbol: "NVDA",
      trend_summary: trend_summary,
      trend_items: trend_items,
      purpose: "x_trends_trading_assist"
    },
    caller_ctx: caller_ctx,
    aliases: ["last_x_sentiment"],
    timeout: 10_000
  )
```

## 5. Ask the Risk/Trading Plan Agent (Plan Only)

Now the coordinator can request a risk-scoped plan using outputs from the first two agents.

```elixir
sentiment_summary = get_in(sentiment_result, [:snapshot, :context, :sentiment_summary])
risk_flags = get_in(sentiment_result, [:snapshot, :context, :risk_flags]) || []

{:ok, plan_result} =
  Synaptic.agent_call(
    "trading.plan.risk",
    %{
      market_symbol: "NVDA",
      topic: "AI chips",
      trend_summary: trend_summary,
      sentiment_summary: sentiment_summary,
      risk_flags: risk_flags,
      objective: "create risk-scoped idea, no order execution",
      purpose: "x_trends_trading_assist"
    },
    caller_ctx: caller_ctx,
    aliases: ["last_trading_plan"],
    timeout: 10_000
  )
```

At this point, the voice agent can summarize the final plan back to the user.

## 6. Handling Suspensions (Human Approval / Clarification)

Any of these workflows may suspend (for example, asking for risk tolerance, budget, or confirmation).

If a call returns a snapshot with `status: :waiting_for_human`, the voice agent can:

1. ask the user the missing question
2. resume the workflow through the router using the returned `handle`

```elixir
# Inspect current status
{:ok, inspect_result} =
  Synaptic.agent_call(trends_result.handle, %{action: :inspect}, caller_ctx: caller_ctx)

# Resume with human input
{:ok, resumed_trends} =
  Synaptic.agent_call(
    trends_result.handle,
    %{action: :resume, payload: %{approved: true}},
    caller_ctx: caller_ctx,
    timeout: 10_000
  )
```

Supported workflow-backed actions in the current V1 implementation:

- `:inspect`
- `:history`
- `:resume`
- `:stop`

## 7. Recover After Caller Memory Loss (Key Practical Pattern)

This is one of the most useful features in the new architecture.

If the voice agent restarts or loses local state, it can recover tasks through the built-in task reference memory.

### Example: recover the latest trends task

```elixir
{:ok, task_ref} =
  Synaptic.AgentDirectory.resolve_task_reference(%{
    user_id: "user_42",
    capability: "x.trends.research",
    alias: "last_x_trends",
    require_active: true
  })
```

Now route directly to that task:

```elixir
{:ok, status_result} =
  Synaptic.agent_call(
    %{task_ref_id: task_ref.task_ref_id},
    %{action: :inspect},
    caller_ctx: caller_ctx
  )
```

### Why this matters

Without task references, the caller must persist raw instance IDs perfectly.

With task references:

- callers should still persist handles when possible (best path)
- but they can recover if memory is lost
- multiple tasks per user are still manageable via aliases/purpose/status/recency

## 8. Orchestrator Pattern (Voice Agent as Coordinator)

The voice agent should act like a coordinator, not a giant monolith.

A practical coordinator flow:

1. Parse user intent
2. Choose which specialized agent(s) to call
3. Pass structured inputs
4. Track handles/task references
5. Recover/resume as needed
6. Synthesize a user-facing response

Pseudo-code:

```elixir
def handle_voice_request(text, caller_ctx) do
  # LLM/intent parser step (outside Synaptic router scope)
  intent = parse_intent(text)

  case intent do
    %{kind: :x_trends_trading, topic: topic, symbol: symbol} ->
      {:ok, trends} =
        Synaptic.agent_call(
          "x.trends.research",
          %{topic: topic, market_symbol: symbol, purpose: "x_trends_trading_assist"},
          caller_ctx: caller_ctx,
          aliases: ["last_x_trends"]
        )

      with %{status: :completed} <- trends.snapshot,
           {:ok, sentiment} <-
             Synaptic.agent_call(
               "x.sentiment.analysis",
               %{topic: topic, market_symbol: symbol, trend_summary: trends.snapshot.context.trend_summary},
               caller_ctx: caller_ctx,
               aliases: ["last_x_sentiment"]
             ),
           {:ok, plan} <-
             Synaptic.agent_call(
               "trading.plan.risk",
               %{market_symbol: symbol, trend_summary: trends.snapshot.context.trend_summary},
               caller_ctx: caller_ctx,
               aliases: ["last_trading_plan"]
             ) do
        summarize_for_voice(trends, sentiment, plan)
      else
        %{status: :waiting_for_human} = waiting ->
          {:ask_user, waiting.waiting}

        error ->
          {:error, error}
      end
  end
end
```

## 9. Suggested Workflow Shapes for the 3 Specialized Agents

You do not need to copy these exactly; this is a practical starting point.

### `x.trends.research` workflow

Inputs:

- `topic`
- `market_symbol`
- `timeframe`

Outputs:

- `trend_items` (list of trend objects)
- `trend_summary`
- `sources_used`
- `confidence`

Potential suspend points:

- missing timeframe
- unclear topic scope

### `x.sentiment.analysis` workflow

Inputs:

- `trend_items`
- `trend_summary`
- `market_symbol`

Outputs:

- `sentiment_summary`
- `bullish_signals`
- `bearish_signals`
- `risk_flags`

Potential suspend points:

- request user preference for aggressive vs conservative interpretation

### `trading.plan.risk` workflow

Inputs:

- `market_symbol`
- `trend_summary`
- `sentiment_summary`
- `risk_flags`
- user constraints (optional)

Outputs (plan only):

- `thesis`
- `invalidation_conditions`
- `risk_notes`
- `position_sizing_guidance`
- `monitoring_checklist`

Potential suspend points:

- missing risk tolerance
- budget/position size constraints

## 10. Observability Tips (Very Practical)

When testing in `iex`, log and inspect these values on every routed call:

- `handle.instance_id`
- `handle.task_ref_id`
- `handle.run_id`
- `snapshot.status`
- `snapshot.waiting` (if present)
- `task_reference.status`

This helps validate that:

- directory registration happened
- workload spawning worked
- task references are linked correctly
- recovery queries resolve to the intended task

## 11. One Common Pitfall (and what it means)

You may see this during a routed call result:

- `snapshot.status == :completed`
- but `task_reference.status == :running`

This can happen because task reference updates are applied asynchronously via PubSub after the router returns.

In practice:

- treat `snapshot` as the immediate authoritative result of the call
- treat `task_reference` as eventually consistent metadata (it catches up)

## 12. What to Build Next (Recommended)

If you want to productionize this pattern, the next good steps are:

1. Add policy rules per service (who can call what)
2. Add lease/heartbeat + stale instance cleanup
3. Add a persistent directory backend (DB/Redis/custom store)
4. Add a small voice-side helper that converts phrases like:
   - "my last trends analysis"
   - "resume the trading plan"
   into structured task reference queries for `Synaptic.AgentDirectory.resolve_task_reference/2`

---

## Minimal End-to-End Checklist (Manual Testing)

- Register the 3 services
- Create a `caller_ctx` for your voice agent
- Call `x.trends.research`
- If suspended, resume via router handle
- Call `x.sentiment.analysis`
- Call `trading.plan.risk`
- Resolve one of the tasks by alias using `resolve_task_reference/2`
- Inspect it via `agent_call(%{task_ref_id: ...}, %{action: :inspect})`

If all of those steps work, your agent-to-agent control-plane is functioning in the way this V1 architecture intends.
