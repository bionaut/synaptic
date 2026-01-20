defmodule Synaptic.RLM.Tools do
  @moduledoc """
  Built-in tools that expose RLM operations (context slicing, searching,
  sub-agent calls, variable management).
  """

  alias Synaptic.RLM.{Budget, Environment}
  alias Synaptic.Tools.Tool

  @spec built_in_tools(pid(), pid(), keyword()) :: [Tool.t()]
  def built_in_tools(env, budget, opts \\ []) do
    sub_agent = Keyword.get(opts, :sub_agent, :sub)
    extra_tools = Keyword.get(opts, :tools, [])

    [
      slice_context_tool(env),
      search_context_tool(env),
      llm_query_tool(budget, sub_agent),
      llm_batch_tool(budget, sub_agent),
      set_variable_tool(env),
      get_variable_tool(env),
      set_answer_tool(env),
      context_info_tool(env)
    ] ++ extra_tools
  end

  defp slice_context_tool(env) do
    %Tool{
      name: "slice_context",
      description:
        "Get a slice of the context by character position. Use to inspect specific ranges.",
      schema: %{
        type: "object",
        properties: %{
          start: %{type: "integer", description: "Start position (0-indexed)"},
          length: %{type: "integer", description: "Number of characters to retrieve"}
        },
        required: ["start", "length"]
      },
      handler: fn args ->
        Environment.slice_context(env, args["start"], args["length"])
      end
    }
  end

  defp search_context_tool(env) do
    %Tool{
      name: "search_context",
      description:
        "Search the context with a regex pattern. Returns matching sections with positions.",
      schema: %{
        type: "object",
        properties: %{
          pattern: %{type: "string", description: "Regex pattern to search for"},
          max_results: %{type: "integer", description: "Maximum results to return (default: 10)"}
        },
        required: ["pattern"]
      },
      handler: fn args ->
        max_results = args["max_results"] || 10
        Environment.search_context(env, args["pattern"], max_results)
      end
    }
  end

  defp llm_query_tool(budget, sub_agent) do
    %Tool{
      name: "llm_query",
      description: "Query a sub-model with content and a question. Use for analyzing chunks.",
      schema: %{
        type: "object",
        properties: %{
          content: %{type: "string", description: "The content to analyze"},
          query: %{type: "string", description: "The question to answer about the content"}
        },
        required: ["content", "query"]
      },
      handler: fn args ->
        messages = [
          %{
            role: "system",
            content: "Analyze the provided content and answer the query concisely."
          },
          %{role: "user", content: "Content:\n#{args["content"]}\n\nQuery: #{args["query"]}"}
        ]

        case Synaptic.Tools.chat(messages, agent: sub_agent, return_usage: true) do
          {:ok, result, %{usage: usage}} ->
            Budget.track_usage(budget, usage, :sub)
            result

          {:ok, result} ->
            Budget.track_usage(budget, %{}, :sub)
            result

          {:error, reason} ->
            Budget.track_usage(budget, %{}, :sub)
            "Error: #{inspect(reason)}"
        end
      end
    }
  end

  defp llm_batch_tool(budget, sub_agent) do
    %Tool{
      name: "llm_batch",
      description: "Query sub-model on multiple chunks in parallel. Efficient for bulk analysis.",
      schema: %{
        type: "object",
        properties: %{
          content: %{
            description: "Fallback form: a single string or list of strings to analyze.",
            oneOf: [
              %{type: "string"},
              %{type: "array", items: %{type: "string"}}
            ]
          },
          query: %{
            type: "string",
            description: "Fallback form: a single query applied to all content."
          },
          queries: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{
                content: %{type: "string"},
                query: %{type: "string"}
              }
            },
            description: "Array of {content, query} pairs to process"
          }
        }
      },
      handler: fn args ->
        queries = normalize_batch_queries(args)

        queries
        |> Task.async_stream(
          fn %{"content" => content, "query" => query} ->
            messages = [
              %{
                role: "system",
                content: "Analyze the provided content and answer the query concisely."
              },
              %{role: "user", content: "Content:\n#{content}\n\nQuery: #{query}"}
            ]

            case Synaptic.Tools.chat(messages, agent: sub_agent, return_usage: true) do
              {:ok, result, %{usage: usage}} ->
                Budget.track_usage(budget, usage, :sub)
                result

              {:ok, result} ->
                Budget.track_usage(budget, %{}, :sub)
                result

              {:error, reason} ->
                Budget.track_usage(budget, %{}, :sub)
                "Error: #{inspect(reason)}"
            end
          end,
          timeout: 60_000,
          max_concurrency: 5
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> "Error: #{inspect(reason)}"
          {:error, reason} -> "Error: #{inspect(reason)}"
        end)
      end
    }
  end

  defp set_variable_tool(env) do
    %Tool{
      name: "set_variable",
      description: "Store a value in a named variable for later use.",
      schema: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Variable name"},
          value: %{type: "string", description: "Value to store"}
        },
        required: ["name", "value"]
      },
      handler: fn args ->
        Environment.set_variable(env, args["name"], args["value"])
        %{status: "ok", name: args["name"]}
      end
    }
  end

  defp get_variable_tool(env) do
    %Tool{
      name: "get_variable",
      description: "Retrieve a previously stored variable.",
      schema: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "Variable name to retrieve"}
        },
        required: ["name"]
      },
      handler: fn args ->
        Environment.get_variable(env, args["name"]) || "Variable not found"
      end
    }
  end

  defp set_answer_tool(env) do
    %Tool{
      name: "set_answer",
      description: "Set the final answer and signal completion.",
      schema: %{
        type: "object",
        properties: %{
          answer: %{type: "string", description: "The final answer to return"}
        },
        required: ["answer"]
      },
      handler: fn args ->
        Environment.mark_answer(env, args["answer"])
        %{status: "answer_recorded"}
      end
    }
  end

  defp context_info_tool(env) do
    %Tool{
      name: "context_info",
      description: "Get metadata about the context (length, line count, previews).",
      schema: %{type: "object", properties: %{}},
      handler: fn _args -> Environment.context_info(env) end
    }
  end

  defp normalize_batch_queries(%{"queries" => queries}) when is_list(queries), do: queries

  defp normalize_batch_queries(%{"content" => content, "query" => query})
       when is_binary(query) do
    cond do
      is_binary(content) ->
        [%{"content" => content, "query" => query}]

      is_list(content) ->
        Enum.map(content, fn item ->
          %{"content" => normalize_batch_content(item), "query" => query}
        end)

      true ->
        []
    end
  end

  defp normalize_batch_queries(_), do: []

  defp normalize_batch_content(%{"content" => content}) when is_binary(content), do: content
  defp normalize_batch_content(content) when is_binary(content), do: content
  defp normalize_batch_content(other), do: inspect(other)
end
