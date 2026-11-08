defmodule ExJSTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, ctx} = ExJS.new()
    %{ctx: ctx}
  end

  describe "eval/2" do
    test "avalia expressões numéricas", %{ctx: ctx} do
      assert {:ok, 3} = ExJS.eval(ctx, "1 + 2")
      assert {:ok, 3.5} = ExJS.eval(ctx, "3.5")
      assert {:ok, -7} = ExJS.eval(ctx, "2 - 9")
    end

    test "avalia strings", %{ctx: ctx} do
      assert {:ok, "hello world"} = ExJS.eval(ctx, "\"hello\" + \" \" + \"world\"")
    end

    test "avalia booleanos e null", %{ctx: ctx} do
      assert {:ok, true} = ExJS.eval(ctx, "true")
      assert {:ok, false} = ExJS.eval(ctx, "false")
      assert {:ok, nil} = ExJS.eval(ctx, "null")
      assert {:ok, nil} = ExJS.eval(ctx, "undefined")
    end

    test "avalia arrays", %{ctx: ctx} do
      assert {:ok, [1, 2, 3]} = ExJS.eval(ctx, "[1, 2, 3]")
      assert {:ok, []} = ExJS.eval(ctx, "[]")
    end

    test "avalia objetos como mapas", %{ctx: ctx} do
      assert {:ok, %{"a" => 1, "b" => "two"}} = ExJS.eval(ctx, "({ a: 1, b: \"two\" })")
    end

    test "avalia estruturas aninhadas", %{ctx: ctx} do
      assert {:ok, %{"user" => %{"tags" => ["a", "b"], "active" => true}}} =
               ExJS.eval(ctx, "({ user: { tags: [\"a\", \"b\"], active: true } })")
    end

    test "valores especiais de número", %{ctx: ctx} do
      assert {:ok, :nan} = ExJS.eval(ctx, "0 / 0")
      assert {:ok, :infinity} = ExJS.eval(ctx, "1 / 0")
      assert {:ok, :negative_infinity} = ExJS.eval(ctx, "-1 / 0")
    end

    test "persiste o estado entre avaliações", %{ctx: ctx} do
      assert {:ok, 1} = ExJS.eval(ctx, "let contador = 1; contador")
      assert {:ok, 2} = ExJS.eval(ctx, "contador + 1")
    end

    test "retorna erro para ReferenceError", %{ctx: ctx} do
      assert {:error, %{name: "ReferenceError", message: message}} =
               ExJS.eval(ctx, "nao_existe")

      assert message =~ "nao_existe"
    end

    test "retorna erro para TypeError", %{ctx: ctx} do
      assert {:error, %{name: "TypeError", message: "boom"}} =
               ExJS.eval(ctx, "throw new TypeError(\"boom\")")
    end

    test "retorna erro para erro de sintaxe", %{ctx: ctx} do
      assert {:error, %{name: "SyntaxError", message: message}} = ExJS.eval(ctx, "function (")
      assert message =~ "Function declaration"
    end

    test "rejeita valores não suportados", %{ctx: ctx} do
      assert {:error, :unsupported_value} = ExJS.eval(ctx, "(() => 1)")
      assert {:error, :unsupported_value} = ExJS.eval(ctx, "10n")
    end
  end

  describe "eval/3" do
    test "injeta bindings com chaves atom", %{ctx: ctx} do
      assert {:ok, 7} = ExJS.eval(ctx, "x + y", %{x: 3, y: 4})
    end

    test "injeta bindings com chaves string", %{ctx: ctx} do
      assert {:ok, 30} = ExJS.eval(ctx, "a + b", %{"a" => 10, "b" => 20})
    end

    test "injeta strings e booleanos", %{ctx: ctx} do
      assert {:ok, "olá"} = ExJS.eval(ctx, "greeting", %{greeting: "olá"})
      assert {:ok, true} = ExJS.eval(ctx, "ok", %{ok: true})
    end

    test "injeta listas e mapas aninhados", %{ctx: ctx} do
      bindings = %{obj: %{"nested" => [10, 20, 30]}}
      assert {:ok, 20} = ExJS.eval(ctx, "obj.nested[1]", bindings)
    end

    test "os bindings ficam visíveis entre avaliações", %{ctx: ctx} do
      assert {:ok, 5} = ExJS.eval(ctx, "valor", %{valor: 5})
      assert {:ok, 6} = ExJS.eval(ctx, "valor + 1")
    end

    test "retorna erro para valor de binding não suportado", %{ctx: ctx} do
      assert {:error, :unsupported_binding_value} = ExJS.eval(ctx, "x", %{x: make_ref()})
    end
  end

  describe "close/1" do
    test "fecha o contexto", %{ctx: ctx} do
      assert :ok = ExJS.close(ctx)
      assert {:error, :context_closed} = ExJS.eval(ctx, "1")
    end

    test "fechar duas vezes retorna erro", %{ctx: ctx} do
      assert :ok = ExJS.close(ctx)
      assert {:error, :context_already_closed} = ExJS.close(ctx)
    end
  end

  describe "info/1" do
    test "conta avaliações", %{ctx: ctx} do
      assert {:ok, %{evaluations: 0}} = ExJS.info(ctx)
      assert {:ok, 1} = ExJS.eval(ctx, "1")
      assert {:ok, %{evaluations: 1}} = ExJS.info(ctx)
      assert {:ok, 2} = ExJS.eval(ctx, "2")
      assert {:ok, %{evaluations: 2}} = ExJS.info(ctx)
    end
  end

  describe "limites" do
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

    test "rejeita opções inválidas" do
      assert_raise ArgumentError, fn -> ExJS.new(max_depth: 0) end
      assert_raise ArgumentError, fn -> ExJS.new(max_depth: "x") end
      assert_raise ArgumentError, fn -> ExJS.new(unknown: 1) end
    end
  end

  describe "scheduler e concorrência" do
    test "eval pesado roda em dirty scheduler sem congelar outros processos" do
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

    test "contextos independentes funcionam em processos concorrentes" do
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

    test "criação e fechamento repetidos não corrompem estado" do
      Enum.each(1..200, fn i ->
        {:ok, ctx} = ExJS.new()
        assert {:ok, ^i} = ExJS.eval(ctx, "n", %{n: i})
        assert :ok = ExJS.close(ctx)
      end)
    end
  end

  describe "ciclo de vida" do
    test "contexto pertence ao processo que o criou" do
      {:ok, ctx} = ExJS.new()

      task =
        Task.async(fn ->
          ExJS.eval(ctx, "1 + 1")
        end)

      assert {:error, :not_owner} = Task.await(task)
      assert :ok = ExJS.close(ctx)
    end

    test "contexto criado em outro processo funciona nele" do
      task =
        Task.async(fn ->
          {:ok, ctx} = ExJS.new()
          result = ExJS.eval(ctx, "21 * 2")
          :ok = ExJS.close(ctx)
          result
        end)

      assert {:ok, 42} = Task.await(task)
    end

    test "destrutor não quebra quando o processo dono morre" do
      parent = self()

      spawn(fn ->
        {:ok, ctx} = ExJS.new()
        {:ok, 1} = ExJS.eval(ctx, "1")
        send(parent, :ready)
      end)

      assert_receive :ready, 5_000
      # Dá tempo do processo morrer e do recurso ser coletado.
      Process.sleep(50)

      {:ok, ctx} = ExJS.new()
      assert {:ok, 2} = ExJS.eval(ctx, "1 + 1")
      assert :ok = ExJS.close(ctx)
    end
  end

  describe "set/3" do
    test "define valores simples", %{ctx: ctx} do
      assert :ok = ExJS.set(ctx, "answer", 42)
      assert {:ok, 42} = ExJS.get(ctx, "answer")

      assert :ok = ExJS.set(ctx, "name", "Folou")
      assert {:ok, "Folou"} = ExJS.get(ctx, "name")

      assert :ok = ExJS.set(ctx, :flag, true)
      assert {:ok, true} = ExJS.get(ctx, "flag")

      assert :ok = ExJS.set(ctx, "nothing", nil)
      assert {:ok, nil} = ExJS.get(ctx, "nothing")
    end

    test "define listas e mapas aninhados", %{ctx: ctx} do
      assert :ok = ExJS.set(ctx, "data", %{tags: ["zig", "elixir"], meta: %{"ok" => true}})

      assert {:ok, %{"tags" => ["zig", "elixir"], "meta" => %{"ok" => true}}} =
               ExJS.get(ctx, "data")
    end

    test "persiste entre avaliações", %{ctx: ctx} do
      assert :ok = ExJS.set(ctx, "counter", 1)
      assert {:ok, 2} = ExJS.eval(ctx, "counter + 1")
      assert :ok = ExJS.set(ctx, "counter", 10)
      assert {:ok, 11} = ExJS.eval(ctx, "counter + 1")
    end

    test "rejeita valores não suportados", %{ctx: ctx} do
      assert {:error, :unsupported_value} = ExJS.set(ctx, "fn", fn -> :ok end)
      assert {:error, :unsupported_value} = ExJS.set(ctx, "ref", make_ref())
    end

    test "respeita limites", _ do
      {:ok, ctx} = ExJS.new(max_depth: 3)
      assert {:error, :max_depth_exceeded} = ExJS.set(ctx, "deep", [[[[1]]]])
      assert :ok = ExJS.close(ctx)
    end

    test "falha em contexto fechado", %{ctx: ctx} do
      assert :ok = ExJS.close(ctx)
      assert {:error, :context_closed} = ExJS.set(ctx, "x", 1)
    end

    test "falha para outro processo", %{ctx: ctx} do
      task = Task.async(fn -> ExJS.set(ctx, "x", 1) end)
      assert {:error, :not_owner} = Task.await(task)
    end
  end

  describe "get/2" do
    test "distingue ausente de null", %{ctx: ctx} do
      assert {:ok, _} = ExJS.eval(ctx, "var nullable = null; var undef = undefined")
      assert {:ok, nil} = ExJS.get(ctx, "nullable")
      assert {:ok, nil} = ExJS.get(ctx, "undef")
      assert {:error, :not_found} = ExJS.get(ctx, "missing")
    end

    test "lê estruturas aninhadas", %{ctx: ctx} do
      assert {:ok, _} = ExJS.eval(ctx, "var obj = { a: [1, { b: 2 }] }")
      assert {:ok, %{"a" => [1, %{"b" => 2}]}} = ExJS.get(ctx, "obj")
    end

    test "rejeita valores não suportados", %{ctx: ctx} do
      assert {:ok, _} = ExJS.eval(ctx, "var fn = () => 1")
      assert {:error, :unsupported_value} = ExJS.get(ctx, "fn")
    end

    test "propaga erro de getter", %{ctx: ctx} do
      assert {:ok, _} =
               ExJS.eval(ctx, """
               Object.defineProperty(globalThis, "boom", {
                 get() { throw new TypeError("getter failed") }
               }); 0
               """)

      assert {:error, %{name: "TypeError", message: "getter failed"}} = ExJS.get(ctx, "boom")
    end

    test "respeita limites de retorno", _ do
      {:ok, ctx} = ExJS.new(max_collection_size: 3)
      assert {:ok, _} = ExJS.eval(ctx, "var big = [1, 2, 3, 4]")
      assert {:error, :collection_too_large} = ExJS.get(ctx, "big")
      assert :ok = ExJS.close(ctx)
    end
  end

  describe "call/3" do
    test "chama função com argumentos numéricos", %{ctx: ctx} do
      assert {:ok, _} = ExJS.eval(ctx, "function sum(a, b) { return a + b }")
      assert {:ok, 5} = ExJS.call(ctx, "sum", [2, 3])
    end

    test "aceita argumentos e retornos complexos", %{ctx: ctx} do
      assert {:ok, _} =
               ExJS.eval(ctx, "function pick(obj, index) { return obj.items[index] }")

      assert {:ok, %{"value" => 20}} =
               ExJS.call(ctx, "pick", [%{items: [%{value: 10}, %{value: 20}]}, 1])
    end

    test "usa globalThis como this", %{ctx: ctx} do
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

    test "erro quando a função não existe", %{ctx: ctx} do
      assert {:error, :not_found} = ExJS.call(ctx, "missing")
    end

    test "erro quando o global não é chamável", %{ctx: ctx} do
      assert :ok = ExJS.set(ctx, "value", 42)
      assert {:error, :not_callable} = ExJS.call(ctx, "value")
    end

    test "propaga exceção JavaScript", %{ctx: ctx} do
      assert {:ok, _} =
               ExJS.eval(ctx, "function explode() { throw new RangeError(\"boom\") }")

      assert {:error, %{name: "RangeError", message: "boom"}} = ExJS.call(ctx, "explode")
    end

    test "respeita limites dos argumentos", _ do
      {:ok, ctx} = ExJS.new(max_collection_size: 3)
      assert {:ok, _} = ExJS.eval(ctx, "function size(xs) { return xs.length }")
      assert {:error, :collection_too_large} = ExJS.call(ctx, "size", [[1, 2, 3, 4]])
      assert :ok = ExJS.close(ctx)
    end

    test "rejeita retorno não suportado", %{ctx: ctx} do
      assert {:ok, _} = ExJS.eval(ctx, "function make() { return () => 1 }")
      assert {:error, :unsupported_value} = ExJS.call(ctx, "make")
    end
  end
end
