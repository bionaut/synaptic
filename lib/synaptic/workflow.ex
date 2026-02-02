defmodule Synaptic.Workflow do
  @moduledoc """
  DSL entry point for defining Synaptic workflows.
  """

  alias Synaptic.Step

  @llm_router_opts [:prompt, :system_prompt, :model, :temperature, :response_format]

  defmacro __using__(_opts) do
    quote do
      import Synaptic.Workflow

      Module.register_attribute(__MODULE__, :synaptic_steps, accumulate: true)
      Module.register_attribute(__MODULE__, :synaptic_commit, persist: false)

      @before_compile Synaptic.Workflow
    end
  end

  @doc """
  Declares a ordered workflow step. The block receives `context` (map)
  accumulated from every previous step and must return `{:ok, map}`,
  `{:error, term}`, or `suspend_for_human/2`.
  """
  defmacro step(name, opts \\ [], do: block) do
    quote do
      @synaptic_steps Synaptic.Workflow.__step_definition__(unquote(name), unquote(opts))

      def __synaptic_handle__(unquote(name), var!(context)) do
        _ = var!(context)
        unquote(block)
      end
    end
  end

  @doc """
  Declares a parallel workflow step. The block must return a list of
  anonymous functions that receive the workflow `context` (map). Each
  function runs concurrently and must return `{:ok, map}` or `{:error, term}`.
  The step succeeds only when all parallel tasks succeed, and their maps are
  merged into the accumulated context.
  """
  defmacro parallel_step(name, opts \\ [], do: block) do
    opts = Keyword.put(opts, :type, :parallel)

    quote do
      @synaptic_steps Synaptic.Workflow.__step_definition__(unquote(name), unquote(opts))

      def __synaptic_handle__(unquote(name), var!(context)) do
        _ = var!(context)
        unquote(block)
      end
    end
  end

  @doc """
  Declares an asynchronous fire-and-forget workflow step. The block receives
  the accumulated `context` and executes like a normal step, but the workflow
  immediately continues to the next step instead of waiting for this one to
  finish. Results are merged back into the context once the step completes.
  """
  defmacro async_step(name, opts \\ [], do: block) do
    opts = Keyword.put(opts, :type, :async)

    quote do
      @synaptic_steps Synaptic.Workflow.__step_definition__(unquote(name), unquote(opts))

      def __synaptic_handle__(unquote(name), var!(context)) do
        _ = var!(context)
        unquote(block)
      end
    end
  end

  @doc """
  Declares an LLM-driven routing step. The block receives the accumulated
  `context` and returns a map or string that becomes the prompt input used
  to choose the next step from the provided branches.
  """
  defmacro llm_router(name, branches, opts \\ [], do: block) do
    quote do
      @synaptic_steps Synaptic.Workflow.__llm_router_definition__(
                        unquote(name),
                        unquote(branches),
                        unquote(opts)
                      )

      def __synaptic_handle__(unquote(name), var!(context)) do
        _ = var!(context)

        prompt_input = unquote(block)
        llm_opts = Synaptic.Workflow.__llm_router_llm_opts__(unquote(opts))

        case Synaptic.LLMRouter.evaluate(
               var!(context),
               unquote(branches),
               prompt_input,
               llm_opts
             ) do
          {:ok, target_step} ->
            {:route, target_step, %{}}

          {:ok, target_step, data} when is_map(data) ->
            {:route, target_step, data}

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, {:invalid_llm_router_return, other}}
        end
      end
    end
  end

  @doc """
  Marks that the workflow definition has declared its terminal point. In the
  MVP the macro only exists to nudge authors so that tests reflect the full
  lifecycle.
  """
  defmacro commit do
    quote do
      @synaptic_commit true
    end
  end

  @spec definition(atom() | %{:__synaptic_definition__ => any(), optional(any()) => any()}) ::
          any()
  @doc """
  Produces the compiled workflow definition for the provided module.
  """
  def definition(module) do
    module.__synaptic_definition__()
  end

  @doc """
  Convenience helper returned from steps to pause execution and wait for a human
  payload to resume the workflow.
  """
  def suspend_for_human(message, metadata \\ %{}, context_updates \\ %{})
      when is_binary(message) do
    {:suspend,
     %{
       message: message,
       metadata: metadata,
       context_updates: context_updates
     }}
  end

  @doc """
  Marks a code block as a side effect (e.g., database mutations, external API calls).
  When `skip_side_effects: true` is set in test configuration, the side effect
  is skipped and returns a default value instead.

  ## Options

    * `:default` - Value to return when side effect is skipped (default: `:ok`)
    * `:name` - Optional identifier for the side effect, used in Telemetry metadata

  ## Examples

      step :save_user do
        side_effect do
          Database.insert(context.user)
        end

        {:ok, %{user_saved: true}}
      end

      step :send_email do
        side_effect default: {:ok, :sent}, name: :welcome_email do
          EmailService.send(context.user.email, "Welcome!")
        end

        {:ok, %{email_sent: true}}
      end
  """
  defmacro side_effect(opts \\ [], do: block) do
    default_value = Keyword.get(opts, :default, :ok)
    name = Keyword.get(opts, :name, nil)

    quote do
      run_id = Map.get(var!(context), :__run_id__)
      step_name = Map.get(var!(context), :__step_name__)
      skip? = Map.get(var!(context), :__skip_side_effects__, false)
      side_effect_name = unquote(name)

      if skip? do
        :telemetry.execute(
          [:synaptic, :side_effect, :skip],
          %{},
          %{run_id: run_id, step_name: step_name, side_effect: side_effect_name}
        )

        unquote(default_value)
      else
        :telemetry.span(
          [:synaptic, :side_effect],
          %{run_id: run_id, step_name: step_name, side_effect: side_effect_name},
          fn ->
            result = unquote(block)
            {result, %{}}
          end
        )
      end
    end
  end

  defmacro __before_compile__(env) do
    steps = env.module |> Module.get_attribute(:synaptic_steps) |> Enum.reverse()
    commit? = Module.get_attribute(env.module, :synaptic_commit)
    Synaptic.Workflow.__validate_llm_steps__(steps, env.module)

    quote do
      unquote(unless(commit?, do: compile_commit_warning(env.module)))

      def __synaptic_definition__ do
        Synaptic.Workflow.__build_definition__(
          __MODULE__,
          unquote(Macro.escape(steps))
        )
      end
    end
  end

  def __step_definition__(name, opts) do
    Step.new(name, opts)
  end

  def __llm_router_definition__(name, branches, opts) do
    {_llm_opts, step_opts} = __split_llm_router_opts__(opts)

    step_opts
    |> Keyword.put(:type, :llm)
    |> Keyword.put(:llm_branches, branches)
    |> then(&Step.new(name, &1))
  end

  def __llm_router_llm_opts__(opts) do
    {llm_opts, _step_opts} = __split_llm_router_opts__(opts)
    llm_opts
  end

  def __build_definition__(module, steps) do
    %{module: module, steps: steps}
  end

  def __split_llm_router_opts__(opts) do
    Keyword.split(opts, @llm_router_opts)
  end

  def __validate_llm_steps__(steps, module) do
    step_names = MapSet.new(Enum.map(steps, & &1.name))

    Enum.each(steps, fn step ->
      case Map.get(step, :type) do
        :llm -> validate_llm_step(step, step_names, module)
        _ -> :ok
      end
    end)
  end

  defp validate_llm_step(step, step_names, module) do
    branches = Map.get(step, :llm_branches, [])

    unless is_list(branches) do
      raise ArgumentError,
            "llm_router #{inspect(step.name)} in #{inspect(module)} must define a list of branches"
    end

    Enum.each(branches, fn
      {condition, target} when is_binary(condition) and is_atom(target) ->
        if not MapSet.member?(step_names, target) do
          raise ArgumentError,
                "llm_router #{inspect(step.name)} in #{inspect(module)} references unknown step #{inspect(target)}"
        end

      other ->
        raise ArgumentError,
              "llm_router #{inspect(step.name)} in #{inspect(module)} has invalid branch #{inspect(other)}"
    end)
  end

  defp compile_commit_warning(module) do
    quote bind_quoted: [module: module] do
      @after_compile unquote(__MODULE__)

      def __synaptic_missing_commit_warning__, do: module
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    if function_exported?(env.module, :__synaptic_missing_commit_warning__, 0) do
      IO.warn("Synaptic workflow #{inspect(env.module)} is missing a commit/0 call")
    end
  end
end
