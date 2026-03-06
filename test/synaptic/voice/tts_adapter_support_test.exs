defmodule Synaptic.Voice.TTSAdapterSupportTest do
  use ExUnit.Case, async: true

  alias Synaptic.Voice.Providers.TTSAdapterSupport

  test "cancel advances generation and subsequent synthesis still emits chunks" do
    state = TTSAdapterSupport.init_state(self(), [])

    canceled = TTSAdapterSupport.cancel(state, :fake)
    assert canceled.generation == state.generation + 1
    assert_receive {:synaptic_voice, :tts_done, %{provider: :fake, canceled: true}}

    next =
      TTSAdapterSupport.handle_synthesis_result(
        canceled,
        canceled.generation,
        {:ok, "audio", %{provider: :fake}}
      )

    assert next.generation == canceled.generation
    assert_receive {:synaptic_voice, :tts_chunk, "audio", %{provider: :fake}}
  end

  test "stale generation responses are ignored" do
    state = TTSAdapterSupport.init_state(self(), [])
    newer_state = %{state | generation: 2}

    result =
      TTSAdapterSupport.handle_synthesis_result(
        newer_state,
        1,
        {:ok, "stale-audio", %{provider: :fake}}
      )

    assert result == newer_state
    refute_receive {:synaptic_voice, :tts_chunk, _, _}
  end

  test "errors are forwarded to the owning session" do
    state = TTSAdapterSupport.init_state(self(), [])

    _state =
      TTSAdapterSupport.handle_synthesis_result(
        state,
        state.generation,
        {:error, {:upstream_error, 500, "boom"}}
      )

    assert_receive {:synaptic_voice, :tts_error, {:upstream_error, 500, "boom"}}
  end
end
