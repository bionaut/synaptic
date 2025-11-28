defmodule Synapse.Workflow do
  @moduledoc """
  DSL entry point for defining Synapse workflows.
  """

  alias Synapse.Step

  defmacro __using__(_opts) do
    quote do
      import Synapse.Workflow

      Module.register_attribute(__MODULE__, :synapse_steps, accumulate: true)
      Module.register_attribute(__MODULE__, :synapse_commit, persist: false)

      @before_compile Synapse.Workflow
    end
  end

  @doc """
  Declares a ordered workflow step. The block receives `context` (map)
  accumulated from every previous step and must return `{:ok, map}`,
  `{:error, term}`, or `suspend_for_human/2`.
  """
  defmacro step(name, opts \\ [], do: block) do
    quote do
      @synapse_steps Synapse.Workflow.__step_definition__(unquote(name), unquote(opts))

      def __synapse_handle__(unquote(name), var!(context)) do
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
      @synapse_commit true
    end
  end

  @spec definition(atom() | %{:__synapse_definition__ => any(), optional(any()) => any()}) ::
          any()
  @doc """
  Produces the compiled workflow definition for the provided module.
  """
  def definition(module) do
    module.__synapse_definition__()
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
    steps = env.module |> Module.get_attribute(:synapse_steps) |> Enum.reverse()
    commit? = Module.get_attribute(env.module, :synapse_commit)

    quote do
      unquote(unless(commit?, do: compile_commit_warning(env.module)))

      def __synapse_definition__ do
        Synapse.Workflow.__build_definition__(
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

      def __synapse_missing_commit_warning__, do: module
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    if function_exported?(env.module, :__synapse_missing_commit_warning__, 0) do
      IO.warn("Synapse workflow #{inspect(env.module)} is missing a commit/0 call")
    end
  end
end
