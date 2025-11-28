if Code.ensure_loaded?(Mix) and Mix.env() == :dev do
  defmodule Synapse.Dev.DemoWorkflow do
    @moduledoc """
    A small workflow available only in the dev environment so you can try the
    Synapse engine end-to-end from `iex -S mix`.
    """

    use Synapse.Workflow
    require Logger

    @default_topic "Learning Elixir fundamentals"

    step :collect_topic, input: %{topic: :string}, output: %{topic: :string} do
      topic = Map.get(context, :topic, @default_topic)
      {:ok, %{topic: topic}}
    end

    step :draft_questions, retry: 2 do
      topic = Map.get(context, :topic, @default_topic)

      case build_questions(topic) do
        {:ok, questions, metadata} ->
          {:ok,
           %{
             pending_questions: questions,
             clarification_answers: %{},
             question_source: metadata[:question_source],
             current_question: nil
           }}
      end
    end

    step :ask_questions,
      suspend: true,
      retry: 2,
      resume_schema: %{answer: :string} do
      handle_question_loop(context)
    end

    step :generate_learning_plan do
      topic = Map.get(context, :topic, @default_topic)
      answers = Map.get(context, :clarification_answers, %{})

      case build_outline(topic, answers) do
        {:ok, plan, metadata} -> {:ok, Map.merge(%{outline: plan}, metadata)}
      end
    end

    defp handle_question_loop(context) do
      questions = Map.get(context, :pending_questions, [])
      answers = Map.get(context, :clarification_answers, %{})
      current_question = Map.get(context, :current_question)
      response = get_in(context, [:human_input, :answer])

      cond do
        current_question && not is_nil(response) ->
          updated_answers = Map.put(answers, current_question.id, response)

          updated_context =
            context
            |> Map.put(:clarification_answers, updated_answers)
            |> Map.put(:current_question, nil)
            |> Map.put(:human_input, nil)

          handle_question_loop(updated_context)

        current_question && is_nil(response) ->
          suspend_for_human(
            current_question.prompt,
            %{
              question_id: current_question.id,
              remaining_questions: length(questions)
            }
          )

        questions == [] ->
          {:ok,
           %{
             clarification_answers: answers,
             pending_questions: [],
             current_question: nil
           }}

        true ->
          [next | rest] = questions

          suspend_for_human(
            next.prompt,
            %{
              question_id: next.id,
              remaining_questions: length(rest)
            },
            %{
              pending_questions: rest,
              current_question: next,
              clarification_answers: answers
            }
          )
      end
    end

    step :human_review,
      suspend: true,
      resume_schema: %{approved: :boolean} do
      case get_in(context, [:human_input, :approved]) do
        nil ->
          suspend_for_human(
            "Review the generated learning outline before proceeding",
            %{
              outline: Map.get(context, :outline, "No outline available."),
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

    defp build_questions(topic) do
      messages = [
        %{role: "system", content: "You design probing questions for learning plans."},
        %{
          role: "user",
          content:
            "Topic: #{topic}. Suggest 2-3 short questions (one per line) that help tailor" <>
              " educational materials."
        }
      ]

      case safe_chat(messages) do
        {:ok, raw} ->
          questions = parse_questions(raw)

          if questions == [] do
            fallback_questions(topic, :empty_response)
          else
            {:ok, questions, %{question_source: :llm}}
          end

        {:error, reason} ->
          fallback_questions(topic, reason)
      end
    end

    defp fallback_questions(topic, reason) do
      Logger.debug("Demo workflow fallback questions: #{inspect(reason)}")

      {:ok,
       [
         %{id: "q_background", prompt: "How familiar are you with #{topic}?"},
         %{id: "q_goal", prompt: "What outcome do you want from learning #{topic}?"}
       ], %{question_source: :fallback}}
    end

    defp parse_questions(raw) do
      raw
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.with_index(1)
      |> Enum.map(fn {line, idx} ->
        cleaned =
          line
          |> String.trim_leading("- ")
          |> String.trim_leading("* ")
          |> String.replace(~r/^\d+\.\s*/, "")

        %{id: "q#{idx}", prompt: cleaned}
      end)
    end

    defp build_outline(topic, answers) do
      case call_llm(topic, answers) do
        {:ok, plan} ->
          {:ok, plan, %{plan_source: :llm}}

        {:error, reason} ->
          Logger.debug("Demo workflow falling back to canned plan: #{inspect(reason)}")
          {:ok, fallback_plan(topic, answers), %{plan_source: :fallback}}
      end
    end

    defp call_llm(topic, answers) do
      serialized_answers = serialize_answers(answers)

      messages = [
        %{role: "system", content: "You create concise study plans tailored to the learner."},
        %{
          role: "user",
          content:
            "Topic: #{topic}. Clarifying questions/answers: #{serialized_answers}.\n" <>
              "Produce a numbered outline for educational materials tailored to this information."
        }
      ]

      safe_chat(messages)
    end

    defp serialize_answers(%{} = answers) do
      answers
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, response} -> "#{id}: #{String.trim(response)}" end)
      |> Enum.join(" | ")
      |> case do
        "" -> "None provided"
        summary -> summary
      end
    end

    defp safe_chat(messages) do
      try do
        Synapse.Tools.chat(messages)
      rescue
        error -> {:error, {:exception, error}}
      end
    end

    defp fallback_plan(topic, answers) do
      serialized = serialize_answers(answers)

      """
      ## Learning outline for: #{topic}

      Clarifying answers: #{serialized}

      1. Define success criteria and vocabulary for the topic.
      2. Cover the key concepts with short explanations and examples.
      3. Include a guided exercise or quiz to reinforce learning.
      4. Provide resources for continued study tailored to the goal.

      (Generated locally because the LLM adapter was unavailable.)
      """
      |> String.trim()
    end
  end
end
