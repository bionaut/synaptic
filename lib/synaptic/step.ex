defmodule Synaptic.Step do
  @moduledoc """
  Metadata structure for compiled workflow steps.
  """

  defstruct [
    :name,
    input: %{},
    output: %{},
    suspend?: false,
    resume_schema: %{},
    max_retries: 0,
    type: :sequential,
    scorers: []
  ]

  @type t :: %__MODULE__{
          name: atom(),
          input: map(),
          output: map(),
          suspend?: boolean(),
          resume_schema: map(),
          max_retries: non_neg_integer(),
          type: :sequential | :parallel | :async,
          scorers: list()
        }

  @doc false
  def new(name, opts) do
    %__MODULE__{
      name: name,
      input: Keyword.get(opts, :input, %{}),
      output: Keyword.get(opts, :output, %{}),
      suspend?: Keyword.get(opts, :suspend, false),
      resume_schema: Keyword.get(opts, :resume_schema, %{}),
      max_retries: Keyword.get(opts, :retry, 0),
      type: Keyword.get(opts, :type, :sequential),
      scorers: Keyword.get(opts, :scorers, [])
    }
  end

  @doc false
  def run(%__MODULE__{} = step, workflow_module, context) do
    apply(workflow_module, :__synaptic_handle__, [step.name, context])
  end
end
