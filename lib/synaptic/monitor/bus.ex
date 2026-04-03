defmodule Synaptic.Monitor.Bus do
  @moduledoc false

  use GenServer

  alias Phoenix.PubSub

  @topic "synaptic:monitor"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def subscribe do
    PubSub.subscribe(Synaptic.PubSub, @topic)
  end

  def unsubscribe do
    PubSub.unsubscribe(Synaptic.PubSub, @topic)
  end

  def publish(event) when is_map(event) do
    PubSub.broadcast(Synaptic.PubSub, @topic, {:synaptic_monitor_event, event})
  end

  @impl true
  def init(_opts), do: {:ok, %{}}
end
