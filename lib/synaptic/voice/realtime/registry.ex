defmodule Synaptic.Voice.Realtime.Registry do
  @moduledoc false

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  def via(session_id), do: {:via, Registry, {__MODULE__, session_id}}
end
