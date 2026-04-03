defmodule Synaptic.Local.EgressGatewaySmokeTest do
  use ExUnit.Case, async: false

  alias Synaptic.MCP
  alias Synaptic.MCP.Adapters.HTTP
  alias Synaptic.MCP.Connection
  alias Synaptic.Tools.OpenAI

  test "shows blocked vs allowlisted outbound chat and managed MCP session binding" do
    chat_bypass = Bypass.open()
    mcp_bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect_once(chat_bypass, "POST", "/chat", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, ~s({"choices":[{"message":{"content":"hello from smoke"}}]}))
    end)

    Bypass.expect(mcp_bypass, "POST", "/mcp", fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-synaptic-session-binding") != []

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      current = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)

      response =
        case {current, payload["method"]} do
          {1, "initialize"} ->
            %{
              "jsonrpc" => "2.0",
              "id" => payload["id"],
              "result" => %{
                "protocolVersion" => "2025-03-26",
                "serverInfo" => %{"name" => "smoke", "version" => "1.0.0"},
                "capabilities" => %{}
              }
            }

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
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> maybe_put_session_header(current)
        |> Plug.Conn.resp(200, Jason.encode!(response))
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    assert {:error, {:egress_blocked, _detail}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "hello"}],
               adapter: OpenAI,
               endpoint: "http://localhost:#{chat_bypass.port}/chat",
               api_key: "test-key",
               finch: Synaptic.Finch,
               egress: [enabled: true]
             )

    assert {:ok, "hello from smoke"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "hello"}],
               adapter: OpenAI,
               endpoint: "http://localhost:#{chat_bypass.port}/chat",
               api_key: "test-key",
               finch: Synaptic.Finch,
               egress: [
                 enabled: true,
                 openai: [
                   allow_hosts: ["localhost"],
                   allow_localhost: true,
                   allow_schemes: ["http"]
                 ]
               ]
             )

    connection = %Connection{
      id: "mcp_smoke",
      name: "smoke",
      transport: :http,
      adapter: HTTP,
      adapter_opts: [base_url: "http://localhost:#{mcp_bypass.port}/mcp", finch: Synaptic.Finch],
      metadata: %{managed: true}
    }

    assert {:error, {:egress_blocked, _detail}} =
             MCP.discover(connection, egress: [enabled: true])

    assert {:ok, _discovery} =
             MCP.discover(
               connection,
               run_id: "smoke-run",
               egress: [
                 enabled: true,
                 mcp: [allow_hosts: ["localhost"], allow_localhost: true, allow_schemes: ["http"]]
               ],
               connector_gateway: [
                 enabled: true,
                 managed_only: true,
                 session_binding: [enabled: true, require_run_id: true]
               ]
             )
  end

  defp maybe_put_session_header(conn, 1 = _init_request) do
    Plug.Conn.put_resp_header(conn, "mcp-session-id", "smoke-session")
  end

  defp maybe_put_session_header(conn, _), do: conn
end
