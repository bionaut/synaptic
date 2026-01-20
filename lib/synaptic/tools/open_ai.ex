defmodule Synaptic.Tools.OpenAI do
  @moduledoc """
  Minimal OpenAI chat client built on Finch.
  """

  use Synaptic.Tools.Adapter

  @endpoint "https://api.openai.com/v1/chat/completions"

  @doc """
  Sends a chat completion request.

  When `stream: true` is passed in opts, returns a streaming response.
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
    response_format =
      opts
      |> response_format()
      |> normalize_response_format()

    body =
      %{
        model: model(opts),
        messages: messages,
        temperature: Keyword.get(opts, :temperature, 0)
      }
      |> maybe_put_tools(opts)
      |> maybe_put_response_format(response_format)

    headers =
      [
        {"content-type", "application/json"},
        {"authorization", "Bearer " <> api_key(opts)}
      ]

    request =
      Finch.build(:post, endpoint(opts), headers, Jason.encode!(body))

    case Finch.request(request, finch(opts), receive_timeout: request_timeout(opts)) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        parse_response(response_body, response_format: response_format)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:upstream_error, status, safe_decode(response_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp chat_stream(messages, opts) do
    # Note: streaming doesn't support response_format or tools
    body =
      %{
        model: model(opts),
        messages: messages,
        temperature: Keyword.get(opts, :temperature, 0),
        stream: true
      }

    headers =
      [
        {"content-type", "application/json"},
        {"authorization", "Bearer " <> api_key(opts)}
      ]

    request = Finch.build(:post, endpoint(opts), headers, Jason.encode!(body))
    on_chunk = Keyword.get(opts, :on_chunk)

    acc = %{buffer: "", accumulated: "", status: nil}

    result =
      Finch.stream(
        request,
        finch(opts),
        acc,
        fn
          {:status, status}, acc ->
            if status != 200 do
              {:error, {:upstream_error, status, nil}, acc}
            else
              {:cont, %{acc | status: status}}
            end

          {:headers, _headers}, acc ->
            {:cont, acc}

          {:data, data}, acc ->
            new_buffer = acc.buffer <> IO.iodata_to_binary(data)

            {remaining_buffer, events, new_accumulated} =
              parse_sse_events(new_buffer, acc.accumulated)

            # Call on_chunk callback for each event
            if on_chunk do
              Enum.each(events, fn {chunk, accumulated} ->
                on_chunk.(chunk, accumulated)
              end)
            end

            new_acc = %{
              buffer: remaining_buffer,
              accumulated: new_accumulated,
              status: acc.status
            }

            {:cont, new_acc}

          :done, acc ->
            {:ok, acc.accumulated}

          {:error, reason}, _acc ->
            {:error, reason}
        end,
        receive_timeout: request_timeout(opts)
      )

    # For streaming, usage info is not available in chunks
    # OpenAI streaming responses don't include usage in chunks, so we return without it
    # If usage is needed for streaming, it would need to be tracked separately
    case result do
      {:ok, accumulated} -> {:ok, accumulated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_sse_events(data, accumulated) do
    # Split on double newline to get individual SSE events
    parts = String.split(data, "\n\n", trim: false)

    # Last part might be incomplete, keep it in buffer
    {complete_parts, incomplete} =
      if length(parts) > 1 do
        {Enum.take(parts, length(parts) - 1), List.last(parts)}
      else
        {[], List.first(parts) || ""}
      end

    {events, new_accumulated} =
      complete_parts
      |> Enum.map(&parse_sse_chunk/1)
      |> Enum.filter(&(&1 != nil))
      |> Enum.reduce({[], accumulated}, fn chunk_data, {acc_events, acc_content} ->
        case extract_delta_content(chunk_data) do
          nil ->
            {acc_events, acc_content}

          content ->
            new_accumulated = acc_content <> content
            {[{content, new_accumulated} | acc_events], new_accumulated}
        end
      end)

    {incomplete, Enum.reverse(events), new_accumulated}
  end

  defp parse_sse_chunk("data: [DONE]"), do: nil

  defp parse_sse_chunk("data: " <> json) do
    case Jason.decode(json) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp parse_sse_chunk(""), do: nil
  defp parse_sse_chunk(_), do: nil

  defp extract_delta_content(%{"choices" => [%{"delta" => %{"content" => content}} | _]})
       when is_binary(content) do
    content
  end

  defp extract_delta_content(%{"choices" => [%{"delta" => %{}} | _]}) do
    nil
  end

  defp extract_delta_content(_), do: nil

  defp model(opts) do
    opts[:model] || config(opts)[:model] || "gpt-4o-mini"
  end

  defp maybe_put_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      [] -> body
      tools -> Map.merge(body, %{tools: tools, tool_choice: "auto"})
    end
  end

  defp maybe_put_response_format(body, nil), do: body

  defp maybe_put_response_format(body, response_format),
    do: Map.put(body, :response_format, response_format)

  defp endpoint(opts), do: opts[:endpoint] || config(opts)[:endpoint] || @endpoint

  defp request_timeout(opts) do
    opts[:receive_timeout] || config(opts)[:receive_timeout] || 120_000
  end

  defp api_key(opts) do
    opts[:api_key] ||
      config(opts)[:api_key] ||
      System.get_env("OPENAI_API_KEY") ||
      raise "Synaptic OpenAI adapter requires an API key"
  end

  defp finch(opts) do
    opts[:finch] || config(opts)[:finch] || Synaptic.Finch
  end

  @doc false
  def parse_response(body, opts \\ []) do
    response_format =
      opts
      |> Keyword.get(:response_format)
      |> normalize_response_format()

    with {:ok, decoded} <- Jason.decode(body),
         [choice | _] <- Map.get(decoded, "choices", []),
         %{"message" => message} <- choice,
         {:ok, content} <- decode_content(message_content(message), response_format) do
      tool_calls = tool_calls_from(message)
      usage = extract_usage(decoded)

      result =
        if tool_calls == [] do
          {:ok, content}
        else
          {:ok, %{content: content, tool_calls: tool_calls}}
        end

      # Append usage metrics if available
      if usage != %{} do
        case result do
          {:ok, content_or_map} -> {:ok, content_or_map, %{usage: usage}}
        end
      else
        result
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  defp extract_usage(%{"usage" => usage}) when is_map(usage) do
    %{
      prompt_tokens: Map.get(usage, "prompt_tokens") || Map.get(usage, :prompt_tokens) || 0,
      completion_tokens:
        Map.get(usage, "completion_tokens") || Map.get(usage, :completion_tokens) || 0,
      total_tokens: Map.get(usage, "total_tokens") || Map.get(usage, :total_tokens) || 0
    }
  end

  defp extract_usage(_), do: %{}

  defp message_content(message) do
    content = Map.get(message, :content) || Map.get(message, "content")

    case content do
      list when is_list(list) -> Enum.map_join(list, "", &content_segment_to_binary/1)
      other -> other
    end
  end

  defp content_segment_to_binary(%{"text" => text}), do: text
  defp content_segment_to_binary(%{text: text}), do: text

  defp content_segment_to_binary(text) when is_binary(text), do: text
  defp content_segment_to_binary(_other), do: ""

  defp decode_content(nil, _response_format), do: {:ok, nil}

  defp decode_content(content, response_format) do
    if json_response_format?(response_format) do
      decode_json_content(content)
    else
      {:ok, content}
    end
  end

  defp decode_json_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_json_response}
    end
  end

  defp decode_json_content(_content), do: {:error, :invalid_json_response}

  defp json_response_format?(%{"type" => type}) when type in ["json_object", "json_schema"],
    do: true

  defp json_response_format?(%{type: type}) when type in ["json_object", "json_schema"], do: true
  defp json_response_format?(_), do: false

  defp tool_calls_from(%{"tool_calls" => calls}) when is_list(calls), do: calls
  defp tool_calls_from(_), do: []

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
