defmodule Synaptic.Voice.Sessions.Headless.Output do
  @moduledoc false

  alias Synaptic.Voice.TextSegmenter

  @enforce_keys [:strategy]
  defstruct strategy: :segmented_batch,
            assistant_text: "",
            tts_buffer: "",
            synthesis_opts: [],
            suppressed: false

  @type strategy :: :segmented_batch | :single_shot | :streaming
  @type action :: {:synthesize, String.t(), keyword()}

  @type t :: %__MODULE__{
          strategy: strategy(),
          assistant_text: String.t(),
          tts_buffer: String.t(),
          synthesis_opts: keyword(),
          suppressed: boolean()
        }

  @spec new(strategy()) :: t()
  def new(strategy), do: %__MODULE__{strategy: strategy}

  @spec consume_chunk(t(), String.t(), keyword()) :: {[action()], t()}
  def consume_chunk(state, chunk, opts \\ [])

  def consume_chunk(%__MODULE__{suppressed: true} = state, _chunk, _opts), do: {[], state}

  def consume_chunk(%__MODULE__{strategy: :segmented_batch} = state, chunk, opts) do
    {segments, tts_buffer} = TextSegmenter.consume(state.tts_buffer, chunk)
    synthesis_opts = Keyword.merge(state.synthesis_opts, opts)
    actions = Enum.map(segments, &{:synthesize, &1, synthesis_opts})

    {actions,
     %{
       state
       | assistant_text: state.assistant_text <> chunk,
         tts_buffer: tts_buffer,
         synthesis_opts: synthesis_opts
     }}
  end

  def consume_chunk(%__MODULE__{} = state, chunk, opts) do
    {[],
     %{
       state
       | assistant_text: state.assistant_text <> chunk,
         synthesis_opts: Keyword.merge(state.synthesis_opts, opts)
     }}
  end

  @spec finalize(t()) :: {[action()], boolean(), t()}
  def finalize(%__MODULE__{suppressed: true} = state) do
    {[], false, %{state | assistant_text: "", tts_buffer: "", synthesis_opts: []}}
  end

  def finalize(%__MODULE__{strategy: :segmented_batch} = state) do
    actions =
      state.tts_buffer
      |> TextSegmenter.flush()
      |> Enum.map(&{:synthesize, &1, state.synthesis_opts})

    {actions, true, %{state | assistant_text: "", tts_buffer: "", synthesis_opts: []}}
  end

  def finalize(%__MODULE__{} = state) do
    actions =
      case String.trim(state.assistant_text) do
        "" -> []
        _ -> [{:synthesize, state.assistant_text, state.synthesis_opts}]
      end

    {actions, true, %{state | assistant_text: "", tts_buffer: "", synthesis_opts: []}}
  end

  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = state) do
    %{state | assistant_text: "", tts_buffer: "", synthesis_opts: [], suppressed: true}
  end

  @spec reset_turn(t()) :: t()
  def reset_turn(%__MODULE__{} = state) do
    %{state | assistant_text: "", tts_buffer: "", synthesis_opts: [], suppressed: false}
  end

  @spec strategy(t()) :: strategy()
  def strategy(%__MODULE__{strategy: strategy}), do: strategy

  @spec tts_buffer(t()) :: String.t()
  def tts_buffer(%__MODULE__{tts_buffer: tts_buffer}), do: tts_buffer

  @spec suppressed?(t()) :: boolean()
  def suppressed?(%__MODULE__{suppressed: suppressed}), do: suppressed
end
