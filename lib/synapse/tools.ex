defmodule Synapse.Tools do
  @moduledoc """
  Helper utilities for invoking LLM providers from workflow steps.
  """

  @default_adapter Synapse.Tools.OpenAI

  @doc """
  Dispatches a chat completion request to the configured adapter.

  Pass `agent: :name` to pull default options (model, temperature, adapter,
  etc.) from the `:agents` configuration. Any explicit options provided at
  call time override the agent defaults.
  """
  def chat(messages, opts \\ []) when is_list(messages) do
    {agent_opts, call_opts} = agent_options(opts)

    merged_opts = Keyword.merge(agent_opts, call_opts)
    adapter = Keyword.get(merged_opts, :adapter, configured_adapter())

    adapter.chat(messages, merged_opts)
  end

  defp agent_options(opts) do
    {agent_name, remaining_opts} = Keyword.pop(opts, :agent)

    agent_opts =
      case agent_name do
        nil -> []
        name -> lookup_agent_opts(name)
      end

    {agent_opts, remaining_opts}
  end

  defp lookup_agent_opts(name) do
    agents = configured_agents()
    key = agent_key(name)

    case Map.fetch(agents, key) do
      {:ok, opts} -> opts
      :error -> raise ArgumentError, "unknown Synapse agent #{inspect(name)}"
    end
  end

  defp configured_agents do
    Application.get_env(:synapse, __MODULE__, [])
    |> Keyword.get(:agents, %{})
    |> normalize_agents()
  end

  defp configured_adapter do
    Application.get_env(:synapse, __MODULE__, [])
    |> Keyword.get(:llm_adapter, @default_adapter)
  end

  defp normalize_agents(%{} = agents) do
    Enum.reduce(agents, %{}, fn {name, opts}, acc ->
      Map.put(acc, agent_key(name), normalize_agent_opts(opts))
    end)
  end

  defp normalize_agents(list) when is_list(list) do
    Enum.reduce(list, %{}, fn {name, opts}, acc ->
      Map.put(acc, agent_key(name), normalize_agent_opts(opts))
    end)
  end

  defp normalize_agents(_), do: %{}

  defp normalize_agent_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "agent options must be a keyword list, got: #{inspect(opts)}"
    end
  end

  defp normalize_agent_opts(%{} = opts) do
    opts
    |> Map.to_list()
    |> normalize_agent_opts()
  end

  defp normalize_agent_opts(other) do
    raise ArgumentError, "agent options must be a keyword list, got: #{inspect(other)}"
  end

  defp agent_key(name) when is_atom(name), do: Atom.to_string(name)

  defp agent_key(name) when is_binary(name) and byte_size(name) > 0, do: name

  defp agent_key(name) do
    raise ArgumentError, "agent names must be atoms or strings, got: #{inspect(name)}"
  end
end
