if Code.ensure_loaded?(Mix) and Mix.env() == :dev do
  defmodule Synapse.Dev.DemoWorkflow do
    @moduledoc """
    A small workflow available only in the dev environment so you can try the
    Synapse engine end-to-end from `iex -S mix`.
    """

    use Synapse.Workflow
    require Logger

    @default_request "Draft a short onboarding plan for a new Synapse user"

    step :collect_requirements, input: %{request: :string}, output: %{request: :string} do
      request = Map.get(context, :request, @default_request)
      {:ok, %{request: request}}
    end

    step :generate_plan do
      request = Map.get(context, :request, @default_request)

      case brainstorm_plan(request) do
        {:ok, plan, metadata} -> {:ok, Map.merge(%{proposal: plan}, metadata)}
        {:error, reason} -> {:error, reason}
      end
    end

    step :human_review,
      suspend: true,
      resume_schema: %{approved: :boolean} do
      case get_in(context, [:human_input, :approved]) do
        nil ->
          suspend_for_human(
            "Review the generated plan before proceeding",
            %{
              proposal: Map.get(context, :proposal, "No plan available."),
              plan_source: Map.get(context, :plan_source, :fallback)
            }
          )

        true ->
          {:ok, %{status: :ready}}

        false ->
          {:error, :rejected}
      end
    end

    commit()

    defp brainstorm_plan(request) do
      case call_llm(request) do
        {:ok, plan} ->
          {:ok, plan, %{plan_source: :llm}}

        {:error, reason} ->
          Logger.debug("Demo workflow falling back to canned plan: #{inspect(reason)}")
          {:ok, fallback_plan(request), %{plan_source: :fallback}}
      end
    end

    defp call_llm(request) do
      messages = [
        %{role: "system", content: "You are a senior engineer helping to scope tiny dev tasks."},
        %{role: "user", content: "Draft a short plan for the following request: #{request}"}
      ]

      try do
        Synapse.Tools.chat(messages)
      rescue
        error -> {:error, {:exception, error}}
      end
    end

    defp fallback_plan(request) do
      """
      ## Plan for: #{request}

      1. Clarify success criteria with the requester.
      2. Break the work into at most three concrete tasks.
      3. List open questions + assumptions.
      4. Prepare a short summary for a human reviewer.

      (Generated locally because the LLM adapter was unavailable.)
      """
      |> String.trim()
    end
  end
end
