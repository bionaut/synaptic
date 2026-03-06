defmodule Synaptic.Voice.Providers.OpenAI.Realtime.Sideband do
  @moduledoc false

  use GenServer

  def start_link(owner, opts \\ []) when is_pid(owner) do
    GenServer.start_link(__MODULE__, {owner, opts})
  end

  def ingest_provider_event(sideband, payload) when is_map(payload) do
    GenServer.cast(sideband, {:provider_event, payload})
    :ok
  end

  def send_event(sideband, event) when is_map(event) do
    GenServer.cast(sideband, {:outbound_event, event})
    :ok
  end

  def stop(sideband, reason \\ :normal) do
    GenServer.stop(sideband, reason)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({owner, opts}) do
    {:ok, %{owner: owner, opts: opts}}
  end

  @impl true
  def handle_cast({:provider_event, payload}, state) do
    send(state.owner, {:synaptic_voice_realtime_sideband, :provider_event, payload})
    {:noreply, state}
  end

  def handle_cast({:outbound_event, event}, state) do
    send(state.owner, {:synaptic_voice_realtime_sideband, :outbound_event, event})
    {:noreply, state}
  end
end
