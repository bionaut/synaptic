defmodule Synaptic.RLM.EnvironmentTest do
  use ExUnit.Case, async: true

  alias Synaptic.RLM.Environment

  test "search_context returns match positions" do
    {:ok, env} = Environment.start_link("hello world\nrelease checklist\nanother line")

    results = Environment.search_context(env, "release", 3)

    assert [%{match: "release", start: start, length: 7}] = results
    assert is_integer(start)

    Environment.stop(env)
  end
end
