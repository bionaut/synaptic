defmodule Synaptic.Scorer do
  @moduledoc """
  Behaviour and helper types for step-level scoring in Synaptic workflows.

  A scorer evaluates the outcome of a workflow step and returns a
  normalized score (typically between 0.0 and 1.0), along with
  optional human-readable reasoning and arbitrary details.

  Scorers are attached to steps via the workflow DSL and are invoked
  automatically by `Synaptic.Runner` after a step completes successfully.
  """

  alias Synaptic.Step

  defmodule Context do
    @moduledoc """
    Immutable snapshot passed to scorers when evaluating a step.

    It contains the step metadata, workflow module, run identifier,
    the context before and after the step, and the step's return data.
    """

    @enforce_keys [:step, :workflow, :run_id, :pre_context, :post_context, :output]
    defstruct [
      :step,
      :workflow,
      :run_id,
      :pre_context,
      :post_context,
      :output,
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            step: Step.t(),
            workflow: module(),
            run_id: String.t(),
            pre_context: map(),
            post_context: map(),
            output: map(),
            metadata: map()
          }
  end

  defmodule Result do
    @moduledoc """
    Standardized result returned by scorers.

    The `score` field is a numeric value (usually between 0.0 and 1.0)
    that represents how well the step output satisfied the scorer's
    criteria. The `reason` and `details` fields are optional but
    recommended for debugging and observability.
    """

    @enforce_keys [:name, :step, :run_id, :score]
    defstruct [
      :name,
      :step,
      :run_id,
      :score,
      reason: nil,
      details: %{},
      timestamp: nil
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            step: atom(),
            run_id: String.t(),
            score: number(),
            reason: String.t() | nil,
            details: map(),
            timestamp: NaiveDateTime.t() | nil
          }

    @doc """
    Convenience constructor for scorer results.

    The `:name`, `:step`, `:run_id`, and `:score` keys are required.
    A `timestamp` will be filled in with `NaiveDateTime.utc_now/0` if
    not explicitly provided.
    """
    @spec new(Keyword.t()) :: t()
    def new(opts) when is_list(opts) do
      name = Keyword.fetch!(opts, :name)
      step = Keyword.fetch!(opts, :step)
      run_id = Keyword.fetch!(opts, :run_id)
      score = Keyword.fetch!(opts, :score)

      reason = Keyword.get(opts, :reason)
      details = Keyword.get(opts, :details, %{})
      timestamp = Keyword.get_lazy(opts, :timestamp, &NaiveDateTime.utc_now/0)

      %__MODULE__{
        name: name,
        step: step,
        run_id: run_id,
        score: score,
        reason: reason,
        details: details,
        timestamp: timestamp
      }
    end
  end

  @typedoc """
  A scorer module evaluates a step given a `Synaptic.Scorer.Context`
  and returns a `Synaptic.Scorer.Result`.
  """
  @callback score(Context.t(), metadata :: map()) :: Result.t()

  @type scorer_spec :: module() | {module(), keyword()} | %{module: module(), opts: keyword()}

  @doc false
  @spec normalize_scorer_specs(term()) :: [scorer_spec()]
  def normalize_scorer_specs(nil), do: []
  def normalize_scorer_specs([]), do: []

  def normalize_scorer_specs(list) when is_list(list) do
    Enum.map(list, fn
      %{} = map when is_map_key(map, :module) ->
        %{module: Map.fetch!(map, :module), opts: Map.get(map, :opts, [])}

      {mod, opts} when is_atom(mod) and is_list(opts) ->
        %{module: mod, opts: opts}

      mod when is_atom(mod) ->
        %{module: mod, opts: []}
    end)
  end

  def normalize_scorer_specs(other), do: normalize_scorer_specs([other])
end
