defmodule Synaptic.Tools.OpenAIResponses do
  @moduledoc """
  OpenAI Responses API adapter with thread/conversation management support.

  This adapter uses OpenAI's Responses API (`/v1/responses`) which supports
  native thread management via `previous_response_id`. It maintains backward
  compatibility by converting Messages format to Items format internally and
  normalizing responses to match the Chat Completions API format.
  """

  use Synaptic.Tools.Adapter

  @endpoint "https://api.openai.com/v1/responses"

  @doc """
  Sends a Responses API request with thread support.

  When `stream: true` is passed in opts, returns a streaming response.
  When `previous_response_id` is provided, continues an existing thread.
  When `thread: true` is set, enables thread management (defaults to `store: true`).
  """
  @impl Synaptic.Tools.Adapter
  def chat(messages, opts \\ []) do
    if Keyword.get(opts, :stream, false) do
      chat_stream(messages, opts)
    else
      chat_non_streaming(messages, opts)
    end
  end

  defp chat_non_streaming(messages, opts) do
    # Convert messages to Items format
    items = messages_to_items(messages)

    # Build request body
    body =
      %{
        model: model(opts),
        input: items,
        temperature: Keyword.get(opts, :temperature, 0)
      }
      |> maybe_put_previous_response_id(opts)
      |> maybe_put_store(opts)
      |> maybe_put_tools(opts)
      |> maybe_put_instructions(opts)
      |> maybe_put_response_format(opts)

    headers =
      [
        {"content-type", "application/json"},
        {"authorization", "Bearer " <> api_key(opts)}
      ]

    request =
      Finch.build(:post, endpoint(opts), headers, Jason.encode!(body))

    case Finch.request(request, finch(opts), receive_timeout: request_timeout(opts)) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        parse_response(response_body, opts)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:upstream_error, status, safe_decode(response_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp chat_stream(messages, opts) do
    # Responses API streaming support (if available)
    # For now, fall back to non-streaming
    # TODO: Implement streaming when Responses API streaming is available
    chat_non_streaming(messages, opts)
  end

  @doc """
  Converts Messages format (Chat Completions) to Items format (Responses API).

  Messages format: `[%{role: "user", content: "text"}, ...]`
  Items format: `[%{type: "message", role: "user", content: [%{type: "input_text", text: "text"}]}, ...]`
  """
  def messages_to_items(messages) when is_list(messages) do
    Enum.map(messages, &message_to_item/1)
  end

  defp message_to_item(%{role: "system"} = msg) do
    content = extract_content(msg)

    %{
      type: "message",
      role: "developer",
      content: [
        %{
          type: "input_text",
          text: content
        }
      ]
    }
  end

  defp message_to_item(%{role: "user"} = msg) do
    content = extract_content(msg)

    %{
      type: "message",
      role: "user",
      content: [
        %{
          type: "input_text",
          text: content
        }
      ]
    }
  end

  defp message_to_item(%{role: "assistant"} = msg) do
    content = extract_content(msg)
    tool_calls = Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls") || []

    text_content =
      case content do
        nil -> ""
        text when is_binary(text) -> text
        other -> to_string(other)
      end

    item = %{
      type: "message",
      role: "assistant",
      content: [
        %{
          type: "output_text",
          text: text_content
        }
      ]
    }

    # Add tool calls if present
    if tool_calls != [] do
      Map.put(item, :tool_calls, tool_calls)
    else
      item
    end
  end

  defp message_to_item(%{role: "tool"} = msg) do
    content = extract_content(msg)
    tool_call_id = Map.get(msg, :tool_call_id) || Map.get(msg, "tool_call_id")
    name = Map.get(msg, :name) || Map.get(msg, "name")

    %{
      type: "tool_output",
      tool_call_id: tool_call_id,
      name: name,
      content: [
        %{
          type: "tool_output_text",
          text: content
        }
      ]
    }
  end

  defp message_to_item(msg) when is_map(msg) do
    # Handle string keys
    msg
    |> atomize_keys()
    |> message_to_item()
  end

  defp extract_content(msg) do
    content = Map.get(msg, :content) || Map.get(msg, "content")

    case content do
      list when is_list(list) ->
        Enum.map_join(list, "", fn
          %{"text" => text} -> text
          %{text: text} -> text
          text when is_binary(text) -> text
          _ -> ""
        end)

      text when is_binary(text) ->
        text

      nil ->
        ""

      other ->
        to_string(other)
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      if is_binary(key) do
        try do
          atom_key = String.to_existing_atom(key)
          Map.put(acc, atom_key, value)
        rescue
          ArgumentError ->
            # If atom doesn't exist, keep as string key
            Map.put(acc, key, value)
        end
      else
        Map.put(acc, key, value)
      end
    end)
  end

  @doc """
  Converts Items format back to Messages format for tool call handling.
  """
  def items_to_messages(items) when is_list(items) do
    Enum.map(items, &item_to_message/1)
  end

  defp item_to_message(%{type: "message", role: role} = item) do
    content = extract_item_content(item)
    tool_calls = Map.get(item, :tool_calls) || []

    msg = %{
      role: role,
      content: content
    }

    if tool_calls != [] do
      Map.put(msg, :tool_calls, tool_calls)
    else
      msg
    end
  end

  defp item_to_message(%{type: "tool_output"} = item) do
    content = extract_item_content(item)
    tool_call_id = Map.get(item, :tool_call_id)
    name = Map.get(item, :name)

    %{
      role: "tool",
      tool_call_id: tool_call_id,
      name: name,
      content: content
    }
  end

  defp item_to_message(item) when is_map(item) do
    # Handle other item types (reasoning, etc.)
    %{
      role: "assistant",
      content: extract_item_content(item)
    }
  end

  defp extract_item_content(item) do
    content_list = Map.get(item, :content) || Map.get(item, "content") || []

    Enum.map_join(content_list, "", fn
      %{"text" => text} -> text
      %{text: text} -> text
      %{"type" => "output_text", "text" => text} -> text
      %{type: "output_text", text: text} -> text
      %{"type" => "input_text", "text" => text} -> text
      %{type: "input_text", text: text} -> text
      %{"type" => "tool_output_text", "text" => text} -> text
      %{type: "tool_output_text", text: text} -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
  end

  @doc false
  def parse_response(body, _opts) do
    with {:ok, decoded} <- Jason.decode(body),
         output_text <- Map.get(decoded, "output_text"),
         output <- Map.get(decoded, "output", []),
         response_id <- Map.get(decoded, "id") do
      # Extract content and tool calls from output items
      {content, tool_calls} = extract_content_and_tool_calls(output, output_text)

      # Extract usage metrics
      usage = extract_usage(decoded)

      # Build response in Chat Completions format
      result =
        if tool_calls == [] do
          {:ok, content}
        else
          {:ok, %{content: content, tool_calls: tool_calls}}
        end

      # Add usage and response_id to metadata
      metadata = %{usage: usage}
      metadata = if response_id, do: Map.put(metadata, :response_id, response_id), else: metadata

      if usage != %{} or response_id do
        case result do
          {:ok, content_or_map} -> {:ok, content_or_map, metadata}
        end
      else
        result
      end
    else
      {:error, reason} -> {:error, reason}
      error -> {:error, {:invalid_response, error}}
    end
  end

  defp extract_content_and_tool_calls(output, output_text) when is_list(output) do
    # Find assistant message items
    assistant_items =
      Enum.filter(output, fn item ->
        Map.get(item, "type") == "message" && Map.get(item, "role") == "assistant"
      end)

    # Extract content from assistant messages
    content =
      if output_text do
        output_text
      else
        assistant_items
        |> Enum.map(&extract_item_content/1)
        |> Enum.join("\n")
      end

    # Extract tool calls from output items
    tool_calls = extract_tool_calls_from_output(output)

    {content || "", tool_calls}
  end

  defp extract_content_and_tool_calls(_output, output_text) do
    {output_text || "", []}
  end

  defp extract_tool_calls_from_output(output) when is_list(output) do
    # Find function/tool_call items in output
    # Responses API returns tool calls as items with type "function"
    output
    |> Enum.filter(fn item ->
      type = Map.get(item, "type") || Map.get(item, :type)
      type == "function" || type == "tool_call"
    end)
    |> Enum.map(fn item ->
      # Convert function item to Chat Completions format
      id = Map.get(item, "id") || Map.get(item, :id)
      function = Map.get(item, "function") || Map.get(item, :function) || %{}

      name =
        Map.get(function, "name") || Map.get(function, :name) || Map.get(item, "name") ||
          Map.get(item, :name)

      args =
        Map.get(function, "arguments") || Map.get(function, :arguments) ||
          Map.get(item, "arguments") || Map.get(item, :arguments) || %{}

      # Ensure arguments is a JSON string
      args_string =
        cond do
          is_binary(args) -> args
          is_map(args) -> Jason.encode!(args)
          true -> Jason.encode!(args)
        end

      %{
        "id" => id,
        "type" => "function",
        "function" => %{
          "name" => name,
          "arguments" => args_string
        }
      }
    end)
  end

  defp extract_tool_calls_from_output(_), do: []

  defp extract_usage(%{"usage" => usage}) when is_map(usage) do
    %{
      prompt_tokens: Map.get(usage, "prompt_tokens") || Map.get(usage, :prompt_tokens) || 0,
      completion_tokens:
        Map.get(usage, "completion_tokens") || Map.get(usage, :completion_tokens) || 0,
      total_tokens: Map.get(usage, "total_tokens") || Map.get(usage, :total_tokens) || 0
    }
  end

  defp extract_usage(_), do: %{}

  defp maybe_put_previous_response_id(body, opts) do
    case Keyword.get(opts, :previous_response_id) do
      nil -> body
      response_id -> Map.put(body, :previous_response_id, response_id)
    end
  end

  defp maybe_put_store(body, opts) do
    # Default to true when using threads, but allow override
    store = Keyword.get(opts, :store, true)
    Map.put(body, :store, store)
  end

  defp maybe_put_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil ->
        body

      [] ->
        body

      tools ->
        # Convert tools from Chat Completions format to Responses API format
        # Chat Completions: {type: "function", function: {name, description, parameters}}
        # Responses API: {type: "function", name, description, parameters}
        normalized_tools =
          Enum.map(tools, fn tool ->
            convert_tool_to_responses_format(tool)
          end)

        Map.put(body, :tools, normalized_tools)
    end
  end

  # Converts Chat Completions tool format to Responses API format
  defp convert_tool_to_responses_format(tool) do
    # Handle both atom and string keys
    tool = normalize_keys(tool)

    # Extract function details from nested structure
    function = Map.get(tool, "function") || Map.get(tool, :function) || %{}

    # Build Responses API format: name, description, parameters at top level
    result = %{
      "type" => Map.get(tool, "type") || Map.get(tool, :type) || "function"
    }

    # Add name, description, parameters from function object
    result =
      if name = Map.get(function, "name") || Map.get(function, :name) do
        Map.put(result, "name", name)
      else
        result
      end

    result =
      if desc = Map.get(function, "description") || Map.get(function, :description) do
        Map.put(result, "description", desc)
      else
        result
      end

    result =
      if params = Map.get(function, "parameters") || Map.get(function, :parameters) do
        # Ensure parameters are also string-keyed
        Map.put(result, "parameters", normalize_keys(params))
      else
        result
      end

    result
  end

  defp normalize_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      string_key = if is_atom(key), do: Atom.to_string(key), else: to_string(key)
      string_value = if is_map(value), do: normalize_keys(value), else: value
      Map.put(acc, string_key, string_value)
    end)
  end

  defp normalize_keys(value), do: value

  defp maybe_put_instructions(body, opts) do
    case Keyword.get(opts, :instructions) do
      nil -> body
      instructions -> Map.put(body, :instructions, instructions)
    end
  end

  defp maybe_put_response_format(body, opts) do
    response_format =
      opts
      |> response_format()
      |> normalize_response_format()

    if response_format do
      Map.put(body, :response_format, response_format)
    else
      body
    end
  end

  defp model(opts) do
    opts[:model] || config(opts)[:model] || "gpt-4o-mini"
  end

  defp endpoint(opts), do: opts[:endpoint] || config(opts)[:endpoint] || @endpoint

  defp request_timeout(opts) do
    opts[:receive_timeout] || config(opts)[:receive_timeout] || 120_000
  end

  defp api_key(opts) do
    opts[:api_key] ||
      config(opts)[:api_key] ||
      System.get_env("OPENAI_API_KEY") ||
      raise "Synaptic OpenAI Responses adapter requires an API key"
  end

  defp finch(opts) do
    opts[:finch] || config(opts)[:finch] || Synaptic.Finch
  end

  defp response_format(opts) do
    opts[:response_format] || config(opts)[:response_format]
  end

  defp normalize_response_format(nil), do: nil

  defp normalize_response_format(:json_object), do: %{"type" => "json_object"}
  defp normalize_response_format("json_object"), do: %{"type" => "json_object"}

  defp normalize_response_format(:json_schema), do: %{"type" => "json_schema"}
  defp normalize_response_format("json_schema"), do: %{"type" => "json_schema"}

  defp normalize_response_format(%{} = format) do
    Enum.reduce(format, %{}, fn {key, value}, acc ->
      string_key = normalize_format_key(key)
      normalized_value = normalize_format_value(string_key, value)
      Map.put(acc, string_key, normalized_value)
    end)
  end

  defp normalize_response_format(format), do: format

  defp normalize_format_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_format_key(key) when is_binary(key), do: key
  defp normalize_format_key(key), do: to_string(key)

  defp normalize_format_value("type", value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_format_value(_key, value), do: value

  defp safe_decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp config(_opts), do: Application.get_env(:synaptic, __MODULE__, [])
end
