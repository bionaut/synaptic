defmodule Synaptic.MCP.Connection do
  @moduledoc """
  Descriptor for one MCP server.
  """

  @enforce_keys [:id, :name, :transport, :adapter, :adapter_opts, :metadata]
  defstruct [:id, :name, :transport, :adapter, :adapter_opts, :metadata]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          transport: atom(),
          adapter: module(),
          adapter_opts: keyword(),
          metadata: map()
        }
end
