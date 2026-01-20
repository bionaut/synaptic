defmodule Synaptic.RLM do
  @moduledoc """
  Recursive Language Model helper for processing large contexts at runtime.

  RLM runs inside a workflow step and exposes tools for slicing/searching the
  external context, delegating to sub-agents, and persisting state.
  """

  require Logger
  alias Synaptic.RLM.{Budget, Environment, Tools}

  @default_max_iterations 20
  @default_token_budget 100_000

  @type stats :: %{budget: map(), variables: map(), context_length: non_neg_integer()}

  @doc """
  Process a large context using the RLM pattern.

  Options:
    * `:root_agent` - Agent for root orchestration (default: :root)
    * `:sub_agent` - Agent for sub-model calls (default: :sub)
    * `:max_iterations` - Max root iterations (default: 20)
    * `:token_budget` - Total token budget to respect (default: 100_000)
    * `:cost_budget` - Optional cost ceiling
    * `:tools` - Additional tools to expose alongside RLM built-ins
    * `:system_prompt` - Override the root system prompt
    * `:accept_content_as_answer` - When true, plain assistant replies are treated as answers (default: true)
    * `:min_subcalls_per_root` - Minimum sub-agent calls required per root call (default: 0)
    * `:max_enforcement_attempts` - Max times to re-prompt for missing subcalls (default: 2)
    * `:enforcement_message` - Custom message injected when subcalls are missing
    * `:progress_logger` - Optional callback for per-iteration progress
    * `:receive_timeout` - Adapter receive timeout in ms
  """
  @spec process(String.t(), String.t(), keyword()) ::
          {:ok, String.t(), stats()} | {:error, term(), stats()}
  def process(context, query, opts \\ []) when is_binary(query) do
    case Environment.start_link(context) do
      {:ok, env} ->
        case Budget.start_link(budget_opts(opts)) do
          {:ok, budget} ->
            try do
              do_process(env, budget, query, opts)
            after
              Budget.stop(budget)
              Environment.stop(env)
            end

          {:error, reason} ->
            snapshot = Environment.snapshot(env)
            Environment.stop(env)

            {:error, reason,
             %{
               budget: nil,
               variables: snapshot.variables,
               context_length: snapshot.context_length
             }}
        end

      {:error, reason} ->
        {:error, reason, %{budget: nil, variables: %{}, context_length: 0}}
    end
  end

  defp budget_opts(opts) do
    [
      token_budget: Keyword.get(opts, :token_budget, @default_token_budget),
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      cost_budget: Keyword.get(opts, :cost_budget)
    ]
  end

  defp do_process(env, budget, query, opts) do
    root_agent = Keyword.get(opts, :root_agent, :root)
    sub_agent = Keyword.get(opts, :sub_agent, :sub)
    accept_content_as_answer? = Keyword.get(opts, :accept_content_as_answer, true)
    receive_timeout = Keyword.get(opts, :receive_timeout)
    incremental_usage? = Keyword.get(opts, :incremental_usage, true)

    usage_callback =
      if incremental_usage? do
        fn usage ->
          Budget.track_usage(budget, usage, :root)
          if Budget.within_budget?(budget), do: :cont, else: :halt
        end
      end

    tools =
      Tools.built_in_tools(env, budget,
        sub_agent: sub_agent,
        tools: extra_tools(env, opts) ++ Keyword.get(opts, :tools, [])
      )

    messages = seed_messages(env, query, opts)

    chat_opts =
      [
        agent: root_agent,
        tools: tools,
        return_usage: true
      ]
      |> maybe_put_timeout(receive_timeout)
      |> maybe_put_on_usage(usage_callback)

    loop(%{
      env: env,
      budget: budget,
      root_agent: root_agent,
      messages: messages,
      tools: tools,
      chat_opts: chat_opts,
      incremental_usage?: incremental_usage?,
      accept_content_as_answer?: accept_content_as_answer?,
      progress_logger: Keyword.get(opts, :progress_logger),
      min_subcalls_per_root: Keyword.get(opts, :min_subcalls_per_root, 0),
      max_enforcement_attempts: Keyword.get(opts, :max_enforcement_attempts, 2),
      enforcement_message: Keyword.get(opts, :enforcement_message),
      enforcement_attempts: 0
    })
  end

  defp loop(state) do
    cond do
      Environment.answer_ready?(state.env) ->
        {:ok, Environment.answer(state.env), build_stats(state)}

      not Budget.within_budget?(state.budget) ->
        {:error, :budget_exceeded, build_stats(state)}

      true ->
        perform_iteration(state)
    end
  end

  defp perform_iteration(state) do
    prev_sub_calls = Budget.to_map(state.budget).sub_calls
    log_call_start(state)

    Task.async(fn -> Synaptic.Tools.chat(state.messages, state.chat_opts) end)
    |> wait_for_chat(state, 0, prev_sub_calls)
  end

  defp handle_response(state, response) do
    content = response_content(response)
    updated_state = maybe_mark_answer(state, content)
    %{updated_state | messages: append_message(updated_state.messages, content)}
  end

  defp response_content(%{content: content}), do: content
  defp response_content(%{"content" => content}), do: content
  defp response_content(content) when is_binary(content), do: content
  defp response_content(_), do: ""

  defp append_message(messages, content) do
    messages ++ [%{role: "assistant", content: content}]
  end

  defp maybe_mark_answer(state, content) do
    cond do
      Environment.answer_ready?(state.env) ->
        state

      state.accept_content_as_answer? and is_binary(content) and String.trim(content) != "" ->
        Environment.mark_answer(state.env, content)
        state

      true ->
        state
    end
  end

  defp build_stats(state) do
    env_snapshot = Environment.snapshot(state.env)

    %{
      budget: Budget.to_map(state.budget),
      variables: env_snapshot.variables,
      context_length: env_snapshot.context_length
    }
  end

  defp wait_for_chat(task, state, waited_ms, prev_sub_calls) do
    case Task.yield(task, 5_000) do
      {:ok, result} ->
        handle_chat_result(state, result, prev_sub_calls)

      {:exit, reason} ->
        log_call_end({:error, reason}, state, %{})
        {:error, reason, build_stats(state)}

      nil ->
        log_wait(waited_ms + 5_000, state)
        wait_for_chat(task, state, waited_ms + 5_000, prev_sub_calls)
    end
  end

  defp handle_chat_result(state, {:ok, response, %{usage: usage}}, prev_sub_calls) do
    maybe_track_usage(state, usage)
    log_call_end(:ok, state, usage)
    maybe_enforce_subcalls(state, response, usage, prev_sub_calls)
  end

  defp handle_chat_result(state, {:ok, response}, prev_sub_calls) do
    maybe_track_usage(state, %{})
    log_call_end(:ok, state, %{})
    maybe_enforce_subcalls(state, response, %{}, prev_sub_calls)
  end

  defp handle_chat_result(state, {:error, reason}, _prev_sub_calls) do
    log_call_end({:error, reason}, state, %{})
    {:error, reason, build_stats(state)}
  end

  defp log_wait(waited_ms, state) do
    budget = Budget.to_map(state.budget)

    Logger.info(fn ->
      "RLM root call waiting #{waited_ms}ms tokens #{budget.tokens_used}/#{budget.token_budget} " <>
        "root_calls #{budget.root_calls} sub_calls #{budget.sub_calls}"
    end)
  end

  defp log_call_start(state) do
    budget = Budget.to_map(state.budget)

    Logger.info(fn ->
      "RLM root call #{budget.iterations + 1}/#{budget.max_iterations} " <>
        "tokens #{budget.tokens_used}/#{budget.token_budget} " <>
        "root_calls #{budget.root_calls} sub_calls #{budget.sub_calls}"
    end)
  end

  defp maybe_put_timeout(opts, nil), do: opts
  defp maybe_put_timeout(opts, timeout), do: Keyword.put(opts, :receive_timeout, timeout)
  defp maybe_put_on_usage(opts, nil), do: opts
  defp maybe_put_on_usage(opts, fun), do: Keyword.put(opts, :on_usage, fun)

  defp log_call_end(:ok, state, usage) do
    budget = Budget.to_map(state.budget)
    used = Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") || 0

    Logger.info(fn ->
      "RLM root call completed tokens_used_now #{budget.tokens_used}/#{budget.token_budget} " <>
        "delta_tokens #{used} root_calls #{budget.root_calls} sub_calls #{budget.sub_calls}"
    end)
  end

  defp log_call_end({:error, reason}, state, _usage) do
    budget = Budget.to_map(state.budget)

    Logger.info(fn ->
      "RLM root call failed tokens #{budget.tokens_used}/#{budget.token_budget} " <>
        "root_calls #{budget.root_calls} sub_calls #{budget.sub_calls} reason=#{inspect(reason)}"
    end)
  end

  defp log_progress(state, usage) do
    case state.progress_logger do
      fun when is_function(fun, 2) ->
        budget = Budget.to_map(state.budget)

        info = %{
          iterations: budget.iterations,
          max_iterations: budget.max_iterations,
          tokens_used: budget.tokens_used,
          token_budget: budget.token_budget,
          root_calls: budget.root_calls,
          sub_calls: budget.sub_calls
        }

        try do
          fun.(info, usage)
        rescue
          _ -> :ok
        end

        state

      _ ->
        state
    end
  end

  defp maybe_track_usage(state, usage) do
    if state.incremental_usage? do
      :ok
    else
      Budget.track_usage(state.budget, usage, :root)
    end
  end

  defp maybe_enforce_subcalls(state, response, usage, prev_sub_calls) do
    required = state.min_subcalls_per_root
    used = Budget.to_map(state.budget).sub_calls - prev_sub_calls

    if required > 0 and used < required do
      if state.enforcement_attempts + 1 > state.max_enforcement_attempts do
        {:error, :subcalls_required, build_stats(state)}
      else
        Logger.info(fn ->
          "RLM root call did not delegate (sub_calls_delta #{used}/#{required}); re-prompting"
        end)

        message =
          state.enforcement_message ||
            "You must call llm_batch with at least #{required} slices before drafting. " <>
              "Your previous response was ignored. Call llm_batch now."

        new_state = %{
          state
          | messages: state.messages ++ [%{role: "system", content: message}],
            enforcement_attempts: state.enforcement_attempts + 1
        }

        new_state |> log_progress(usage) |> loop()
      end
    else
      state |> handle_response(response) |> log_progress(usage) |> loop()
    end
  end

  defp seed_messages(env, query, opts) do
    info = Environment.context_info(env)

    [
      %{role: "system", content: system_prompt(opts)},
      %{
        role: "user",
        content:
          "User query: #{query}\nThe full context is stored externally; use the provided tools to search, slice, and delegate analysis. Context length: #{info.total_length} chars (#{info.line_count} lines)."
      }
    ]
  end

  defp system_prompt(opts) do
    opts[:system_prompt] ||
      """
      You are the root RLM agent. The full context is too large to inline; access it via tools:
      - slice_context: fetch a specific character range
      - search_context: regex search to find relevant spans
      - llm_query/llm_batch: delegate focused analysis to a sub-agent
      - set_variable/get_variable: persist intermediate state
      - set_answer: submit the final answer once ready
      Always minimize token use, re-use variables, and stop when the final answer is known.
      """
  end

  defp extra_tools(env, opts) do
    case Keyword.get(opts, :tools_builder) do
      fun when is_function(fun, 1) ->
        try do
          fun.(env) || []
        rescue
          _ -> []
        end

      _ ->
        []
    end
  end
end
