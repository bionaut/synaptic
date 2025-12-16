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

    adapter = Keyword.get(merged_opts, :adapter, configured_adapter())
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
    do: do_chat_with_telemetry(adapter, messages, opts, [])

  defp do_chat(adapter, messages, opts, tools) do
    tool_map = Map.new(tools, &{&1.name, &1})

    case do_chat_with_telemetry(adapter, messages, opts, tools) do
      {:ok, %{tool_calls: tool_calls} = message} when is_list(tool_calls) and tool_calls != [] ->
        new_messages = apply_tool_calls(messages, message, tool_map)
        do_chat(adapter, new_messages, opts, tools)

      {:ok, %{tool_calls: tool_calls} = message, _usage}
      when is_list(tool_calls) and tool_calls != [] ->
        new_messages = apply_tool_calls(messages, message, tool_map)
        do_chat(adapter, new_messages, opts, tools)

      {:ok, %{"tool_calls" => tool_calls} = message}
      when is_list(tool_calls) and
             tool_calls != [] ->
        new_messages = apply_tool_calls(messages, message, tool_map)
        do_chat(adapter, new_messages, opts, tools)

      {:ok, %{"tool_calls" => tool_calls} = message, _usage}
      when is_list(tool_calls) and
             tool_calls != [] ->
        new_messages = apply_tool_calls(messages, message, tool_map)
        do_chat(adapter, new_messages, opts, tools)

      other ->
        other
    end
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

    result =
      :telemetry.span(
        [:synaptic, :llm],
        metadata,
        fn ->
          adapter_result = adapter.chat(messages, opts)
          updated_metadata = extract_telemetry_metadata(adapter_result, metadata)

          # Return the (possibly usage-stripped) result alongside updated metadata.
          # Telemetry will merge the updated metadata into the stop event, so
          # handlers on [:synaptic, :llm, :stop] see token usage fields.
          {strip_usage(adapter_result), updated_metadata}
        end
      )

    result
  end

  defp extract_telemetry_metadata({:ok, _content, %{usage: usage}}, metadata)
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
  end

  defp extract_telemetry_metadata({:ok, _content}, metadata), do: metadata
  defp extract_telemetry_metadata({:error, _reason}, metadata), do: metadata

  defp strip_usage({:ok, content, %{usage: _usage}}), do: {:ok, content}
  defp strip_usage({:ok, content, _other}), do: {:ok, content}
  defp strip_usage(other), do: other

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
end
