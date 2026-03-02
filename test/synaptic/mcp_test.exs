defmodule Synaptic.MCPTest do
  use ExUnit.Case, async: true

  alias Synaptic.MCP
  alias Synaptic.MCP.Connection

  setup do
    original = Application.get_env(:synaptic, Synaptic.MCP)

    Application.put_env(:synaptic, Synaptic.MCP,
      servers: [
        github: [
          transport: :http,
          adapter: Synaptic.MCP.Adapters.HTTP,
          base_url: "http://localhost:4001/mcp"
        ]
      ]
    )

    on_exit(fn ->
      if original do
        Application.put_env(:synaptic, Synaptic.MCP, original)
      else
        Application.delete_env(:synaptic, Synaptic.MCP)
      end
    end)

    :ok
  end

  test "normalizes named server config into connections" do
    assert {:ok, [%Connection{} = connection]} = MCP.normalize_connections([:github])
    assert connection.name == "github"
    assert connection.transport == :http
    assert connection.adapter == Synaptic.MCP.Adapters.HTTP
    assert connection.adapter_opts[:base_url] == "http://localhost:4001/mcp"
  end

  test "normalizes map and keyword server descriptors" do
    assert {:ok, [map_connection, keyword_connection]} =
             MCP.normalize_connections([
               %{
                 name: "Docs API",
                 transport: :http,
                 adapter: Synaptic.MCP.Adapters.HTTP,
                 base_url: "http://docs"
               },
               [
                 name: "CLI Docs",
                 transport: :http,
                 adapter: Synaptic.MCP.Adapters.HTTP,
                 base_url: "http://cli"
               ]
             ])

    assert map_connection.name == "docs_api"
    assert keyword_connection.name == "cli_docs"
  end

  test "returns an error for unknown named servers" do
    assert {:error, {:unknown_server, :missing}} = MCP.normalize_connections([:missing])
  end
end
