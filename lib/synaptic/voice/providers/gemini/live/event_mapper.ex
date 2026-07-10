defmodule Synaptic.Voice.Providers.Gemini.Live.EventMapper do
  @moduledoc false

  @spec normalize_event(map()) :: {:ok, %{event: atom(), data: map()}} | {:ignore, term()}
  def normalize_event(%{"setupComplete" => _}) do
    {:ok, %{event: :session_ready, data: %{}}}
  end

  def normalize_event(%{"goAway" => go_away}) do
    {:ok,
     %{event: :session_error, data: %{source: :provider, reason: :go_away, details: go_away}}}
  end

  def normalize_event(%{"toolCall" => payload}) do
    {:ok, %{event: :provider_outbound, data: %{type: :tool_call, payload: payload}}}
  end

  def normalize_event(%{"toolCallCancellation" => payload}) do
    {:ok, %{event: :provider_outbound, data: %{type: :tool_call_cancellation, payload: payload}}}
  end

  def normalize_event(%{"serverContent" => content}) when is_map(content) do
    cond do
      is_map(content["inputTranscription"]) ->
        normalize_input_transcription(content["inputTranscription"])

      is_map(content["modelTurn"]) ->
        normalize_model_turn(content["modelTurn"], content)

      content["turnComplete"] == true ->
        {:ok, %{event: :assistant_response_done, data: %{}}}

      content["interrupted"] == true ->
        {:ok, %{event: :duplex_interruption, data: %{reason: :speech_started}}}

      true ->
        {:ignore, :unhandled_server_content}
    end
  end

  def normalize_event(%{"inputTranscription" => payload}) when is_map(payload) do
    normalize_input_transcription(payload)
  end

  def normalize_event(%{"transcription" => payload}) when is_map(payload) do
    normalize_input_transcription(payload)
  end

  def normalize_event(other), do: {:ignore, {:unhandled, other}}

  defp normalize_input_transcription(payload) when is_map(payload) do
    text = payload["text"] || payload["transcript"]

    if is_binary(text) do
      is_final? =
        payload["isFinal"] == true or
          payload["final"] == true or
          payload["type"] == "final" or
          payload["state"] == "FINAL"

      event = if is_final?, do: :input_final_text, else: :input_partial_text
      {:ok, %{event: event, data: %{text: text}}}
    else
      {:ignore, :invalid_input_transcription}
    end
  end

  defp normalize_input_transcription(_), do: {:ignore, :invalid_input_transcription}

  defp normalize_model_turn(%{"parts" => parts}, content) when is_list(parts) do
    normalized_parts =
      Enum.flat_map(parts, fn
        %{"inlineData" => %{"mimeType" => mime, "data" => data}}
        when is_binary(mime) and is_binary(data) ->
          [{:audio, %{mime_type: mime, data: data}}]

        %{"text" => text} when is_binary(text) ->
          [{:text, text}]

        _ ->
          []
      end)

    {:ok,
     %{
       event: :model_turn_parts,
       data: %{
         parts: normalized_parts,
         turn_complete: content["turnComplete"] == true,
         interrupted: content["interrupted"] == true
       }
     }}
  end

  defp normalize_model_turn(_, _), do: {:ignore, :invalid_model_turn}
end
