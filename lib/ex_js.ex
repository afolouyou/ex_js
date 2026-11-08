defmodule ExJS do
  @moduledoc """
  Embedding the Kiesel JavaScript engine in Elixir via a NIF.

  ## Example

      {:ok, ctx} = ExJS.new()
      {:ok, 3} = ExJS.eval(ctx, "1 + 2")
      :ok = ExJS.close(ctx)

  Returned values are JSON-compatible: `nil`, booleans, numbers, strings,
  lists and maps with string keys. Special values such as `NaN` and
  `Infinity` are returned as the atoms `:nan`, `:infinity` and
  `:negative_infinity`.

  ## Limits

  `new/1` accepts limits to bound memory usage and nesting depth:

      ExJS.new(
        max_depth: 64,
        max_collection_size: 10_000,
        max_string_bytes: 1_048_576,
        max_source_bytes: 1_048_576
      )

  ## Execution modes

    * `:embedded` (default) - NIF with Kiesel inside the BEAM process. Low
      latency, suitable for trusted code.
    * `:isolated` - separate process via Port, with real timeouts and
      infinite-loop killing. Suitable for untrusted code.

        {:ok, ctx} = ExJS.new(mode: :isolated, timeout: 1_000)

  ## Limitations

    * In `:embedded` mode there is no timeout or infinite-loop interruption.
      `eval` runs on a dirty CPU scheduler, so it does not block normal BEAM
      schedulers.
    * In `:isolated` mode, values travel as JSON: `NaN` and `Infinity` become
      `nil`, and functions cannot be returned.
    * JavaScript errors return `{:error, %{name: ..., message: ...}}`.
  """

  @type context :: reference() | ExJS.Isolated.Context.t()
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
  Creates a new isolated JavaScript context.

  ## Options

    * `:mode` - `:embedded` (default) or `:isolated`
    * `:timeout` - isolated mode timeout in milliseconds (default: 5_000)
    * `:max_depth` - maximum nesting depth (default: 64)
    * `:max_collection_size` - maximum items in lists/maps (default: 10_000)
    * `:max_string_bytes` - maximum string size (default: 1 MiB)
    * `:max_source_bytes` - maximum evaluated source size (default: 1 MiB)
  """
  @spec new(keyword()) :: {:ok, context()} | {:error, term()}
  def new(opts \\ []) when is_list(opts) do
    {mode, opts} = Keyword.pop(opts, :mode, :embedded)

    case mode do
      :embedded ->
        nif_new(build_limits(opts))

      :isolated ->
        ExJS.Isolated.start(opts)

      other ->
        raise ArgumentError, "unknown mode #{inspect(other)}; expected :embedded or :isolated"
    end
  end

  @doc """
  Sets a global variable in the context.

  ## Example

      iex> {:ok, ctx} = ExJS.new()
      iex> :ok = ExJS.set(ctx, "config", %{enabled: true})
      iex> {:ok, %{"enabled" => true}} = ExJS.get(ctx, "config")
  """
  @spec set(context(), binary() | atom(), term()) :: :ok | {:error, term()}
  def set(%ExJS.Isolated.Context{} = ctx, name, value)
      when is_binary(name) or is_atom(name) do
    ExJS.Isolated.set(ctx, name, value)
  end

  def set(ctx, name, value)
      when is_reference(ctx) and (is_binary(name) or is_atom(name)) do
    nif_set(ctx, name, value)
  end

  @doc """
  Reads a global variable from the context.

  Returns `{:error, :not_found}` when the property does not exist. JavaScript
  `null` and `undefined` values return `{:ok, nil}`.
  """
  @spec get(context(), binary() | atom()) :: {:ok, term()} | {:error, term()}
  def get(%ExJS.Isolated.Context{} = ctx, name) when is_binary(name) or is_atom(name) do
    ExJS.Isolated.get(ctx, name)
  end

  def get(ctx, name) when is_reference(ctx) and (is_binary(name) or is_atom(name)) do
    nif_get(ctx, name)
  end

  @doc """
  Calls a global function, using `globalThis` as `this`.

  ## Example

      iex> {:ok, ctx} = ExJS.new()
      iex> :ok = ExJS.eval(ctx, "function sum(a, b) { return a + b }")
      iex> {:ok, 5} = ExJS.call(ctx, "sum", [2, 3])
  """
  @spec call(context(), binary() | atom(), list()) :: {:ok, term()} | {:error, term()}
  def call(ctx, name, arguments \\ [])

  def call(%ExJS.Isolated.Context{} = ctx, name, arguments)
      when (is_binary(name) or is_atom(name)) and is_list(arguments) do
    ExJS.Isolated.call(ctx, name, arguments)
  end

  def call(ctx, name, arguments)
      when is_reference(ctx) and (is_binary(name) or is_atom(name)) and is_list(arguments) do
    nif_call(ctx, name, arguments)
  end

  @doc """
  Evaluates a JavaScript script in the context.
  """
  @spec eval(context(), binary()) :: {:ok, term()} | {:error, js_error() | term()}
  def eval(%ExJS.Isolated.Context{} = ctx, source) when is_binary(source) do
    ExJS.Isolated.eval(ctx, source)
  end

  def eval(ctx, source) when is_reference(ctx) and is_binary(source) do
    nif_eval(ctx, source)
  end

  @doc """
  Evaluates a JavaScript script with variables injected into global scope.

  Map keys may be strings or atoms. Values accept the same JSON-compatible
  types as the return value of `eval/2`.

  ## Example

      iex> {:ok, ctx} = ExJS.new()
      iex> {:ok, 7} = ExJS.eval(ctx, "x + y", %{x: 3, y: 4})
  """
  @spec eval(context(), binary(), map()) :: {:ok, term()} | {:error, js_error() | term()}
  def eval(%ExJS.Isolated.Context{} = ctx, source, bindings)
      when is_binary(source) and is_map(bindings) do
    ExJS.Isolated.eval(ctx, source, bindings)
  end

  def eval(ctx, source, bindings)
      when is_reference(ctx) and is_binary(source) and is_map(bindings) do
    nif_eval(ctx, source, bindings)
  end

  @doc """
  Evaluates a JavaScript file as a script.

  Returns `{:error, posix}` when the file cannot be read.
  """
  @spec eval_file(context(), Path.t()) :: {:ok, term()} | {:error, term()}
  def eval_file(ctx, path) when is_binary(path) do
    with {:ok, source} <- File.read(path) do
      eval(ctx, source)
    end
  end

  @doc """
  Evaluates a JavaScript file with injected variables.
  """
  @spec eval_file(context(), Path.t(), map()) :: {:ok, term()} | {:error, term()}
  def eval_file(ctx, path, bindings)
      when is_binary(path) and is_map(bindings) do
    with {:ok, source} <- File.read(path) do
      eval(ctx, source, bindings)
    end
  end

  @doc """
  Registers an ES module in the context, to be resolved by `import`.

  ## Example

      :ok = ExJS.put_module(ctx, "math", "export const sum = (a, b) => a + b")

      {:ok, %{"default" => 3}} =
        ExJS.eval_module(ctx, ~s(import { sum } from "math"; export default sum(1, 2)))
  """
  @spec put_module(context(), binary(), binary()) :: :ok | {:error, term()}
  def put_module(%ExJS.Isolated.Context{}, _name, _source), do: {:error, :unsupported}

  def put_module(ctx, name, source)
      when is_reference(ctx) and is_binary(name) and is_binary(source) do
    nif_put_module(ctx, name, source)
  end

  @doc """
  Evaluates an ES module and returns its exports.

  ## Options

    * `:name` - module name for error messages (default: `"main"`)

  Imports are resolved only against modules registered with `put_module/3`;
  there is no filesystem access.
  """
  @spec eval_module(context(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def eval_module(ctx, source, opts \\ [])

  def eval_module(%ExJS.Isolated.Context{}, _source, _opts), do: {:error, :unsupported}

  def eval_module(ctx, source, opts)
      when is_reference(ctx) and is_binary(source) and is_list(opts) do
    name = Keyword.get(opts, :name, "main")

    unless is_binary(name) do
      raise ArgumentError, "expected :name to be a string, got: #{inspect(name)}"
    end

    nif_eval_module(ctx, source, name)
  end

  @doc """
  Deletes a global variable from the context.

  Returns `:ok` when the property does not exist or was removed.
  """
  @spec delete(context(), binary() | atom()) :: :ok | {:error, term()}
  def delete(%ExJS.Isolated.Context{} = ctx, name) when is_binary(name) or is_atom(name) do
    ExJS.Isolated.delete(ctx, name)
  end

  def delete(ctx, name) when is_reference(ctx) and (is_binary(name) or is_atom(name)) do
    nif_delete(ctx, name)
  end

  @doc """
  Checks whether a global variable exists.
  """
  @spec has?(context(), binary() | atom()) :: {:ok, boolean()} | {:error, term()}
  def has?(%ExJS.Isolated.Context{} = ctx, name) when is_binary(name) or is_atom(name) do
    ExJS.Isolated.has?(ctx, name)
  end

  def has?(ctx, name) when is_reference(ctx) and (is_binary(name) or is_atom(name)) do
    nif_has(ctx, name)
  end

  @doc """
  Lists the own enumerable keys of `globalThis`.
  """
  @spec keys(context()) :: {:ok, [binary()]} | {:error, term()}
  def keys(%ExJS.Isolated.Context{} = ctx) do
    ExJS.Isolated.keys(ctx)
  end

  def keys(ctx) when is_reference(ctx) do
    nif_keys(ctx)
  end

  @doc """
  Calls a function by property path.

  ## Example

      iex> {:ok, ctx} = ExJS.new()
      iex> {:ok, 3} = ExJS.call_path(ctx, ["Math", "max"], [1, 2, 3])
  """
  @spec call_path(context(), [binary() | atom()], list()) :: {:ok, term()} | {:error, term()}
  def call_path(ctx, path, arguments \\ [])

  def call_path(%ExJS.Isolated.Context{} = ctx, path, arguments)
      when is_list(path) and is_list(arguments) do
    ExJS.Isolated.call_path(ctx, path, arguments)
  end

  def call_path(ctx, path, arguments)
      when is_reference(ctx) and is_list(path) and is_list(arguments) do
    nif_call_path(ctx, path, arguments)
  end

  @doc """
  Runs an explicit Kiesel GC collection.

  Not needed in normal usage; useful for diagnostics and tests.
  """
  @spec collect(context()) :: :ok | {:error, term()}
  def collect(%ExJS.Isolated.Context{} = ctx) do
    ExJS.Isolated.collect(ctx)
  end

  def collect(ctx) when is_reference(ctx) do
    nif_collect(ctx)
  end

  @doc """
  Returns context information.

  ## Example

      {:ok, %{evaluations: 3}} = ExJS.info(ctx)
  """
  @spec info(context()) :: {:ok, %{evaluations: non_neg_integer()}} | {:error, term()}
  def info(%ExJS.Isolated.Context{} = ctx) do
    ExJS.Isolated.info(ctx)
  end

  def info(ctx) when is_reference(ctx) do
    nif_info(ctx)
  end

  @doc """
  Explicitly closes the context.
  """
  @spec close(context()) :: :ok | {:error, term()}
  def close(%ExJS.Isolated.Context{} = ctx) do
    ExJS.Isolated.close(ctx)
  end

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
  defp nif_delete(_ctx, _name), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_has(_ctx, _name), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_keys(_ctx), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_call_path(_ctx, _path, _arguments), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_collect(_ctx), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_put_module(_ctx, _name, _source), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_eval_module(_ctx, _source, _name), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_info(_ctx), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_close(_ctx), do: :erlang.nif_error(:nif_not_loaded)
end
