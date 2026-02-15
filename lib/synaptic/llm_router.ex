defmodule Synaptic.LLMRouter do
  @moduledoc false

  alias Synaptic.Tools

  @default_system_prompt """
  You are a router. Select the single best option. Reply with JSON like:
  {"choice": 1} or {"target": "step_name"}.
  """

  @default_prompt "Given the state below, pick the single best next step."
  @default_response_format :json_object

  def evaluate(_context, branches, prompt_input, opts \\ []) do
    with :ok <- validate_branches(branches),
         {:ok, formatted_input} <- format_prompt_input(prompt_input),
         {system_prompt, user_prompt, llm_opts} <-
           build_messages(branches, formatted_input, opts),
         {:ok, content} <- call_llm(system_prompt, user_prompt, llm_opts),
         {:ok, target} <- parse_response(content, branches) do
      {:ok, target}
    end
  end

  defp build_messages(branches, formatted_input, opts) do
    prompt = Keyword.get(opts, :prompt, @default_prompt)
    system_prompt = Keyword.get(opts, :system_prompt, @default_system_prompt)
    response_format = Keyword.get(opts, :response_format, @default_response_format)

    options_text =
      branches
      |> Enum.with_index(1)
      |> Enum.map(fn {{condition, target}, index} ->
        "#{index}. #{condition} -> #{Atom.to_string(target)}"
      end)
      |> Enum.join("\n")

    user_prompt = """
    #{prompt}

    Options:
    #{options_text}

    State:
    #{formatted_input}
    """

    llm_opts =
      opts
      |> Keyword.drop([:prompt, :system_prompt])
      |> Keyword.put_new(:response_format, response_format)

    {system_prompt, user_prompt, llm_opts}
  end

  defp call_llm(system_prompt, user_prompt, opts) do
    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_prompt}
    ]

    case Tools.chat(messages, opts) do
      {:ok, content} -> {:ok, content}
      {:ok, content, _usage} -> {:ok, content}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_llm_response, other}}
    end
  end

  defp validate_branches(branches) when is_list(branches) do
    case Enum.all?(branches, &valid_branch?/1) do
      true -> :ok
      false -> {:error, :invalid_branches}
    end
  end

  defp validate_branches(_), do: {:error, :invalid_branches}

  defp valid_branch?({condition, target})
       when is_binary(condition) and is_atom(target),
       do: true

  defp valid_branch?(_), do: false

  defp format_prompt_input(%{} = map) do
    case Jason.encode(map) do
      {:ok, json} -> {:ok, json}
      _ -> {:ok, inspect(map)}
    end
  end

  defp format_prompt_input(input) when is_binary(input), do: {:ok, input}
  defp format_prompt_input(_), do: {:error, :invalid_prompt_input}

  defp parse_response(%{} = map, branches) do
    target = Map.get(map, "target") || Map.get(map, :target)

    choice =
      Map.get(map, "choice") || Map.get(map, :choice) || Map.get(map, "option") ||
        Map.get(map, :option)

    cond do
      not is_nil(target) -> resolve_target(target, branches)
      not is_nil(choice) -> resolve_choice(choice, branches)
      true -> {:error, :invalid_llm_response}
    end
  end

  defp parse_response(content, branches) when is_binary(content) do
    trimmed = String.trim(content)

    case extract_integer(trimmed) do
      {:ok, index} -> resolve_choice(index, branches)
      :error -> resolve_target(trimmed, branches)
    end
  end

  defp parse_response(_other, _branches), do: {:error, :invalid_llm_response}

  defp resolve_choice(choice, branches) when is_integer(choice) do
    case Enum.at(branches, choice - 1) do
      {_, target} -> {:ok, target}
      nil -> {:error, {:invalid_route_choice, choice}}
    end
  end

  defp resolve_choice(choice, branches) when is_float(choice) do
    resolve_choice(trunc(choice), branches)
  end

  defp resolve_choice(choice, branches) when is_binary(choice) do
    case extract_integer(choice) do
      {:ok, index} -> resolve_choice(index, branches)
      :error -> resolve_target(choice, branches)
    end
  end

  defp resolve_choice(_choice, _branches), do: {:error, :invalid_llm_response}

  defp resolve_target(target, branches) when is_atom(target) do
    if target in branch_targets(branches) do
      {:ok, target}
    else
      {:error, {:invalid_route_target, target}}
    end
  end

  defp resolve_target(target, branches) when is_binary(target) do
    normalized =
      target
      |> String.trim()
      |> String.trim_leading(":")

    lookup =
      branches
      |> branch_targets()
      |> Enum.reduce(%{}, fn branch_target, acc ->
        name = Atom.to_string(branch_target)

        acc
        |> Map.put(name, branch_target)
        |> Map.put(String.downcase(name), branch_target)
      end)

    case Map.get(lookup, normalized) || Map.get(lookup, String.downcase(normalized)) do
      nil -> {:error, {:invalid_route_target, target}}
      step -> {:ok, step}
    end
  end

  defp resolve_target(_target, _branches), do: {:error, :invalid_llm_response}

  defp branch_targets(branches), do: Enum.map(branches, &elem(&1, 1))

  defp extract_integer(text) when is_binary(text) do
    case Regex.run(~r/\d+/, text) do
      [match] -> {:ok, String.to_integer(match)}
      _ -> :error
    end
  end
end
