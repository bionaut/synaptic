defmodule Synaptic.Voice.Sessions.Headless.LifecycleTest do
  use ExUnit.Case, async: true

  alias Synaptic.Voice.Sessions.Headless.Lifecycle

  defp base_ctx(overrides \\ %{}) do
    Map.merge(
      %{
        status: :listening,
        mode: :duplex,
        end_turn_requested: false,
        waiting_for_human_pending: false,
        output_in_progress: false,
        playback_drain_pending: false,
        latest_final: nil
      },
      overrides
    )
  end

  test "workflow waiting with active output defers turn entry" do
    ctx = base_ctx(%{status: :speaking, output_in_progress: true})

    assert {:ok, next_ctx, commands} = Lifecycle.reduce(ctx, :workflow_waiting_for_human)
    assert next_ctx.waiting_for_human_pending
    assert next_ctx.status == :speaking
    assert commands == [{:set_flag, :waiting_for_human_pending, true}]
  end

  test "tts_done in duplex waits for playback drain before listening" do
    ctx =
      base_ctx(%{
        status: :speaking,
        waiting_for_human_pending: true,
        output_in_progress: true
      })

    assert {:ok, next_ctx, commands} = Lifecycle.reduce(ctx, :tts_done)
    assert next_ctx.status == :awaiting_playback_drain
    assert next_ctx.playback_drain_pending
    assert not next_ctx.output_in_progress

    assert commands == [
             {:set_flag, :output_in_progress, false},
             {:set_flag, :playback_drain_pending, true},
             {:set_status, :awaiting_playback_drain},
             {:emit_state_changed, :awaiting_playback_drain}
           ]
  end

  test "playback_drained enters listening turn when ready" do
    ctx =
      base_ctx(%{
        status: :awaiting_playback_drain,
        waiting_for_human_pending: true,
        playback_drain_pending: true
      })

    assert {:ok, next_ctx, commands} = Lifecycle.reduce(ctx, :playback_drained)
    assert next_ctx.status == :listening
    assert next_ctx.waiting_for_human_pending == false

    assert commands == [
             {:set_flag, :playback_drain_pending, false},
             {:set_flag, :waiting_for_human_pending, false},
             {:set_status, :listening},
             {:emit_state_changed, :listening},
             {:emit, :turn_started, %{}},
             {:reset_turn_state}
           ]
  end

  test "stt_error clears flags and emits recoverable session error" do
    ctx =
      base_ctx(%{
        status: :speaking,
        end_turn_requested: true,
        waiting_for_human_pending: true,
        output_in_progress: true,
        playback_drain_pending: true
      })

    reason = %{type: :transcription_failed, status: 400}
    assert {:ok, next_ctx, commands} = Lifecycle.reduce(ctx, {:stt_error, reason})

    assert next_ctx.status == :listening
    assert next_ctx.end_turn_requested == false
    assert next_ctx.waiting_for_human_pending == false
    assert next_ctx.output_in_progress == false
    assert next_ctx.playback_drain_pending == false

    assert {:emit, :session_error, %{source: :stt, reason: ^reason}} = List.last(commands)
  end

  test "resume_error clears flags and returns listening with session_error command" do
    ctx =
      base_ctx(%{status: :thinking, end_turn_requested: true, waiting_for_human_pending: true})

    reason = %{type: :unknown, detail: "boom"}

    assert {:ok, next_ctx, commands} = Lifecycle.reduce(ctx, {:resume_error, reason})
    assert next_ctx.status == :listening
    assert next_ctx.end_turn_requested == false
    assert next_ctx.waiting_for_human_pending == false
    assert {:emit, :session_error, %{source: :resume, reason: ^reason}} = List.last(commands)
  end

  test "hold_turn keeps the session listening without committing the final transcript" do
    ctx = base_ctx(%{status: :evaluating_turn, end_turn_requested: true, latest_final: "draft"})

    assert {:ok, next_ctx, commands} = Lifecycle.reduce(ctx, :hold_turn)
    assert next_ctx.status == :listening
    assert next_ctx.end_turn_requested == false
    assert next_ctx.latest_final == nil

    assert commands == [
             {:set_flag, :latest_final, nil},
             {:clear_turn_flags},
             {:set_status, :listening},
             {:emit_state_changed, :listening}
           ]
  end

  test "unknown transition returns invalid_transition error" do
    ctx = base_ctx()
    assert {:error, :invalid_transition, ^ctx, []} = Lifecycle.reduce(ctx, :unknown_event)
  end
end
