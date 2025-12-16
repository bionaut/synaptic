defmodule Synaptic.EvalIntegrationTest do
  use ExUnit.Case

  alias Synaptic.Eval.Integration

  defmodule TestEvalIntegration do
    @behaviour Integration

    defstruct [
      :llm_calls,
      :scorer_results,
      :step_completions,
      :config
    ]

    def new(config \\ %{}) do
      %__MODULE__{
        llm_calls: [],
        scorer_results: [],
        step_completions: [],
        config: config
      }
    end

    @impl Integration
    def on_llm_call(_event, measurements, metadata, config) do
      pid = Map.get(config, :pid, self())
      send(pid, {:llm_call, measurements, metadata})
      :ok
    end

    @impl Integration
    def on_scorer_result(_event, measurements, metadata, config) do
      pid = Map.get(config, :pid, self())
      send(pid, {:scorer_result, measurements, metadata})
      :ok
    end

    @impl Integration
    def on_step_complete(_event, measurements, metadata, config) do
      pid = Map.get(config, :pid, self())
      send(pid, {:step_complete, measurements, metadata})
      :ok
    end
  end

  defmodule AdapterWithUsage do
    def chat(_messages, _opts) do
      {:ok, "response", %{usage: %{prompt_tokens: 10, completion_tokens: 20, total_tokens: 30}}}
    end
  end

  defmodule AdapterWithoutUsage do
    def chat(_messages, _opts) do
      {:ok, "response"}
    end
  end

  setup do
    # Clean up any existing handlers
    try do
      Integration.detach(TestEvalIntegration)
    rescue
      _ -> :ok
    end

    on_exit(fn ->
      try do
        Integration.detach(TestEvalIntegration)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "Integration.attach/2" do
    test "attaches Telemetry handlers for LLM calls" do
      config = %{pid: self()}
      :ok = Integration.attach(TestEvalIntegration, config)

      # Trigger an LLM call via Tools
      :telemetry.execute(
        [:synaptic, :llm, :stop],
        %{duration: 100},
        %{
          run_id: "test-run",
          step_name: :test_step,
          adapter: AdapterWithUsage,
          model: "gpt-4",
          stream: false
        }
      )

      assert_receive {:llm_call, %{duration: 100}, metadata}, 100
      assert metadata.run_id == "test-run"
      assert metadata.step_name == :test_step
      assert metadata.adapter == AdapterWithUsage
      assert metadata.model == "gpt-4"
      assert metadata.stream == false
    end

    test "includes usage metrics in LLM call metadata when available" do
      config = %{pid: self()}
      :ok = Integration.attach(TestEvalIntegration, config)

      :telemetry.execute(
        [:synaptic, :llm, :stop],
        %{duration: 100},
        %{
          run_id: "test-run",
          step_name: :test_step,
          adapter: AdapterWithUsage,
          model: "gpt-4",
          stream: false,
          usage: %{prompt_tokens: 10, completion_tokens: 20, total_tokens: 30},
          prompt_tokens: 10,
          completion_tokens: 20,
          total_tokens: 30
        }
      )

      assert_receive {:llm_call, measurements, metadata}, 100
      assert measurements.duration == 100
      # Token counts are in metadata
      assert metadata.prompt_tokens == 10
      assert metadata.completion_tokens == 20
      assert metadata.total_tokens == 30
      assert metadata.usage == %{prompt_tokens: 10, completion_tokens: 20, total_tokens: 30}
    end

    test "attaches Telemetry handlers for scorer results" do
      config = %{pid: self()}
      :ok = Integration.attach(TestEvalIntegration, config)

      :telemetry.execute(
        [:synaptic, :scorer, :stop],
        %{duration: 50},
        %{
          run_id: "test-run",
          workflow: TestWorkflow,
          step_name: :test_step,
          scorer: TestScorer,
          status: :ok,
          score: 0.9,
          reason: "looks good"
        }
      )

      assert_receive {:scorer_result, %{duration: 50}, metadata}, 100
      assert metadata.run_id == "test-run"
      assert metadata.workflow == TestWorkflow
      assert metadata.step_name == :test_step
      assert metadata.scorer == TestScorer
      assert metadata.status == :ok
      assert metadata.score == 0.9
      assert metadata.reason == "looks good"
    end

    test "attaches Telemetry handlers for step completions" do
      config = %{pid: self()}
      :ok = Integration.attach(TestEvalIntegration, config)

      :telemetry.execute(
        [:synaptic, :step, :stop],
        %{duration: 200},
        %{
          run_id: "test-run",
          workflow: TestWorkflow,
          step_name: :test_step,
          type: :default,
          status: :ok
        }
      )

      assert_receive {:step_complete, %{duration: 200}, metadata}, 100
      assert metadata.run_id == "test-run"
      assert metadata.workflow == TestWorkflow
      assert metadata.step_name == :test_step
      assert metadata.type == :default
      assert metadata.status == :ok
    end

    test "works with integration that only implements on_llm_call" do
      defmodule MinimalIntegration do
        @behaviour Integration

        @impl Integration
        def on_llm_call(_event, _measurements, _metadata, _config), do: :ok
      end

      config = %{pid: self()}
      :ok = Integration.attach(MinimalIntegration, config)

      :telemetry.execute(
        [:synaptic, :llm, :stop],
        %{duration: 100},
        %{
          run_id: "test",
          step_name: :test,
          adapter: AdapterWithUsage,
          model: "gpt-4",
          stream: false
        }
      )

      # Should not crash even though scorer/step callbacks don't exist
      Process.sleep(50)
      refute_receive {:scorer_result, _, _}, 50
      refute_receive {:step_complete, _, _}, 50

      :ok = Integration.detach(MinimalIntegration)
    end
  end

  describe "Integration.detach/1" do
    test "detaches Telemetry handlers" do
      config = %{pid: self()}
      :ok = Integration.attach(TestEvalIntegration, config)

      # Verify it's attached
      :telemetry.execute(
        [:synaptic, :llm, :stop],
        %{duration: 100},
        %{
          run_id: "test",
          step_name: :test,
          adapter: AdapterWithUsage,
          model: "gpt-4",
          stream: false
        }
      )

      assert_receive {:llm_call, _, _}, 100

      # Detach
      :ok = Integration.detach(TestEvalIntegration)

      # Verify it's detached
      :telemetry.execute(
        [:synaptic, :llm, :stop],
        %{duration: 100},
        %{
          run_id: "test",
          step_name: :test,
          adapter: AdapterWithUsage,
          model: "gpt-4",
          stream: false
        }
      )

      refute_receive {:llm_call, _, _}, 100
    end

    test "returns {:error, :not_found} when integration not attached" do
      assert {:error, :not_found} = Integration.detach(__MODULE__.NonExistentIntegration)
    end
  end

  describe "LLM Telemetry events" do
    test "emits Telemetry events for LLM calls with usage metrics" do
      config = %{pid: self()}
      :ok = Integration.attach(TestEvalIntegration, config)

      # Simulate what Tools does
      :telemetry.span(
        [:synaptic, :llm],
        %{
          run_id: "test-run",
          step_name: :test_step,
          adapter: AdapterWithUsage,
          model: "gpt-4",
          stream: false
        },
        fn ->
          result = AdapterWithUsage.chat([], [])
          usage = extract_usage(result)

          metadata = %{
            run_id: "test-run",
            step_name: :test_step,
            adapter: AdapterWithUsage,
            model: "gpt-4",
            stream: false
          }

          if usage != %{} do
            updated_metadata =
              metadata
              |> Map.put(:usage, usage)
              |> Map.put(:prompt_tokens, Map.get(usage, :prompt_tokens, 0))
              |> Map.put(:completion_tokens, Map.get(usage, :completion_tokens, 0))
              |> Map.put(:total_tokens, Map.get(usage, :total_tokens, 0))

            {result, updated_metadata}
          else
            {result, metadata}
          end
        end
      )

      assert_receive {:llm_call, measurements, metadata}, 100
      # Duration is automatically added by Telemetry span
      assert Map.has_key?(measurements, :duration)
      # Token counts are in metadata
      assert metadata.prompt_tokens == 10
      assert metadata.completion_tokens == 20
      assert metadata.total_tokens == 30
      assert metadata.usage == %{prompt_tokens: 10, completion_tokens: 20, total_tokens: 30}
    end

    test "emits Telemetry events for LLM calls without usage metrics" do
      config = %{pid: self()}
      :ok = Integration.attach(TestEvalIntegration, config)

      :telemetry.span(
        [:synaptic, :llm],
        %{
          run_id: "test-run",
          step_name: :test_step,
          adapter: AdapterWithoutUsage,
          model: "gpt-4",
          stream: false
        },
        fn ->
          result = AdapterWithoutUsage.chat([], [])

          metadata = %{
            run_id: "test-run",
            step_name: :test_step,
            adapter: AdapterWithoutUsage,
            model: "gpt-4",
            stream: false
          }

          {result, metadata}
        end
      )

      assert_receive {:llm_call, measurements, metadata}, 100
      # Duration is automatically added by Telemetry span
      assert Map.has_key?(measurements, :duration)
      # No usage metrics when adapter doesn't return them
      refute Map.has_key?(metadata, :usage)
      refute Map.has_key?(metadata, :prompt_tokens)
    end
  end

  defp extract_usage({:ok, _content, %{usage: usage}}), do: usage
  defp extract_usage({:ok, _content}), do: %{}
  defp extract_usage({:error, _reason}), do: %{}
end
