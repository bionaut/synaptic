defmodule Synaptic.MCP.Adapter do
  @moduledoc """
  Behaviour for MCP transport adapters.
  """

  alias Synaptic.MCP.{Connection, Discovery}

  @callback discover(Connection.t(), keyword()) :: {:ok, Discovery.t()} | {:error, term()}
  @callback call_tool(Connection.t(), String.t(), map(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback list_resources(Connection.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback read_resource(Connection.t(), String.t(), keyword()) ::
              {:ok, term()} | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Synaptic.MCP.Adapter
    end
  end
end
