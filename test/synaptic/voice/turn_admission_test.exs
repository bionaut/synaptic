defmodule Synaptic.Voice.TurnAdmissionTest do
  use ExUnit.Case, async: true

  alias Synaptic.Voice.TurnAdmission

  defmodule Policy do
    @behaviour TurnAdmission

    @impl true
    def decide(input, opts), do: {:commit, %{input: input, opts: opts}}
  end

  test "normalizes function and module decisions" do
    assert {:ok, :keep_listening, %{reason: :incomplete}} =
             TurnAdmission.evaluate(
               fn _input -> {:keep_listening, %{reason: :incomplete}} end,
               %{}
             )

    assert {:ok, :commit, %{input: %{text: "hello"}, opts: [source: :test]}} =
             TurnAdmission.evaluate(Policy, %{text: "hello"}, source: :test)
  end

  test "returns errors for invalid decisions and policy exceptions" do
    assert {:error, {:invalid_decision, :later}} =
             TurnAdmission.evaluate(fn _input -> :later end, %{})

    assert {:error, {:exception, %RuntimeError{message: "boom"}, _stacktrace}} =
             TurnAdmission.evaluate(fn _input -> raise "boom" end, %{})
  end
end
