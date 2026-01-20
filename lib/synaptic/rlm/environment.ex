defmodule Synaptic.RLM.Environment do
  @moduledoc """
  Manages the external state for RLM runs: the long-form context, variables,
  and the final answer marker.
  """

  use Agent

  defstruct [
    :context,
    :context_length,
    variables: %{},
    answer: nil,
    answer_ready: false
  ]

  @type t :: %__MODULE__{
          context: String.t(),
          context_length: non_neg_integer(),
          variables: map(),
          answer: String.t() | nil,
          answer_ready: boolean()
        }

  @doc """
  Starts an environment Agent holding the provided context.
  """
  def start_link(context, opts \\ []) do
    Agent.start_link(fn -> new(context) end, opts)
  end

  @doc """
  Builds a new environment struct.
  """
  @spec new(String.t()) :: t()
  def new(context) when is_binary(context) do
    %__MODULE__{
      context: context,
      context_length: String.length(context),
      variables: %{},
      answer: nil,
      answer_ready: false
    }
  end

  def new(context), do: new(to_string(context))

  @doc """
  Stops the underlying Agent.
  """
  def stop(env), do: Agent.stop(env)

  @doc """
  Returns the current environment snapshot.
  """
  @spec snapshot(pid()) :: t()
  def snapshot(env), do: Agent.get(env, & &1)

  @doc """
  Returns the stored answer if present.
  """
  def answer(env), do: Agent.get(env, & &1.answer)

  @doc """
  Marks the answer and flips `answer_ready` to true.
  """
  def mark_answer(env, answer) do
    Agent.update(env, fn state ->
      %{state | answer: answer, answer_ready: true}
    end)
  end

  @doc """
  Indicates whether an answer has been set.
  """
  def answer_ready?(env), do: Agent.get(env, & &1.answer_ready)

  @doc """
  Sets a variable in the environment.
  """
  def set_variable(env, name, value) when is_binary(name) do
    Agent.update(env, fn state ->
      %{state | variables: Map.put(state.variables, name, value)}
    end)
  end

  @doc """
  Fetches a variable by name.
  """
  def get_variable(env, name) when is_binary(name) do
    Agent.get(env, fn state -> Map.get(state.variables, name) end)
  end

  @doc """
  Returns a substring of the context by character position.
  """
  def slice_context(env, start, length)
      when is_integer(start) and is_integer(length) and start >= 0 and length >= 0 do
    Agent.get(env, fn state ->
      String.slice(state.context, start, length) || ""
    end)
  end

  def slice_context(_env, _start, _length), do: ""

  @doc """
  Searches the context with a regex `pattern`, returning up to `max_results`
  matches with their positions.
  """
  def search_context(env, pattern, max_results \\ 10)

  def search_context(env, pattern, max_results)
      when is_binary(pattern) and is_integer(max_results) and max_results > 0 do
    Agent.get(env, fn state ->
      case Regex.compile(pattern, "m") do
        {:ok, regex} ->
          regex
          |> Regex.scan(state.context, return: :index)
          |> Enum.take(max_results)
          |> Enum.map(fn [{start, length} | _] ->
            %{
              match: String.slice(state.context, start, length),
              start: start,
              length: length
            }
          end)

        {:error, reason} ->
          %{error: reason}
      end
    end)
  end

  def search_context(_env, _pattern, _max_results), do: %{error: :invalid_arguments}

  @doc """
  Returns metadata about the stored context.
  """
  def context_info(env) do
    Agent.get(env, fn state ->
      %{
        total_length: state.context_length,
        line_count: state.context |> String.split("\n") |> length(),
        preview_start: String.slice(state.context, 0, 200),
        preview_end: String.slice(state.context, -200, 200)
      }
    end)
  end
end
