defmodule ExJS.Isolated do
  @moduledoc false

  use GenServer

  defmodule Context do
    @moduledoc false
    defstruct [:pid, :timeout, :max_source_bytes]
    @type t :: %__MODULE__{pid: pid(), timeout: timeout(), max_source_bytes: pos_integer()}
  end

  @default_timeout 5_000
  @default_max_source_bytes 1_048_576

  ## API

  def start(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_source_bytes = Keyword.get(opts, :max_source_bytes, @default_max_source_bytes)

    unless is_integer(timeout) and timeout > 0 do
      raise ArgumentError, "expected :timeout to be a positive integer, got: #{inspect(timeout)}"
    end

    unless is_integer(max_source_bytes) and max_source_bytes > 0 do
      raise ArgumentError,
            "expected :max_source_bytes to be a positive integer, got: #{inspect(max_source_bytes)}"
    end

    case GenServer.start_link(__MODULE__, %{owner: self()}) do
      {:ok, pid} ->
        {:ok, %Context{pid: pid, timeout: timeout, max_source_bytes: max_source_bytes}}

      other ->
        other
    end
  end

  def eval(%Context{} = ctx, source) do
    request(ctx, {:eval, source, ctx.timeout}, ctx.timeout)
  end

  def eval(%Context{} = ctx, source, bindings) when is_map(bindings) do
    with {:ok, prelude} <- bindings_prelude(bindings) do
      eval(ctx, prelude <> source)
    end
  end

  def set(%Context{} = ctx, name, value) do
    with {:ok, json} <- encode(value),
         {:ok, _} <-
           eval(
             ctx,
             "globalThis[#{json_string(to_string(name))}] = JSON.parse(#{json_string(json)}); null"
           ) do
      :ok
    end
  end

  def get(%Context{} = ctx, name) do
    key = json_string(to_string(name))

    expression = """
    (function() {
      if (!Object.prototype.hasOwnProperty.call(globalThis, #{key})) return {__exjs: "not_found"};
      return {__exjs: "ok", value: globalThis[#{key}]};
    })()
    """

    with {:ok, result} <- eval(ctx, expression) do
      unwrap_call(result)
    end
  end

  def delete(%Context{} = ctx, name) do
    case eval(ctx, "delete globalThis[#{json_string(to_string(name))}]") do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :delete_failed}
      other -> other
    end
  end

  def has?(%Context{} = ctx, name) do
    eval(ctx, "Object.prototype.hasOwnProperty.call(globalThis, #{json_string(to_string(name))})")
  end

  def keys(%Context{} = ctx) do
    eval(ctx, "Object.keys(globalThis)")
  end

  def call(%Context{} = ctx, name, arguments) do
    with {:ok, args_json} <- encode(arguments) do
      expression = """
      (function() {
        var f = globalThis[#{json_string(to_string(name))}];
        if (f === undefined) return {__exjs: "not_found"};
        if (typeof f !== "function") return {__exjs: "not_callable"};
        var r = f.apply(globalThis, JSON.parse(#{json_string(args_json)}));
        return {__exjs: "ok", value: r};
      })()
      """

      with {:ok, result} <- eval(ctx, expression) do
        unwrap_call(result)
      end
    end
  end

  def call_path(%Context{} = ctx, path, arguments) do
    with {:ok, path_json} <- encode(Enum.map(path, &to_string/1)),
         {:ok, args_json} <- encode(arguments) do
      expression = """
      (function() {
        var p = #{path_json};
        var t = globalThis;
        for (var i = 0; i < p.length - 1; i++) {
          if (t === null || t === undefined) return {__exjs: "not_found"};
          t = t[p[i]];
        }
        if (t === null || t === undefined) return {__exjs: "not_found"};
        var f = t[p[p.length - 1]];
        if (f === undefined) return {__exjs: "not_found"};
        if (typeof f !== "function") return {__exjs: "not_callable"};
        var r = f.apply(t, JSON.parse(#{json_string(args_json)}));
        return {__exjs: "ok", value: r};
      })()
      """

      with {:ok, result} <- eval(ctx, expression) do
        unwrap_call(result)
      end
    end
  end

  def collect(%Context{} = ctx) do
    request(ctx, {:collect, ctx.timeout}, ctx.timeout)
  end

  def info(%Context{} = ctx) do
    request(ctx, :info, ctx.timeout)
  end

  def close(%Context{} = ctx) do
    GenServer.stop(ctx.pid, :normal, ctx.timeout)
    :ok
  catch
    :exit, _ -> {:error, :context_closed}
  end

  ## GenServer

  @impl true
  def init(%{owner: owner}) do
    runner = Application.app_dir(:ex_js, "priv/ex_js_runner")

    port =
      Port.open({:spawn_executable, String.to_charlist(runner)}, [
        :binary,
        {:packet, 4},
        :exit_status,
        :use_stdio
      ])

    {:ok, %{port: port, owner: owner, evaluations: 0, alive: true}}
  end

  @impl true
  def handle_call({:eval, source, timeout}, {caller, _tag}, state) do
    cond do
      caller != state.owner ->
        {:reply, {:error, :not_owner}, state}

      not state.alive ->
        {:reply, {:error, :context_closed}, state}

      true ->
        try do
          Port.command(state.port, <<?E>> <> source)
        rescue
          _ -> {:reply, {:error, :context_closed}, %{state | alive: false}}
        else
          true ->
            case await_response(state.port, timeout) do
              {:ok, value} ->
                {:reply, {:ok, value}, %{state | evaluations: state.evaluations + 1}}

              {:error, :timeout} ->
                kill(state.port)
                {:stop, :normal, {:error, :timeout}, %{state | alive: false}}

              {:error, reason} ->
                {:reply, {:error, reason}, %{state | evaluations: state.evaluations + 1}}
            end

          false ->
            {:reply, {:error, :context_closed}, %{state | alive: false}}
        end
    end
  end

  def handle_call(:info, {caller, _tag}, state) do
    if caller == state.owner do
      {:reply, {:ok, %{evaluations: state.evaluations}}, state}
    else
      {:reply, {:error, :not_owner}, state}
    end
  end

  def handle_call({:collect, timeout}, {caller, _tag}, state) do
    cond do
      caller != state.owner ->
        {:reply, {:error, :not_owner}, state}

      not state.alive ->
        {:reply, {:error, :context_closed}, state}

      true ->
        case Port.command(state.port, <<?C>>) do
          true ->
            case await_response(state.port, timeout) do
              {:ok, _} ->
                {:reply, :ok, state}

              {:error, :timeout} ->
                kill(state.port)
                {:stop, :normal, {:error, :timeout}, %{state | alive: false}}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          false ->
            {:reply, {:error, :context_closed}, %{state | alive: false}}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    kill(state.port)
  end

  ## Protocol

  defp await_response(port, timeout) do
    receive do
      {^port, {:data, data}} ->
        parse_response(data)

      {^port, {:exit_status, _status}} ->
        {:error, :runner_exited}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp parse_response(<<"OK ", json::binary>>) do
    {:ok, decode(json)}
  rescue
    _ -> {:error, :invalid_response}
  end

  defp parse_response(<<"ERR ", rest::binary>>) do
    case String.split(rest, " ", parts: 2) do
      [name, message] -> {:error, %{name: name, message: message}}
      [_name] -> {:error, %{name: rest, message: ""}}
    end
  end

  defp parse_response(_other), do: {:error, :invalid_response}

  defp decode(json) do
    json |> :json.decode() |> normalize_decoded()
  end

  defp normalize_decoded(:null), do: nil
  defp normalize_decoded(list) when is_list(list), do: Enum.map(list, &normalize_decoded/1)

  defp normalize_decoded(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, normalize_decoded(value)} end)
  end

  defp normalize_decoded(other), do: other

  defp unwrap_call(%{"__exjs" => "ok"} = result), do: {:ok, Map.get(result, "value")}
  defp unwrap_call(%{"__exjs" => "not_found"}), do: {:error, :not_found}
  defp unwrap_call(%{"__exjs" => "not_callable"}), do: {:error, :not_callable}
  defp unwrap_call(_other), do: {:error, :invalid_response}

  ## Helpers

  defp request(ctx, message, timeout) do
    GenServer.call(ctx.pid, message, timeout + 5_000)
  catch
    :exit, {:timeout, _} ->
      kill_by_pid(ctx.pid)
      {:error, :timeout}

    :exit, _reason ->
      {:error, :context_closed}
  end

  defp kill_by_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :kill, 5_000)
  catch
    :exit, _ -> :ok
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) ->
        System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end

  defp json_string(binary) when is_binary(binary) do
    binary |> normalize_encode() |> :json.encode() |> IO.iodata_to_binary()
  end

  defp encode(value) do
    {:ok, value |> normalize_encode() |> :json.encode() |> IO.iodata_to_binary()}
  rescue
    _ -> {:error, :unsupported_value}
  end

  defp normalize_encode(nil), do: :null
  defp normalize_encode(true), do: true
  defp normalize_encode(false), do: false
  defp normalize_encode(value) when is_number(value) or is_binary(value), do: value
  defp normalize_encode(list) when is_list(list), do: Enum.map(list, &normalize_encode/1)

  defp normalize_encode(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      unless is_binary(key) do
        raise ArgumentError, "expected map keys to be atoms or strings"
      end

      {key, normalize_encode(value)}
    end)
  end

  defp normalize_encode(other) do
    raise ArgumentError, "cannot encode #{inspect(other)}"
  end

  defp bindings_prelude(bindings) do
    Enum.reduce_while(bindings, {:ok, ""}, fn {key, value}, {:ok, acc} ->
      case encode(value) do
        {:ok, json} ->
          line =
            "globalThis[#{json_string(to_string(key))}] = JSON.parse(#{json_string(json)});\n"

          {:cont, {:ok, acc <> line}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end
end
