defmodule Synaptic.Voice do
  @moduledoc """
  Unified voice session API for headless and realtime integrations.
  """

  alias Phoenix.PubSub
  alias Synaptic.Voice.Router

  @spec start_session(module(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workflow_module, input \\ %{}, opts \\ []) when is_map(input) do
    Router.start_session(workflow_module, input, opts)
  end

  @spec attach_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def attach_run(run_id, opts \\ []) when is_binary(run_id) do
    Router.attach_run(run_id, opts)
  end

  def push_audio(session_id, audio_chunk, opts \\ []),
    do: Router.push_audio(session_id, audio_chunk, opts)

  def push_text(session_id, text, opts \\ []), do: Router.push_text(session_id, text, opts)

  def end_turn(session_id, opts \\ []), do: Router.end_turn(session_id, opts)
  def playback_drained(session_id), do: Router.playback_drained(session_id)
  def cancel_output(session_id), do: Router.cancel_output(session_id)

  def client_connected(session_id, meta \\ %{}) when is_map(meta),
    do: Router.client_connected(session_id, meta)

  def client_disconnected(session_id, meta \\ %{}) when is_map(meta),
    do: Router.client_disconnected(session_id, meta)

  def ingest_provider_event(session_id, payload) when is_map(payload),
    do: Router.ingest_provider_event(session_id, payload)

  def stop_session(session_id, reason \\ :normal) do
    Router.stop_session(session_id, reason)
  catch
    :exit, _ -> :ok
  end

  def inspect_session(session_id), do: Router.inspect_session(session_id)

  def subscribe_session(session_id) when is_binary(session_id) do
    PubSub.subscribe(Synaptic.PubSub, topic(session_id))
  end

  def unsubscribe_session(session_id) when is_binary(session_id) do
    PubSub.unsubscribe(Synaptic.PubSub, topic(session_id))
  end

  defp topic(session_id), do: "synaptic:voice:session:" <> session_id
end
