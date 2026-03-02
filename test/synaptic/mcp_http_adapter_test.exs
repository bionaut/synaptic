defmodule Synaptic.MCPHTTPAdapterTest do
  use ExUnit.Case, async: true

  alias Synaptic.MCP.Connection
  alias Synaptic.MCP.Adapters.HTTP

  setup do
    bypass = Bypass.open()

    connection = %Connection{
      id: "mcp_1",
      name: "github",
      transport: :http,
      adapter: HTTP,
      adapter_opts: [base_url: endpoint_url(bypass.port), finch: Synaptic.Finch],
      metadata: %{}
    }

    {:ok, bypass: bypass, connection: connection}
  end

  test "discover returns tools and resources support", %{bypass: bypass, connection: connection} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      current = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)

      response =
        case {current, payload["method"]} do
          {1, "initialize"} ->
            init_response(payload["id"])

          {2, "notifications/initialized"} ->
            nil

          {3, "tools/list"} ->
            %{
              "jsonrpc" => "2.0",
              "id" => payload["id"],
              "result" => %{
                "tools" => [
                  %{
                    "name" => "search_issues",
                    "description" => "Searches issues",
                    "inputSchema" => %{"type" => "object", "properties" => %{}}
                  }
                ]
              }
            }

          {4, "resources/list"} ->
            %{
              "jsonrpc" => "2.0",
              "id" => payload["id"],
              "result" => %{
                "resources" => [
                  %{"uri" => "file:///guide.md", "name" => "Guide"}
                ]
              }
            }
        end

      if response do
        conn
        |> maybe_put_session_header(current)
        |> Plug.Conn.resp(200, Jason.encode!(response))
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    assert {:ok, discovery} = HTTP.discover(connection)
    assert [%{name: "search_issues"}] = discovery.tools
    assert discovery.resources_supported?
    assert [%{"uri" => "file:///guide.md", "name" => "Guide"}] = discovery.resources
    assert Agent.get(counter, & &1) == 4
  end

  test "discover handles unsupported resources", %{bypass: bypass, connection: connection} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      current = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)

      response =
        case {current, payload["method"]} do
          {1, "initialize"} ->
            init_response(payload["id"])

          {2, "notifications/initialized"} ->
            nil

          {3, "tools/list"} ->
            %{"jsonrpc" => "2.0", "id" => payload["id"], "result" => %{"tools" => []}}

          {4, "resources/list"} ->
            %{
              "jsonrpc" => "2.0",
              "id" => payload["id"],
              "error" => %{"code" => -32_601, "message" => "Method not found"}
            }
        end

      if response do
        conn
        |> maybe_put_session_header(current)
        |> Plug.Conn.resp(200, Jason.encode!(response))
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    assert {:ok, discovery} = HTTP.discover(connection)
    refute discovery.resources_supported?
    assert Agent.get(counter, & &1) == 4
  end

  test "call_tool returns upstream errors", %{bypass: bypass, connection: connection} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      current = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)

      case {current, payload["method"]} do
        {1, "initialize"} ->
          conn
          |> maybe_put_session_header(current)
          |> Plug.Conn.resp(200, Jason.encode!(init_response(payload["id"])))

        {2, "notifications/initialized"} ->
          Plug.Conn.resp(conn, 202, "")

        {3, "tools/call"} ->
          Plug.Conn.resp(conn, 500, ~s({"oops":true}))
      end
    end)

    assert {:error, {:upstream_error, 500, %{"oops" => true}}} =
             HTTP.call_tool(connection, "search_issues", %{"query" => "bugs"})
  end

  test "list_resources handles invalid json responses", %{bypass: bypass, connection: connection} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      current = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)

      case {current, payload["method"]} do
        {1, "initialize"} ->
          conn
          |> maybe_put_session_header(current)
          |> Plug.Conn.resp(200, Jason.encode!(init_response(payload["id"])))

        {2, "notifications/initialized"} ->
          Plug.Conn.resp(conn, 202, "")

        {3, "resources/list"} ->
          Plug.Conn.resp(conn, 200, "not-json")
      end
    end)

    assert {:error, :invalid_response} = HTTP.list_resources(connection)
  end

  test "read_resource returns rpc results", %{bypass: bypass, connection: connection} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      current = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)

      case {current, payload["method"]} do
        {1, "initialize"} ->
          conn
          |> maybe_put_session_header(current)
          |> Plug.Conn.resp(200, Jason.encode!(init_response(payload["id"])))

        {2, "notifications/initialized"} ->
          Plug.Conn.resp(conn, 202, "")

        {3, "resources/read"} ->
          assert %{"params" => %{"uri" => "file:///guide.md"}} = payload

          Plug.Conn.resp(
            conn,
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => payload["id"],
              "result" => %{"contents" => [%{"text" => "guide"}]}
            })
          )
      end
    end)

    assert {:ok, %{"contents" => [%{"text" => "guide"}]}} =
             HTTP.read_resource(connection, "file:///guide.md")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp init_response(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-03-26",
        "serverInfo" => %{"name" => "test-server", "version" => "1.0.0"},
        "capabilities" => %{}
      }
    }
  end

  defp maybe_put_session_header(conn, 1 = _init_request) do
    Plug.Conn.put_resp_header(conn, "mcp-session-id", "test-session-#{:rand.uniform(1000)}")
  end

  defp maybe_put_session_header(conn, _), do: conn

  defp endpoint_url(port), do: "http://localhost:#{port}/mcp"
end
