defmodule Synaptic.MCP.Adapters.HTTP do
  @moduledoc """
  HTTP JSON-RPC adapter for MCP servers.

  Supports both plain JSON-RPC endpoints and the MCP Streamable HTTP transport
  which requires a session handshake (`initialize` → `notifications/initialized`).
  Sessions are lazily established per endpoint and cached in the calling process.
  """

  use Synaptic.MCP.Adapter

  alias Synaptic.MCP.{Connection, Discovery}

  @mcp_session_header "mcp-session-id"
  @client_info %{name: "synaptic", version: "0.3.0"}
  @protocol_version "2025-03-26"

  @impl true
  def discover(%Connection{} = connection, opts \\ []) do
    with :ok <- ensure_session(connection, opts),
         {:ok, result} <- rpc(connection, "tools/list", %{}, opts) do
      tools = normalize_tools(result)

      case rpc(connection, "resources/list", %{}, opts) do
        {:ok, resource_result} ->
          {:ok,
           %Discovery{
             tools: tools,
             resources_supported?: true,
             resources: normalize_resources(resource_result),
             server_info: %{transport: :http},
             warnings: []
           }}

        {:error, :unsupported} ->
          {:ok,
           %Discovery{
             tools: tools,
             resources_supported?: false,
             resources: nil,
             server_info: %{transport: :http},
             warnings: []
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def call_tool(%Connection{} = connection, remote_name, args, opts \\ []) when is_map(args) do
    with :ok <- ensure_session(connection, opts) do
      rpc(connection, "tools/call", %{name: remote_name, arguments: args}, opts)
    end
  end

  @impl true
  def list_resources(%Connection{} = connection, opts \\ []) do
    with :ok <- ensure_session(connection, opts),
         {:ok, result} <- rpc(connection, "resources/list", %{}, opts) do
      {:ok, normalize_resources(result)}
    end
  end

  @impl true
  def read_resource(%Connection{} = connection, uri, opts \\ []) when is_binary(uri) do
    with :ok <- ensure_session(connection, opts) do
      rpc(connection, "resources/read", %{uri: uri}, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Session management (MCP Streamable HTTP)
  # ---------------------------------------------------------------------------

  defp ensure_session(connection, opts) do
    key = session_key(connection)

    case Process.get(key) do
      nil -> initialize_session(connection, opts, key)
      _session_id -> :ok
    end
  end

  defp initialize_session(connection, opts, key) do
    init_params = %{
      protocolVersion: @protocol_version,
      clientInfo: @client_info,
      capabilities: %{}
    }

    case rpc_raw(connection, "initialize", init_params, opts) do
      {:ok, _result, session_id} ->
        # Store session ID, or :none for plain JSON-RPC servers without sessions
        Process.put(key, session_id || :none)

        # Fire-and-forget the initialized notification
        notify(connection, "notifications/initialized", %{}, opts)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp session_key(connection), do: {:mcp_session, endpoint(connection)}

  # ---------------------------------------------------------------------------
  # JSON-RPC transport
  # ---------------------------------------------------------------------------

  defp rpc(connection, method, params, opts) do
    case rpc_raw(connection, method, params, opts) do
      {:ok, result, _session_id} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rpc_raw(%Connection{} = connection, method, params, opts) do
    headers = build_headers(connection)
    body = Jason.encode!(%{jsonrpc: "2.0", id: request_id(), method: method, params: params})
    request = Finch.build(:post, endpoint(connection), headers, body)

    case Finch.request(request, finch(connection, opts), receive_timeout: receive_timeout(connection, opts)) do
      {:ok, %Finch.Response{status: status, body: response_body, headers: resp_headers}}
      when status in [200, 202] ->
        session_id = get_header(resp_headers, @mcp_session_header)

        case parse_rpc_response(response_body) do
          {:ok, result} -> {:ok, result, session_id}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:upstream_error, status, safe_decode(response_body)}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp notify(%Connection{} = connection, method, params, opts) do
    headers = build_headers(connection)
    body = Jason.encode!(%{jsonrpc: "2.0", method: method, params: params})
    request = Finch.build(:post, endpoint(connection), headers, body)
    # Best-effort, ignore response
    Finch.request(request, finch(connection, opts))
    :ok
  end

  defp build_headers(connection) do
    base = [{"content-type", "application/json"}, {"accept", "application/json"}]
    custom = Keyword.get(connection.adapter_opts, :headers, [])

    session_id = Process.get(session_key(connection))

    session_headers =
      if session_id && session_id != :none,
        do: [{@mcp_session_header, session_id}],
        else: []

    base ++ session_headers ++ custom
  end

  defp get_header(headers, name) do
    name_down = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == name_down, do: v
    end)
  end

  # ---------------------------------------------------------------------------
  # Response parsing
  # ---------------------------------------------------------------------------

  defp parse_rpc_response(""), do: {:ok, nil}

  defp parse_rpc_response(body) do
    with {:ok, decoded} <- Jason.decode(body) do
      cond do
        is_map(decoded["error"]) ->
          normalize_rpc_error(decoded["error"])

        Map.has_key?(decoded, "result") ->
          {:ok, decoded["result"]}

        true ->
          {:error, :invalid_response}
      end
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_rpc_error(%{"code" => code, "message" => message} = error) do
    if unsupported_method?(code, message) do
      {:error, :unsupported}
    else
      {:error, {:rpc_error, code, message, Map.get(error, "data")}}
    end
  end

  defp normalize_rpc_error(_), do: {:error, :invalid_response}

  defp unsupported_method?(code, message) do
    code == -32_601 or
      String.contains?(String.downcase(to_string(message || "")), "method not found") or
      String.contains?(String.downcase(to_string(message || "")), "unsupported")
  end

  # ---------------------------------------------------------------------------
  # Normalization helpers
  # ---------------------------------------------------------------------------

  defp normalize_tools(%{"tools" => tools}) when is_list(tools),
    do: Enum.map(tools, &normalize_tool/1)

  defp normalize_tools(tools) when is_list(tools), do: Enum.map(tools, &normalize_tool/1)
  defp normalize_tools(_), do: []

  defp normalize_tool(tool) when is_map(tool) do
    %{
      name: Map.get(tool, "name") || Map.get(tool, :name) || "",
      description: Map.get(tool, "description") || Map.get(tool, :description) || "",
      input_schema:
        Map.get(tool, "inputSchema") ||
          Map.get(tool, :inputSchema) ||
          Map.get(tool, "input_schema") ||
          Map.get(tool, :input_schema) ||
          Map.get(tool, "parameters") ||
          Map.get(tool, :parameters) ||
          %{type: "object", properties: %{}},
      annotations: Map.get(tool, "annotations") || Map.get(tool, :annotations) || %{}
    }
  end

  defp normalize_resources(%{"resources" => resources}) when is_list(resources), do: resources
  defp normalize_resources(resources) when is_list(resources), do: resources
  defp normalize_resources(_), do: []

  defp endpoint(%Connection{} = connection) do
    Keyword.get(connection.adapter_opts, :base_url) ||
      Keyword.get(connection.adapter_opts, :endpoint) ||
      raise ArgumentError, "MCP HTTP adapter requires :base_url or :endpoint"
  end

  defp finch(%Connection{} = connection, opts) do
    Keyword.get(opts, :finch) ||
      Keyword.get(connection.adapter_opts, :finch) ||
      Synaptic.Finch
  end

  @default_receive_timeout 120_000

  defp receive_timeout(%Connection{} = connection, opts) do
    Keyword.get(opts, :receive_timeout) ||
      Keyword.get(connection.adapter_opts, :receive_timeout) ||
      @default_receive_timeout
  end

  defp request_id do
    System.unique_integer([:positive, :monotonic])
  end

  defp safe_decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp safe_decode(other), do: other
end
