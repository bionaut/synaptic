defmodule Synaptic.Voice.TextSegmenter do
  @moduledoc """
  Incremental text segmentation so TTS can start speaking before full text is available.
  """

  @delimiters [".", "!", "?", "\n"]

  @spec consume(String.t(), String.t()) :: {list(String.t()), String.t()}
  def consume(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    split_segments(buffer <> chunk, [])
  end

  @spec flush(String.t()) :: list(String.t())
  def flush(buffer) when is_binary(buffer) do
    if String.trim(buffer) == "" do
      []
    else
      [buffer]
    end
  end

  defp split_segments(text, acc) do
    case split_once(text) do
      {:segment, segment, rest} -> split_segments(rest, [segment | acc])
      :none -> {Enum.reverse(acc), text}
    end
  end

  defp split_once(text) do
    index =
      @delimiters
      |> Enum.map(&delimiter_index(text, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    if is_nil(index) do
      :none
    else
      split_at = index + 1
      {segment, rest} = String.split_at(text, split_at)
      {:segment, segment, rest}
    end
  end

  defp delimiter_index(text, delimiter) do
    case :binary.match(text, delimiter) do
      {index, _len} -> index
      :nomatch -> nil
    end
  end
end
