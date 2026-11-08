defmodule ExJSStressTest do
  use ExUnit.Case, async: false

  @moduletag :stress
  @moduletag timeout: 120_000

  test "500 contextos sequenciais" do
    Enum.each(1..500, fn i ->
      {:ok, ctx} = ExJS.new()
      assert {:ok, ^i} = ExJS.eval(ctx, "n", %{n: i})
      assert :ok = ExJS.close(ctx)
    end)
  end

  test "50 processos concorrentes com contextos próprios" do
    results =
      1..50
      |> Enum.map(fn i ->
        Task.async(fn ->
          {:ok, ctx} = ExJS.new()

          Enum.each(1..20, fn _ ->
            assert {:ok, ^i} = ExJS.eval(ctx, "n", %{n: i})
          end)

          :ok = ExJS.close(ctx)
          i
        end)
      end)
      |> Task.await_many(60_000)

    assert Enum.sort(results) == Enum.to_list(1..50)
  end

  test "unicode, regexp e exceções" do
    {:ok, ctx} = ExJS.new()

    assert {:ok, "ação 🚀"} = ExJS.eval(ctx, ~S|"ação 🚀"|)
    assert {:ok, ["ab", "cd"]} = ExJS.eval(ctx, ~S|"ab cd".match(/\w+/g)|)
    assert {:ok, "ção"} = ExJS.eval(ctx, ~S|"ação".slice(1)|)
    assert {:ok, "OLA"} = ExJS.eval(ctx, ~S|"ola".toUpperCase()|)
    assert {:error, %{name: "TypeError"}} = ExJS.eval(ctx, "null.x")
    assert {:error, %{name: "ReferenceError"}} = ExJS.eval(ctx, "missing")

    assert :ok = ExJS.close(ctx)
  end

  test "objetos grandes e profundos dentro dos limites" do
    {:ok, ctx} = ExJS.new(max_collection_size: 20_000, max_depth: 100)

    assert {:ok, list} = ExJS.eval(ctx, "Array.from({length: 5000}, (_, i) => i)")
    assert length(list) == 5000
    assert List.first(list) == 0
    assert List.last(list) == 4999

    assert {:ok, deep} =
             ExJS.eval(
               ctx,
               "let o = {}; let c = o; for (let i = 0; i < 80; i++) { c.n = {}; c = c.n }; o"
             )

    assert is_map(deep)
    assert :ok = ExJS.close(ctx)
  end

  test "pressão de GC" do
    {:ok, ctx} = ExJS.new()

    Enum.each(1..2000, fn i ->
      assert {:ok, _} = ExJS.eval(ctx, "({ s: 'x'.repeat(200), n: #{i} })")
    end)

    assert {:ok, %{evaluations: 2000}} = ExJS.info(ctx)
    assert :ok = ExJS.close(ctx)
  end
end
