defmodule Synaptic.RLM.Budget do
  @moduledoc """
  Tracks token/cost budgets and iteration counts for RLM runs.
  """

  use Agent

  defstruct token_budget: 100_000,
            tokens_used: 0,
            cost_budget: nil,
            cost_used: 0.0,
            iterations: 0,
            max_iterations: 20,
            root_calls: 0,
            sub_calls: 0

  @type t :: %__MODULE__{
          token_budget: non_neg_integer(),
          tokens_used: non_neg_integer(),
          cost_budget: number() | nil,
          cost_used: number(),
          iterations: non_neg_integer(),
          max_iterations: non_neg_integer(),
          root_calls: non_neg_integer(),
          sub_calls: non_neg_integer()
        }

  @doc """
  Starts a budget Agent initialized from opts.
  """
  def start_link(opts \\ []) do
    Agent.start_link(fn -> new(opts) end)
  end

  @doc """
  Builds a budget struct.
  """
  def new(opts \\ []) do
    %__MODULE__{
      token_budget: Keyword.get(opts, :token_budget, 100_000),
      max_iterations: Keyword.get(opts, :max_iterations, 20),
      cost_budget: Keyword.get(opts, :cost_budget)
    }
  end

  @doc """
  Stops the budget Agent.
  """
  def stop(budget) when is_pid(budget), do: Agent.stop(budget)

  @doc """
  Returns the current budget snapshot.
  """
  @spec snapshot(pid()) :: t()
  def snapshot(budget) when is_pid(budget), do: Agent.get(budget, & &1)

  @doc """
  Tracks token usage and increments call counters.
  """
  def track_usage(budget, usage_map, call_type \\ :root)

  def track_usage(%__MODULE__{} = budget, usage_map, call_type) do
    tokens = tokens_from_usage(usage_map)
    cost = cost_from_usage(usage_map)

    budget
    |> Map.update!(:tokens_used, &(&1 + tokens))
    |> Map.update!(:cost_used, &(&1 + cost))
    |> Map.update!(:iterations, &(&1 + 1))
    |> increment_call_count(call_type)
  end

  def track_usage(budget, usage_map, call_type) when is_pid(budget) do
    Agent.get_and_update(budget, fn state ->
      updated = track_usage(state, usage_map, call_type)
      {updated, updated}
    end)
  end

  defp tokens_from_usage(%{total_tokens: tokens}) when is_integer(tokens), do: tokens
  defp tokens_from_usage(%{"total_tokens" => tokens}) when is_integer(tokens), do: tokens
  defp tokens_from_usage(_), do: 0

  defp cost_from_usage(%{cost: cost}) when is_number(cost), do: cost
  defp cost_from_usage(%{"cost" => cost}) when is_number(cost), do: cost
  defp cost_from_usage(_), do: 0.0

  @doc """
  Returns true when within budgets.
  """
  def within_budget?(%__MODULE__{} = budget) do
    budget.tokens_used < budget.token_budget and
      budget.iterations < budget.max_iterations and
      (is_nil(budget.cost_budget) or budget.cost_used < budget.cost_budget)
  end

  def within_budget?(budget) when is_pid(budget), do: Agent.get(budget, &within_budget?/1)

  @doc """
  Remaining token budget (floored at 0).
  """
  def remaining_tokens(%__MODULE__{} = budget),
    do: max(0, budget.token_budget - budget.tokens_used)

  def remaining_tokens(budget) when is_pid(budget),
    do: Agent.get(budget, &remaining_tokens/1)

  @doc """
  Remaining iterations (floored at 0).
  """
  def remaining_iterations(%__MODULE__{} = budget),
    do: max(0, budget.max_iterations - budget.iterations)

  def remaining_iterations(budget) when is_pid(budget),
    do: Agent.get(budget, &remaining_iterations/1)

  @doc """
  Serializes the budget for reporting.
  """
  def to_map(%__MODULE__{} = budget) do
    %{
      tokens_used: budget.tokens_used,
      token_budget: budget.token_budget,
      iterations: budget.iterations,
      max_iterations: budget.max_iterations,
      root_calls: budget.root_calls,
      sub_calls: budget.sub_calls,
      cost_used: budget.cost_used,
      cost_budget: budget.cost_budget
    }
  end

  def to_map(budget) when is_pid(budget), do: budget |> snapshot() |> to_map()

  defp increment_call_count(budget, :root), do: Map.update!(budget, :root_calls, &(&1 + 1))
  defp increment_call_count(budget, :sub), do: Map.update!(budget, :sub_calls, &(&1 + 1))
  defp increment_call_count(budget, _), do: budget
end
