defmodule Synaptic.ToolsTest do
  use ExUnit.Case

  alias Synaptic.MCP.Discovery

  defmodule PrimaryAdapter do
    def chat(_messages, opts), do: {:ok, {:primary, opts}}
  end

  defmodule SecondaryAdapter do
    def chat(_messages, opts), do: {:ok, {:secondary, opts}}
  end

  defmodule ToolAdapter do
    def chat(_messages, _opts) do
      case Process.get({__MODULE__, :stage}, :first) do
        :first ->
          Process.put({__MODULE__, :stage}, :second)

          {:ok,
           %{
             "content" => nil,
             "tool_calls" => [
               %{
                 "id" => "call_1",
                 "function" => %{
                   "name" => "echo",
                   "arguments" => ~s<{"text":"hi"}>
                 }
               }
             ]
           }}

        :second ->
          {:ok, "final"}
      end
    end
  end

  defmodule MCPAdapter do
    use Synaptic.MCP.Adapter

    @impl true
    def discover(connection, _opts) do
      Process.put(
        {__MODULE__, :discover_calls},
        Process.get({__MODULE__, :discover_calls}, 0) + 1
      )

      if Keyword.get(connection.adapter_opts, :fail_discovery, false) do
        {:error, :boom}
      else
        {:ok,
         %Discovery{
           tools: [
             %{
               name: Keyword.get(connection.adapter_opts, :remote_tool, "search_issues"),
               description: "Searches issues",
               input_schema:
                 Keyword.get(connection.adapter_opts, :schema, %{
                   type: "object",
                   properties: %{query: %{type: "string"}},
                   required: ["query"]
                 })
             }
           ],
           resources_supported?:
             !Keyword.get(connection.adapter_opts, :resources_unsupported, false),
           resources: nil,
           server_info: %{},
           warnings: []
         }}
      end
    end

    @impl true
    def call_tool(connection, remote_name, args, _opts) do
      Process.put({__MODULE__, :last_call_tool}, {connection.name, remote_name, args})

      if Keyword.get(connection.adapter_opts, :fail_tool_call, false) do
        {:error, :tool_failed}
      else
        {:ok, %{remote: remote_name, args: args}}
      end
    end

    @impl true
    def list_resources(connection, _opts) do
      Process.put({__MODULE__, :last_list_resources}, connection.name)

      {:ok,
       [
         %{
           "uri" => "file:///#{connection.name}/guide.md",
           "name" => "#{connection.name} guide",
           "description" => "Guide"
         }
       ]}
    end

    @impl true
    def read_resource(connection, uri, _opts) do
      Process.put({__MODULE__, :last_read_resource}, {connection.name, uri})
      {:ok, %{"contents" => [%{"text" => "resource:#{connection.name}:#{uri}"}]}}
    end
  end

  defmodule MCPToolLoopAdapter do
    def chat(messages, opts) do
      Process.put(:captured_adapter_tools, opts[:tools] || [])

      case Process.get({__MODULE__, :stage}, :first) do
        :first ->
          Process.put({__MODULE__, :stage}, :second)

          {:ok,
           %{
             "content" => nil,
             "tool_calls" => [
               %{
                 "id" => "call_1",
                 "function" => %{
                   "name" => Process.get(:next_tool_name),
                   "arguments" => Process.get(:next_tool_args_json, "{}")
                 }
               }
             ]
           }}

        :second ->
          Process.put(:last_tool_message, List.last(messages))
          {:ok, "final"}
      end
    end
  end

  @messages [%{role: "user", content: "ping"}]

  setup do
    original_tools = Application.get_env(:synaptic, Synaptic.Tools)
    original_mcp = Application.get_env(:synaptic, Synaptic.MCP)

    Application.put_env(:synaptic, Synaptic.Tools,
      llm_adapter: __MODULE__.PrimaryAdapter,
      agents: [
        engineer: [model: "o4-mini", temperature: 0.2],
        translator: [adapter: __MODULE__.SecondaryAdapter, model: "gpt-4o-mini"]
      ]
    )

    Application.put_env(:synaptic, Synaptic.MCP,
      servers: [
        github: [transport: :http, adapter: __MODULE__.MCPAdapter],
        docs: [transport: :http, adapter: __MODULE__.MCPAdapter, remote_tool: "lookup_docs"],
        broken: [transport: :http, adapter: __MODULE__.MCPAdapter, fail_discovery: true]
      ]
    )

    reset_process_state()

    on_exit(fn ->
      restore_env(Synaptic.Tools, original_tools)
      restore_env(Synaptic.MCP, original_mcp)
      reset_process_state()
    end)

    :ok
  end

  test "applies agent defaults" do
    assert {:ok, {:primary, opts}} = Synaptic.Tools.chat(@messages, agent: :engineer)
    assert opts[:model] == "o4-mini"
    assert opts[:temperature] == 0.2
  end

  test "allows explicit overrides" do
    assert {:ok, {:primary, opts}} =
             Synaptic.Tools.chat(@messages, agent: :engineer, temperature: 0.5)

    assert opts[:temperature] == 0.5
  end

  test "uses adapter overrides configured on agent" do
    assert {:ok, {:secondary, opts}} = Synaptic.Tools.chat(@messages, agent: :translator)
    assert opts[:model] == "gpt-4o-mini"
  end

  test "raises when agent is missing" do
    assert_raise ArgumentError, ~r/unknown Synaptic agent/, fn ->
      Synaptic.Tools.chat(@messages, agent: :missing)
    end
  end

  test "executes tools when adapter requests tool calls" do
    tool = %Synaptic.Tools.Tool{
      name: "echo",
      description: "echoes text",
      schema: %{
        type: "object",
        properties: %{text: %{type: "string"}},
        required: ["text"]
      },
      handler: fn %{"text" => text} ->
        Process.put(:tool_called, text)
        %{reply: text <> "!"}
      end
    }

    Process.delete({ToolAdapter, :stage})

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: ToolAdapter,
               tools: [tool]
             )

    assert Process.get(:tool_called) == "hi"
  end

  test "exposes MCP tools and synthetic resource tools to the adapter" do
    assert {:ok, {:primary, opts}} = Synaptic.Tools.chat(@messages, mcp: [:github])

    names =
      opts[:tools]
      |> Enum.map(&get_in(&1, [:function, :name]))

    assert "github__search_issues" in names
    assert "github__list_resources" in names
    assert "github__read_resource" in names
  end

  test "merges local and MCP tools" do
    tool = %Synaptic.Tools.Tool{
      name: "echo",
      description: "echoes text",
      schema: %{type: "object", properties: %{}},
      handler: fn _args -> "ok" end
    }

    assert {:ok, {:primary, opts}} = Synaptic.Tools.chat(@messages, tools: [tool], mcp: [:github])

    names =
      opts[:tools]
      |> Enum.map(&get_in(&1, [:function, :name]))

    assert "echo" in names
    assert "github__search_issues" in names
  end

  test "discovers MCP capabilities once per top-level chat call" do
    Process.put(:next_tool_name, "github__search_issues")
    Process.put(:next_tool_args_json, ~s({"query":"bugs"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               mcp: [:github]
             )

    assert Process.get({MCPAdapter, :discover_calls}) == 1
  end

  test "suffixes duplicate normalized server names" do
    connections = [
      %{name: "GitHub", adapter: MCPAdapter, transport: :http},
      %{name: "github", adapter: MCPAdapter, transport: :http}
    ]

    assert {:ok, {:primary, opts}} = Synaptic.Tools.chat(@messages, mcp: connections)

    names =
      opts[:tools]
      |> Enum.map(&get_in(&1, [:function, :name]))

    assert "github__search_issues" in names
    assert "github_2__search_issues" in names
  end

  test "returns an error when local and MCP tool names collide" do
    tool = %Synaptic.Tools.Tool{
      name: "github__search_issues",
      description: "collision",
      schema: %{type: "object", properties: %{}},
      handler: fn _args -> :ok end
    }

    assert {:error, {:duplicate_tool_name, "github__search_issues"}} =
             Synaptic.Tools.chat(@messages, tools: [tool], mcp: [:github])
  end

  test "surfaces which MCP server failed discovery" do
    assert {:error, {:mcp_discovery_failed, "broken", :boom}} =
             Synaptic.Tools.chat(@messages, mcp: [:github, :broken])
  end

  test "dispatches MCP tool calls through the MCP facade" do
    Process.put(:next_tool_name, "github__search_issues")
    Process.put(:next_tool_args_json, ~s({"query":"bugs"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               mcp: [:github]
             )

    assert {"github", "search_issues", %{"query" => "bugs"}} =
             Process.get({MCPAdapter, :last_call_tool})
  end

  test "reads MCP resources via synthetic tools" do
    Process.put(:next_tool_name, "github__read_resource")
    Process.put(:next_tool_args_json, ~s({"uri":"file:///github/guide.md"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               mcp: [:github]
             )

    assert {"github", "file:///github/guide.md"} = Process.get({MCPAdapter, :last_read_resource})
    assert "resource:github:file:///github/guide.md" == Process.get(:last_tool_message).content
  end

  test "returns a structured error when synthetic read_resource is missing uri" do
    Process.put(:next_tool_name, "github__read_resource")
    Process.put(:next_tool_args_json, "{}")

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               mcp: [:github]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)
    assert payload["error"] == true
    assert payload["code"] == "invalid_arguments"
    assert payload["tool"] == "read_resource"
  end

  test "returns structured MCP tool errors back into the tool loop" do
    Process.put(:next_tool_name, "github__search_issues")
    Process.put(:next_tool_args_json, ~s({"query":"bugs"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               mcp: [
                 %{name: "github", adapter: MCPAdapter, transport: :http, fail_tool_call: true}
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)
    assert payload["error"] == true
    assert payload["code"] == "tool_call_failed"
    assert payload["server"] == "github"
    assert payload["tool"] == "search_issues"
  end

  test "falls back to non-streaming when MCP tools are present" do
    assert {:ok, {:primary, opts}} =
             Synaptic.Tools.chat(@messages, stream: true, mcp: [:github])

    refute opts[:stream]
    assert is_list(opts[:tools])
    assert Process.get({MCPAdapter, :discover_calls}) == 1
  end

  test "sanitizes top-level MCP combinators for OpenAI tool schemas" do
    schema = %{
      "type" => "object",
      "oneOf" => [
        %{
          "type" => "object",
          "properties" => %{
            "selector" => %{"type" => "string"},
            "index" => %{"type" => "integer"}
          },
          "required" => ["selector"]
        }
      ]
    }

    assert {:ok, {:primary, opts}} =
             Synaptic.Tools.chat(@messages,
               mcp: [
                 %{name: "browser_use", adapter: MCPAdapter, transport: :http, schema: schema}
               ]
             )

    parameters =
      opts[:tools]
      |> Enum.find(&(get_in(&1, [:function, :name]) == "browser_use__search_issues"))
      |> get_in([:function, :parameters])

    assert parameters["type"] == "object"
    refute Map.has_key?(parameters, "oneOf")
    refute Map.has_key?(parameters, "anyOf")
    refute Map.has_key?(parameters, "allOf")
    refute Map.has_key?(parameters, "enum")
    refute Map.has_key?(parameters, "not")
    assert Map.has_key?(parameters["properties"], "selector")
  end

  defp restore_env(app, nil), do: Application.delete_env(:synaptic, app)
  defp restore_env(app, value), do: Application.put_env(:synaptic, app, value)

  defp reset_process_state do
    keys = [
      {ToolAdapter, :stage},
      {MCPAdapter, :discover_calls},
      {MCPAdapter, :last_call_tool},
      {MCPAdapter, :last_list_resources},
      {MCPAdapter, :last_read_resource},
      {MCPToolLoopAdapter, :stage},
      :captured_adapter_tools,
      :last_tool_message,
      :next_tool_name,
      :next_tool_args_json,
      :tool_called
    ]

    Enum.each(keys, &Process.delete/1)
  end
end
