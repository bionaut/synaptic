defmodule Synaptic.Voice.SessionContext do
  @moduledoc """
  Typed, session-scoped customer and authorization context.

  Values exist only in the owning voice session process and are not persisted by
  Synaptic. Only fields classified as `:safe` are compiled into model prompts.
  """

  defstruct values: %{}, authorization: %{capabilities: :all, scopes: MapSet.new()}, metadata: %{}

  @classifications [:safe, :internal, :restricted]

  def new!(context_schema, values \\ %{}, opts \\ [])
      when is_map(context_schema) and is_map(values) do
    normalized_schema = normalize_schema(context_schema)
    normalized_values = normalize_values(values, normalized_schema)
    reject_unknown!(values, normalized_schema)

    authorization =
      opts
      |> Keyword.get(:authorization, %{})
      |> normalize_authorization()

    %__MODULE__{
      values: normalized_values,
      authorization: authorization,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  def prompt_values(%__MODULE__{values: values}, context_schema) do
    safe_keys =
      context_schema
      |> normalize_schema()
      |> Enum.filter(fn {_key, spec} -> spec.classification == :safe end)
      |> Map.new()
      |> Map.keys()

    Map.take(values, safe_keys)
  end

  def capability_allowed?(%__MODULE__{authorization: %{capabilities: :all}}, _name), do: true

  def capability_allowed?(%__MODULE__{authorization: %{capabilities: allowed}}, name),
    do: MapSet.member?(allowed, name)

  def scopes(%__MODULE__{authorization: %{scopes: scopes}}), do: scopes

  def scopes_allowed?(%__MODULE__{} = context, required_scopes) do
    granted = scopes(context)
    Enum.all?(required_scopes, &MapSet.member?(granted, &1))
  end

  defp normalize_schema(schema) do
    Enum.map(schema, fn {key, definition} ->
      key = normalize_declared_key!(key)
      {key, normalize_field_definition!(key, definition)}
    end)
    |> Map.new()
  end

  defp normalize_values(values, schema) do
    Enum.reduce(schema, %{}, fn {key, definition}, acc ->
      value = Map.get(values, key, Map.get(values, Atom.to_string(key)))

      cond do
        is_nil(value) and definition.required ->
          raise ArgumentError, "missing required session context field: #{key}"

        is_nil(value) ->
          acc

        valid_value_type?(value, definition.type) ->
          Map.put(acc, key, value)

        true ->
          raise ArgumentError,
                "invalid value type for session context field #{key}; expected #{definition.type}"
      end
    end)
  end

  defp reject_unknown!(values, schema) do
    allowed = schema |> Map.keys() |> Enum.flat_map(&[&1, Atom.to_string(&1)]) |> MapSet.new()
    unknown = values |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unknown != [] do
      raise ArgumentError, "undeclared session context fields: #{inspect(unknown)}"
    end
  end

  defp normalize_authorization(authorization) do
    capabilities =
      Map.get(authorization, :capabilities, Map.get(authorization, "capabilities", :all))

    scopes = Map.get(authorization, :scopes, Map.get(authorization, "scopes", []))

    %{
      capabilities: if(capabilities == :all, do: :all, else: MapSet.new(capabilities)),
      scopes: MapSet.new(scopes)
    }
  end

  defp normalize_field_definition!(_key, classification) when classification in @classifications,
    do: %{classification: classification, type: :string, required: false}

  defp normalize_field_definition!(key, definition) when is_map(definition) do
    classification =
      Map.get(definition, :classification, Map.get(definition, "classification"))

    type = Map.get(definition, :type, Map.get(definition, "type", :string))
    required = Map.get(definition, :required, Map.get(definition, "required", false))

    unless classification in @classifications do
      raise ArgumentError,
            "invalid context classification #{inspect(classification)} for #{inspect(key)}"
    end

    unless type in [:string, :integer, :number, :boolean, :map, :list] do
      raise ArgumentError, "invalid context type #{inspect(type)} for #{inspect(key)}"
    end

    unless is_boolean(required) do
      raise ArgumentError, "context field #{inspect(key)} requires a boolean :required value"
    end

    %{classification: classification, type: type, required: required}
  end

  defp normalize_field_definition!(key, definition) do
    raise ArgumentError,
          "invalid context field definition #{inspect(definition)} for #{inspect(key)}"
  end

  defp valid_value_type?(value, :string), do: is_binary(value)
  defp valid_value_type?(value, :integer), do: is_integer(value)
  defp valid_value_type?(value, :number), do: is_number(value)
  defp valid_value_type?(value, :boolean), do: is_boolean(value)
  defp valid_value_type?(value, :map), do: is_map(value)
  defp valid_value_type?(value, :list), do: is_list(value)

  defp normalize_declared_key!(key) when is_atom(key), do: key

  defp normalize_declared_key!(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> raise ArgumentError, "context schema keys must be existing atoms"
    end
  end

  defp normalize_declared_key!(key),
    do: raise(ArgumentError, "invalid context schema key: #{inspect(key)}")
end
