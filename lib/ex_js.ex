defmodule ExJS do
  @moduledoc """
  Embedding do motor JavaScript Kiesel no Elixir via NIF.

  ## Exemplo

      {:ok, ctx} = ExJS.new()
      {:ok, 3} = ExJS.eval(ctx, "1 + 2")
      :ok = ExJS.close(ctx)

  Os valores retornados são compatíveis com JSON: `nil`, booleanos, números,
  strings, listas e mapas com chaves string. Valores especiais como `NaN` e
  `Infinity` são retornados como os átomos `:nan`, `:infinity` e
  `:negative_infinity`.

  ## Limites

  `new/1` aceita limites para conter uso de memória e profundidade:

      ExJS.new(
        max_depth: 64,
        max_collection_size: 10_000,
        max_string_bytes: 1_048_576,
        max_source_bytes: 1_048_576
      )

  ## Limitações (v0.1)

    * Apenas scripts confiáveis: não há timeout nem interrupção de loops
      infinitos. `eval` roda em dirty CPU scheduler, então não bloqueia os
      schedulers normais do BEAM.
    * Erros JavaScript retornam `{:error, %{name: ..., message: ...}}`.
  """

  @type context :: reference()
  @type js_error :: %{
          required(:name) => binary(),
          required(:message) => binary(),
          optional(:stack) => binary() | [binary()]
        }

  @default_limits %{
    max_depth: 64,
    max_collection_size: 10_000,
    max_string_bytes: 1_048_576,
    max_source_bytes: 1_048_576
  }

  @on_load :load_nif

  def load_nif do
    nif_path = :filename.join(:code.priv_dir(:ex_js), ~c"libex_js_nif")

    case :erlang.load_nif(nif_path, 0) do
      :ok ->
        :ok

      {:error, reason} ->
        :logger.error("Failed to load ExJS NIF: ~p", [reason])
        :ok
    end
  end

  @doc """
  Cria um novo contexto JavaScript isolado.

  ## Opções

    * `:max_depth` - profundidade máxima de aninhamento (padrão: 64)
    * `:max_collection_size` - itens máximos em listas/mapas (padrão: 10_000)
    * `:max_string_bytes` - tamanho máximo de strings (padrão: 1 MiB)
    * `:max_source_bytes` - tamanho máximo do código avaliado (padrão: 1 MiB)
  """
  @spec new(keyword()) :: {:ok, context()} | {:error, term()}
  def new(opts \\ []) when is_list(opts) do
    nif_new(build_limits(opts))
  end

  @doc """
  Define uma variável global no contexto.

  ## Exemplo

      iex> {:ok, ctx} = ExJS.new()
      iex> :ok = ExJS.set(ctx, "config", %{enabled: true})
      iex> {:ok, %{"enabled" => true}} = ExJS.get(ctx, "config")
  """
  @spec set(context(), binary() | atom(), term()) :: :ok | {:error, term()}
  def set(ctx, name, value)
      when is_reference(ctx) and (is_binary(name) or is_atom(name)) do
    nif_set(ctx, name, value)
  end

  @doc """
  Lê uma variável global do contexto.

  Retorna `{:error, :not_found}` quando a propriedade não existe. Valores
  JavaScript `null` e `undefined` retornam `{:ok, nil}`.
  """
  @spec get(context(), binary() | atom()) :: {:ok, term()} | {:error, term()}
  def get(ctx, name) when is_reference(ctx) and (is_binary(name) or is_atom(name)) do
    nif_get(ctx, name)
  end

  @doc """
  Chama uma função global do contexto, usando `globalThis` como `this`.

  ## Exemplo

      iex> {:ok, ctx} = ExJS.new()
      iex> :ok = ExJS.eval(ctx, "function sum(a, b) { return a + b }")
      iex> {:ok, 5} = ExJS.call(ctx, "sum", [2, 3])
  """
  @spec call(context(), binary() | atom(), list()) :: {:ok, term()} | {:error, term()}
  def call(ctx, name, arguments \\ [])
      when is_reference(ctx) and (is_binary(name) or is_atom(name)) and is_list(arguments) do
    nif_call(ctx, name, arguments)
  end

  @doc """
  Avalia um script JavaScript no contexto.
  """
  @spec eval(context(), binary()) :: {:ok, term()} | {:error, js_error() | term()}
  def eval(ctx, source) when is_reference(ctx) and is_binary(source) do
    nif_eval(ctx, source)
  end

  @doc """
  Avalia um script JavaScript com variáveis injetadas no escopo global.

  As chaves do mapa podem ser strings ou átomos. Os valores aceitam os mesmos
  tipos compatíveis com JSON do retorno de `eval/2`.

  ## Exemplo

      iex> {:ok, ctx} = ExJS.new()
      iex> {:ok, 7} = ExJS.eval(ctx, "x + y", %{x: 3, y: 4})
  """
  @spec eval(context(), binary(), map()) :: {:ok, term()} | {:error, js_error() | term()}
  def eval(ctx, source, bindings)
      when is_reference(ctx) and is_binary(source) and is_map(bindings) do
    nif_eval(ctx, source, bindings)
  end

  @doc """
  Retorna informações do contexto.

  ## Exemplo

      {:ok, %{evaluations: 3}} = ExJS.info(ctx)
  """
  @spec info(context()) :: {:ok, %{evaluations: non_neg_integer()}} | {:error, term()}
  def info(ctx) when is_reference(ctx) do
    nif_info(ctx)
  end

  @doc """
  Fecha explicitamente o contexto.
  """
  @spec close(context()) :: :ok | {:error, term()}
  def close(ctx) when is_reference(ctx) do
    nif_close(ctx)
  end

  defp build_limits(opts) do
    Enum.reduce(opts, @default_limits, fn
      {key, value}, acc when is_map_key(acc, key) ->
        unless is_integer(value) and value > 0 do
          raise ArgumentError,
                "expected #{inspect(key)} to be a positive integer, got: #{inspect(value)}"
        end

        Map.put(acc, key, value)

      {key, _value}, _acc ->
        raise ArgumentError,
              "unknown option #{inspect(key)}. Valid options: #{inspect(Map.keys(@default_limits))}"
    end)
  end

  # NIF stubs
  defp nif_new(_limits), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_eval(_ctx, _source), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_eval(_ctx, _source, _bindings), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_set(_ctx, _name, _value), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_get(_ctx, _name), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_call(_ctx, _name, _arguments), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_info(_ctx), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_close(_ctx), do: :erlang.nif_error(:nif_not_loaded)
end
