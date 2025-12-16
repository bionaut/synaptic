defmodule Synaptic.StreamingTest do
  use ExUnit.Case, async: true

  describe "SSE parsing" do
    test "parse_sse_chunk extracts JSON from data prefix" do
      chunk = ~s(data: {"id":"test","choices":[{"delta":{"content":"Hello"}}]})
      result = parse_sse_chunk_internal(chunk)

      assert result == %{
               "id" => "test",
               "choices" => [%{"delta" => %{"content" => "Hello"}}]
             }
    end

    test "parse_sse_chunk returns nil for [DONE]" do
      assert parse_sse_chunk_internal("data: [DONE]") == nil
    end

    test "parse_sse_chunk handles empty lines" do
      assert parse_sse_chunk_internal("") == nil
    end

    test "parse_sse_chunk handles invalid JSON gracefully" do
      assert parse_sse_chunk_internal("data: {invalid json}") == nil
    end

    test "extract_delta_content gets content from delta" do
      chunk_data = %{
        "choices" => [
          %{"delta" => %{"content" => "Hello"}},
          %{"delta" => %{"content" => " world"}}
        ]
      }

      assert extract_delta_content_internal(chunk_data) == "Hello"
    end

    test "extract_delta_content returns nil when no content" do
      chunk_data = %{
        "choices" => [%{"delta" => %{}}]
      }

      assert extract_delta_content_internal(chunk_data) == nil
    end

    test "extract_delta_content returns nil for empty choices" do
      assert extract_delta_content_internal(%{"choices" => []}) == nil
    end
  end

  describe "SSE event parsing" do
    test "parse_sse_events splits on double newline" do
      data =
        ~s(data: {"choices":[{"delta":{"content":"Hello"}}]}\n\ndata: {"choices":[{"delta":{"content":" world"}}]}\n\n)

      {remaining, events, accumulated} = parse_sse_events_internal(data, "")

      assert remaining == ""
      assert length(events) == 2
      assert accumulated == "Hello world"
    end

    test "parse_sse_events handles incomplete buffer" do
      data =
        ~s(data: {"choices":[{"delta":{"content":"Hello"}}]}\n\ndata: {"choices":[{"delta":{"content":" wo)

      {remaining, events, accumulated} = parse_sse_events_internal(data, "")

      assert remaining == ~s(data: {"choices":[{"delta":{"content":" wo)
      assert length(events) == 1
      assert accumulated == "Hello"
    end

    test "parse_sse_events accumulates content correctly" do
      chunks = [
        ~s(data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":" "}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":"world"}}]}\n\n)
      ]

      {_, events, accumulated} =
        Enum.reduce(chunks, {"", [], ""}, fn chunk, {buffer, acc_events, acc_content} ->
          new_buffer = buffer <> chunk
          {rem, evts, new_acc} = parse_sse_events_internal(new_buffer, acc_content)
          {rem, acc_events ++ evts, new_acc}
        end)

      assert length(events) == 3
      assert accumulated == "Hello world"
    end

    test "parse_sse_events handles [DONE] marker" do
      data = ~s(data: {"choices":[{"delta":{"content":"Hello"}}]}\n\ndata: [DONE]\n\n)
      {remaining, events, accumulated} = parse_sse_events_internal(data, "")

      assert remaining == ""
      assert length(events) == 1
      assert accumulated == "Hello"
    end
  end

  describe "content accumulation" do
    test "accumulates chunks correctly" do
      chunks = ["Hello", " ", "world"]

      accumulated = Enum.reduce(chunks, "", fn chunk, acc -> acc <> chunk end)

      assert accumulated == "Hello world"
    end

    test "handles empty chunks" do
      chunks = ["Hello", "", "world"]

      accumulated = Enum.reduce(chunks, "", fn chunk, acc -> acc <> chunk end)

      assert accumulated == "Helloworld"
    end
  end

  # Helper functions to test internal parsing logic
  # These mirror the private functions in OpenAI module
  defp parse_sse_chunk_internal("data: [DONE]"), do: nil

  defp parse_sse_chunk_internal("data: " <> json) do
    case Jason.decode(json) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp parse_sse_chunk_internal(""), do: nil
  defp parse_sse_chunk_internal(_), do: nil

  defp extract_delta_content_internal(%{"choices" => [%{"delta" => %{"content" => content}} | _]})
       when is_binary(content) do
    content
  end

  defp extract_delta_content_internal(%{"choices" => [%{"delta" => %{}} | _]}) do
    nil
  end

  defp extract_delta_content_internal(_), do: nil

  defp parse_sse_events_internal(data, accumulated) do
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
      |> Enum.map(&parse_sse_chunk_internal/1)
      |> Enum.filter(&(&1 != nil))
      |> Enum.reduce({[], accumulated}, fn chunk_data, {acc_events, acc_content} ->
        case extract_delta_content_internal(chunk_data) do
          nil ->
            {acc_events, acc_content}

          content ->
            new_accumulated = acc_content <> content
            {[{content, new_accumulated} | acc_events], new_accumulated}
        end
      end)

    {incomplete, Enum.reverse(events), new_accumulated}
  end
end
