defmodule Synaptic.Voice.Sessions.Headless.Output do
  @moduledoc false

  alias Synaptic.Voice.TextSegmenter

  @enforce_keys [:strategy]
  defstruct strategy: :segmented_batch,
            assistant_text: "",
            tts_buffer: "",
            suppressed: false

  @type strategy :: :segmented_batch | :single_shot | :streaming
  @type action :: {:synthesize, String.t()}

  @type t :: %__MODULE__{
          strategy: strategy(),
          assistant_text: String.t(),
          tts_buffer: String.t(),
          suppressed: boolean()
        }

  @spec new(strategy()) :: t()
  def new(strategy), do: %__MODULE__{strategy: strategy}

  @spec consume_chunk(t(), String.t()) :: {[action()], t()}
  def consume_chunk(%__MODULE__{suppressed: true} = state, _chunk), do: {[], state}

  def consume_chunk(%__MODULE__{strategy: :segmented_batch} = state, chunk) do
    {segments, tts_buffer} = TextSegmenter.consume(state.tts_buffer, chunk)
    actions = Enum.map(segments, &{:synthesize, &1})
    {actions, %{state | assistant_text: state.assistant_text <> chunk, tts_buffer: tts_buffer}}
  end

  def consume_chunk(%__MODULE__{} = state, chunk) do
    {[], %{state | assistant_text: state.assistant_text <> chunk}}
  end

  @spec finalize(t()) :: {[action()], boolean(), t()}
  def finalize(%__MODULE__{suppressed: true} = state) do
    {[], false, %{state | assistant_text: "", tts_buffer: ""}}
  end

  def finalize(%__MODULE__{strategy: :segmented_batch} = state) do
    actions =
      state.tts_buffer
      |> TextSegmenter.flush()
      |> Enum.map(&{:synthesize, &1})

    {actions, true, %{state | assistant_text: "", tts_buffer: ""}}
  end

  def finalize(%__MODULE__{} = state) do
    actions =
      case String.trim(state.assistant_text) do
        "" -> []
        _ -> [{:synthesize, state.assistant_text}]
      end

    {actions, true, %{state | assistant_text: "", tts_buffer: ""}}
  end

  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = state) do
    %{state | assistant_text: "", tts_buffer: "", suppressed: true}
  end

  @spec reset_turn(t()) :: t()
  def reset_turn(%__MODULE__{} = state) do
    %{state | assistant_text: "", tts_buffer: "", suppressed: false}
  end

  @spec strategy(t()) :: strategy()
  def strategy(%__MODULE__{strategy: strategy}), do: strategy

  @spec tts_buffer(t()) :: String.t()
  def tts_buffer(%__MODULE__{tts_buffer: tts_buffer}), do: tts_buffer

  @spec suppressed?(t()) :: boolean()
  def suppressed?(%__MODULE__{suppressed: suppressed}), do: suppressed
end
