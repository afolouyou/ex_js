defmodule Bench do
  def run(name, iterations, fun) do
    # Warmup
    fun.()

    {elapsed_us, _} = :timer.tc(fn -> Enum.each(1..iterations, fn _ -> fun.() end) end)
    ops_per_second = iterations / (elapsed_us / 1_000_000)

    IO.puts(
      "#{String.pad_trailing(name, 24)} #{String.pad_leading(format(ops_per_second), 12)} ops/s" <>
        "   (#{Float.round(elapsed_us / iterations, 1)} µs/op)"
    )
  end

  defp format(value) when value >= 1_000_000, do: "#{Float.round(value / 1_000_000, 2)}M"
  defp format(value) when value >= 1_000, do: "#{Float.round(value / 1_000, 1)}k"
  defp format(value), do: "#{Float.round(value, 1)}"
end

{:ok, ctx} = ExJS.new()

IO.puts("ExJS benchmark\n")

Bench.run("eval trivial", 10_000, fn ->
  {:ok, 3} = ExJS.eval(ctx, "1 + 2")
end)

Bench.run("eval objeto", 5_000, fn ->
  {:ok, _} = ExJS.eval(ctx, "({ a: 1, b: [1, 2, 3], c: { d: 'x' } })")
end)

Bench.run("eval string", 5_000, fn ->
  {:ok, _} = ExJS.eval(ctx, ~S|"olá ".repeat(10)|)
end)

Bench.run("set + get", 10_000, fn ->
  :ok = ExJS.set(ctx, "x", 42)
  {:ok, 42} = ExJS.get(ctx, "x")
end)

{:ok, _} = ExJS.eval(ctx, "function twice(a) { return a * 2 }")

Bench.run("call", 10_000, fn ->
  {:ok, 8} = ExJS.call(ctx, "twice", [4])
end)

:ok = ExJS.close(ctx)
IO.puts("\nOK")
