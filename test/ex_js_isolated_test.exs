defmodule ExJSIsolatedTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, ctx} = ExJS.new(mode: :isolated, timeout: 2_000)
    %{ctx: ctx}
  end

  describe "eval" do
    test "evaluates scripts", %{ctx: ctx} do
      assert {:ok, 3} = ExJS.eval(ctx, "1 + 2")
      assert {:ok, "hello"} = ExJS.eval(ctx, ~S|"hel" + "lo"|)
      assert {:ok, [1, 2]} = ExJS.eval(ctx, "[1, 2]")
      assert {:ok, %{"a" => 1}} = ExJS.eval(ctx, "({ a: 1 })")
      assert {:ok, nil} = ExJS.eval(ctx, "null")
    end

    test "injects bindings", %{ctx: ctx} do
      assert {:ok, 7} = ExJS.eval(ctx, "x + y", %{x: 3, y: 4})
      assert {:ok, 20} = ExJS.eval(ctx, "obj.nested[1]", %{obj: %{"nested" => [10, 20]}})
    end

    test "persists state", %{ctx: ctx} do
      assert {:ok, 1} = ExJS.eval(ctx, "let n = 1; n")
      assert {:ok, 2} = ExJS.eval(ctx, "n + 1")
    end

    test "propagates exceptions", %{ctx: ctx} do
      assert {:error, %{name: "ReferenceError"}} = ExJS.eval(ctx, "missing")

      assert {:error, %{name: "TypeError", message: "boom"}} =
               ExJS.eval(ctx, ~S|throw new TypeError("boom")|)

      assert {:error, %{name: "SyntaxError"}} = ExJS.eval(ctx, "function (")
    end

    test "eval_file", %{ctx: ctx} do
      path = Path.join(System.tmp_dir!(), "ex_js_iso_#{System.unique_integer([:positive])}.js")
      File.write!(path, "let base = 20; base + 22")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, 42} = ExJS.eval_file(ctx, path)
    end
  end

  describe "global variables" do
    test "set/get/has?/delete", %{ctx: ctx} do
      assert :ok = ExJS.set(ctx, "config", %{enabled: true, tags: ["a"]})
      assert {:ok, %{"enabled" => true, "tags" => ["a"]}} = ExJS.get(ctx, "config")
      assert {:ok, true} = ExJS.has?(ctx, "config")
      assert :ok = ExJS.delete(ctx, "config")
      assert {:ok, false} = ExJS.has?(ctx, "config")
      assert {:error, :not_found} = ExJS.get(ctx, "config")
    end

    test "keys", %{ctx: ctx} do
      :ok = ExJS.set(ctx, "custom_key", 1)
      assert {:ok, keys} = ExJS.keys(ctx)
      assert "custom_key" in keys
    end

    test "call and call_path", %{ctx: ctx} do
      assert {:ok, _} = ExJS.eval(ctx, "function sum(a, b) { return a + b }; 0")
      assert {:ok, 5} = ExJS.call(ctx, "sum", [2, 3])
      assert {:ok, 9} = ExJS.call_path(ctx, ["Math", "max"], [1, 9, 3])
      assert {:error, :not_found} = ExJS.call(ctx, "missing")
      assert {:error, :not_found} = ExJS.call_path(ctx, ["Math", "missing"], [])
    end

    test "collect and info", %{ctx: ctx} do
      assert {:ok, %{evaluations: _}} = ExJS.info(ctx)
      assert :ok = ExJS.collect(ctx)
    end
  end

  describe "timeout and lifecycle" do
    test "kills an infinite loop" do
      {:ok, ctx} = ExJS.new(mode: :isolated, timeout: 300)

      {elapsed_us, result} = :timer.tc(fn -> ExJS.eval(ctx, "while (true) {}") end)

      assert {:error, :timeout} = result
      assert elapsed_us < 2_000_000
      assert {:error, :context_closed} = ExJS.eval(ctx, "1")
    end

    test "close terminates the process", %{ctx: ctx} do
      assert :ok = ExJS.close(ctx)
      assert {:error, :context_closed} = ExJS.eval(ctx, "1")
      assert {:error, :context_closed} = ExJS.close(ctx)
    end

    test "context belongs to the creating process", %{ctx: ctx} do
      task = Task.async(fn -> ExJS.eval(ctx, "1") end)
      assert {:error, :not_owner} = Task.await(task)
    end

    test "modules are not supported in isolated mode", %{ctx: ctx} do
      assert {:error, :unsupported} = ExJS.put_module(ctx, "m", "export default 1")
      assert {:error, :unsupported} = ExJS.eval_module(ctx, "export default 1")
    end
  end
end
