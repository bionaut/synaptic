defmodule Synaptic.Voice.Providers.TTSAdapterSupport do
  @moduledoc false

  require Logger

  def init_state(owner, opts), do: %{owner: owner, opts: opts, generation: 0}

  def stop_process(adapter, reason) do
    GenServer.stop(adapter, reason)
    :ok
  catch
    :exit, _ -> :ok
  end

  def cancel(state, provider) do
    send(state.owner, {:synaptic_voice, :tts_done, %{provider: provider, canceled: true}})
    %{state | generation: state.generation + 1}
  end

  def flush(state, provider) do
    send(state.owner, {:synaptic_voice, :tts_done, %{provider: provider}})
    state
  end

  def handle_synthesis_result(state, generation, result, opts \\ []) do
    case result do
      {:ok, audio_chunk, meta} when generation == state.generation ->
        emit_synthesis_chunk(state, generation, audio_chunk, meta, opts)
        state

      {:ok, _audio_chunk, _meta} ->
        Logger.debug("[voice.tts_adapter] stale_synthesis_result generation=#{generation}")
        state

      {:error, reason} ->
        send(state.owner, {:synaptic_voice, :tts_error, reason})
        state
    end
  end

  def emit_synthesis_chunk(state, generation, audio_chunk, meta, opts \\ []) do
    if generation == state.generation do
      metadata = Keyword.get(opts, :metadata, %{})
      meta = if is_map(metadata), do: Map.merge(metadata, meta), else: meta
      send(state.owner, {:synaptic_voice, :tts_chunk, audio_chunk, meta})
    end

    :ok
  end
end
