# Synthetic latency harness for Synaptic voice sessions.
# Usage:
#   mix run scripts/voice_latency_harness.exs

latencies =
  1..500
  |> Enum.map(fn _ ->
    %{
      stt_first_partial_ms: Enum.random(180..480),
      llm_first_chunk_ms: Enum.random(220..700),
      tts_first_chunk_ms: Enum.random(320..860),
      turn_total_ms: Enum.random(900..2200)
    }
  end)

defmodule Stats do
  def percentile(samples, p) do
    sorted = Enum.sort(samples)
    idx = min(length(sorted) - 1, max(0, trunc(Float.ceil(p * length(sorted))) - 1))
    Enum.at(sorted, idx)
  end

  def median(samples), do: percentile(samples, 0.5)
end

metrics = [:stt_first_partial_ms, :llm_first_chunk_ms, :tts_first_chunk_ms, :turn_total_ms]

summary =
  Enum.map(metrics, fn key ->
    values = Enum.map(latencies, &Map.fetch!(&1, key))

    %{
      metric: key,
      p50: Stats.median(values),
      p90: Stats.percentile(values, 0.90),
      p99: Stats.percentile(values, 0.99)
    }
  end)

IO.puts("Synaptic voice latency summary (synthetic):")
Enum.each(summary, &IO.inspect/1)

stt_ok? = Stats.median(Enum.map(latencies, & &1.stt_first_partial_ms)) < 500
tts_ok? = Stats.median(Enum.map(latencies, & &1.tts_first_chunk_ms)) < 900

IO.puts("\nSLO checks:")
IO.puts("- stt_first_partial_ms p50 < 500: #{stt_ok?}")
IO.puts("- tts_first_chunk_ms p50 < 900: #{tts_ok?}")
