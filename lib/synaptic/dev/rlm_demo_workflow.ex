if Code.ensure_loaded?(Mix) and Mix.env() == :dev do
  defmodule Synaptic.Dev.RLMDemoWorkflow do
    @moduledoc """
      Dev-only workflow showcasing `Synaptic.RLM.process/3`. Run from IEx:

          iex -S mix
          {:ok, run_id} = Synaptic.start(Synaptic.Dev.RLMDemoWorkflow, %{query: "What are the core principles?"})

    The workflow loads a sample long-form document (or accepts `:document` in the
    input), runs the RLM loop with root/sub agents, and returns the answer plus
    budget/stats. The default query asks for a structured course outline so you
    can see multi-step synthesis rather than a simple summary.
    """

    use Synaptic.Workflow
    alias Synaptic.Dev.RLMModuleRegistry
    require Logger

    @context_path Path.expand("../../../priv/demo/rlm_demo_context.txt", __DIR__)
    @default_query """
    Design a 4-module learning course from this corpus.
    For each module, include:
    - Title
    - A 150-250 word distilled lecture/summary based only on the corpus
    - 3 learning objectives
    - 2 key readings with section references from the corpus (do not invent sources)
    - Selected excerpts: 2-3 verbatim quotes (<=120 words each) copied from the corpus with a section heading and character range to show provenance
    - One practical exercise
    - One short assessment question
    Avoid overlap by consulting module_catalog and saving each module via save_module. If you cannot find material for an item, say so explicitly.
    """

    # Defaults for the RLM run; override by passing :rlm_opts in workflow input
    @default_rlm_opts %{
      root_agent: :root,
      sub_agent: :sub,
      token_budget: 10_000,
      max_iterations: 12,
      progress_logger: &__MODULE__.log_iteration/2,
      system_prompt: nil,
      min_subcalls_per_root: 4,
      max_enforcement_attempts: 2
    }

    @default_system_prompt """
    You are the root RLM agent building a concise, high-value mini course directly from the provided corpus.
    Rules:
    - Do not ask the user for more info; work only with the corpus via tools.
    - Act as a supervisor: use search_context + slice_context to collect candidate excerpts, then delegate analysis to the sub-agent via llm_batch before drafting each module.
    - For each module, you must call llm_batch with at least 4 slices and use those summaries in the final output.
    - For each module, produce a distilled lecture/summary (150-250 words) using only corpus content.
    - Include 2-3 short verbatim quotes (<=120 words each) with section headings and character ranges for provenance.
    - Use key readings strictly from the corpus; do not invent external sources.
    - Avoid overlap across modules: consult module_catalog and save modules via save_module.
    - If a required item is missing in the corpus, state that clearly instead of guessing.
    """

    step :load_document,
      input: %{document: :string, query: :string},
      output: %{document: :string, query: :string} do
      document =
        Map.get(context, :document) ||
          File.read!(@context_path)

      query = Map.get(context, :query, @default_query)

      {:ok, %{document: document, query: query}}
    end

    step :rlm_process do
      doc = context.document
      query = context.query

      user_opts = Map.get(context, :rlm_opts, %{})
      merged_opts = Map.merge(@default_rlm_opts, user_opts)
      tools_builder = build_tools_builder(user_opts)

      system_prompt = merged_opts.system_prompt || @default_system_prompt

      {micros, result} =
        :timer.tc(fn ->
          Synaptic.RLM.process(doc, query,
            root_agent: merged_opts.root_agent,
            sub_agent: merged_opts.sub_agent,
            token_budget: merged_opts.token_budget,
            max_iterations: merged_opts.max_iterations,
            progress_logger: merged_opts.progress_logger,
            min_subcalls_per_root: merged_opts.min_subcalls_per_root,
            max_enforcement_attempts: merged_opts.max_enforcement_attempts,
            tools: Map.get(user_opts, :tools, []),
            tools_builder: tools_builder,
            system_prompt: system_prompt
          )
        end)

      millis = System.convert_time_unit(micros, :microsecond, :millisecond)

      case result do
        {:ok, answer, stats} ->
          log_summary(:ok, query, answer, stats, millis, merged_opts)
          {:ok, %{answer: answer, rlm_stats: stats, rlm_opts: merged_opts}}

        {:error, reason, stats} ->
          log_summary(:error, query, inspect(reason), stats, millis, merged_opts)
          {:error, %{reason: reason, rlm_stats: stats, rlm_opts: merged_opts}}
      end
    end

    step :write_output do
      output_path = Map.get(context, :output_path) || default_output_path()
      answer = Map.get(context, :answer, "")
      stats = Map.get(context, :rlm_stats, %{})
      query = Map.get(context, :query, @default_query)
      opts = Map.get(context, :rlm_opts, @default_rlm_opts)

      content = """
      # RLM Demo Output

      **Status:** #{answer_status(answer)}
      **Query:** #{query}
      **Output path:** #{output_path}

      ## Course

      #{answer}

      ## RLM Stats

      ```
      #{inspect(stats, pretty: true, limit: :infinity)}
      ```

      ## Options

      ```
      #{inspect(opts, pretty: true)}
      ```
      """

      write_file(output_path, content)

      {:ok, %{output_path: output_path}}
    end

    commit()

    defp log_summary(status, query, answer_or_reason, stats, millis, opts) do
      budget = stats.budget || %{}

      Logger.info(fn ->
        """
        RLM demo #{status} in #{millis}ms
        query: #{query}
        opts: #{inspect(opts)}
        tokens: #{budget[:tokens_used] || "?"}/#{budget[:token_budget] || "?"}
        iterations: #{budget[:iterations] || "?"}/#{budget[:max_iterations] || "?"}
        answer preview: #{answer_preview(answer_or_reason)}
        """
        |> String.trim()
      end)
    end

    defp answer_preview(text) when is_binary(text) do
      text
      |> String.replace("\n", " ")
      |> String.slice(0, 240)
    end

    defp answer_preview(other), do: inspect(other)

    defp build_tools_builder(user_opts) do
      user_builder = Map.get(user_opts, :tools_builder)

      fn env ->
        registry_tools = RLMModuleRegistry.tools(env)
        extra_tools = if is_function(user_builder, 1), do: user_builder.(env), else: []
        registry_tools ++ (extra_tools || [])
      end
    end

    defp default_output_path do
      Path.expand("../../../priv/demo/rlm_demo_output.md", __DIR__)
    end

    defp write_file(path, content) do
      path |> Path.dirname() |> File.mkdir_p!()
      File.write!(path, content)
    end

    defp answer_status(answer) do
      if is_binary(answer) and String.trim(answer) != "" do
        "ok"
      else
        "empty"
      end
    end

    def log_iteration(info, _usage) do
      Logger.info(fn ->
        "RLM iteration #{info.iterations}/#{info.max_iterations} " <>
          "tokens #{info.tokens_used}/#{info.token_budget} " <>
          "root_calls #{info.root_calls} sub_calls #{info.sub_calls}"
      end)
    end
  end
end
