defmodule Synaptic.Voice.CapabilityGateway do
  @moduledoc """
  Deterministic authorization, confirmation, validation, and execution boundary.
  """

  alias Synaptic.Voice.{Capability, SecurityPolicy, SessionContext}

  def execute(
        %Capability{} = capability,
        arguments,
        %SessionContext{} = context,
        %SecurityPolicy{} = policy,
        opts \\ []
      )
      when is_map(arguments) do
    confirmed? = Keyword.get(opts, :confirmed, false)

    with :ok <- authorize(capability, context, policy),
         :ok <- validate_arguments(capability.parameters, arguments),
         :ok <- require_confirmation(capability, policy, confirmed?) do
      case Capability.invoke(capability, arguments, context) do
        {:ok, _result} = ok -> ok
        {:error, _reason} = error -> error
        result -> {:ok, result}
      end
    end
  rescue
    error -> {:error, {:capability_exception, Exception.message(error)}}
  end

  def authorize(
        %Capability{} = capability,
        %SessionContext{} = context,
        %SecurityPolicy{} = policy
      ) do
    cond do
      SecurityPolicy.denied?(policy, capability) ->
        {:error, :capability_denied}

      not SessionContext.capability_allowed?(context, capability.name) ->
        {:error, :capability_not_authorized}

      not required_scopes_present?(capability, context) ->
        {:error, :missing_required_scope}

      true ->
        :ok
    end
  end

  def validate_arguments(schema, arguments) when is_map(schema) and is_map(arguments) do
    required = field(schema, :required, [])
    properties = field(schema, :properties, %{})

    missing = Enum.reject(required, &has_key?(arguments, &1))

    cond do
      missing != [] ->
        {:error, {:missing_arguments, missing}}

      field(schema, :additionalProperties, true) == false and
          unknown_keys(arguments, properties) != [] ->
        {:error, {:unknown_arguments, unknown_keys(arguments, properties)}}

      true ->
        validate_property_types(arguments, properties)
    end
  end

  defp require_confirmation(capability, policy, false) do
    if SecurityPolicy.confirmation_required?(policy, capability) do
      {:confirmation_required,
       %{capability: capability.name, risk: capability.risk, one_shot: true}}
    else
      :ok
    end
  end

  defp require_confirmation(_capability, _policy, true), do: :ok

  defp required_scopes_present?(capability, context) do
    SessionContext.scopes_allowed?(context, capability.required_scopes)
  end

  defp validate_property_types(arguments, properties) do
    Enum.reduce_while(arguments, :ok, fn {key, value}, :ok ->
      property = property_schema(properties, key)

      case validate_value(property, value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {reason, key}}}
      end
    end)
  end

  defp validate_value(schema, value) do
    cond do
      not valid_type?(field(schema, :type, nil), value) ->
        {:error, :invalid_argument_type}

      not enum_valid?(field(schema, :enum, nil), value) ->
        {:error, :invalid_argument_value}

      is_number(value) and value < field(schema, :minimum, value) ->
        {:error, :argument_below_minimum}

      is_number(value) and value > field(schema, :maximum, value) ->
        {:error, :argument_above_maximum}

      is_binary(value) and String.length(value) < field(schema, :minLength, 0) ->
        {:error, :argument_too_short}

      is_binary(value) and
          String.length(value) > field(schema, :maxLength, String.length(value)) ->
        {:error, :argument_too_long}

      true ->
        :ok
    end
  end

  defp valid_type?(nil, _value), do: true
  defp valid_type?(type, value) when type in ["string", :string], do: is_binary(value)
  defp valid_type?(type, value) when type in ["integer", :integer], do: is_integer(value)
  defp valid_type?(type, value) when type in ["number", :number], do: is_number(value)
  defp valid_type?(type, value) when type in ["boolean", :boolean], do: is_boolean(value)
  defp valid_type?(type, value) when type in ["object", :object], do: is_map(value)
  defp valid_type?(type, value) when type in ["array", :array], do: is_list(value)
  defp valid_type?(_type, _value), do: false

  defp enum_valid?(nil, _value), do: true
  defp enum_valid?(allowed, value) when is_list(allowed), do: value in allowed
  defp enum_valid?(_allowed, _value), do: false

  defp property_schema(properties, key) do
    normalized_key = to_string(key)

    Enum.find_value(properties, %{}, fn {property_key, schema} ->
      if to_string(property_key) == normalized_key, do: schema
    end)
  end

  defp unknown_keys(arguments, properties) do
    allowed = properties |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()
    arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, to_string(&1)))
  end

  defp has_key?(map, key), do: Enum.any?(Map.keys(map), &(to_string(&1) == to_string(key)))
  defp field(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
