defmodule Synaptic.Voice.Sessions.Headless.Lifecycle do
  @moduledoc false

  @type ctx :: %{
          required(:status) => atom(),
          required(:mode) => :duplex | :turn_based,
          required(:end_turn_requested) => boolean(),
          required(:waiting_for_human_pending) => boolean(),
          required(:output_in_progress) => boolean(),
          required(:playback_drain_pending) => boolean(),
          required(:latest_final) => binary() | nil
        }

  @type command ::
          {:set_status, atom()}
          | {:clear_turn_flags}
          | {:emit, atom(), map()}
          | {:emit_state_changed, atom()}
          | {:reset_turn_state}
          | {:set_flag, atom(), term()}

  @spec reduce(ctx(), term()) :: {:ok, ctx(), [command()]} | {:error, atom(), ctx(), [command()]}
  def reduce(ctx, :cancel_output) do
    next_ctx =
      ctx
      |> clear_turn_flags_ctx()
      |> Map.put(:status, :listening)

    commands = [
      {:clear_turn_flags},
      {:emit, :duplex_interruption, %{reason: :cancel_output}},
      {:set_status, :listening},
      {:emit_state_changed, :listening}
    ]

    {:ok, next_ctx, commands}
  end

  def reduce(ctx, :playback_drained) do
    ctx = Map.put(ctx, :playback_drain_pending, false)
    commands = [{:set_flag, :playback_drain_pending, false}]
    {next_ctx, next_commands} = maybe_enter_turn(ctx, commands)
    {:ok, next_ctx, next_commands}
  end

  def reduce(ctx, :workflow_waiting_for_human) do
    ctx = Map.put(ctx, :waiting_for_human_pending, true)
    commands = [{:set_flag, :waiting_for_human_pending, true}]
    {next_ctx, next_commands} = maybe_enter_turn(ctx, commands)
    {:ok, next_ctx, next_commands}
  end

  def reduce(ctx, :workflow_stream_chunk_started) do
    commands =
      if ctx.status == :speaking do
        [{:set_flag, :output_in_progress, true}]
      else
        [
          {:set_status, :speaking},
          {:emit_state_changed, :speaking},
          {:set_flag, :output_in_progress, true}
        ]
      end

    next_ctx =
      ctx
      |> Map.put(:status, :speaking)
      |> Map.put(:output_in_progress, true)

    {:ok, next_ctx, commands}
  end

  def reduce(ctx, :workflow_stream_done) do
    next_ctx = Map.put(ctx, :output_in_progress, true)
    {:ok, next_ctx, [{:set_flag, :output_in_progress, true}]}
  end

  def reduce(ctx, :tts_done) do
    ctx = Map.put(ctx, :output_in_progress, false)
    commands = [{:set_flag, :output_in_progress, false}]
    {next_ctx, next_commands} = settle_output_completion(ctx, commands)
    {:ok, next_ctx, next_commands}
  end

  def reduce(ctx, {:tts_error, reason}) do
    ctx = Map.put(ctx, :output_in_progress, false)
    commands = [{:set_flag, :output_in_progress, false}]
    {next_ctx, commands} = settle_output_completion(ctx, commands)
    {:ok, next_ctx, commands ++ [{:emit, :session_error, %{source: :tts, reason: reason}}]}
  end

  def reduce(ctx, {:stt_error, reason}) do
    next_ctx =
      ctx
      |> clear_turn_flags_ctx()
      |> Map.put(:status, :listening)

    commands = [
      {:clear_turn_flags},
      {:set_status, :listening},
      {:emit_state_changed, :listening},
      {:emit, :session_error, %{source: :stt, reason: reason}}
    ]

    {:ok, next_ctx, commands}
  end

  def reduce(ctx, {:stt_empty_final, meta}) do
    next_ctx =
      ctx
      |> clear_turn_flags_ctx()
      |> Map.put(:latest_final, nil)
      |> Map.put(:status, :listening)

    commands = [
      {:set_flag, :latest_final, nil},
      {:clear_turn_flags},
      {:set_status, :listening},
      {:emit_state_changed, :listening},
      {:emit, :session_error, %{source: :stt, reason: :empty_transcript, meta: meta}}
    ]

    {:ok, next_ctx, commands}
  end

  def reduce(ctx, :hold_turn) do
    next_ctx =
      ctx
      |> clear_turn_flags_ctx()
      |> Map.put(:latest_final, nil)
      |> Map.put(:status, :listening)

    commands = [
      {:set_flag, :latest_final, nil},
      {:clear_turn_flags},
      {:set_status, :listening},
      {:emit_state_changed, :listening}
    ]

    {:ok, next_ctx, commands}
  end

  def reduce(ctx, :resume_ok) do
    next_ctx =
      ctx
      |> clear_turn_flags_ctx()
      |> Map.put(:status, :thinking)

    commands = [
      {:clear_turn_flags},
      {:set_status, :thinking},
      {:emit_state_changed, :thinking}
    ]

    {:ok, next_ctx, commands}
  end

  def reduce(ctx, {:resume_error, reason}) do
    next_ctx =
      ctx
      |> clear_turn_flags_ctx()
      |> Map.put(:status, :listening)

    commands = [
      {:clear_turn_flags},
      {:set_status, :listening},
      {:emit_state_changed, :listening},
      {:emit, :session_error, %{source: :resume, reason: reason}}
    ]

    {:ok, next_ctx, commands}
  end

  def reduce(ctx, :enter_turn) do
    {next_ctx, next_commands} = maybe_enter_turn(ctx, [])
    {:ok, next_ctx, next_commands}
  end

  def reduce(ctx, _event), do: {:error, :invalid_transition, ctx, []}

  @spec turn_phase(ctx()) :: atom()
  def turn_phase(%{status: :evaluating_turn}), do: :evaluating_turn

  def turn_phase(%{
        waiting_for_human_pending: true,
        output_in_progress: false,
        playback_drain_pending: false
      }),
      do: :ready_to_listen

  def turn_phase(%{playback_drain_pending: true}), do: :awaiting_playback_drain
  def turn_phase(%{output_in_progress: true}), do: :output_active
  def turn_phase(%{waiting_for_human_pending: true}), do: :waiting_for_human
  def turn_phase(%{end_turn_requested: true}), do: :ending_turn
  def turn_phase(_ctx), do: :ready_for_input

  defp maybe_enter_turn(ctx, commands) do
    if ctx.waiting_for_human_pending and turn_phase(ctx) == :ready_to_listen do
      next_ctx =
        ctx
        |> Map.put(:waiting_for_human_pending, false)
        |> Map.put(:latest_final, nil)
        |> Map.put(:status, :listening)

      next_commands =
        commands ++
          [
            {:set_flag, :waiting_for_human_pending, false},
            {:set_status, :listening},
            {:emit_state_changed, :listening},
            {:emit, :turn_started, %{}},
            {:reset_turn_state}
          ]

      {next_ctx, next_commands}
    else
      {ctx, commands}
    end
  end

  defp settle_output_completion(ctx, commands) do
    cond do
      ctx.mode == :duplex and ctx.waiting_for_human_pending and not ctx.output_in_progress ->
        next_ctx =
          ctx
          |> Map.put(:playback_drain_pending, true)
          |> Map.put(:status, :awaiting_playback_drain)

        next_commands =
          commands ++
            [
              {:set_flag, :playback_drain_pending, true},
              {:set_status, :awaiting_playback_drain},
              {:emit_state_changed, :awaiting_playback_drain}
            ]

        {next_ctx, next_commands}

      true ->
        maybe_enter_turn(ctx, commands)
    end
  end

  defp clear_turn_flags_ctx(ctx) do
    ctx
    |> Map.put(:end_turn_requested, false)
    |> Map.put(:waiting_for_human_pending, false)
    |> Map.put(:output_in_progress, false)
    |> Map.put(:playback_drain_pending, false)
  end
end
