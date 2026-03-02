defmodule Synaptic.MCP do
  @moduledoc """
  Facade for MCP connection normalization, discovery, and execution.
  """

  alias Synaptic.MCP.{Connection, Discovery}

  @type connection_entry :: Connection.t() | atom() | map() | keyword()

  @spec normalize_connections([connection_entry()] | connection_entry(), keyword()) ::
          {:ok, [Connection.t()]} | {:error, term()}
  def normalize_connections(entries, opts \\ [])

  def normalize_connections([], _opts), do: {:ok, []}

  def normalize_connections(entries, opts) when is_list(entries) do
    if Keyword.keyword?(entries) do
      normalize_connections([entries], opts)
    else
      entries
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
        case normalize_connection(entry, index, opts) do
          {:ok, connection} -> {:cont, {:ok, acc ++ [connection]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def normalize_connections(entry, opts), do: normalize_connections([entry], opts)

  @spec discover(Connection.t(), keyword()) :: {:ok, Discovery.t()} | {:error, term()}
  def discover(%Connection{} = connection, opts \\ []) do
    metadata = mcp_metadata(connection, opts)

    :telemetry.span([:synaptic, :mcp, :discover], metadata, fn ->
      result = connection.adapter.discover(connection, opts)
      {result, discovery_metadata(result, metadata)}
    end)
  end

  @spec call_tool(Connection.t(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def call_tool(%Connection{} = connection, remote_name, args, opts \\ [])
      when is_binary(remote_name) do
    metadata = mcp_metadata(connection, opts) |> Map.put(:remote_name, remote_name)

    :telemetry.span([:synaptic, :mcp, :tool_call], metadata, fn ->
      result = connection.adapter.call_tool(connection, remote_name, args, opts)
      {result, metadata}
    end)
  end

  @spec list_resources(Connection.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_resources(%Connection{} = connection, opts \\ []) do
    metadata = mcp_metadata(connection, opts)

    :telemetry.span([:synaptic, :mcp, :resource_list], metadata, fn ->
      result = connection.adapter.list_resources(connection, opts)
      {result, list_metadata(result, metadata)}
    end)
  end

  @spec read_resource(Connection.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def read_resource(%Connection{} = connection, uri, opts \\ []) when is_binary(uri) do
    metadata = mcp_metadata(connection, opts) |> Map.put(:uri, uri)

    :telemetry.span([:synaptic, :mcp, :resource_read], metadata, fn ->
      result = connection.adapter.read_resource(connection, uri, opts)
      {result, metadata}
    end)
  end

  @spec server_name(Connection.t()) :: String.t()
  def server_name(%Connection{name: name}), do: name

  defp normalize_connection(%Connection{} = connection, _index, _opts), do: {:ok, connection}

  defp normalize_connection(name, index, opts) when is_atom(name) do
    config =
      configured_servers()
      |> Map.fetch(name)
      |> case do
        {:ok, server_opts} -> {:ok, server_opts}
        :error -> {:error, {:unknown_server, name}}
      end

    with {:ok, server_opts} <- config do
      server_opts
      |> merge_name(name)
      |> normalize_connection(index, opts)
    end
  end

  defp normalize_connection(entry, index, _opts) when is_list(entry) do
    if Keyword.keyword?(entry) do
      entry
      |> Enum.into(%{})
      |> normalize_connection(index, [])
    else
      {:error, {:invalid_connection, entry}}
    end
  end

  defp normalize_connection(%{} = entry, index, _opts) do
    transport = Map.get(entry, :transport, :http)
    adapter = Map.get(entry, :adapter, default_adapter(transport))

    if is_nil(adapter) do
      {:error, {:missing_adapter, entry}}
    else
      {:ok,
       %Connection{
         id: Map.get(entry, :id, "mcp_#{index}"),
         name: normalize_name(Map.get(entry, :name, "mcp_#{index}")),
         transport: transport,
         adapter: adapter,
         adapter_opts: normalize_adapter_opts(entry),
         metadata: Map.get(entry, :metadata, %{})
       }}
    end
  end

  defp normalize_connection(other, _index, _opts), do: {:error, {:invalid_connection, other}}

  defp normalize_adapter_opts(entry) do
    entry
    |> Map.drop([:id, :name, :transport, :adapter, :metadata])
    |> Enum.into([])
  end

  defp configured_servers do
    Application.get_env(:synaptic, __MODULE__, [])
    |> Keyword.get(:servers, [])
    |> Enum.into(%{}, fn
      {name, opts} -> {name, Map.new(opts)}
    end)
  end

  defp merge_name(config, name) do
    Map.put_new(config, :name, Atom.to_string(name))
  end

  defp default_adapter(:http), do: Synaptic.MCP.Adapters.HTTP
  defp default_adapter(_), do: nil

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> "mcp"
      normalized -> normalized
    end
  end

  defp mcp_metadata(connection, opts) do
    %{
      server: connection.name,
      transport: connection.transport,
      run_id: Keyword.get(opts, :run_id) || get_from_context(:__run_id__),
      step_name: Keyword.get(opts, :step_name) || get_from_context(:__step_name__)
    }
  end

  defp discovery_metadata({:ok, %Discovery{} = discovery}, metadata) do
    metadata
    |> Map.put(:tool_count, length(discovery.tools))
    |> Map.put(:resources_supported, discovery.resources_supported?)
  end

  defp discovery_metadata(_, metadata), do: metadata

  defp list_metadata({:ok, resources}, metadata) when is_list(resources) do
    Map.put(metadata, :resource_count, length(resources))
  end

  defp list_metadata(_, metadata), do: metadata

  defp get_from_context(key) do
    case Process.get({:synaptic_context, key}) do
      nil -> nil
      value -> value
    end
  end
end
