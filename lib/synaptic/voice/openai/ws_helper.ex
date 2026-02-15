defmodule Synaptic.Voice.OpenAI.WSHelper do
  @moduledoc """
  Utility to normalize provider WS payloads into Synaptic voice event names.
  """

  @behaviour Synaptic.Voice.TransportHelper

  @impl true
  def normalize_event(%{"type" => "input_audio.transcript.partial", "text" => text}) do
    {:ok, %{event: :input_partial_text, data: %{text: text}}}
  end

  def normalize_event(%{"type" => "input_audio.transcript.final", "text" => text}) do
    {:ok, %{event: :input_final_text, data: %{text: text}}}
  end

  def normalize_event(%{"type" => "response.text.delta", "text" => text}) do
    {:ok, %{event: :assistant_text_chunk, data: %{text: text}}}
  end

  def normalize_event(%{"type" => "response.text.done"}) do
    {:ok, %{event: :assistant_text_done, data: %{}}}
  end

  def normalize_event(%{"type" => "response.audio.delta", "audio" => audio}) do
    {:ok, %{event: :assistant_audio_chunk, data: %{audio_chunk: audio}}}
  end

  def normalize_event(%{"type" => "response.audio.done"}) do
    {:ok, %{event: :assistant_audio_done, data: %{}}}
  end

  def normalize_event(payload), do: {:error, {:unknown_event, payload}}
end
