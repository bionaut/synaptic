defmodule Synaptic.ScorerTest do
  use ExUnit.Case, async: true

  alias Synaptic.Scorer
  alias Synaptic.Scorer.{Context, Result}

  describe "Result.new/1" do
    test "builds a result with required fields and auto timestamp" do
      now = NaiveDateTime.utc_now()

      result =
        Result.new(
          name: "test_scorer",
          step: :some_step,
          run_id: "run-123",
          score: 0.9,
          reason: "looks good",
          details: %{foo: :bar}
        )

      assert %Result{
               name: "test_scorer",
               step: :some_step,
               run_id: "run-123",
               score: 0.9,
               reason: "looks good",
               details: %{foo: :bar},
               timestamp: timestamp
             } = result

      # sanity check we got a recent timestamp
      assert NaiveDateTime.diff(timestamp, now) in 0..5
    end
  end

  describe "normalize_scorer_specs/1" do
    test "normalizes nil and empty list" do
      assert [] == Scorer.normalize_scorer_specs(nil)
      assert [] == Scorer.normalize_scorer_specs([])
    end

    test "normalizes module-only entries" do
      assert [%{module: Mod, opts: []}] = Scorer.normalize_scorer_specs(Mod)
      assert [%{module: Mod, opts: []}] = Scorer.normalize_scorer_specs([Mod])
    end

    test "normalizes {module, opts} tuples" do
      assert [%{module: Mod, opts: [foo: :bar]}] =
               Scorer.normalize_scorer_specs({Mod, [foo: :bar]})
    end

    test "normalizes map specs" do
      assert [%{module: Mod, opts: [foo: :bar]}] =
               Scorer.normalize_scorer_specs(%{module: Mod, opts: [foo: :bar]})
    end
  end

  defmodule ExampleScorer do
    @behaviour Synaptic.Scorer

    @impl true
    def score(%Context{step: step, run_id: run_id, output: output}, metadata) do
      Result.new(
        name: "example",
        step: step.name,
        run_id: run_id,
        score: 1.0,
        reason: "always passes",
        details: %{called_with: metadata, output: output}
      )
    end
  end
end
