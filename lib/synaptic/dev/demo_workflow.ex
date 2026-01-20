if Code.ensure_loaded?(Mix) and Mix.env() == :dev do
  defmodule Synaptic.Dev.DemoWorkflow do
    @moduledoc """
    A small workflow available only in the dev environment so you can try the
    Synaptic engine end-to-end from `iex -S mix`.
    """

    use Synaptic.Workflow
    require Logger

    @default_topic "Learning Elixir fundamentals"

    # This workflow uses OpenAI's Responses API with thread support to maintain
    # conversation continuity across steps and human-in-the-loop suspensions.
    # The response_id is preserved in context and passed as previous_response_id
    # to continue the thread across workflow steps.

    step :collect_topic, input: %{topic: :string}, output: %{topic: :string} do
      topic = Map.get(context, :topic, @default_topic)
      {:ok, %{topic: topic}}
    end

    step :draft_questions, retry: 2 do
      topic = Map.get(context, :topic, @default_topic)

      case build_questions(topic, context) do
        {:ok, questions, metadata} ->
          {:ok,
           %{
             pending_questions: questions,
             clarification_answers: %{},
             question_source: metadata[:question_source],
             current_question: nil,
             response_id: metadata[:response_id] || context[:response_id]
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
      previous_response_id = Map.get(context, :response_id)

      case build_outline(topic, answers, previous_response_id) do
        {:ok, plan, metadata} ->
          {:ok,
           Map.merge(%{outline: plan}, %{
             response_id: metadata[:response_id] || previous_response_id
           })}
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

    defp build_questions(topic, context) do
      messages = [
        %{role: "system", content: "You design probing questions for learning plans."},
        %{
          role: "user",
          content:
            "Topic: #{topic}. Suggest 2-3 short questions (one per line) that help tailor" <>
              " educational materials. Make sure to call learning_resources tool."
        }
      ]

      # Use Responses API with thread support
      # First call uses thread: true, subsequent calls use previous_response_id
      # This maintains conversation continuity even across suspend/resume boundaries
      previous_response_id = Map.get(context, :response_id)

      opts =
        if previous_response_id do
          Logger.debug("Continuing thread with previous_response_id: #{previous_response_id}")

          [
            thread: true,
            previous_response_id: previous_response_id,
            stream: true,
            model: "gpt-4o-mini",
            receive_timeout: 60_000
          ]
        else
          Logger.debug("Starting new thread")
          [thread: true, stream: true, model: "gpt-4o-mini", receive_timeout: 60_000]
        end

      case safe_chat(messages, opts) do
        {:ok, raw, meta} when is_map(meta) ->
          response_id = Map.get(meta, :response_id)
          Logger.debug("Received response with response_id: #{inspect(response_id)}")
          questions = parse_questions(raw)

          if questions == [] do
            Logger.warning("No questions parsed from LLM response, using fallback")
            # Preserve response_id even when using fallback questions
            fallback_result = fallback_questions(topic, :empty_response)
            case fallback_result do
              {:ok, questions, metadata} ->
                metadata = if response_id, do: Map.put(metadata, :response_id, response_id), else: metadata
                {:ok, questions, metadata}
              other -> other
            end
          else
            metadata = %{question_source: :llm}

            metadata =
              if response_id, do: Map.put(metadata, :response_id, response_id), else: metadata

            Logger.info("Generated #{length(questions)} questions from LLM")
            {:ok, questions, metadata}
          end

        {:ok, raw} ->
          Logger.debug("Received response without metadata")
          questions = parse_questions(raw)

          if questions == [] do
            Logger.warning("No questions parsed from LLM response, using fallback")
            fallback_questions(topic, :empty_response)
          else
            Logger.info("Generated #{length(questions)} questions from LLM (no response_id)")
            {:ok, questions, %{question_source: :llm}}
          end

        {:error, reason} ->
          Logger.error("LLM call failed: #{inspect(reason)}, using fallback questions")
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

    defp build_outline(topic, answers, previous_response_id) do
      case call_llm(topic, answers, previous_response_id) do
        {:ok, plan, meta} when is_map(meta) ->
          response_id = Map.get(meta, :response_id, previous_response_id)
          {:ok, plan, %{plan_source: :llm, response_id: response_id}}

        {:ok, plan} ->
          {:ok, plan, %{plan_source: :llm, response_id: previous_response_id}}

        {:error, reason} ->
          Logger.debug("Demo workflow falling back to canned plan: #{inspect(reason)}")
          {:ok, fallback_plan(topic, answers), %{plan_source: :fallback}}
      end
    end

    defp call_llm(topic, answers, previous_response_id) do
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

      # Use Responses API with thread support to continue conversation
      # This continues the thread from draft_questions step, maintaining full context
      opts =
        if previous_response_id do
          Logger.debug(
            "Continuing thread in generate_learning_plan with previous_response_id: #{previous_response_id}"
          )

          [
            thread: true,
            previous_response_id: previous_response_id,
            stream: true,
            model: "gpt-4o-mini",
            receive_timeout: 60_000
          ]
        else
          Logger.debug("Starting new thread in generate_learning_plan")
          [thread: true, stream: true, model: "gpt-4o-mini", receive_timeout: 60_000]
        end

      try do
        Synaptic.Tools.chat(messages, opts)
      rescue
        error -> {:error, {:exception, error}}
      end
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

    defp safe_chat(messages, opts) do
      tool = %Synaptic.Tools.Tool{
        name: "learning_resources",
        description: "Returns a short list of resources for a topic.",
        schema: %{
          type: "object",
          properties: %{topic: %{type: "string"}},
          required: ["topic"]
        },
        handler: fn %{"topic" => topic} ->
          Logger.info("Looking up resources for topic: #{topic}")

          # Just return an empty list for now
          []
        end
      }

      try do
        # Note: When tools are provided and stream: true, it automatically falls back to non-streaming
        # This is an OpenAI limitation - streaming doesn't support tool calling
        # Responses API thread support is preserved even when falling back to non-streaming
        result = Synaptic.Tools.chat(messages, Keyword.merge(opts, tools: [tool]))

        case result do
          {:ok, _content, _meta} = ok_result ->
            Logger.debug("safe_chat succeeded with metadata")
            ok_result

          {:ok, _content} = ok_result ->
            Logger.debug("safe_chat succeeded without metadata")
            ok_result

          {:error, reason} = error_result ->
            Logger.error("safe_chat failed: #{inspect(reason)}")
            error_result
        end
      rescue
        error ->
          Logger.error("safe_chat exception: #{inspect(error)}")
          {:error, {:exception, error}}
      catch
        :exit, reason ->
          Logger.error("safe_chat exit: #{inspect(reason)}")
          {:error, {:exit, reason}}
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
