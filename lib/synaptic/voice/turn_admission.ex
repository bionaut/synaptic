defmodule Synaptic.Voice.TurnAdmission do
  @moduledoc """
  Normalizes application-owned decisions about whether a final transcript
  should resume a headless voice workflow or keep the current turn open.

  A policy may be a one- or two-argument function, or a module exporting
  `decide/2`. Policies return `:commit`, `:keep_listening`, or either action
  paired with an application metadata map. The headless session evaluates the
  policy asynchronously so network- or model-backed policies do not block the
  session GenServer.
  """

  @type action :: :commit | :keep_listening
  @type decision :: action() | {action(), map()}
  @type result :: {:ok, action(), map()} | {:error, term()}

  @callback decide(input :: map(), opts :: keyword()) :: decision()

  @spec evaluate(module() | function(), map(), keyword()) :: result()
  def evaluate(policy, input, opts \\ []) when is_map(input) do
    if is_list(opts) do
      policy
      |> invoke(input, opts)
      |> normalize()
    else
      {:error, {:invalid_options, opts}}
    end
  rescue
    error -> {:error, {:exception, error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp invoke(policy, input, opts) when is_function(policy, 2), do: policy.(input, opts)
  defp invoke(policy, input, _opts) when is_function(policy, 1), do: policy.(input)

  defp invoke(policy, input, opts) when is_atom(policy) do
    if Code.ensure_loaded?(policy) and function_exported?(policy, :decide, 2) do
      policy.decide(input, opts)
    else
      {:error, {:invalid_policy, policy}}
    end
  end

  defp invoke(policy, _input, _opts), do: {:error, {:invalid_policy, policy}}

  defp normalize(:commit), do: {:ok, :commit, %{}}
  defp normalize(:keep_listening), do: {:ok, :keep_listening, %{}}

  defp normalize({action, metadata})
       when action in [:commit, :keep_listening] and is_map(metadata),
       do: {:ok, action, metadata}

  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(other), do: {:error, {:invalid_decision, other}}
end
