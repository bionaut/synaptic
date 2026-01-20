# RLM Integration Plan for Synaptic

## Overview

This document outlines the plan for integrating **Recursive Language Models (RLM)** concepts from the research paper (arXiv:2512.24601 by Zhang, Kraska, Khattab) into Synaptic.

### What is RLM?

RLM is an inference-time strategy that allows LLMs to handle arbitrarily large contexts by:

1. **Externalizing context** - Treating long input as part of an external environment (REPL) rather than feeding it all into the model
2. **Programmatic decomposition** - The model writes code/uses tools to search, partition, and filter the context
3. **Recursive sub-calls** - The root model can delegate work to sub-models on smaller chunks
4. **State persistence** - Variables track intermediate results across iterations

### Key Results from Paper

- Successfully handles inputs up to **two orders of magnitude beyond** native context window
- On OOLONG benchmark, RLM(GPT-5-mini) **doubles correct answers** vs baseline
- On BrowseComp-Plus (~100K documents), maintains strong performance at scale
- Cost-effective: often cheaper per query than baseline approaches

---

## Synaptic Architecture Analysis

### Alignment with Existing Features

| RLM Concept | Synaptic Equivalent | Gap/Opportunity |
|-------------|---------------------|-----------------|
| Root model orchestration | `Synaptic.Runner` GenServer | Already handles step orchestration |
| Sub-model delegation | `parallel_step/3`, `async_step/3` | Could be extended for recursive LLM calls |
| State persistence | `context` map accumulated across steps | Already tracks state between steps |
| Tool calling | `Synaptic.Tools` with tool handlers | Good foundation for RLM tools |
| Iteration/loops | Steps execute sequentially | Need runtime iteration within a step |

### Critical Constraints

| Aspect | Reality | Impact on Plan |
|--------|---------|----------------|
| **Steps are compile-time** | DSL macros create fixed step definitions | Can't dynamically add steps at runtime |
| **No native iteration** | Steps run once (or suspend for human) | Need runtime iteration within a step |
| **No workflow composition** | Can't call `Synaptic.start` from within a step cleanly | Sub-workflows require manual handling |
| **Tool calling works well** | `Synaptic.Tools.chat` with tools is robust | Good foundation for RLM tools |
| **Context accumulation works** | Maps persist across steps in Runner | Aligns with RLM state management |

### Key Insight

RLM's core loop is:

```
while not done:
    code = root_llm.generate(prompt)
    result = repl.execute(code)
    if answer_ready: break
```

This is fundamentally a **runtime iteration pattern**, not a compile-time workflow structure. The best approach is to build RLM as a **helper module** that works *within* existing Synaptic steps, not as new step types.

---

## Architecture

### Approach: RLM as a Runtime Helper Module

```
┌──────────────────────────────────────────────────────────┐
│                   Synaptic Workflow                       │
│  ┌────────────────────────────────────────────────────┐  │
│  │  step :analyze_document do                          │  │
│  │    # Use RLM helper for long-context processing     │  │
│  │    Synaptic.RLM.process(context.document, query,    │  │
│  │      agents: [:root, :sub],                         │  │
│  │      max_iterations: 20,                            │  │
│  │      token_budget: 100_000                          │  │
│  │    )                                                │  │
│  │  end                                                │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────┐
│                    Synaptic.RLM Module                    │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │ Environment │  │  Iteration  │  │   Sub-Agent     │  │
│  │   (State)   │  │    Loop     │  │   Dispatcher    │  │
│  └─────────────┘  └─────────────┘  └─────────────────┘  │
│         │                │                  │            │
│         └────────────────┴──────────────────┘            │
│                          │                               │
│                          ▼                               │
│             Synaptic.Tools.chat (existing)               │
└──────────────────────────────────────────────────────────┘
```

---

## Implementation Plan

### Phase 1: Core RLM Module

**Viability: 9/10**

**New module: `Synaptic.RLM`**

```elixir
defmodule Synaptic.RLM do
  @moduledoc """
  Recursive Language Model helper for processing large contexts.
  """
  
  defstruct [
    :context,           # The large input (stored externally)
    :query,             # User's question
    :state,             # Environment state (variables)
    :iteration,         # Current iteration count
    :accumulated_tokens,# Token tracking
    config: %{}         # Configuration
  ]
  
  @doc """
  Process a large context using RLM pattern.
  
  ## Options
    * `:root_agent` - Agent name for root model (default: :root)
    * `:sub_agent` - Agent name for sub-model calls (default: :sub)  
    * `:max_iterations` - Maximum iteration count (default: 20)
    * `:token_budget` - Maximum tokens to use (default: 100_000)
    * `:tools` - Additional tools to expose
  """
  def process(context, query, opts \\ []) do
    # Runtime iteration loop (not compile-time)
  end
end
```

**Why high viability:**
- No DSL changes needed
- Works within existing steps
- Pure runtime logic
- Leverages existing `Synaptic.Tools.chat`

---

### Phase 2: RLM Environment/State Manager

**Viability: 8/10**

**New module: `Synaptic.RLM.Environment`**

```elixir
defmodule Synaptic.RLM.Environment do
  @moduledoc """
  Manages the external state for RLM - variables, context slices, etc.
  """
  
  defstruct [
    :context,
    :context_length,
    variables: %{},
    answer: nil,
    answer_ready: false
  ]
  
  def new(context) do
    %__MODULE__{
      context: context,
      context_length: String.length(context),
      variables: %{},
      answer: nil,
      answer_ready: false
    }
  end
  
  def set_variable(env, name, value) do
    %{env | variables: Map.put(env.variables, name, value)}
  end
  
  def get_variable(env, name) do
    Map.get(env.variables, name)
  end
  
  def slice_context(env, start, length) do
    String.slice(env.context, start, length)
  end
  
  def search_context(env, pattern) do
    # Regex search returning matching sections with positions
  end
  
  def mark_answer(env, answer) do
    %{env | answer: answer, answer_ready: true}
  end
end
```

**Why high viability:**
- Simple data structure
- No external dependencies for basic functionality
- Can be enhanced incrementally

---

### Phase 3: RLM Tools

**Viability: 8/10**

**Built-in tools exposed to the root model:**

```elixir
defmodule Synaptic.RLM.Tools do
  @moduledoc """
  Built-in tools for RLM operations.
  """
  
  alias Synaptic.RLM.Environment
  alias Synaptic.Tools.Tool
  
  def built_in_tools(env, opts \\ []) do
    sub_agent = Keyword.get(opts, :sub_agent, :sub)
    
    [
      slice_context_tool(env),
      search_context_tool(env),
      llm_query_tool(sub_agent),
      llm_batch_tool(sub_agent),
      set_variable_tool(env),
      get_variable_tool(env),
      set_answer_tool(env),
      context_info_tool(env)
    ]
  end
  
  defp slice_context_tool(env) do
    %Tool{
      name: "slice_context",
      description: "Get a slice of the context by character position. Use to examine specific portions.",
      schema: %{
        type: "object",
        properties: %{
          start: %{type: "integer", description: "Start position (0-indexed)"},
          length: %{type: "integer", description: "Number of characters to retrieve"}
        },
        required: ["start", "length"]
      },
      handler: fn args -> 
        Environment.slice_context(env, args["start"], args["length"]) 
      end
    }
  end
  
  defp search_context_tool(env) do
    %Tool{
      name: "search_context",
      description: "Search the context with a regex pattern. Returns matching sections with positions.",
      schema: %{
        type: "object",
        properties: %{
          pattern: %{type: "string", description: "Regex pattern to search for"},
          max_results: %{type: "integer", description: "Maximum results to return (default: 10)"}
        },
        required: ["pattern"]
      },
      handler: fn args -> 
        Environment.search_context(env, args["pattern"], args["max_results"] || 10) 
      end
    }
  end
  
  defp llm_query_tool(sub_agent) do
    %Tool{
      name: "llm_query",
      description: "Query a sub-model with content and a question. Use for analyzing chunks.",
      schema: %{
        type: "object",
        properties: %{
          content: %{type: "string", description: "The content to analyze"},
          query: %{type: "string", description: "The question to answer about the content"}
        },
        required: ["content", "query"]
      },
      handler: fn args ->
        messages = [
          %{role: "system", content: "Analyze the provided content and answer the query concisely."},
          %{role: "user", content: "Content:\n#{args["content"]}\n\nQuery: #{args["query"]}"}
        ]
        case Synaptic.Tools.chat(messages, agent: sub_agent) do
          {:ok, result} -> result
          {:error, reason} -> "Error: #{inspect(reason)}"
        end
      end
    }
  end
  
  defp llm_batch_tool(sub_agent) do
    %Tool{
      name: "llm_batch",
      description: "Query sub-model on multiple chunks in parallel. More efficient for bulk analysis.",
      schema: %{
        type: "object",
        properties: %{
          queries: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{
                content: %{type: "string"},
                query: %{type: "string"}
              }
            },
            description: "Array of {content, query} pairs to process"
          }
        },
        required: ["queries"]
      },
      handler: fn args ->
        args["queries"]
        |> Task.async_stream(fn %{"content" => content, "query" => query} ->
          messages = [
            %{role: "system", content: "Analyze the provided content and answer the query concisely."},
            %{role: "user", content: "Content:\n#{content}\n\nQuery: #{query}"}
          ]
          case Synaptic.Tools.chat(messages, agent: sub_agent) do
            {:ok, result} -> result
            {:error, reason} -> "Error: #{inspect(reason)}"
          end
        end, timeout: 60_000, max_concurrency: 5)
        |> Enum.map(fn {:ok, result} -> result end)
      end
    }
  end
  
  defp set_variable_tool(env) do
    %Tool{
      name: "set_variable",
      description: "Store a value in a named variable for later use.",
      schema: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Variable name"},
          value: %{type: "string", description: "Value to store"}
        },
        required: ["name", "value"]
      },
      handler: fn args ->
        # Note: This needs to update env via Agent or return update instruction
        "Variable '#{args["name"]}' set"
      end
    }
  end
  
  defp get_variable_tool(env) do
    %Tool{
      name: "get_variable",
      description: "Retrieve a previously stored variable.",
      schema: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Variable name to retrieve"}
        },
        required: ["name"]
      },
      handler: fn args ->
        Environment.get_variable(env, args["name"]) || "Variable not found"
      end
    }
  end
  
  defp set_answer_tool(_env) do
    %Tool{
      name: "set_answer",
      description: "Set the final answer and signal that processing is complete. Call this when you have the answer.",
      schema: %{
        type: "object",
        properties: %{
          answer: %{type: "string", description: "The final answer to return"}
        },
        required: ["answer"]
      },
      handler: fn args ->
        # Returns special marker that main loop detects
        {:answer, args["answer"]}
      end
    }
  end
  
  defp context_info_tool(env) do
    %Tool{
      name: "context_info",
      description: "Get metadata about the context (length, structure hints).",
      schema: %{type: "object", properties: %{}},
      handler: fn _args ->
        %{
          total_length: env.context_length,
          line_count: length(String.split(env.context, "\n")),
          preview_start: String.slice(env.context, 0, 200),
          preview_end: String.slice(env.context, -200, 200)
        }
        |> Jason.encode!()
      end
    }
  end
end
```

**Why high viability:**
- Uses existing `Synaptic.Tools.Tool` struct
- Integrates with existing tool calling flow
- No new infrastructure needed

---

### Phase 4: Token/Cost Tracking

**Viability: 9/10**

**New module: `Synaptic.RLM.Budget`**

```elixir
defmodule Synaptic.RLM.Budget do
  @moduledoc """
  Tracks token usage and cost for RLM sessions.
  """
  
  defstruct [
    token_budget: 100_000,
    tokens_used: 0,
    cost_budget: nil,
    cost_used: 0.0,
    iterations: 0,
    max_iterations: 20,
    root_calls: 0,
    sub_calls: 0
  ]
  
  def new(opts \\ []) do
    %__MODULE__{
      token_budget: Keyword.get(opts, :token_budget, 100_000),
      max_iterations: Keyword.get(opts, :max_iterations, 20),
      cost_budget: Keyword.get(opts, :cost_budget)
    }
  end
  
  def track_usage(budget, usage_map, call_type \\ :root) do
    tokens = Map.get(usage_map, :total_tokens, 0)
    
    budget
    |> Map.update!(:tokens_used, &(&1 + tokens))
    |> Map.update!(:iterations, &(&1 + 1))
    |> increment_call_count(call_type)
  end
  
  defp increment_call_count(budget, :root), do: Map.update!(budget, :root_calls, &(&1 + 1))
  defp increment_call_count(budget, :sub), do: Map.update!(budget, :sub_calls, &(&1 + 1))
  
  def within_budget?(budget) do
    budget.tokens_used < budget.token_budget and
    budget.iterations < budget.max_iterations and
    (is_nil(budget.cost_budget) or budget.cost_used < budget.cost_budget)
  end
  
  def remaining_tokens(budget) do
    max(0, budget.token_budget - budget.tokens_used)
  end
  
  def remaining_iterations(budget) do
    max(0, budget.max_iterations - budget.iterations)
  end
  
  def to_map(budget) do
    %{
      tokens_used: budget.tokens_used,
      token_budget: budget.token_budget,
      iterations: budget.iterations,
      max_iterations: budget.max_iterations,
      root_calls: budget.root_calls,
      sub_calls: budget.sub_calls,
      cost_used: budget.cost_used
    }
  end
end
```

**Why high viability:**
- Synaptic already tracks usage in telemetry
- Simple arithmetic tracking
- Essential for production RLM use

---

### Phase 5: Code Execution/REPL (Optional)

**Viability: 5/10**

**Optional module: `Synaptic.RLM.CodeExecutor`**

```elixir
defmodule Synaptic.RLM.CodeExecutor do
  @moduledoc """
  Sandboxed code execution for RLM.
  
  WARNING: This is inherently risky. Consider alternatives:
  - Using only tool calls (safer)
  - Running in isolated Docker container
  - Using restricted subset of operations
  """
  
  def execute(code, bindings, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    
    # Option A: Restricted Elixir eval (limited safety)
    # Option B: External Python sandbox via Port
    # Option C: Pre-defined operation DSL (safest)
  end
end
```

**Why medium viability:**
- Security concerns with arbitrary code execution
- Elixir's `Code.eval_string` is powerful but dangerous
- External sandbox adds complexity
- **Recommendation:** Skip initially; tool-based approach covers most use cases

---

## Viability Summary

| Component | Viability | Effort | Notes |
|-----------|-----------|--------|-------|
| `Synaptic.RLM` main module | **9/10** | Medium | Core iteration loop, no DSL changes |
| `Synaptic.RLM.Environment` | **8/10** | Low | Simple state management |
| `Synaptic.RLM.Tools` | **8/10** | Medium | Reuses existing tool infrastructure |
| `Synaptic.RLM.Budget` | **9/10** | Low | Extends existing telemetry |
| `Synaptic.RLM.CodeExecutor` | **5/10** | High | Security complexity, consider skipping |
| Context chunking utilities | **8/10** | Low | Pure functions, well-defined |

### Overall Viability: **7.5/10**

The plan is viable with these caveats:
1. **Skip REPL/code execution initially** - Use rich tool set instead
2. **Build as helper module** - Don't modify the DSL
3. **Leverage existing infrastructure** - Tools, telemetry, agents

---

## Recommended Implementation Order

1. **`Synaptic.RLM.Environment`** - State container
2. **`Synaptic.RLM.Budget`** - Token/cost tracking  
3. **`Synaptic.RLM.Tools`** - Built-in tools (slice, search, llm_query, set_answer)
4. **`Synaptic.RLM`** - Main entry point with iteration loop
5. **Agent configuration** - Add root/sub agent presets
6. **Integration tests** - Validate on OOLONG-style tasks
7. **(Optional) `Synaptic.RLM.CodeExecutor`** - Only if tool-based approach proves insufficient

---

## Example Usage

```elixir
defmodule DocumentAnalyzer do
  use Synaptic.Workflow
  
  step :analyze do
    # RLM handles the iteration internally
    case Synaptic.RLM.process(
      context.document,  # Large context (could be millions of chars)
      context.query,     # User's question
      root_agent: :root,
      sub_agent: :sub,
      max_iterations: 25,
      token_budget: 150_000,
      # Optional: custom tools
      tools: [my_custom_tool()]
    ) do
      {:ok, answer, stats} -> 
        {:ok, %{answer: answer, rlm_stats: stats}}
      {:error, :budget_exceeded} ->
        {:error, :token_limit_reached}
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  commit()
end
```

### Agent Configuration

```elixir
# In config/config.exs
config :synaptic, Synaptic.Tools,
  llm_adapter: Synaptic.Tools.OpenAI,
  agents: [
    # Root agent: powerful model for orchestration
    root: [model: "gpt-4o", temperature: 0.3],
    # Sub agent: efficient model for chunk analysis
    sub: [model: "gpt-4o-mini", temperature: 0.1],
    # Verifier: for double-checking answers
    verifier: [model: "gpt-4o", temperature: 0.0]
  ]
```

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Tool-only approach insufficient | Low | Paper shows tools cover 90%+ of cases |
| Token tracking inaccurate | Medium | Use API response usage fields |
| Sub-agent latency issues | Medium | Leverage `llm_batch` for parallelization |
| Integration complexity | Low | Clean module boundaries |

---

## Changes from Original Plan

| Original Idea | Revised Approach | Reason |
|---------------|------------------|--------|
| New `recursive_step/3` macro | Helper module within steps | DSL changes are complex; runtime is simpler |
| New `loop_step/3` macro | Internal iteration in `Synaptic.RLM.process` | Same reason |
| REPL code execution | Tool-based approach | Security; tools are safer and sufficient |
| Modify workflow compilation | No DSL changes | Preserves existing architecture |

---

## References

- **Paper:** "Recursive Language Models" (arXiv:2512.24601)
- **Authors:** Alex L. Zhang, Tim Kraska, Omar Khattab
- **Key implementations:** alexzhang13/rlm, Prime Intellect's RLMEnv
