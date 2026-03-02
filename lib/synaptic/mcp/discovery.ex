defmodule Synaptic.MCP.Discovery do
  @moduledoc """
  Normalized MCP server discovery result.
  """

  @enforce_keys [:tools, :resources_supported?, :resources, :server_info, :warnings]
  defstruct tools: [],
            resources_supported?: false,
            resources: nil,
            server_info: %{},
            warnings: []

  @type tool :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:input_schema) => map(),
          optional(:annotations) => map()
        }

  @type t :: %__MODULE__{
          tools: [tool()],
          resources_supported?: boolean(),
          resources: list(map()) | nil,
          server_info: map(),
          warnings: [term()]
        }
end
