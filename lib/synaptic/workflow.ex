defmodule Synaptic.Workflow do
  @moduledoc """
  DSL entry point for defining Synaptic workflows.
  """

  alias Synaptic.Step

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

  defmacro __before_compile__(env) do
    steps = env.module |> Module.get_attribute(:synaptic_steps) |> Enum.reverse()
    commit? = Module.get_attribute(env.module, :synaptic_commit)

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

  def __build_definition__(module, steps) do
    %{module: module, steps: steps}
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
