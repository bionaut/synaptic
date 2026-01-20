defmodule Synaptic.Tools do
  @moduledoc """
  Helper utilities for invoking LLM providers from workflow steps.
  """

  alias Synaptic.Tools.Tool

  @default_adapter Synaptic.Tools.OpenAI

  @doc """
  Dispatches a chat completion request to the configured adapter.

  Pass `agent: :name` to pull default options (model, temperature, adapter,
  etc.) from the `:agents` configuration. Provide `tools: [...]` with
  `%Synaptic.Tools.Tool{}` structs (or maps/keywords convertible via
  `Synaptic.Tools.Tool.new/1`) to enable tool-calling flows.

  When `stream: true` is passed, the response will be streamed and PubSub events
  will be emitted for each chunk. Note: streaming automatically falls back to
  non-streaming mode when tools are provided, as OpenAI streaming doesn't support
  tool calling.
  """
  def chat(messages, opts \\ []) when is_list(messages) do
    {agent_opts, call_opts} = agent_options(opts)
    merged_opts = Keyword.merge(agent_opts, call_opts)

    {tools, merged_opts} = Keyword.pop(merged_opts, :tools, [])
    tool_specs = normalize_tools(tools)

    # Detect thread usage: thread: true, use_threads: true, or previous_response_id present
    use_threads? =
      Keyword.get(merged_opts, :thread, false) ||
        Keyword.get(merged_opts, :use_threads, false) ||
        Keyword.has_key?(merged_opts, :previous_response_id)

    # Auto-select adapter based on thread usage
    adapter =
      if use_threads? do
        Keyword.get(merged_opts, :adapter, Synaptic.Tools.OpenAIResponses)
      else
        Keyword.get(merged_opts, :adapter, configured_adapter())
      end

    stream_enabled = Keyword.get(merged_opts, :stream, false)

    # If tools are provided and streaming is requested, fall back to non-streaming
    if stream_enabled and tool_specs != [] do
      require Logger

      Logger.warning(
        "Streaming requested but tools are provided. Falling back to non-streaming mode (OpenAI limitation)."
      )

      merged_opts = Keyword.delete(merged_opts, :stream)
      adapter_opts = Keyword.put(merged_opts, :tools, Enum.map(tool_specs, &Tool.to_openai/1))
      do_chat(adapter, messages, adapter_opts, tool_specs)
    else
      adapter_opts =
        if tool_specs == [] do
          merged_opts
        else
          Keyword.put(merged_opts, :tools, Enum.map(tool_specs, &Tool.to_openai/1))
        end

      if stream_enabled do
        do_chat_stream(adapter, messages, adapter_opts)
      else
        do_chat(adapter, messages, adapter_opts, tool_specs)
      end
    end
  end

  defp do_chat(adapter, messages, opts, []),
    do: do_chat(adapter, messages, opts, [], %{})

  defp do_chat(adapter, messages, opts, tools) do
    do_chat(adapter, messages, opts, tools, %{})
  end

  defp do_chat(adapter, messages, opts, tools, usage_acc) do
    tool_map = Map.new(tools, &{&1.name, &1})

    case do_chat_with_telemetry(adapter, messages, opts, tools) do
      {:ok, message, %{usage: usage} = meta} ->
        # Preserve metadata (e.g., response_id) and pass to handle_tool_response
        handle_tool_response(
          adapter,
          messages,
          opts,
          tools,
          tool_map,
          message,
          usage,
          usage_acc,
          meta
        )

      {:ok, message, meta} when is_map(meta) ->
        # Metadata without usage (e.g., response_id only)
        handle_tool_response(
          adapter,
          messages,
          opts,
          tools,
          tool_map,
          message,
          nil,
          usage_acc,
          meta
        )

      {:ok, message} ->
        handle_tool_response(
          adapter,
          messages,
          opts,
          tools,
          tool_map,
          message,
          nil,
          usage_acc,
          %{}
        )

      other ->
        other
    end
  end

  defp handle_tool_response(
         adapter,
         messages,
         opts,
         tools,
         tool_map,
         message,
         usage,
         usage_acc,
         meta
       ) do
    tool_calls = tool_calls_from(message)
    usage_acc = add_usage(usage_acc, usage)

    if is_list(tool_calls) and tool_calls != [] do
      new_messages = apply_tool_calls(messages, message, tool_map)
      do_chat(adapter, new_messages, opts, tools, usage_acc)
    else
      # Preserve metadata (e.g., response_id) from adapter response
      result = {:ok, message}
      result = if map_size(meta) > 0, do: {:ok, message, meta}, else: result
      maybe_attach_usage(result, usage_acc, Keyword.get(opts, :return_usage, false))
    end
  end

  defp do_chat_with_telemetry(adapter, messages, opts, tools) do
    run_id = Keyword.get(opts, :run_id) || get_from_context(:__run_id__)
    step_name = Keyword.get(opts, :step_name) || get_from_context(:__step_name__)
    model = Keyword.get(opts, :model) || "unknown"
    return_usage? = Keyword.get(opts, :return_usage, false)
    stream = Keyword.get(opts, :stream, false)
    call_index = increment_llm_call_counter()

    log_llm_call_start(call_index, adapter, model, tools)

    metadata = %{
      run_id: run_id,
      step_name: step_name,
      adapter: adapter,
      model: model,
      stream: stream
    }

    result =
      :telemetry.span(
        [:synaptic, :llm],
        metadata,
        fn ->
          adapter_result = adapter.chat(messages, opts)
          log_llm_call_end(call_index, adapter_result)

          usage = usage_from_result(adapter_result)

          case maybe_report_usage(opts, usage) do
            :halt ->
              {{:error, :budget_exceeded}, metadata}

            :cont ->
              updated_metadata = extract_telemetry_metadata(adapter_result, metadata)

              # Return the (possibly usage-stripped) result alongside updated metadata.
              # Telemetry will merge the updated metadata into the stop event, so
              # handlers on [:synaptic, :llm, :stop] see token usage fields.
              {maybe_strip_usage(adapter_result, return_usage?), updated_metadata}
          end
        end
      )

    result
  end

  defp extract_telemetry_metadata({:ok, _content, %{usage: usage} = meta}, metadata)
       when is_map(usage) do
    # Add usage to metadata and also add token counts as separate fields for easier access
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
    |> maybe_put_response_id(meta)
  end

  defp extract_telemetry_metadata({:ok, _content, meta}, metadata) when is_map(meta) do
    # Handle metadata without usage (e.g., response_id from Responses API)
    maybe_put_response_id(metadata, meta)
  end

  defp extract_telemetry_metadata({:ok, _content}, metadata), do: metadata
  defp extract_telemetry_metadata({:error, _reason}, metadata), do: metadata

  defp maybe_put_response_id(metadata, meta) do
    case Map.get(meta, :response_id) || Map.get(meta, "response_id") do
      nil -> metadata
      response_id -> Map.put(metadata, :response_id, response_id)
    end
  end

  defp maybe_strip_usage(result, true), do: result

  defp maybe_strip_usage({:ok, content, %{usage: _usage} = meta}, return_usage?) do
    # Preserve non-usage metadata (e.g., response_id) even when stripping usage
    if return_usage? do
      {:ok, content, meta}
    else
      stripped_meta = Map.delete(meta, :usage)

      if map_size(stripped_meta) > 0 do
        {:ok, content, stripped_meta}
      else
        {:ok, content}
      end
    end
  end

  defp maybe_strip_usage({:ok, content, meta}, _) when is_map(meta) do
    # Preserve metadata that doesn't contain usage (e.g., response_id)
    {:ok, content, meta}
  end

  defp maybe_strip_usage(other, _), do: other

  defp usage_from_result({:ok, _content, %{usage: usage}}) when is_map(usage), do: usage
  defp usage_from_result(_), do: %{}

  defp maybe_report_usage(opts, usage) do
    case Keyword.get(opts, :on_usage) do
      fun when is_function(fun, 1) ->
        try do
          case fun.(usage) do
            :halt -> :halt
            _ -> :cont
          end
        rescue
          _ -> :cont
        end

      _ ->
        :cont
    end
  end

  defp do_chat_stream(adapter, messages, opts) do
    # Extract run_id and step_name from context (injected by Runner)
    # These are passed via opts[:context] or can be extracted from a process dictionary
    # For now, we'll get them from opts - they should be passed by the step
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

    # Create on_chunk callback that publishes PubSub events
    on_chunk = fn chunk, accumulated ->
      publish_stream_chunk(run_id, step_name, chunk, accumulated)
    end

    adapter_opts = Keyword.put(opts, :on_chunk, on_chunk)

    result =
      :telemetry.span(
        [:synaptic, :llm],
        metadata,
        fn ->
          adapter_result = adapter.chat(messages, adapter_opts)

          case adapter_result do
            {:ok, accumulated} = ok_result ->
              # Publish stream_done event
              if run_id do
                publish_stream_done(run_id, step_name, accumulated)
              end

              {ok_result, metadata}

            {:ok, accumulated, %{usage: usage}} = ok_result ->
              # Publish stream_done event
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

    result
  end

  # Helper to get values from process dictionary (set by Runner)
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

  alias Synaptic.Tools.Tool

  defp normalize_tools([]), do: []

  defp normalize_tools(tools) when is_list(tools) do
    Enum.map(tools, &Tool.new/1)
  end

  defp normalize_tools(tool), do: [Tool.new(tool)]

  defp apply_tool_calls(messages, message, tool_map) do
    assistant_msg = %{
      role: "assistant",
      content: Map.get(message, :content) || Map.get(message, "content"),
      tool_calls: Map.get(message, :tool_calls) || Map.get(message, "tool_calls")
    }

    tool_messages =
      assistant_msg.tool_calls
      |> Enum.map(&execute_tool_call(&1, tool_map))

    messages ++ [assistant_msg | tool_messages]
  end

  defp execute_tool_call(call, tool_map) do
    %{"function" => %{"name" => name, "arguments" => raw_args}, "id" => id} = call

    tool =
      Map.fetch!(tool_map, name)

    args =
      case Jason.decode(raw_args) do
        {:ok, decoded} -> decoded
        _ -> %{}
      end

    log_tool_call(name, args)

    result = tool.handler.(args)

    %{
      role: "tool",
      tool_call_id: id,
      name: name,
      content: encode_tool_result(result)
    }
  end

  defp encode_tool_result(result) when is_binary(result), do: result
  defp encode_tool_result(result), do: Jason.encode!(result)

  defp log_tool_call(name, args) do
    if Code.ensure_loaded?(Mix) and Mix.env() == :dev do
      require Logger
      Logger.debug("Tool call #{name} args=#{inspect(args)}")
    end
  end

  defp tool_calls_from(%{tool_calls: calls}), do: calls
  defp tool_calls_from(%{"tool_calls" => calls}), do: calls
  defp tool_calls_from(_), do: []

  defp add_usage(acc, nil), do: acc

  defp add_usage(acc, usage) when is_map(usage) do
    acc = normalize_usage(acc)
    usage = normalize_usage(usage)

    %{
      prompt_tokens: acc.prompt_tokens + usage.prompt_tokens,
      completion_tokens: acc.completion_tokens + usage.completion_tokens,
      total_tokens: acc.total_tokens + usage.total_tokens
    }
  end

  defp normalize_usage(%{} = usage) do
    %{
      prompt_tokens: Map.get(usage, :prompt_tokens) || Map.get(usage, "prompt_tokens") || 0,
      completion_tokens:
        Map.get(usage, :completion_tokens) || Map.get(usage, "completion_tokens") || 0,
      total_tokens: Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") || 0
    }
  end

  defp maybe_attach_usage({:ok, message, meta}, usage, return_usage?) when is_map(meta) do
    # Preserve existing metadata (e.g., response_id) and conditionally add usage
    new_meta =
      if return_usage? and map_size(usage) > 0 do
        Map.put(meta, :usage, usage)
      else
        meta
      end

    {:ok, message, new_meta}
  end

  defp maybe_attach_usage({:ok, message}, usage, true) when map_size(usage) > 0 do
    {:ok, message, %{usage: usage}}
  end

  defp maybe_attach_usage({:ok, message}, _usage, _), do: {:ok, message}

  defp increment_llm_call_counter do
    count = (Process.get(:synaptic_llm_call_counter) || 0) + 1
    Process.put(:synaptic_llm_call_counter, count)
    count
  end

  defp log_llm_call_start(call_index, adapter, model, tools) do
    if Code.ensure_loaded?(Mix) and Mix.env() == :dev do
      require Logger
      tool_count = length(tools || [])

      Logger.info(
        "LLM call ##{call_index} start adapter=#{inspect(adapter)} model=#{model} tools=#{tool_count}"
      )
    end
  end

  defp log_llm_call_end(call_index, result) do
    if Code.ensure_loaded?(Mix) and Mix.env() == :dev do
      require Logger
      tool_calls = tool_call_count(result)
      status = if match?({:ok, _}, result) or match?({:ok, _, _}, result), do: :ok, else: :error

      Logger.info("LLM call ##{call_index} done status=#{status} tool_calls=#{tool_calls}")
    end
  end

  defp tool_call_count({:ok, %{tool_calls: calls}}) when is_list(calls), do: length(calls)
  defp tool_call_count({:ok, %{"tool_calls" => calls}}) when is_list(calls), do: length(calls)

  defp tool_call_count({:ok, %{tool_calls: calls}, _meta}) when is_list(calls),
    do: length(calls)

  defp tool_call_count({:ok, %{"tool_calls" => calls}, _meta}) when is_list(calls),
    do: length(calls)

  defp tool_call_count({:ok, %{content: _content, tool_calls: calls}})
       when is_list(calls),
       do: length(calls)

  defp tool_call_count({:ok, %{"content" => _content, "tool_calls" => calls}})
       when is_list(calls),
       do: length(calls)

  defp tool_call_count({:ok, %{content: _content, tool_calls: calls}, _meta})
       when is_list(calls),
       do: length(calls)

  defp tool_call_count({:ok, %{"content" => _content, "tool_calls" => calls}, _meta})
       when is_list(calls),
       do: length(calls)

  defp tool_call_count({:ok, _content, _meta}), do: 0
  defp tool_call_count({:ok, _content}), do: 0
  defp tool_call_count(_), do: 0
end
