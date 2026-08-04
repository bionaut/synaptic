defmodule Synaptic.Voice.Capability do
  @moduledoc """
  A model-visible capability and its executable, security-relevant metadata.
  """

  alias Synaptic.Tools.Tool

  @risk_levels [:read_only, :reversible_write, :external_action, :sensitive, :destructive]
  @executors [:direct, :workflow]
  @confirmation_modes [:policy, :always, :never]

  @enforce_keys [:name, :description, :parameters]
  defstruct name: nil,
            description: nil,
            parameters: nil,
            handler: nil,
            executor: :direct,
            risk: :read_only,
            confirmation: :policy,
            required_scopes: [],
            examples: [],
            limitations: [],
            metadata: %{}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          handler: nil | function(),
          executor: :direct | :workflow,
          risk: atom(),
          confirmation: :policy | :always | :never,
          required_scopes: [String.t() | atom()],
          examples: [String.t()],
          limitations: [String.t()],
          metadata: map()
        }

  def new!(%__MODULE__{} = capability), do: validate!(capability)
  def new!(attrs) when is_list(attrs), do: attrs |> Map.new() |> new!()
  def new!(attrs) when is_map(attrs), do: __MODULE__ |> struct!(attrs) |> validate!()

  def to_realtime_tool(%__MODULE__{} = capability) do
    %{
      type: "function",
      name: capability.name,
      description: model_description(capability),
      parameters: capability.parameters
    }
  end

  def to_tool(%__MODULE__{} = capability, execution_context \\ nil) do
    %Tool{
      name: capability.name,
      description: model_description(capability),
      schema: capability.parameters,
      handler: fn arguments ->
        case execute_for_tool(capability, arguments, execution_context) do
          {:ok, result} -> %{"ok" => true, "result" => result}
          {:error, reason} -> %{"ok" => false, "error" => inspect(reason, limit: 100)}
          result -> result
        end
      end
    }
  end

  def invoke(%__MODULE__{executor: :direct, handler: handler}, arguments, execution_context)
      when is_function(handler, 2),
      do: handler.(arguments, execution_context)

  def invoke(%__MODULE__{executor: :direct, handler: handler}, arguments, _execution_context)
      when is_function(handler, 1),
      do: handler.(arguments)

  def invoke(%__MODULE__{executor: :workflow}, _arguments, _execution_context),
    do: {:error, :workflow_delegation_required}

  defp execute_for_tool(capability, arguments, {context, policy}) do
    Synaptic.Voice.CapabilityGateway.execute(capability, arguments, context, policy)
  end

  defp execute_for_tool(capability, arguments, execution_context),
    do: invoke(capability, arguments, execution_context)

  def model_description(%__MODULE__{} = capability) do
    [
      capability.description,
      list_sentence("Limitations", capability.limitations),
      list_sentence("Examples", capability.examples)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp list_sentence(_label, []), do: nil
  defp list_sentence(label, values), do: "#{label}: #{Enum.join(values, "; ")}."

  defp validate!(%__MODULE__{} = capability) do
    cond do
      not is_binary(capability.name) or
          not Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_-]{0,63}$/, capability.name) ->
        raise ArgumentError, "invalid capability name: #{inspect(capability.name)}"

      not is_binary(capability.description) or capability.description == "" ->
        raise ArgumentError, "capability #{capability.name} requires a description"

      not is_map(capability.parameters) ->
        raise ArgumentError, "capability #{capability.name} requires a parameter schema"

      capability.executor not in @executors ->
        raise ArgumentError, "invalid executor for capability #{capability.name}"

      capability.risk not in @risk_levels ->
        raise ArgumentError, "invalid risk for capability #{capability.name}"

      capability.confirmation not in @confirmation_modes ->
        raise ArgumentError, "invalid confirmation policy for capability #{capability.name}"

      capability.executor == :direct and
          not (is_function(capability.handler, 1) or is_function(capability.handler, 2)) ->
        raise ArgumentError, "direct capability #{capability.name} requires a handler"

      true ->
        capability
    end
  end
end
