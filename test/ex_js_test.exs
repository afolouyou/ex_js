defmodule ExJSTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, ctx} = ExJS.new()
    %{ctx: ctx}
  end

  describe "eval/2" do
    test "evaluates numeric expressions", %{ctx: ctx} do
      assert {:ok, 3} = ExJS.eval(ctx, "1 + 2")
      assert {:ok, 3.5} = ExJS.eval(ctx, "3.5")
      assert {:ok, -7} = ExJS.eval(ctx, "2 - 9")
    end

    test "evaluates strings", %{ctx: ctx} do
      assert {:ok, "hello world"} = ExJS.eval(ctx, "\"hello\" + \" \" + \"world\"")
    end

    test "evaluates booleans and null", %{ctx: ctx} do
      assert {:ok, true} = ExJS.eval(ctx, "true")
      assert {:ok, false} = ExJS.eval(ctx, "false")
      assert {:ok, nil} = ExJS.eval(ctx, "null")
      assert {:ok, nil} = ExJS.eval(ctx, "undefined")
    end

    test "evaluates arrays", %{ctx: ctx} do
      assert {:ok, [1, 2, 3]} = ExJS.eval(ctx, "[1, 2, 3]")
      assert {:ok, []} = ExJS.eval(ctx, "[]")
    end

    test "evaluates objects as maps", %{ctx: ctx} do
      assert {:ok, %{"a" => 1, "b" => "two"}} = ExJS.eval(ctx, "({ a: 1, b: \"two\" })")
    end

    test "evaluates nested structures", %{ctx: ctx} do
      assert {:ok, %{"user" => %{"tags" => ["a", "b"], "active" => true}}} =
               ExJS.eval(ctx, "({ user: { tags: [\"a\", \"b\"], active: true } })")
    end

    test "special number values", %{ctx: ctx} do
      assert {:ok, :nan} = ExJS.eval(ctx, "0 / 0")
      assert {:ok, :infinity} = ExJS.eval(ctx, "1 / 0")
      assert {:ok, :negative_infinity} = ExJS.eval(ctx, "-1 / 0")
    end

    test "persists state between evaluations", %{ctx: ctx} do
      assert {:ok, 1} = ExJS.eval(ctx, "let contador = 1; contador")
      assert {:ok, 2} = ExJS.eval(ctx, "contador + 1")
    end

    test "returns an error for ReferenceError", %{ctx: ctx} do
      assert {:error, %{name: "ReferenceError", message: message}} =
               ExJS.eval(ctx, "nao_existe")

      assert message =~ "nao_existe"
    end

    test "returns an error for TypeError", %{ctx: ctx} do
      assert {:error, %{name: "TypeError", message: "boom"}} =
               ExJS.eval(ctx, "throw new TypeError(\"boom\")")
    end

    test "returns an error for syntax errors", %{ctx: ctx} do
      assert {:error, %{name: "SyntaxError", message: message}} = ExJS.eval(ctx, "function (")
      assert message =~ "Function declaration"
    end

    test "rejects unsupported values", %{ctx: ctx} do
      assert {:error, :unsupported_value} = ExJS.eval(ctx, "(() => 1)")
      assert {:error, :unsupported_value} = ExJS.eval(ctx, "10n")
    end
  end

  describe "eval/3" do
    test "injects bindings with atom keys", %{ctx: ctx} do
      assert {:ok, 7} = ExJS.eval(ctx, "x + y", %{x: 3, y: 4})
    end

    test "injects bindings with string keys", %{ctx: ctx} do
      assert {:ok, 30} = ExJS.eval(ctx, "a + b", %{"a" => 10, "b" => 20})
    end

    test "injects strings and booleans", %{ctx: ctx} do
      assert {:ok, "olá"} = ExJS.eval(ctx, "greeting", %{greeting: "olá"})
      assert {:ok, true} = ExJS.eval(ctx, "ok", %{ok: true})
    end

    test "injects nested lists and maps", %{ctx: ctx} do
      bindings = %{obj: %{"nested" => [10, 20, 30]}}
      assert {:ok, 20} = ExJS.eval(ctx, "obj.nested[1]", bindings)
    end

    test "bindings stay visible between evaluations", %{ctx: ctx} do
      assert {:ok, 5} = ExJS.eval(ctx, "valor", %{valor: 5})
      assert {:ok, 6} = ExJS.eval(ctx, "valor + 1")
    end

    test "returns an error for unsupported binding values", %{ctx: ctx} do
      assert {:error, :unsupported_binding_value} = ExJS.eval(ctx, "x", %{x: make_ref()})
    end
  end

  describe "close/1" do
    test "closes the context", %{ctx: ctx} do
      assert :ok = ExJS.close(ctx)
      assert {:error, :context_closed} = ExJS.eval(ctx, "1")
    end

    test "closing twice returns an error", %{ctx: ctx} do
      assert :ok = ExJS.close(ctx)
      assert {:error, :context_already_closed} = ExJS.close(ctx)
    end
  end

  describe "info/1" do
    test "counts evaluations", %{ctx: ctx} do
      assert {:ok, %{evaluations: 0}} = ExJS.info(ctx)
      assert {:ok, 1} = ExJS.eval(ctx, "1")
      assert {:ok, %{evaluations: 1}} = ExJS.info(ctx)
      assert {:ok, 2} = ExJS.eval(ctx, "2")
      assert {:ok, %{evaluations: 2}} = ExJS.info(ctx)
    end
  end

  describe "limits" do
    test "max_depth" do
      {:ok, ctx} = ExJS.new(max_depth: 3)
      assert {:error, :max_depth_exceeded} = ExJS.eval(ctx, "[[[[1]]]]")
      assert :ok = ExJS.close(ctx)
    end

    test "max_collection_size" do
      {:ok, ctx} = ExJS.new(max_collection_size: 5)

      assert {:error, :collection_too_large} = ExJS.eval(ctx, "[1, 2, 3, 4, 5, 6]")

      assert {:error, :collection_too_large} =
               ExJS.eval(ctx, "values.length", %{values: Enum.to_list(1..10)})

      assert :ok = ExJS.close(ctx)
    end

    test "max_string_bytes" do
      {:ok, ctx} = ExJS.new(max_string_bytes: 10)

      assert {:error, :string_too_large} = ExJS.eval(ctx, "\"12345678901\"")
      assert {:error, :string_too_large} = ExJS.eval(ctx, "value", %{value: "12345678901"})
      assert :ok = ExJS.close(ctx)
    end

    test "max_source_bytes" do
      {:ok, ctx} = ExJS.new(max_source_bytes: 8)
      assert {:error, :source_too_large} = ExJS.eval(ctx, "1 + 2 + 3 + 4")
      assert :ok = ExJS.close(ctx)
    end

    test "rejects invalid options" do
      assert_raise ArgumentError, fn -> ExJS.new(max_depth: 0) end
      assert_raise ArgumentError, fn -> ExJS.new(max_depth: "x") end
      assert_raise ArgumentError, fn -> ExJS.new(unknown: 1) end
    end
  end

  describe "scheduler and concurrency" do
    test "heavy eval runs on a dirty scheduler without freezing other processes" do
      busy =
        Task.async(fn ->
          {:ok, ctx} = ExJS.new()

          result =
            ExJS.eval(
              ctx,
              "let start = Date.now(); while (Date.now() - start < 200) {}; \"done\""
            )

          :ok = ExJS.close(ctx)
          result
        end)

      Process.sleep(20)

      {elapsed_us, _} = :timer.tc(fn -> send(self(), :ping) end)
      assert_receive :ping, 100
      assert elapsed_us < 100_000
      assert {:ok, "done"} = Task.await(busy, 5_000)
    end

    test "independent contexts work in concurrent processes" do
      results =
        1..20
        |> Enum.map(fn i ->
          Task.async(fn ->
            {:ok, ctx} = ExJS.new()
            result = ExJS.eval(ctx, "n * 2", %{n: i})
            :ok = ExJS.close(ctx)
            result
          end)
        end)
        |> Task.await_many(30_000)

      assert results == Enum.map(1..20, &{:ok, &1 * 2})
    end

    test "repeated creation and closing do not corrupt state" do
      Enum.each(1..200, fn i ->
        {:ok, ctx} = ExJS.new()
        assert {:ok, ^i} = ExJS.eval(ctx, "n", %{n: i})
        assert :ok = ExJS.close(ctx)
      end)
    end
  end

  describe "ES modules" do
    test "export default and named import", %{ctx: ctx} do
      assert :ok =
               ExJS.put_module(
                 ctx,
                 "math",
                 "export const sum = (a, b) => a + b; export const pi = 3.14"
               )

      assert {:ok, %{"default" => 3}} =
               ExJS.eval_module(ctx, ~S|import { sum } from "math"; export default sum(1, 2)|)
    end

    test "named exports", %{ctx: ctx} do
      assert :ok = ExJS.put_module(ctx, "math", "export const sum = (a, b) => a + b")

      assert {:ok, %{"total" => 5}} =
               ExJS.eval_module(
                 ctx,
                 ~S|import { sum } from "math"; export const total = sum(2, 3)|
               )
    end

    test "namespace import", %{ctx: ctx} do
      assert :ok = ExJS.put_module(ctx, "math", "export const a = 1; export const b = 2")

      assert {:ok, %{"count" => 2}} =
               ExJS.eval_module(
                 ctx,
                 ~S|import * as m from "math"; export const count = Object.keys(m).length|
               )
    end

    test "missing module returns an error", %{ctx: ctx} do
      assert {:error, %{name: "Error", message: message}} =
               ExJS.eval_module(ctx, ~S|import { x } from "missing"; export default x|)

      assert message =~ "not found"
    end

    test "syntax error in the module", %{ctx: ctx} do
      assert {:error, %{name: "SyntaxError"}} = ExJS.eval_module(ctx, "export default (")
    end
  end

  describe "eval_file/2" do
    test "executes a JavaScript file", %{ctx: ctx} do
      path = Path.join(System.tmp_dir!(), "ex_js_#{System.unique_integer([:positive])}.js")
      File.write!(path, "let base = 20; base + 22")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, 42} = ExJS.eval_file(ctx, path)
    end

    test "returns an error for a missing file", %{ctx: ctx} do
      assert {:error, :enoent} = ExJS.eval_file(ctx, "/tmp/definitely-missing-exjs.js")
    end
  end

  describe "delete/2, has?/2 and keys/1" do
    test "removes and queries variables", %{ctx: ctx} do
      :ok = ExJS.set(ctx, "temp", 1)
      assert {:ok, true} = ExJS.has?(ctx, "temp")
      assert :ok = ExJS.delete(ctx, "temp")
      assert {:ok, false} = ExJS.has?(ctx, "temp")
      assert {:ok, false} = ExJS.has?(ctx, "never_existed")
    end

    test "lists enumerable keys", %{ctx: ctx} do
      :ok = ExJS.set(ctx, "custom_key", 1)
      assert {:ok, keys} = ExJS.keys(ctx)
      assert "custom_key" in keys
    end
  end

  describe "call_path/3 and collect/1" do
    test "calls a function by path", %{ctx: ctx} do
      assert {:ok, 9} = ExJS.call_path(ctx, ["Math", "max"], [1, 9, 3])
      assert {:error, :not_found} = ExJS.call_path(ctx, ["Math", "nope"], [])
      assert {:error, :not_found} = ExJS.call_path(ctx, ["Nope", "max"], [])
    end

    test "explicit GC collection", %{ctx: ctx} do
      assert :ok = ExJS.collect(ctx)
    end
  end

  describe "lifecycle" do
    test "context belongs to the process that created it" do
      {:ok, ctx} = ExJS.new()

      task =
        Task.async(fn ->
          ExJS.eval(ctx, "1 + 1")
        end)

      assert {:error, :not_owner} = Task.await(task)
      assert :ok = ExJS.close(ctx)
    end

    test "context created in another process works there" do
      task =
        Task.async(fn ->
          {:ok, ctx} = ExJS.new()
          result = ExJS.eval(ctx, "21 * 2")
          :ok = ExJS.close(ctx)
          result
        end)

      assert {:ok, 42} = Task.await(task)
    end

    test "destructor does not crash when the owner process dies" do
      parent = self()

      spawn(fn ->
        {:ok, ctx} = ExJS.new()
        {:ok, 1} = ExJS.eval(ctx, "1")
        send(parent, :ready)
      end)

      assert_receive :ready, 5_000
      # Allow time for the process to die and the resource to be collected.
      Process.sleep(50)

      {:ok, ctx} = ExJS.new()
      assert {:ok, 2} = ExJS.eval(ctx, "1 + 1")
      assert :ok = ExJS.close(ctx)
    end
  end

  describe "set/3" do
    test "sets simple values", %{ctx: ctx} do
      assert :ok = ExJS.set(ctx, "answer", 42)
      assert {:ok, 42} = ExJS.get(ctx, "answer")

      assert :ok = ExJS.set(ctx, "name", "Folou")
      assert {:ok, "Folou"} = ExJS.get(ctx, "name")

      assert :ok = ExJS.set(ctx, :flag, true)
      assert {:ok, true} = ExJS.get(ctx, "flag")

      assert :ok = ExJS.set(ctx, "nothing", nil)
      assert {:ok, nil} = ExJS.get(ctx, "nothing")
    end

    test "sets nested lists and maps", %{ctx: ctx} do
      assert :ok = ExJS.set(ctx, "data", %{tags: ["zig", "elixir"], meta: %{"ok" => true}})

      assert {:ok, %{"tags" => ["zig", "elixir"], "meta" => %{"ok" => true}}} =
               ExJS.get(ctx, "data")
    end

    test "persists between evaluations", %{ctx: ctx} do
      assert :ok = ExJS.set(ctx, "counter", 1)
      assert {:ok, 2} = ExJS.eval(ctx, "counter + 1")
      assert :ok = ExJS.set(ctx, "counter", 10)
      assert {:ok, 11} = ExJS.eval(ctx, "counter + 1")
    end

    test "rejects unsupported values", %{ctx: ctx} do
      assert {:error, :unsupported_value} = ExJS.set(ctx, "fn", fn -> :ok end)
      assert {:error, :unsupported_value} = ExJS.set(ctx, "ref", make_ref())
    end

    test "respects limits", _ do
      {:ok, ctx} = ExJS.new(max_depth: 3)
      assert {:error, :max_depth_exceeded} = ExJS.set(ctx, "deep", [[[[1]]]])
      assert :ok = ExJS.close(ctx)
    end

    test "fails on a closed context", %{ctx: ctx} do
      assert :ok = ExJS.close(ctx)
      assert {:error, :context_closed} = ExJS.set(ctx, "x", 1)
    end

    test "fails for another process", %{ctx: ctx} do
      task = Task.async(fn -> ExJS.set(ctx, "x", 1) end)
      assert {:error, :not_owner} = Task.await(task)
    end
  end

  describe "get/2" do
    test "distinguishes missing from null", %{ctx: ctx} do
      assert {:ok, _} = ExJS.eval(ctx, "var nullable = null; var undef = undefined")
      assert {:ok, nil} = ExJS.get(ctx, "nullable")
      assert {:ok, nil} = ExJS.get(ctx, "undef")
      assert {:error, :not_found} = ExJS.get(ctx, "missing")
    end

    test "reads nested structures", %{ctx: ctx} do
      assert {:ok, _} = ExJS.eval(ctx, "var obj = { a: [1, { b: 2 }] }")
      assert {:ok, %{"a" => [1, %{"b" => 2}]}} = ExJS.get(ctx, "obj")
    end

    test "rejects unsupported values", %{ctx: ctx} do
      assert {:ok, _} = ExJS.eval(ctx, "var fn = () => 1")
      assert {:error, :unsupported_value} = ExJS.get(ctx, "fn")
    end

    test "propagates getter errors", %{ctx: ctx} do
      assert {:ok, _} =
               ExJS.eval(ctx, """
               Object.defineProperty(globalThis, "boom", {
                 get() { throw new TypeError("getter failed") }
               }); 0
               """)

      assert {:error, %{name: "TypeError", message: "getter failed"}} = ExJS.get(ctx, "boom")
    end

    test "respects return limits", _ do
      {:ok, ctx} = ExJS.new(max_collection_size: 3)
      assert {:ok, _} = ExJS.eval(ctx, "var big = [1, 2, 3, 4]")
      assert {:error, :collection_too_large} = ExJS.get(ctx, "big")
      assert :ok = ExJS.close(ctx)
    end
  end

  describe "call/3" do
    test "calls a function with numeric arguments", %{ctx: ctx} do
      assert {:ok, _} = ExJS.eval(ctx, "function sum(a, b) { return a + b }")
      assert {:ok, 5} = ExJS.call(ctx, "sum", [2, 3])
    end

    test "accepts complex arguments and return values", %{ctx: ctx} do
      assert {:ok, _} =
               ExJS.eval(ctx, "function pick(obj, index) { return obj.items[index] }")

      assert {:ok, %{"value" => 20}} =
               ExJS.call(ctx, "pick", [%{items: [%{value: 10}, %{value: 20}]}, 1])
    end

    test "uses globalThis as this", %{ctx: ctx} do
      assert {:ok, _} =
               ExJS.eval(ctx, """
               globalThis.counter = 0
               globalThis.increment = function () {
                 this.counter += 1
                 return this.counter
               }; 0
               """)

      assert {:ok, 1} = ExJS.call(ctx, "increment")
      assert {:ok, 2} = ExJS.call(ctx, "increment")
    end

    test "error when the function does not exist", %{ctx: ctx} do
      assert {:error, :not_found} = ExJS.call(ctx, "missing")
    end

    test "error when the global is not callable", %{ctx: ctx} do
      assert :ok = ExJS.set(ctx, "value", 42)
      assert {:error, :not_callable} = ExJS.call(ctx, "value")
    end

    test "propagates JavaScript exceptions", %{ctx: ctx} do
      assert {:ok, _} =
               ExJS.eval(ctx, "function explode() { throw new RangeError(\"boom\") }")

      assert {:error, %{name: "RangeError", message: "boom"}} = ExJS.call(ctx, "explode")
    end

    test "respects argument limits", _ do
      {:ok, ctx} = ExJS.new(max_collection_size: 3)
      assert {:ok, _} = ExJS.eval(ctx, "function size(xs) { return xs.length }")
      assert {:error, :collection_too_large} = ExJS.call(ctx, "size", [[1, 2, 3, 4]])
      assert :ok = ExJS.close(ctx)
    end

    test "rejects unsupported return values", %{ctx: ctx} do
      assert {:ok, _} = ExJS.eval(ctx, "function make() { return () => 1 }")
      assert {:error, :unsupported_value} = ExJS.call(ctx, "make")
    end
  end
end
