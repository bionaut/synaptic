defmodule Synapse.Registry do
  @moduledoc false

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  def via(run_id), do: {:via, Registry, {__MODULE__, run_id}}

  def entries do
    Registry.select(__MODULE__, [{{:"$1", :_, :_}, [], [{{:"$1", :"$_"}}]}])
  end
end
