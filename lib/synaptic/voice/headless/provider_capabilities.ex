defmodule Synaptic.Voice.Headless.ProviderCapabilities do
  @moduledoc false

  @enforce_keys [:stt_mode, :tts_mode, :supports_barge_in_cancel, :supports_turn_tts_consistency]
  defstruct stt_mode: :batch,
            stt_final_mode: :segment,
            tts_mode: :segmented_batch,
            supports_barge_in_cancel: false,
            supports_turn_tts_consistency: false

  @type stt_mode :: :batch | :partial_stream
  @type stt_final_mode :: :segment | :cumulative | :replace
  @type tts_mode :: :segmented_batch | :single_shot | :streaming

  @type t :: %__MODULE__{
          stt_mode: stt_mode(),
          stt_final_mode: stt_final_mode(),
          tts_mode: tts_mode(),
          supports_barge_in_cancel: boolean(),
          supports_turn_tts_consistency: boolean()
        }

  @spec default() :: t()
  def default do
    %__MODULE__{
      stt_mode: :batch,
      stt_final_mode: :segment,
      tts_mode: :segmented_batch,
      supports_barge_in_cancel: false,
      supports_turn_tts_consistency: false
    }
  end
end
