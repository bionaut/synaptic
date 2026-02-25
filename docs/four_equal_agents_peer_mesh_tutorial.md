# Tutorial: 4 Equal Agents in a Peer Mesh (No Single "Main" Agent)

This tutorial shows how to design **four equal agents** in Synaptic that can call each other as needed through the Agent Directory + Router control plane.

Unlike a strict coordinator/worker model, this pattern treats each agent as a peer:

- any agent can initiate work
- any agent can delegate to another agent
- any agent can resume or inspect tasks (if authorized)
- there is no permanent "boss" agent in the architecture

## Topic: Product Launch Intelligence Mesh

We will use a practical topic where peer communication makes sense:

**"Product launch intelligence"** for a company preparing a new release.

The four agents:

- `market.scan` - scans market signals and competitor movements
- `social.listening` - summarizes community/social chatter and sentiment
- `pricing.strategy` - proposes pricing hypotheses and scenarios
- `risk.review` - challenges assumptions and generates risk checks

Each of these agents can call the others when needed.

Examples:

- `pricing.strategy` may call `market.scan` to fetch competitor moves
- `risk.review` may call `social.listening` to check backlash signals
- `social.listening` may call `market.scan` to verify whether chatter maps to real market events
- `market.scan` may call `risk.review` before returning a recommendation summary

## Why This Pattern Matters

This design demonstrates the actual flexibility of the new Synaptic control plane:

- not voice-specific
- not coordinator-only
- not a single static workflow graph
- dynamic peer-to-peer delegation via service registry + router

It is closer to a real multi-agent system / agent mesh.

## Architecture (Peer Mesh)

All four agents are registered as services and can discover/invoke each other.

```text
market.scan <--> social.listening
     |               |
     v               v
pricing.strategy <--> risk.review
```

In practice, communication flows through Synaptic's router (not direct process coupling):

- `Synaptic.AgentDirectory` (service + task references)
- `Synaptic.AgentRouter` (authorized calls)
- `Synaptic.WorkloadManager` (spawn/reuse workflow-backed instances)

## 1. Register the 4 Peer Agents

```elixir
alias MyApp.Agents.{MarketScanWorkflow, SocialListeningWorkflow, PricingStrategyWorkflow, RiskReviewWorkflow}

services = [
  {"market.scan", MarketScanWorkflow, ["market.scan"]},
  {"social.listening", SocialListeningWorkflow, ["social.listening"]},
  {"pricing.strategy", PricingStrategyWorkflow, ["pricing.strategy"]},
  {"risk.review", RiskReviewWorkflow, ["risk.review"]}
]

Enum.each(services, fn {service_id, mod, capabilities} ->
  {:ok, _} =
    Synaptic.register_agent_service(
      service_id,
      %{
        kind: :workflow,
        capabilities: capabilities,
        visibility: :tenant,
        lifecycle_mode: :spawn_on_demand,
        provider: {:workflow_module, mod}
      }
    )
end)
```

## 2. Shared Calling Contract (Recommended)

To make peer-to-peer collaboration stable, define a shared payload convention.

Each agent call should include:

- `request_id` - stable correlation id for a user request
- `goal` - what the caller is trying to achieve
- `context_pack` - structured facts gathered so far
- `purpose` - task labeling for recovery/querying
- `delegation_reason` - why this agent is calling another one

Example payload shape:

```elixir
%{
  request_id: "launch-intel-2026-02-24-001",
  goal: "Assess launch viability for Product X",
  delegation_reason: "Need competitor pricing baselines",
  context_pack: %{
    product: "Product X",
    region: "US",
    launch_window: "Q2",
    known_competitors: ["A", "B", "C"]
  },
  purpose: "launch_intelligence_mesh"
}
```

## 3. Peer-to-Peer Call Example (Pricing -> Market)

`pricing.strategy` may need current competitor pricing movement before finalizing a recommendation.

```elixir
caller_ctx = %{
  tenant_id: "default",
  user_id: "user_42",
  caller_agent_id: "pricing.strategy",
  session_id: "launch_mesh_session_1"
}

{:ok, market_result} =
  Synaptic.agent_call(
    "market.scan",
    %{
      request_id: "launch-intel-2026-02-24-001",
      goal: "Assess launch viability for Product X",
      delegation_reason: "Need competitor pricing baselines",
      context_pack: %{
        product: "Product X",
        region: "US",
        launch_window: "Q2",
        competitors: ["A", "B", "C"]
      },
      purpose: "launch_intelligence_mesh"
    },
    caller_ctx: caller_ctx,
    aliases: ["last_market_scan"],
    timeout: 10_000
  )
```

If `market.scan` suspends, `pricing.strategy` can resume it through the returned handle.

## 4. Another Peer Call (Risk -> Social)

`risk.review` may ask `social.listening` for sentiment/complaint patterns.

```elixir
risk_ctx = %{
  tenant_id: "default",
  user_id: "user_42",
  caller_agent_id: "risk.review",
  session_id: "launch_mesh_session_1"
}

{:ok, social_result} =
  Synaptic.agent_call(
    "social.listening",
    %{
      request_id: "launch-intel-2026-02-24-001",
      goal: "Assess launch viability for Product X",
      delegation_reason: "Need pre-launch sentiment and complaint themes",
      context_pack: %{
        product: "Product X",
        audience: ["devs", "teams", "ops"],
        channels: ["X", "Reddit", "Discord"]
      },
      purpose: "launch_intelligence_mesh"
    },
    caller_ctx: risk_ctx,
    aliases: ["last_social_listening"],
    timeout: 10_000
  )
```

## 5. No Single Main Agent: How State Still Stays Coherent

When agents are peers, the main challenge is not calling each other. The challenge is **maintaining coherence**.

Use these conventions:

- Shared `request_id` across all related tasks
- Shared `purpose` (e.g. `"launch_intelligence_mesh"`)
- Agent-specific aliases (e.g. `last_market_scan`, `last_risk_review`)
- Structured `context_pack` payloads instead of raw text only

This lets any peer recover the chain.

## 6. Recovery Example (Any Peer Can Recover Another Task)

Suppose `pricing.strategy` crashes and restarts. It can recover the latest `market.scan` task for the same user/request.

```elixir
{:ok, task_ref} =
  Synaptic.AgentDirectory.resolve_task_reference(%{
    user_id: "user_42",
    capability: "market.scan",
    alias: "last_market_scan",
    require_active: true
  })

{:ok, status_result} =
  Synaptic.agent_call(
    %{task_ref_id: task_ref.task_ref_id},
    %{action: :inspect},
    caller_ctx: %{
      tenant_id: "default",
      user_id: "user_42",
      caller_agent_id: "pricing.strategy"
    }
  )
```

## 7. Example Peer Workflow Behaviors (Suggested)

These are not exact implementations, but practical shapes.

### `market.scan`

Responsibilities:

- identify competitor actions
- summarize launch timing/messaging moves
- return evidence and confidence

Can delegate to:

- `risk.review` ("What assumptions are weak?")
- `social.listening` ("Is this signal reflected in user chatter?")

### `social.listening`

Responsibilities:

- summarize sentiment themes
- identify recurring complaints/questions
- estimate volatility in discussion

Can delegate to:

- `market.scan` ("Did a competitor trigger this conversation?")
- `risk.review` ("Are these signals operationally relevant?")

### `pricing.strategy`

Responsibilities:

- produce pricing options (not final decision)
- compare scenarios
- explain tradeoffs

Can delegate to:

- `market.scan` (competitor baselines)
- `social.listening` (price sensitivity chatter)
- `risk.review` (risk constraints before presenting options)

### `risk.review`

Responsibilities:

- challenge assumptions
- identify blind spots and downside scenarios
- propose monitoring checks

Can delegate to:

- `market.scan` (verify competitor reality)
- `social.listening` (reputation/sentiment risks)
- `pricing.strategy` (stress-test plan under constraints)

## 8. Communication Rules (Highly Recommended)

When everyone is a peer, define simple rules to avoid chaos.

### Rule A: Include caller identity in `caller_ctx`

Always set `caller_agent_id` correctly.

This improves:

- auditability
- policy decisions
- debugging logs

### Rule B: Use capability-specific aliases

Avoid generic aliases like `last_task`.

Prefer:

- `last_market_scan`
- `last_social_listening`
- `last_pricing_strategy`
- `last_risk_review`

### Rule C: Keep delegations narrow

A peer call should request one thing, not an entire orchestration.

Good:

- "Get competitor price changes for last 30 days"

Bad:

- "Do everything and tell me what to do"

### Rule D: Return structured outputs

Use maps with stable keys so downstream peers can consume them reliably.

## 9. Optional Pattern: Temporary Convening Agent (Still Peer-Friendly)

Even in a peer mesh, you may sometimes create a temporary orchestration task for a single request.

That is still consistent with this design as long as:

- it is not a permanent privileged coordinator
- other peers can initiate their own delegations independently
- all interactions still go through the same directory/router/policy layer

Think of it as a **temporary convening role**, not a hard-coded hierarchy.

## 10. Observability Checklist for Peer Mesh Testing

When testing peer-to-peer calls, log these values on each hop:

- `caller_agent_id`
- target `service_id`
- `handle.instance_id`
- `handle.task_ref_id`
- `handle.run_id`
- `snapshot.status`
- `request_id`
- `purpose`

This makes it much easier to validate peer-call chains and recover tasks after failures.

## 11. Common Failure Modes (and how this architecture helps)

### Failure: Caller agent loses local memory

Fix:

- recover by task reference (`capability + alias + user_id + recency`)

### Failure: Too many similar tasks for one user

Fix:

- use better aliases and `purpose`
- include `request_id` in payload/context and surface it in task metadata (recommended future improvement)

### Failure: Peer loops / circular delegation

Fix (design rule):

- add delegation depth counters in payload
- set max delegation depth
- log `delegation_reason`

## 12. Practical Implementation Recipe

If you want to build this in your app, do it in this order:

1. Create 4 workflows (one per peer agent)
2. Register them as services in app startup
3. Standardize a shared payload contract (`request_id`, `goal`, `context_pack`, `purpose`)
4. Add aliases per capability
5. Add policy rules (who may call whom)
6. Add recovery logic using `resolve_task_reference/2`
7. Add logs/telemetry for each peer hop

## 13. Minimal Manual Test Script (IEx)

Use this to validate the architecture concept quickly.

```elixir
# 1. Register the 4 services (see section 1)

# 2. Start one peer call (pricing -> market)
caller_ctx = %{tenant_id: "default", user_id: "user_42", caller_agent_id: "pricing.strategy"}

{:ok, market_result} =
  Synaptic.agent_call(
    "market.scan",
    %{
      request_id: "launch-intel-001",
      goal: "Assess launch viability",
      delegation_reason: "Need competitor movement summary",
      context_pack: %{product: "Product X", region: "US"},
      purpose: "launch_intelligence_mesh"
    },
    caller_ctx: caller_ctx,
    aliases: ["last_market_scan"]
  )

# 3. Recover it from another peer identity (risk.review)
{:ok, task_ref} =
  Synaptic.AgentDirectory.resolve_task_reference(%{
    user_id: "user_42",
    capability: "market.scan",
    alias: "last_market_scan",
    require_active: true
  })

{:ok, status_result} =
  Synaptic.agent_call(
    %{task_ref_id: task_ref.task_ref_id},
    %{action: :inspect},
    caller_ctx: %{tenant_id: "default", user_id: "user_42", caller_agent_id: "risk.review"}
  )
```

If this works, you have verified a peer-mesh style agent system where all four agents are equals and can communicate through Synaptic's shared control plane.
