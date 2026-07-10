defmodule Synaptic.Voice.SessionRegistry do
  @moduledoc """
  Unified registry for all voice sessions keyed by session id.
  """

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  def via(session_id, metadata \\ %{}) when is_binary(session_id) and is_map(metadata) do
    {:via, Registry, {__MODULE__, session_id, metadata}}
  end
end
