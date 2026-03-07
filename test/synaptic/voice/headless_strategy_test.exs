defmodule Synaptic.Voice.HeadlessStrategyTest do
  use ExUnit.Case

  alias Synaptic.Voice.Headless.{ProviderCapabilities, Strategy}
  alias Synaptic.Voice.ProviderRegistry

  test "provider registry exposes headless capability metadata" do
    assert {:ok, metadata} = ProviderRegistry.metadata(:openai)
    assert metadata.modules.tts == Synaptic.Voice.Providers.OpenAI.TTSAdapter
    assert metadata.capabilities.tts_mode == :single_shot

    assert {:ok, caps} = ProviderRegistry.capabilities(:eleven_labs)
    assert caps.stt_mode == :batch
    assert caps.supports_turn_tts_consistency
  end

  test "strategy selects streaming, single_shot, then segmented fallback" do
    assert Strategy.select_tts(%ProviderCapabilities{
             stt_mode: :partial_stream,
             tts_mode: :streaming,
             supports_barge_in_cancel: true,
             supports_turn_tts_consistency: true
           }) == :streaming

    assert Strategy.select_tts(%ProviderCapabilities{
             stt_mode: :batch,
             tts_mode: :single_shot,
             supports_barge_in_cancel: true,
             supports_turn_tts_consistency: true
           }) == :single_shot

    assert Strategy.select_tts(%ProviderCapabilities{
             stt_mode: :batch,
             tts_mode: :segmented_batch,
             supports_barge_in_cancel: false,
             supports_turn_tts_consistency: false
           }) == :segmented_batch
  end
end
