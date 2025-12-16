defmodule Synaptic.Tools.OpenAITest do
  use ExUnit.Case, async: true

  alias Synaptic.Tools.OpenAI

  test "parse_response returns plain text content" do
    body = completion_body(%{"content" => "hello"})

    assert {:ok, "hello"} = OpenAI.parse_response(body)
  end

  test "parse_response decodes json when response_format requests objects" do
    body = completion_body(%{"content" => ~s({"foo":"bar"})})

    assert {:ok, %{"foo" => "bar"}} =
             OpenAI.parse_response(body, response_format: :json_object)
  end

  test "parse_response flattens list content payloads" do
    message = %{
      "content" => [
        %{"type" => "text", "text" => "hello"},
        %{"text" => " world"}
      ]
    }

    assert {:ok, "hello world"} = OpenAI.parse_response(completion_body(message))
  end

  test "parse_response surfaces tool calls" do
    message = %{
      "content" => nil,
      "tool_calls" => [
        %{
          "id" => "call_1",
          "function" => %{
            "name" => "echo",
            "arguments" => ~s({"text":"hi"})
          }
        }
      ]
    }

    assert {:ok, %{content: nil, tool_calls: [%{"id" => "call_1"} | _]}} =
             OpenAI.parse_response(completion_body(message))
  end

  test "parse_response errors when json response is invalid" do
    body = completion_body(%{"content" => "oops"})

    assert {:error, :invalid_json_response} =
             OpenAI.parse_response(body, response_format: %{type: "json_object"})
  end

  test "parse_response extracts and returns usage metrics when available" do
    body =
      Jason.encode!(%{
        "choices" => [
          %{"message" => %{"content" => "hello"}}
        ],
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 20,
          "total_tokens" => 30
        }
      })

    assert {:ok, "hello", %{usage: usage}} = OpenAI.parse_response(body)
    assert usage.prompt_tokens == 10
    assert usage.completion_tokens == 20
    assert usage.total_tokens == 30
  end

  test "parse_response returns usage metrics with tool calls" do
    body =
      Jason.encode!(%{
        "choices" => [
          %{
            "message" => %{
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "function" => %{"name" => "echo", "arguments" => ~s({"text":"hi"})}
                }
              ]
            }
          }
        ],
        "usage" => %{
          "prompt_tokens" => 15,
          "completion_tokens" => 25,
          "total_tokens" => 40
        }
      })

    assert {:ok, %{content: nil, tool_calls: [_]}, %{usage: usage}} =
             OpenAI.parse_response(body)

    assert usage.prompt_tokens == 15
    assert usage.completion_tokens == 25
    assert usage.total_tokens == 40
  end

  test "parse_response returns without usage when not present in response" do
    body = completion_body(%{"content" => "hello"})

    assert {:ok, "hello"} = OpenAI.parse_response(body)
  end

  test "parse_response handles missing usage fields gracefully" do
    body =
      Jason.encode!(%{
        "choices" => [
          %{"message" => %{"content" => "hello"}}
        ],
        "usage" => %{}
      })

    assert {:ok, "hello", %{usage: usage}} = OpenAI.parse_response(body)
    assert usage.prompt_tokens == 0
    assert usage.completion_tokens == 0
    assert usage.total_tokens == 0
  end

  defp completion_body(message) do
    Jason.encode!(%{
      "choices" => [
        %{"message" => message}
      ]
    })
  end
end
