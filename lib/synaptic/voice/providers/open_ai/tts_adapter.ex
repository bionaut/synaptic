defmodule Synaptic.Voice.Providers.OpenAI.TTSAdapter do
  @moduledoc """
  OpenAI-oriented TTS adapter that emits chunked audio messages to the owning session.
  """

  use GenServer

  @behaviour Synaptic.Voice.TTSAdapter

  alias Synaptic.Voice.Providers.OpenAI
  alias Synaptic.Voice.Providers.TTSAdapterSupport

  @default_endpoint "https://api.openai.com/v1/audio/speech"

  @impl true
  def start_link(owner, opts) do
    GenServer.start_link(__MODULE__, {owner, opts})
  end

  @impl true
  def synthesize_segment(adapter, text_segment, opts \\ []) do
    GenServer.cast(adapter, {:synthesize, text_segment, opts})
    :ok
  end

  @impl true
  def flush(adapter, opts \\ []) do
    GenServer.cast(adapter, {:flush, opts})
    :ok
  end

  @impl true
  def cancel_output(adapter) do
    GenServer.cast(adapter, :cancel)
    :ok
  end

  @impl true
  def stop(adapter, reason) do
    TTSAdapterSupport.stop_process(adapter, reason)
  end

  @impl true
  def init({owner, opts}) do
    {:ok, TTSAdapterSupport.init_state(owner, opts)}
  end

  @impl true
  def handle_cast(:cancel, state) do
    {:noreply, TTSAdapterSupport.cancel(state, :openai)}
  end

  def handle_cast({:synthesize, text_segment, opts}, state) do
    generation = state.generation
    result = synthesize(text_segment, Keyword.merge(state.opts, opts))
    {:noreply, TTSAdapterSupport.handle_synthesis_result(state, generation, result)}
  end

  def handle_cast({:flush, _opts}, state) do
    {:noreply, TTSAdapterSupport.flush(state, :openai)}
  end

  defp synthesize(text_segment, opts) do
    audio_format =
      Keyword.get(opts, :audio_format, OpenAI.config(opts)[:tts_audio_format] || "pcm16")

    base_body = %{
      model:
        Keyword.get(opts, :tts_model, OpenAI.config(opts)[:tts_model] || "gpt-4o-mini-tts"),
      input: text_segment,
      voice: Keyword.get(opts, :voice, OpenAI.config(opts)[:voice] || "alloy"),
      format: audio_format
    }

    body =
      base_body
      |> maybe_put_speed(opts)
      |> maybe_put_instructions(opts)
      |> Jason.encode!()

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer " <> OpenAI.api_key(opts)}
    ]

    request = Finch.build(:post, endpoint(opts), headers, body)

    case Finch.request(request, OpenAI.finch(opts)) do
      {:ok, %Finch.Response{status: 200, body: response_body, headers: response_headers}}
      when is_binary(response_body) ->
        content_type = header_value(response_headers, "content-type")
        {:ok, response_body, tts_meta(audio_format, content_type)}

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:upstream_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tts_meta("pcm16", content_type) do
    normalized_content_type = normalize_content_type(content_type)

    if normalized_content_type in ["audio/l16", "application/octet-stream"] do
      %{
        provider: :openai,
        audio_format: %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1},
        content_type: "audio/L16"
      }
    else
      tts_meta_from_content_type(normalized_content_type)
    end
  end

  defp tts_meta(audio_format, content_type) do
    normalized_content_type = normalize_content_type(content_type)

    if normalized_content_type != "application/octet-stream" do
      tts_meta_from_content_type(normalized_content_type)
    else
      %{
        provider: :openai,
        audio_format: audio_format,
        content_type: content_type(audio_format)
      }
    end
  end

  defp tts_meta_from_content_type("audio/mpeg") do
    %{
      provider: :openai,
      audio_format: "mp3",
      content_type: "audio/mpeg"
    }
  end

  defp tts_meta_from_content_type("audio/mp3"),
    do: tts_meta_from_content_type("audio/mpeg")

  defp tts_meta_from_content_type("audio/ogg") do
    %{
      provider: :openai,
      audio_format: "opus",
      content_type: "audio/ogg"
    }
  end

  defp tts_meta_from_content_type("audio/wav") do
    %{
      provider: :openai,
      audio_format: "wav",
      content_type: "audio/wav"
    }
  end

  defp tts_meta_from_content_type("audio/l16") do
    %{
      provider: :openai,
      audio_format: %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1},
      content_type: "audio/L16"
    }
  end

  defp tts_meta_from_content_type(_unknown_content_type) do
    %{
      provider: :openai,
      audio_format: %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1},
      content_type: "audio/L16"
    }
  end

  defp header_value(headers, name) when is_list(headers) do
    downcased_name = String.downcase(name)

    headers
    |> Enum.find_value(fn
      {header_name, header_value} when is_binary(header_name) and is_binary(header_value) ->
        if String.downcase(header_name) == downcased_name, do: header_value, else: nil

      _ ->
        nil
    end)
  end

  defp header_value(_headers, _name), do: nil

  defp normalize_content_type(content_type) when is_binary(content_type) do
    content_type
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp normalize_content_type(_), do: "application/octet-stream"

  defp content_type("mp3"), do: "audio/mpeg"
  defp content_type("wav"), do: "audio/wav"
  defp content_type("pcm16"), do: "audio/L16"
  defp content_type("opus"), do: "audio/ogg"
  defp content_type(_), do: "application/octet-stream"

  defp maybe_put_speed(body, opts) do
    case Keyword.get(opts, :speed, OpenAI.config(opts)[:tts_speed]) do
      speed when is_number(speed) and speed >= 0.25 and speed <= 4.0 ->
        Map.put(body, :speed, speed)

      _ ->
        body
    end
  end

  defp maybe_put_instructions(body, opts) do
    case Keyword.get(opts, :instructions, OpenAI.config(opts)[:tts_instructions]) do
      instructions when is_binary(instructions) and instructions != "" ->
        Map.put(body, :instructions, instructions)

      _ ->
        body
    end
  end

  defp endpoint(opts),
    do: opts[:endpoint] || OpenAI.config(opts)[:tts_endpoint] || @default_endpoint
end
