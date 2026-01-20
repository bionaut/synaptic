if Code.ensure_loaded?(Mix) and Mix.env() == :dev do
  defmodule Synaptic.Dev.RLMModuleRegistry do
    @moduledoc """
    Dev-only tools to help the RLM avoid repetition by tracking generated modules
    in the in-memory environment.
    """

    alias Synaptic.RLM.Environment
    alias Synaptic.Tools.Tool

    @doc """
    Returns tools for saving and listing module summaries.
    """
    def tools(env) do
      [
        save_module_tool(env),
        module_catalog_tool(env)
      ]
    end

    defp save_module_tool(env) do
      %Tool{
        name: "save_module",
        description: "Store a module summary to avoid duplication in later modules.",
        schema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Unique module id, e.g., module_1"},
            title: %{type: "string"},
            summary: %{type: "string"},
            topics: %{
              type: "array",
              items: %{type: "string"},
              description: "Key concepts covered"
            }
          },
          required: ["id", "title", "summary"]
        },
        handler: fn args ->
          catalog = Environment.get_variable(env, "module_catalog") || %{}

          entry = %{
            title: args["title"],
            summary: args["summary"],
            topics: args["topics"] || []
          }

          new_catalog = Map.put(catalog, args["id"], entry)
          Environment.set_variable(env, "module_catalog", new_catalog)

          %{
            status: "saved",
            modules: map_size(new_catalog)
          }
        end
      }
    end

    defp module_catalog_tool(env) do
      %Tool{
        name: "module_catalog",
        description:
          "List saved modules (id, title, summary, topics) to check coverage before adding new content.",
        schema: %{type: "object", properties: %{}},
        handler: fn _args ->
          Environment.get_variable(env, "module_catalog") || %{}
        end
      }
    end
  end
end
