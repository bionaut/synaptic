if Code.ensure_loaded?(Mix) and Mix.env() == :dev do
  defmodule Synaptic.Dev.CostTracker do
    @moduledoc """
    Dev-only telemetry handler that tracks and logs LLM token usage and
    estimated costs across Synaptic workflow runs.

    ## Usage

        # Attach once (e.g. in iex or application start)
        Synaptic.Dev.CostTracker.attach()

        # Run your workflow...
        Synaptic.Dev.BrowserUseDemo.run()

        # See accumulated totals
        Synaptic.Dev.CostTracker.summary()

        # Reset counters
        Synaptic.Dev.CostTracker.reset()
    """

    require Logger

    @agent_key :synaptic_cost_tracker

    # Approximate pricing per 1M tokens (USD) — update as needed
    @pricing %{
      "gpt-5-nano" => %{input: 0.05, output: 0.40},
      "gpt-4.1-nano" => %{input: 0.10, output: 0.40},
      "gpt-4o-mini" => %{input: 0.15, output: 0.60},
      "gpt-5-mini" => %{input: 0.25, output: 2.00},
      "gpt-4.1-mini" => %{input: 0.40, output: 1.60},
      "gpt-4.1" => %{input: 2.00, output: 8.00},
      "gpt-4o" => %{input: 2.50, output: 10.00}
    }

    @default_pricing %{input: 2.50, output: 10.00}

    def attach do
      ensure_agent()

      :telemetry.attach_many(
        "synaptic-cost-tracker",
        [
          [:synaptic, :llm, :stop],
          [:synaptic, :mcp, :tool_call, :stop]
        ],
        &__MODULE__.handle_event/4,
        nil
      )

      Logger.info("[cost_tracker] attached — tracking LLM token usage")
      :ok
    end

    def detach do
      :telemetry.detach("synaptic-cost-tracker")
      :ok
    end

    def handle_event([:synaptic, :llm, :stop], measurements, metadata, _config) do
      prompt = Map.get(metadata, :prompt_tokens, 0)
      completion = Map.get(metadata, :completion_tokens, 0)
      total = Map.get(metadata, :total_tokens, prompt + completion)
      model = Map.get(metadata, :model, "unknown")
      duration_ms = div(Map.get(measurements, :duration, 0), 1_000_000)

      pricing = Map.get(@pricing, model, @default_pricing)
      cost = prompt / 1_000_000 * pricing.input + completion / 1_000_000 * pricing.output

      record(:llm, %{
        model: model,
        prompt_tokens: prompt,
        completion_tokens: completion,
        total_tokens: total,
        estimated_cost_usd: cost,
        duration_ms: duration_ms
      })

      if total > 0 do
        Logger.info(
          "[cost_tracker] LLM call model=#{model} " <>
            "tokens=#{prompt}+#{completion}=#{total} " <>
            "cost=$#{Float.round(cost, 6)} " <>
            "duration=#{duration_ms}ms"
        )
      end
    end

    def handle_event([:synaptic, :mcp, :tool_call, :stop], measurements, metadata, _config) do
      duration_ms = div(Map.get(measurements, :duration, 0), 1_000_000)
      server = Map.get(metadata, :server_name, "unknown")
      tool = Map.get(metadata, :remote_name, "unknown")

      record(:mcp, %{server: server, tool: tool, duration_ms: duration_ms})

      Logger.info(
        "[cost_tracker] MCP tool server=#{server} tool=#{tool} duration=#{duration_ms}ms"
      )
    end

    def summary do
      ensure_agent()
      state = Agent.get(@agent_key, & &1)

      llm_calls = state.llm
      total_prompt = Enum.sum(Enum.map(llm_calls, & &1.prompt_tokens))
      total_completion = Enum.sum(Enum.map(llm_calls, & &1.completion_tokens))
      total_tokens = Enum.sum(Enum.map(llm_calls, & &1.total_tokens))
      total_cost = Enum.sum(Enum.map(llm_calls, & &1.estimated_cost_usd))
      total_llm_ms = Enum.sum(Enum.map(llm_calls, & &1.duration_ms))

      mcp_calls = state.mcp
      total_mcp_ms = Enum.sum(Enum.map(mcp_calls, & &1.duration_ms))

      IO.puts("""

      === Synaptic Cost Summary ===
      LLM calls:        #{length(llm_calls)}
      Prompt tokens:    #{total_prompt}
      Completion tokens: #{total_completion}
      Total tokens:     #{total_tokens}
      Estimated cost:   $#{Float.round(total_cost, 4)}
      LLM time:         #{total_llm_ms}ms

      MCP tool calls:   #{length(mcp_calls)}
      MCP time:         #{total_mcp_ms}ms

      Total wall time:  #{total_llm_ms + total_mcp_ms}ms
      """)

      %{
        llm_calls: length(llm_calls),
        prompt_tokens: total_prompt,
        completion_tokens: total_completion,
        total_tokens: total_tokens,
        estimated_cost_usd: Float.round(total_cost, 6),
        llm_duration_ms: total_llm_ms,
        mcp_calls: length(mcp_calls),
        mcp_duration_ms: total_mcp_ms
      }
    end

    def reset do
      ensure_agent()
      Agent.update(@agent_key, fn _ -> %{llm: [], mcp: []} end)
      :ok
    end

    defp record(type, entry) do
      ensure_agent()
      Agent.update(@agent_key, fn state -> Map.update!(state, type, &[entry | &1]) end)
    end

    defp ensure_agent do
      case Agent.start_link(fn -> %{llm: [], mcp: []} end, name: @agent_key) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
