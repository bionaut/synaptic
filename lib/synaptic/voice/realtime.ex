defmodule Synaptic.Voice.Realtime do
  @moduledoc """
  Headless realtime voice session APIs for direct WebRTC media + Synaptic workflow orchestration.
  """

  alias Phoenix.PubSub
  alias Synaptic.Voice.Realtime.Session

  @spec start_session(module(), map(), keyword()) ::
          {:ok, %{session_id: String.t(), run_id: String.t(), realtime: map()}} | {:error, term()}
  def start_session(workflow_module, input \\ %{}, opts \\ []) when is_map(input) do
    workflow_opts = Keyword.get(opts, :workflow_opts, [])

    with {:ok, run_id} <- Synaptic.start(workflow_module, input, workflow_opts),
         {:ok, session_id} <- attach_run(run_id, opts),
         session <- inspect_session(session_id) do
      {:ok, %{session_id: session_id, run_id: run_id, realtime: session.realtime}}
    end
  end

  @spec attach_run(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def attach_run(run_id, opts \\ []) when is_binary(run_id) do
    session_id = Keyword.get(opts, :session_id, generate_session_id())

    child_opts =
      opts
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put(:session_id, session_id)

    case DynamicSupervisor.start_child(
           Synaptic.Voice.Realtime.SessionSupervisor,
           {Session, child_opts}
         ) do
      {:ok, _pid} -> {:ok, session_id}
      {:error, {:already_started, _pid}} -> {:error, :already_running}
      {:error, reason} -> {:error, reason}
    end
  end

  def stop_session(session_id, reason \\ :normal) do
    Session.stop_session(session_id, reason)
  catch
    :exit, _ -> :ok
  end

  def inspect_session(session_id), do: Session.inspect_session(session_id)

  def ingest_provider_event(session_id, payload) when is_map(payload) do
    Session.ingest_provider_event(session_id, payload)
  end

  def client_connected(session_id, meta \\ %{}) when is_map(meta) do
    Session.client_connected(session_id, meta)
  end

  def client_disconnected(session_id, meta \\ %{}) when is_map(meta) do
    Session.client_disconnected(session_id, meta)
  end

  def subscribe_session(session_id) when is_binary(session_id) do
    PubSub.subscribe(Synaptic.PubSub, topic(session_id))
  end

  def unsubscribe_session(session_id) when is_binary(session_id) do
    PubSub.unsubscribe(Synaptic.PubSub, topic(session_id))
  end

  defp topic(session_id), do: "synaptic:voice:realtime:session:" <> session_id

  defp generate_session_id do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
