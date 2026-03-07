defmodule Synaptic.Voice.Headless.Strategy do
  @moduledoc false

  alias Synaptic.Voice.Headless.ProviderCapabilities

  @type tts_strategy :: :segmented_batch | :single_shot | :streaming

  @spec select_tts(map() | ProviderCapabilities.t()) :: tts_strategy()
  def select_tts(%ProviderCapabilities{tts_mode: :streaming}), do: :streaming
  def select_tts(%ProviderCapabilities{tts_mode: :single_shot}), do: :single_shot
  def select_tts(%ProviderCapabilities{supports_turn_tts_consistency: true}), do: :single_shot
  def select_tts(_), do: :segmented_batch
end
