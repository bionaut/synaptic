defmodule Synaptic.Tools do
  @moduledoc """
  Helper utilities for invoking LLM providers from workflow steps.
  """

  require Logger

  alias Synaptic.{MCP, MCP.Connection}
  alias Synaptic.Tools.Tool

  @default_adapter Synaptic.Tools.OpenAI

  @doc """
  Dispatches a chat completion request to the configured adapter.

  Pass `agent: :name` to pull default options (model, temperature, adapter,
  etc.) from the `:agents` configuration. Provide `tools: [...]` with
  `%Synaptic.Tools.Tool{}` structs (or maps/keywords convertible via
  `Synaptic.Tools.Tool.new/1`) to enable tool-calling flows. Provide `mcp: [...]`
  with MCP server descriptors to expose remote tools and MCP resource browsing.

  When `stream: true` is passed, the response will be streamed and PubSub events
  will be emitted for each chunk. Note: streaming automatically falls back to
  non-streaming mode when tools are provided, as OpenAI streaming doesn't support
  tool calling.
  """
  def chat(messages, opts \\ []) when is_list(messages) do
    {agent_opts, call_opts} = agent_options(opts)
    merged_opts = Keyword.merge(agent_opts, call_opts)

    {tools, merged_opts} = Keyword.pop(merged_opts, :tools, [])
    {mcp_entries, merged_opts} = Keyword.pop(merged_opts, :mcp, [])

    local_tools = normalize_tools(tools)

    with {:ok, registry_entries, llm_specs} <-
           build_tool_registry(local_tools, mcp_entries, merged_opts) do
      adapter = Keyword.get(merged_opts, :adapter, configured_adapter())
      stream_enabled = Keyword.get(merged_opts, :stream, false)
      tools_present? = registry_entries != []

      if stream_enabled and tools_present? do
        require Logger

        Logger.warning(
          "Streaming requested but tools are provided. Falling back to non-streaming mode (OpenAI limitation)."
        )

        adapter_opts =
          merged_opts
          |> Keyword.delete(:stream)
          |> maybe_put_adapter_tools(llm_specs)

        do_chat(adapter, messages, adapter_opts, registry_entries)
      else
        adapter_opts = maybe_put_adapter_tools(merged_opts, llm_specs)

        if stream_enabled do
          do_chat_stream(adapter, messages, adapter_opts)
        else
          do_chat(adapter, messages, adapter_opts, registry_entries)
        end
      end
    end
  end

  defp do_chat(adapter, messages, opts, []),
    do: do_chat_with_telemetry(adapter, messages, opts, [])

  defp do_chat(adapter, messages, opts, registry_entries) do
    max_tool_rounds = Keyword.get(opts, :max_tool_rounds, 8)
    do_chat(adapter, messages, opts, registry_entries, max_tool_rounds)
  end

  defp do_chat(adapter, messages, opts, registry_entries, remaining_tool_rounds) do
    registry = Map.new(registry_entries, &{&1.llm_name, &1})

    case do_chat_with_telemetry(adapter, messages, opts, registry_entries) do
      {:ok, %{tool_calls: tool_calls} = message} when is_list(tool_calls) and tool_calls != [] ->
        continue_after_tool_calls(
          adapter,
          messages,
          message,
          tool_calls,
          registry,
          opts,
          registry_entries,
          remaining_tool_rounds
        )

      {:ok, %{tool_calls: tool_calls} = message, _usage}
      when is_list(tool_calls) and tool_calls != [] ->
        continue_after_tool_calls(
          adapter,
          messages,
          message,
          tool_calls,
          registry,
          opts,
          registry_entries,
          remaining_tool_rounds
        )

      {:ok, %{"tool_calls" => tool_calls} = message}
      when is_list(tool_calls) and tool_calls != [] ->
        continue_after_tool_calls(
          adapter,
          messages,
          message,
          tool_calls,
          registry,
          opts,
          registry_entries,
          remaining_tool_rounds
        )

      {:ok, %{"tool_calls" => tool_calls} = message, _usage}
      when is_list(tool_calls) and tool_calls != [] ->
        continue_after_tool_calls(
          adapter,
          messages,
          message,
          tool_calls,
          registry,
          opts,
          registry_entries,
          remaining_tool_rounds
        )

      other ->
        other
    end
  end

  defp continue_after_tool_calls(
         _adapter,
         _messages,
         _message,
         tool_calls,
         _registry,
         _opts,
         _registry_entries,
         remaining_tool_rounds
       )
       when remaining_tool_rounds <= 0 do
    {:error, {:max_tool_rounds_exceeded, tool_call_names(tool_calls)}}
  end

  defp continue_after_tool_calls(
         adapter,
         messages,
         message,
         _tool_calls,
         registry,
         opts,
         registry_entries,
         remaining_tool_rounds
       ) do
    new_messages = apply_tool_calls(messages, message, registry, opts)
    do_chat(adapter, new_messages, opts, registry_entries, remaining_tool_rounds - 1)
  end

  defp do_chat_with_telemetry(adapter, messages, opts, _tools) do
    run_id = Keyword.get(opts, :run_id) || get_from_context(:__run_id__)
    step_name = Keyword.get(opts, :step_name) || get_from_context(:__step_name__)
    model = Keyword.get(opts, :model) || "unknown"
    stream = Keyword.get(opts, :stream, false)

    metadata = %{
      run_id: run_id,
      step_name: step_name,
      adapter: adapter,
      model: model,
      stream: stream
    }

    :telemetry.span(
      [:synaptic, :llm],
      metadata,
      fn ->
        adapter_result = adapter.chat(messages, opts)
        updated_metadata = extract_telemetry_metadata(adapter_result, metadata)
        {strip_usage(adapter_result), updated_metadata}
      end
    )
  end

  defp extract_telemetry_metadata({:ok, _content, %{usage: usage}}, metadata)
       when is_map(usage) do
    metadata
    |> Map.put(:usage, usage)
    |> Map.put(
      :prompt_tokens,
      Map.get(usage, :prompt_tokens) || Map.get(usage, "prompt_tokens") || 0
    )
    |> Map.put(
      :completion_tokens,
      Map.get(usage, :completion_tokens) || Map.get(usage, "completion_tokens") || 0
    )
    |> Map.put(
      :total_tokens,
      Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") || 0
    )
  end

  defp extract_telemetry_metadata({:ok, _content}, metadata), do: metadata
  defp extract_telemetry_metadata({:error, _reason}, metadata), do: metadata

  defp strip_usage({:ok, content, %{usage: _usage}}), do: {:ok, content}
  defp strip_usage({:ok, content, _other}), do: {:ok, content}
  defp strip_usage(other), do: other

  defp do_chat_stream(adapter, messages, opts) do
    run_id = Keyword.get(opts, :run_id) || get_from_context(:__run_id__)
    step_name = Keyword.get(opts, :step_name) || get_from_context(:__step_name__)
    model = Keyword.get(opts, :model) || "unknown"

    metadata = %{
      run_id: run_id,
      step_name: step_name,
      adapter: adapter,
      model: model,
      stream: true
    }

    on_chunk = fn chunk, accumulated ->
      publish_stream_chunk(run_id, step_name, chunk, accumulated)
    end

    adapter_opts = Keyword.put(opts, :on_chunk, on_chunk)

    :telemetry.span(
      [:synaptic, :llm],
      metadata,
      fn ->
        adapter_result = adapter.chat(messages, adapter_opts)

        case adapter_result do
          {:ok, accumulated} = ok_result ->
            if run_id do
              publish_stream_done(run_id, step_name, accumulated)
            end

            {ok_result, metadata}

          {:ok, accumulated, %{usage: usage}} = ok_result ->
            if run_id do
              publish_stream_done(run_id, step_name, accumulated)
            end

            updated_metadata =
              metadata
              |> Map.put(:usage, usage)
              |> Map.put(
                :prompt_tokens,
                Map.get(usage, :prompt_tokens) || Map.get(usage, "prompt_tokens") || 0
              )
              |> Map.put(
                :completion_tokens,
                Map.get(usage, :completion_tokens) || Map.get(usage, "completion_tokens") || 0
              )
              |> Map.put(
                :total_tokens,
                Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") || 0
              )

            {ok_result, updated_metadata}

          error ->
            {error, metadata}
        end
      end
    )
  end

  defp get_from_context(key) do
    case Process.get({:synaptic_context, key}) do
      nil -> nil
      value -> value
    end
  end

  defp publish_stream_chunk(nil, _step_name, _chunk, _accumulated), do: :ok

  defp publish_stream_chunk(run_id, step_name, chunk, accumulated) do
    alias Phoenix.PubSub

    event = %{
      event: :stream_chunk,
      step: step_name,
      chunk: chunk,
      accumulated: accumulated,
      run_id: run_id,
      current_step: step_name
    }

    PubSub.broadcast(Synaptic.PubSub, "synaptic:run:" <> run_id, {:synaptic_event, event})
  end

  defp publish_stream_done(nil, _step_name, _accumulated), do: :ok

  defp publish_stream_done(run_id, step_name, accumulated) do
    alias Phoenix.PubSub

    event = %{
      event: :stream_done,
      step: step_name,
      accumulated: accumulated,
      run_id: run_id,
      current_step: step_name
    }

    PubSub.broadcast(Synaptic.PubSub, "synaptic:run:" <> run_id, {:synaptic_event, event})
  end

  defp agent_options(opts) do
    {agent_name, remaining_opts} = Keyword.pop(opts, :agent)

    agent_opts =
      case agent_name do
        nil -> []
        name -> lookup_agent_opts(name)
      end

    {agent_opts, remaining_opts}
  end

  defp lookup_agent_opts(name) do
    agents = configured_agents()
    key = agent_key(name)

    case Map.fetch(agents, key) do
      {:ok, opts} -> opts
      :error -> raise ArgumentError, "unknown Synaptic agent #{inspect(name)}"
    end
  end

  defp configured_agents do
    Application.get_env(:synaptic, __MODULE__, [])
    |> Keyword.get(:agents, %{})
    |> normalize_agents()
  end

  defp configured_adapter do
    Application.get_env(:synaptic, __MODULE__, [])
    |> Keyword.get(:llm_adapter, @default_adapter)
  end

  defp normalize_agents(%{} = agents) do
    Enum.reduce(agents, %{}, fn {name, opts}, acc ->
      Map.put(acc, agent_key(name), normalize_agent_opts(opts))
    end)
  end

  defp normalize_agents(list) when is_list(list) do
    Enum.reduce(list, %{}, fn {name, opts}, acc ->
      Map.put(acc, agent_key(name), normalize_agent_opts(opts))
    end)
  end

  defp normalize_agents(_), do: %{}

  defp normalize_agent_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "agent options must be a keyword list, got: #{inspect(opts)}"
    end
  end

  defp normalize_agent_opts(%{} = opts) do
    opts
    |> Map.to_list()
    |> normalize_agent_opts()
  end

  defp normalize_agent_opts(other) do
    raise ArgumentError, "agent options must be a keyword list, got: #{inspect(other)}"
  end

  defp agent_key(name) when is_atom(name), do: Atom.to_string(name)
  defp agent_key(name) when is_binary(name) and byte_size(name) > 0, do: name

  defp agent_key(name) do
    raise ArgumentError, "agent names must be atoms or strings, got: #{inspect(name)}"
  end

  defp normalize_tools([]), do: []

  defp normalize_tools(tools) when is_list(tools) do
    Enum.map(tools, &Tool.new/1)
  end

  defp normalize_tools(tool), do: [Tool.new(tool)]

  defp build_tool_registry(local_tools, mcp_entries, opts) do
    with {:ok, connections} <- MCP.normalize_connections(mcp_entries, opts),
         {:ok, mcp_registry} <- build_mcp_registry(connections, opts),
         {:ok, registry} <-
           merge_registry_entries(build_local_registry(local_tools), mcp_registry) do
      {:ok, registry, Enum.map(registry, & &1.llm_spec)}
    end
  end

  defp build_local_registry(local_tools) do
    Enum.map(local_tools, fn tool ->
      %{
        llm_name: tool.name,
        llm_spec: Tool.to_openai(tool),
        dispatch: {:local, tool},
        source: %{type: :local, server: nil, remote_name: tool.name}
      }
    end)
  end

  defp build_mcp_registry([], _opts), do: {:ok, []}

  defp build_mcp_registry(connections, opts) do
    connections
    |> uniquify_server_names()
    |> Enum.reduce_while({:ok, []}, fn connection, {:ok, acc} ->
      case MCP.discover(connection, opts) do
        {:ok, discovery} ->
          maybe_log_mcp_discovery(connection, discovery, opts)

          entries =
            build_mcp_tool_entries(connection, discovery.tools) ++
              build_mcp_resource_entries(connection, discovery.resources_supported?)

          {:cont, {:ok, acc ++ entries}}

        {:error, reason} ->
          {:halt, {:error, {:mcp_discovery_failed, connection.name, reason}}}
      end
    end)
  end

  defp uniquify_server_names(connections) do
    {reversed, _counts} =
      Enum.reduce(connections, {[], %{}}, fn %Connection{name: name} = connection,
                                             {acc, counts} ->
        count = Map.get(counts, name, 0) + 1
        unique_name = if count == 1, do: name, else: "#{name}_#{count}"
        {[Map.put(connection, :name, unique_name) | acc], Map.put(counts, name, count)}
      end)

    Enum.reverse(reversed)
  end

  defp build_mcp_tool_entries(connection, tools) do
    Enum.map(tools, fn tool ->
      remote_name = tool_name(tool)
      llm_name = "#{connection.name}__#{remote_name}"

      %{
        llm_name: llm_name,
        llm_spec: %{
          type: "function",
          function: %{
            name: llm_name,
            description: tool_description(tool),
            parameters: tool_schema(tool)
          }
        },
        dispatch: {:mcp_tool, connection, remote_name},
        source: %{type: :mcp, server: connection.name, remote_name: remote_name}
      }
    end)
  end

  defp build_mcp_resource_entries(_connection, false), do: []

  defp build_mcp_resource_entries(connection, true) do
    [
      %{
        llm_name: "#{connection.name}__list_resources",
        llm_spec: %{
          type: "function",
          function: %{
            name: "#{connection.name}__list_resources",
            description: "Lists resources available from the #{connection.name} MCP server.",
            parameters: %{type: "object", properties: %{}}
          }
        },
        dispatch: {:mcp_list_resources, connection},
        source: %{type: :mcp, server: connection.name, remote_name: "list_resources"}
      },
      %{
        llm_name: "#{connection.name}__read_resource",
        llm_spec: %{
          type: "function",
          function: %{
            name: "#{connection.name}__read_resource",
            description: "Reads one resource from the #{connection.name} MCP server by URI.",
            parameters: %{
              type: "object",
              properties: %{uri: %{type: "string", description: "The resource URI to read."}},
              required: ["uri"]
            }
          }
        },
        dispatch: {:mcp_read_resource, connection},
        source: %{type: :mcp, server: connection.name, remote_name: "read_resource"}
      }
    ]
  end

  defp merge_registry_entries(local_registry, mcp_registry) do
    all_entries = local_registry ++ mcp_registry

    all_entries
    |> Enum.reduce_while({:ok, MapSet.new()}, fn entry, {:ok, seen} ->
      if MapSet.member?(seen, entry.llm_name) do
        {:halt, {:error, {:duplicate_tool_name, entry.llm_name}}}
      else
        {:cont, {:ok, MapSet.put(seen, entry.llm_name)}}
      end
    end)
    |> case do
      {:ok, _seen} -> {:ok, all_entries}
      error -> error
    end
  end

  defp maybe_put_adapter_tools(opts, []), do: opts
  defp maybe_put_adapter_tools(opts, llm_specs), do: Keyword.put(opts, :tools, llm_specs)

  defp tool_name(tool) do
    Map.get(tool, :name) || Map.get(tool, "name") || ""
  end

  defp tool_description(tool) do
    Map.get(tool, :description) || Map.get(tool, "description") || ""
  end

  defp tool_schema(tool) do
    schema =
      Map.get(tool, :input_schema) ||
        Map.get(tool, "input_schema") ||
        Map.get(tool, "inputSchema") ||
        %{type: "object", properties: %{}}

    sanitize_schema_for_openai(schema)
  end

  # OpenAI function calling requires top-level type: "object" and forbids
  # oneOf/anyOf/allOf/enum/not at the root. We recursively sanitize schemas
  # so that MCP tools with rich JSON Schema work with OpenAI.
  defp sanitize_schema_for_openai(schema) when is_map(schema) do
    schema
    |> collapse_root_combinators()
    |> strip_top_level_combinators()
    |> ensure_object_type()
    |> sanitize_properties()
  end

  defp sanitize_schema_for_openai(other), do: other

  defp collapse_root_combinators(schema) do
    combo = Map.get(schema, "anyOf") || Map.get(schema, "oneOf") || Map.get(schema, "allOf")
    type = Map.get(schema, "type") || Map.get(schema, :type)

    cond do
      # No combinators — nothing to do
      !is_list(combo) or combo == [] ->
        schema

      # Schema already has type: "object" — merge properties from variants into
      # the existing schema rather than replacing it wholesale
      type == "object" ->
        existing_props = Map.get(schema, "properties") || Map.get(schema, :properties) || %{}
        existing_required = Map.get(schema, "required") || Map.get(schema, :required) || []

        {merged_props, merged_required} =
          Enum.reduce(combo, {existing_props, existing_required}, fn variant, {props, req} ->
            if is_map(variant) do
              vp = Map.get(variant, "properties") || Map.get(variant, :properties) || %{}
              vr = Map.get(variant, "required") || Map.get(variant, :required) || []
              {Map.merge(props, vp), Enum.uniq(req ++ vr)}
            else
              {props, req}
            end
          end)

        schema
        |> Map.put("properties", merged_props)
        |> Map.drop([:properties])
        |> then(fn s ->
          if merged_required != [], do: Map.put(s, "required", merged_required), else: s
        end)

      # No type: "object" — pick the best variant and replace
      true ->
        chosen =
          Enum.find(combo, fn variant ->
            t = Map.get(variant, "type") || Map.get(variant, :type)
            t == "object"
          end) || List.first(combo)

        chosen = if is_map(chosen), do: chosen, else: %{"type" => "object", "properties" => %{}}
        inherited_description = Map.get(schema, "description") || Map.get(schema, :description)
        inherited_title = Map.get(schema, "title") || Map.get(schema, :title)

        chosen
        |> maybe_put_if_missing("description", inherited_description)
        |> maybe_put_if_missing("title", inherited_title)
    end
  end

  defp ensure_object_type(schema) do
    type = Map.get(schema, "type") || Map.get(schema, :type)

    if type == "object" do
      schema
    else
      # Wrap non-object or union schemas into an object with the original as
      # a single property so OpenAI accepts them.
      %{
        "type" => "object",
        "properties" => %{"value" => strip_top_level_combinators(schema)},
        "required" => ["value"]
      }
    end
  end

  defp sanitize_properties(schema) do
    props =
      Map.get(schema, "properties") || Map.get(schema, :properties) || %{}

    sanitized_props =
      Map.new(props, fn {key, prop_schema} ->
        {key, sanitize_property(prop_schema)}
      end)

    schema
    |> Map.put("properties", sanitized_props)
    |> Map.delete("enum")
    |> Map.delete("not")
    |> Map.drop([:properties])
  end

  defp sanitize_property(schema) when is_map(schema) do
    cond do
      # anyOf/oneOf at property level — pick first variant or flatten to string
      combo = Map.get(schema, "anyOf") || Map.get(schema, "oneOf") ->
        pick_best_variant(combo, schema)

      # Nested object — recurse
      (Map.get(schema, "type") || Map.get(schema, :type)) == "object" ->
        sanitize_properties(schema)

      # Array items may need sanitization
      (Map.get(schema, "type") || Map.get(schema, :type)) == "array" ->
        items = Map.get(schema, "items") || Map.get(schema, :items)

        if is_map(items) do
          Map.put(schema, "items", sanitize_property(items))
        else
          schema
        end

      true ->
        schema
    end
  end

  defp sanitize_property(other), do: other

  defp pick_best_variant(variants, original_schema) when is_list(variants) do
    # Prefer the first non-null typed variant; fall back to string
    best =
      Enum.find(variants, fn v ->
        t = Map.get(v, "type") || Map.get(v, :type)
        t != nil and t != "null"
      end)

    description =
      Map.get(original_schema, "description") || Map.get(original_schema, :description)

    base = sanitize_property(best || %{"type" => "string"})
    if description, do: Map.put(base, "description", description), else: base
  end

  defp strip_top_level_combinators(schema) do
    Map.drop(schema, [
      "oneOf",
      "anyOf",
      "allOf",
      "enum",
      "not",
      :oneOf,
      :anyOf,
      :allOf,
      :enum,
      :not
    ])
  end

  defp maybe_put_if_missing(map, _key, nil), do: map

  defp maybe_put_if_missing(map, key, value) do
    if Map.has_key?(map, key) do
      map
    else
      Map.put(map, key, value)
    end
  end

  defp apply_tool_calls(messages, message, registry, opts) do
    assistant_msg = %{
      role: "assistant",
      content: Map.get(message, :content) || Map.get(message, "content"),
      tool_calls: Map.get(message, :tool_calls) || Map.get(message, "tool_calls")
    }

    tool_messages =
      assistant_msg.tool_calls
      |> Enum.map(&execute_tool_call(&1, registry, opts))

    messages ++ [assistant_msg | tool_messages]
  end

  defp execute_tool_call(call, registry, opts) do
    function = Map.get(call, "function") || Map.get(call, :function) || %{}
    name = Map.get(function, "name") || Map.get(function, :name)
    raw_args = Map.get(function, "arguments") || Map.get(function, :arguments) || "{}"
    id = Map.get(call, "id") || Map.get(call, :id)
    entry = Map.fetch!(registry, name)
    args = decode_tool_args(raw_args)
    result = dispatch_tool_call(entry, args, opts)

    %{
      role: "tool",
      tool_call_id: id,
      name: name,
      content: encode_tool_result(result)
    }
  end

  defp dispatch_tool_call(%{dispatch: {:local, tool}}, args, _opts) do
    tool.handler.(args)
  end

  defp dispatch_tool_call(%{dispatch: {:mcp_tool, connection, remote_name}} = entry, args, opts) do
    maybe_log_mcp_request(entry, args, opts)

    case MCP.call_tool(connection, remote_name, args, opts) do
      {:ok, result} ->
        maybe_log_mcp_result(entry, {:ok, result}, opts)
        normalize_mcp_result(result)

      {:error, reason} ->
        maybe_log_mcp_result(entry, {:error, reason}, opts)
        mcp_error_payload(entry, "tool_call_failed", inspect(reason))
    end
  end

  defp dispatch_tool_call(%{dispatch: {:mcp_list_resources, connection}} = entry, _args, opts) do
    maybe_log_mcp_request(entry, %{}, opts)

    case MCP.list_resources(connection, opts) do
      {:ok, resources} ->
        maybe_log_mcp_result(entry, {:ok, resources}, opts)
        resources

      {:error, reason} ->
        maybe_log_mcp_result(entry, {:error, reason}, opts)
        mcp_error_payload(entry, "tool_call_failed", inspect(reason))
    end
  end

  defp dispatch_tool_call(%{dispatch: {:mcp_read_resource, connection}} = entry, args, opts) do
    uri = Map.get(args, "uri") || Map.get(args, :uri)

    if is_binary(uri) and String.trim(uri) != "" do
      maybe_log_mcp_request(entry, %{"uri" => uri}, opts)

      case MCP.read_resource(connection, uri, opts) do
        {:ok, result} ->
          maybe_log_mcp_result(entry, {:ok, result}, opts)
          normalize_mcp_result(result)

        {:error, reason} ->
          maybe_log_mcp_result(entry, {:error, reason}, opts)
          mcp_error_payload(entry, "tool_call_failed", inspect(reason))
      end
    else
      mcp_error_payload(entry, "invalid_arguments", "MCP read_resource requires a non-empty uri")
    end
  end

  defp decode_tool_args(raw_args) when is_map(raw_args), do: raw_args

  defp decode_tool_args(raw_args) when is_binary(raw_args) do
    case Jason.decode(raw_args) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_tool_args(_), do: %{}

  defp normalize_mcp_result(%{"content" => content}) when is_binary(content), do: content
  defp normalize_mcp_result(%{content: content}) when is_binary(content), do: content

  defp normalize_mcp_result(%{"contents" => [%{"text" => text}]}) when is_binary(text), do: text
  defp normalize_mcp_result(%{contents: [%{text: text}]}) when is_binary(text), do: text

  defp normalize_mcp_result(result), do: result

  defp mcp_error_payload(entry, code, message) do
    %{
      error: true,
      source: :mcp,
      code: code,
      message: message,
      server: entry.source.server,
      tool: entry.source.remote_name
    }
  end

  defp encode_tool_result(result) when is_binary(result), do: result
  defp encode_tool_result(result), do: Jason.encode!(result)

  defp tool_call_names(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn call ->
      function = Map.get(call, "function") || Map.get(call, :function) || %{}
      Map.get(function, "name") || Map.get(function, :name) || "unknown_tool"
    end)
  end

  defp maybe_log_mcp_discovery(connection, discovery, opts) do
    if mcp_debug?(opts) do
      tool_names = Enum.map(discovery.tools, &tool_name/1)

      Logger.info(
        "[mcp] discovered server=#{connection.name} tools=#{inspect(tool_names)} resources_supported=#{discovery.resources_supported?}"
      )
    end
  end

  defp maybe_log_mcp_request(entry, payload, opts) do
    if mcp_debug?(opts) do
      Logger.info(
        "[mcp] request server=#{entry.source.server} tool=#{entry.source.remote_name} payload=#{truncate_for_log(payload)}"
      )
    end
  end

  defp maybe_log_mcp_result(entry, result, opts) do
    if mcp_debug?(opts) do
      Logger.info(
        "[mcp] result server=#{entry.source.server} tool=#{entry.source.remote_name} result=#{truncate_for_log(result)}"
      )
    end
  end

  defp mcp_debug?(opts) do
    Keyword.get(opts, :mcp_debug, false) || mcp_debug_from_config?()
  end

  defp mcp_debug_from_config? do
    Application.get_env(:synaptic, Synaptic.MCP, [])
    |> Keyword.get(:debug, false)
  end

  defp truncate_for_log(term) do
    inspected = inspect(term, pretty: false, limit: 20, printable_limit: 600)

    if String.length(inspected) > 700 do
      String.slice(inspected, 0, 700) <> "..."
    else
      inspected
    end
  end
end
