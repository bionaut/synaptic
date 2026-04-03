defmodule Synaptic.Monitor.Collector do
  @moduledoc false

  use GenServer

  alias Synaptic.Monitor.Bus
  alias Synaptic.Monitor.Event
  alias Synaptic.Monitor.Store

  @handler_id "synaptic-monitor-collector"

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

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def capture(attrs) when is_map(attrs) do
    GenServer.cast(__MODULE__, {:capture, attrs})
  end

  @impl true
  def init(_opts) do
    attach_telemetry()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:capture, attrs}, state) do
    event =
      attrs
      |> Event.new()
      |> Event.to_map()
      |> Store.ingest()

    Bus.publish(event)
    {:noreply, state}
  end

  @impl true
  def handle_info({:telemetry, [:synaptic, :llm, :stop], measurements, metadata}, state) do
    pricing = Map.get(@pricing, Map.get(metadata, :model, "unknown"), @default_pricing)
    prompt_tokens = Map.get(metadata, :prompt_tokens, 0)
    completion_tokens = Map.get(metadata, :completion_tokens, 0)
    duration_ms = div(Map.get(measurements, :duration, 0), 1_000_000)

    estimated_cost_usd =
      prompt_tokens / 1_000_000 * pricing.input +
        completion_tokens / 1_000_000 * pricing.output

    capture(%{
      kind: :llm_call,
      status: :completed,
      run_id: Map.get(metadata, :run_id),
      step: Map.get(metadata, :step_name),
      summary: "LLM call #{Map.get(metadata, :model, "unknown")}",
      data: %{
        adapter: inspect(Map.get(metadata, :adapter)),
        model: Map.get(metadata, :model),
        stream: Map.get(metadata, :stream, false),
        duration_ms: duration_ms,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: Map.get(metadata, :total_tokens, prompt_tokens + completion_tokens),
        estimated_cost_usd: Float.round(estimated_cost_usd, 6)
      }
    })

    {:noreply, state}
  end

  def handle_info({:telemetry, [:synaptic, :llm, :exception], measurements, metadata}, state) do
    capture(%{
      kind: :llm_call,
      status: :failed,
      run_id: Map.get(metadata, :run_id),
      step: Map.get(metadata, :step_name),
      summary: "LLM call failed",
      data: %{
        adapter: inspect(Map.get(metadata, :adapter)),
        model: Map.get(metadata, :model),
        duration_ms: div(Map.get(measurements, :duration, 0), 1_000_000)
      }
    })

    {:noreply, state}
  end

  def handle_info(
        {:telemetry, [:synaptic, :mcp, :tool_call, :stop], measurements, metadata},
        state
      ) do
    status = Map.get(metadata, :result_status, :completed)

    capture(%{
      kind: :mcp_call,
      status: status,
      run_id: Map.get(metadata, :run_id),
      step: Map.get(metadata, :step_name),
      summary: mcp_summary(metadata, status),
      data: %{
        server_name: Map.get(metadata, :server_name) || Map.get(metadata, :server),
        remote_name: Map.get(metadata, :remote_name),
        duration_ms: div(Map.get(measurements, :duration, 0), 1_000_000),
        input: Map.get(metadata, :input),
        output: Map.get(metadata, :output)
      }
    })

    {:noreply, state}
  end

  def handle_info(
        {:telemetry, [:synaptic, :mcp, :tool_call, :exception], measurements, metadata},
        state
      ) do
    capture(%{
      kind: :mcp_call,
      status: :failed,
      run_id: Map.get(metadata, :run_id),
      step: Map.get(metadata, :step_name),
      summary: mcp_summary(metadata, :failed),
      data: %{
        server_name: Map.get(metadata, :server_name) || Map.get(metadata, :server),
        remote_name: Map.get(metadata, :remote_name),
        duration_ms: div(Map.get(measurements, :duration, 0), 1_000_000),
        input: Map.get(metadata, :input),
        output: %{error: Map.get(measurements, :reason)}
      }
    })

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id <> "-llm-stop")
    :telemetry.detach(@handler_id <> "-llm-exception")
    :telemetry.detach(@handler_id <> "-mcp-stop")
    :telemetry.detach(@handler_id <> "-mcp-exception")
    :ok
  end

  defp attach_telemetry do
    attach_once(@handler_id <> "-llm-stop", [:synaptic, :llm, :stop])
    attach_once(@handler_id <> "-llm-exception", [:synaptic, :llm, :exception])
    attach_once(@handler_id <> "-mcp-stop", [:synaptic, :mcp, :tool_call, :stop])
    attach_once(@handler_id <> "-mcp-exception", [:synaptic, :mcp, :tool_call, :exception])
  end

  defp attach_once(handler_id, event_name) do
    :telemetry.detach(handler_id)

    :telemetry.attach(
      handler_id,
      event_name,
      fn event, measurements, metadata, _config ->
        if pid = Process.whereis(__MODULE__) do
          send(pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )
  end

  defp mcp_summary(metadata, :failed) do
    "MCP tool #{Map.get(metadata, :remote_name, "unknown")} failed"
  end

  defp mcp_summary(metadata, _status) do
    "MCP tool #{Map.get(metadata, :remote_name, "unknown")}"
  end
end
