defmodule Synaptic.Voice do
  @moduledoc """
  Headless voice session APIs for integrating audio input/output with Synaptic workflows.
  """

  alias Phoenix.PubSub
  alias Synaptic.Voice.{Realtime, Session}

  @type start_result ::
          {:ok, String.t()}
          | {:ok, %{session_id: String.t(), run_id: String.t(), realtime: map()}}
          | {:error, term()}

  @spec start_session(module(), map(), keyword()) :: start_result()
  def start_session(workflow_module, input \\ %{}, opts \\ []) when is_map(input) do
    case normalized_mode(opts) do
      :realtime ->
        Realtime.start_session(workflow_module, input, opts)

      _mode ->
        workflow_opts = Keyword.get(opts, :workflow_opts, [])

        with {:ok, run_id} <- Synaptic.start(workflow_module, input, workflow_opts),
             {:ok, session_id} <- attach_run(run_id, normalize_attach_opts(opts)) do
          {:ok, session_id}
        end
    end
  end

  @spec attach_run(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def attach_run(run_id, opts \\ []) when is_binary(run_id) do
    case normalized_mode(opts) do
      :realtime ->
        Realtime.attach_run(run_id, opts)

      _mode ->
        session_id = Keyword.get(opts, :session_id, generate_session_id())

        child_opts =
          opts
          |> normalize_attach_opts()
          |> Keyword.put(:run_id, run_id)
          |> Keyword.put(:session_id, session_id)

        case DynamicSupervisor.start_child(
               Synaptic.Voice.SessionSupervisor,
               {Session, child_opts}
             ) do
          {:ok, _pid} -> {:ok, session_id}
          {:error, {:already_started, _pid}} -> {:error, :already_running}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def push_audio(session_id, audio_chunk, opts \\ []),
    do: Session.push_audio(session_id, audio_chunk, opts)

  def push_text(session_id, text, opts \\ []),
    do: Session.push_text(session_id, text, opts)

  def end_turn(session_id, opts \\ []), do: Session.end_turn(session_id, opts)
  def cancel_output(session_id), do: Session.cancel_output(session_id)

  def playback_drained(session_id) do
    case session_kind(session_id) do
      :classic -> Session.playback_drained(session_id)
      :realtime -> {:error, :unsupported_for_mode}
      :unknown -> {:error, :not_found}
    end
  end

  def stop_session(session_id, reason \\ :normal) do
    case session_kind(session_id) do
      :classic -> Session.stop_session(session_id, reason)
      :realtime -> Realtime.stop_session(session_id, reason)
      :unknown -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  def inspect_session(session_id) do
    case session_kind(session_id) do
      :classic -> Session.inspect_session(session_id)
      :realtime -> Realtime.inspect_session(session_id)
      :unknown -> {:error, :not_found}
    end
  end

  def subscribe_session(session_id) when is_binary(session_id) do
    case session_kind(session_id) do
      :classic -> PubSub.subscribe(Synaptic.PubSub, topic(session_id))
      :realtime -> Realtime.subscribe_session(session_id)
      :unknown -> PubSub.subscribe(Synaptic.PubSub, topic(session_id))
    end
  end

  def unsubscribe_session(session_id) when is_binary(session_id) do
    case session_kind(session_id) do
      :classic -> PubSub.unsubscribe(Synaptic.PubSub, topic(session_id))
      :realtime -> Realtime.unsubscribe_session(session_id)
      :unknown -> PubSub.unsubscribe(Synaptic.PubSub, topic(session_id))
    end
  end

  def client_connected(session_id, meta \\ %{}) when is_map(meta) do
    case session_kind(session_id) do
      :realtime -> Realtime.client_connected(session_id, meta)
      :classic -> {:error, :unsupported_for_mode}
      :unknown -> {:error, :not_found}
    end
  end

  def client_disconnected(session_id, meta \\ %{}) when is_map(meta) do
    case session_kind(session_id) do
      :realtime -> Realtime.client_disconnected(session_id, meta)
      :classic -> {:error, :unsupported_for_mode}
      :unknown -> {:error, :not_found}
    end
  end

  def ingest_provider_event(session_id, payload) when is_map(payload) do
    case session_kind(session_id) do
      :realtime -> Realtime.ingest_provider_event(session_id, payload)
      :classic -> {:error, :unsupported_for_mode}
      :unknown -> {:error, :not_found}
    end
  end

  defp topic(session_id), do: "synaptic:voice:session:" <> session_id

  defp normalize_attach_opts(opts) do
    case normalized_mode(opts) do
      mode when mode in [:duplex, :turn_based] ->
        opts
        |> Keyword.put(:voice_mode, mode)
        |> Keyword.delete(:mode)

      _ ->
        opts
    end
  end

  defp normalized_mode(opts) do
    Keyword.get(opts, :voice_mode) || Keyword.get(opts, :mode)
  end

  defp session_kind(session_id) when is_binary(session_id) do
    cond do
      registry_member?(Synaptic.Voice.Registry, session_id) -> :classic
      registry_member?(Synaptic.Voice.Realtime.Registry, session_id) -> :realtime
      true -> :unknown
    end
  end

  defp registry_member?(registry, session_id) do
    Process.whereis(registry) && Registry.lookup(registry, session_id) != []
  end

  defp generate_session_id do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
