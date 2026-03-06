defmodule Synaptic.Voice.Providers.OpenAI.Realtime.EventMapper do
  @moduledoc false

  @spec normalize_event(map()) :: {:ok, %{event: atom(), data: map()}} | {:ignore, term()}
  def normalize_event(%{
        "type" => "conversation.item.input_audio_transcription.delta",
        "delta" => text
      })
      when is_binary(text) do
    {:ok, %{event: :input_partial_text, data: %{text: text}}}
  end

  def normalize_event(%{
        "type" => "conversation.item.input_audio_transcription.completed",
        "transcript" => text,
        "item_id" => item_id
      })
      when is_binary(text) and is_binary(item_id) do
    {:ok, %{event: :input_final_text, data: %{text: text, item_id: item_id}}}
  end

  def normalize_event(%{
        "type" => "conversation.item.input_audio_transcription.completed",
        "transcript" => text
      })
      when is_binary(text) do
    {:ok, %{event: :input_final_text, data: %{text: text}}}
  end

  def normalize_event(%{"type" => "response.audio_transcript.delta", "delta" => text})
      when is_binary(text) do
    {:ok, %{event: :assistant_text_chunk, data: %{text: text}}}
  end

  def normalize_event(%{"type" => "response.audio_transcript.done", "transcript" => text})
      when is_binary(text) do
    {:ok, %{event: :assistant_text_chunk, data: %{text: text}}}
  end

  def normalize_event(%{"type" => "response.text.delta", "delta" => text}) when is_binary(text) do
    {:ok, %{event: :assistant_text_chunk, data: %{text: text}}}
  end

  def normalize_event(%{"type" => "response.created"}) do
    {:ok, %{event: :assistant_response_started, data: %{}}}
  end

  def normalize_event(%{"type" => "response.done"}) do
    {:ok, %{event: :assistant_response_done, data: %{}}}
  end

  def normalize_event(%{"type" => "input_audio_buffer.speech_started"}) do
    {:ok, %{event: :duplex_interruption, data: %{reason: :speech_started}}}
  end

  def normalize_event(%{
        "type" => "error",
        "error" => %{"code" => "response_cancel_not_active"}
      }) do
    {:ignore, :response_cancel_not_active}
  end

  def normalize_event(%{"type" => "error", "error" => error}) do
    {:ok, %{event: :session_error, data: %{source: :provider, reason: error}}}
  end

  def normalize_event(%{"type" => type}), do: {:ignore, {:unhandled, type}}
  def normalize_event(other), do: {:ignore, {:unhandled, other}}
end
