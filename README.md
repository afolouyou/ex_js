# ExJS

[![CI](https://github.com/afolouyou/ex_js/actions/workflows/ci.yml/badge.svg)](https://github.com/afolouyou/ex_js/actions/workflows/ci.yml)

JavaScript execution for Elixir, powered by [Kiesel](https://kiesel.dev), a
JavaScript engine written in Zig, embedded as a NIF.

```elixir
{:ok, ctx} = ExJS.new()

{:ok, 3} = ExJS.eval(ctx, "1 + 2")
{:ok, 7} = ExJS.eval(ctx, "x + y", %{x: 3, y: 4})

{:ok, %{"name" => "Folou", "tags" => ["zig", "elixir"]}} =
  ExJS.eval(ctx, "({ name: \"Folou\", tags: [\"zig\", \"elixir\"] })")

:ok = ExJS.set(ctx, "config", %{enabled: true})
{:ok, %{"enabled" => true}} = ExJS.get(ctx, "config")

{:ok, _} = ExJS.eval(ctx, "function sum(a, b) { return a + b }")
{:ok, 5} = ExJS.call(ctx, "sum", [2, 3])

:ok = ExJS.close(ctx)
```

## API

| Function | Description |
| --- | --- |
| `new/0,1` | Creates an isolated JavaScript context |
| `eval/2` | Evaluates a script and returns the result |
| `eval/3` | Evaluates a script with injected global variables |
| `eval_file/2,3` | Evaluates a `.js` file |
| `set/3` | Sets a global variable |
| `get/2` | Reads a global variable |
| `delete/2` | Deletes a global variable |
| `has?/2` | Checks whether a variable exists |
| `keys/1` | Lists enumerable keys of `globalThis` |
| `call/3` | Calls a global function |
| `call_path/3` | Calls a function by path (`["Math", "max"]`) |
| `put_module/3` | Registers an in-memory ES module |
| `eval_module/3` | Evaluates an ES module and returns its exports |
| `collect/1` | Runs an explicit GC collection |
| `info/1` | Returns context information |
| `close/1` | Explicitly closes the context |

## Execution modes

### `:embedded` (default)

Kiesel runs as a NIF inside the BEAM process. Lowest latency, suitable for
trusted code.

```elixir
{:ok, ctx} = ExJS.new()
```

### `:isolated`

A separate OS process managed through a Port, with real timeouts and the
ability to kill infinite loops. Suitable for untrusted code.

```elixir
{:ok, ctx} = ExJS.new(mode: :isolated, timeout: 1_000)

{:error, :timeout} = ExJS.eval(ctx, "while (true) {}")
{:error, :context_closed} = ExJS.eval(ctx, "1")
```

In isolated mode values travel as JSON: `NaN`/`Infinity` become `nil`, and
functions cannot be returned. ES modules are not supported in this mode.

## ES modules

Imports are resolved only against modules registered in memory — there is no
filesystem access.

```elixir
{:ok, ctx} = ExJS.new()

:ok = ExJS.put_module(ctx, "math", "export const sum = (a, b) => a + b")

{:ok, %{"default" => 3}} =
  ExJS.eval_module(ctx, ~s|import { sum } from "math"; export default sum(1, 2)|)
```

### Value conversion

JSON-compatible values are converted automatically:

| JavaScript | Elixir |
| --- | --- |
| `null` / `undefined` | `nil` |
| `true` / `false` | `true` / `false` |
| safe integer number | `integer` |
| fractional number | `float` |
| string | `binary` |
| array | `list` |
| plain object | `map` with string keys |

Special values: `NaN`, `Infinity` and `-Infinity` become `:nan`, `:infinity`
and `:negative_infinity`. Functions, symbols and `BigInt` return
`{:error, :unsupported_value}`.

Bindings (`eval/3`), `set/3` and `call/3` arguments accept maps with atom or
string keys and the same JSON-compatible types, including nested lists and
maps.

### Limits

`new/1` accepts limits to bound memory usage and nesting depth:

```elixir
ExJS.new(
  max_depth: 64,
  max_collection_size: 10_000,
  max_string_bytes: 1_048_576,
  max_source_bytes: 1_048_576
)
```

When a limit is exceeded, the operation returns a specific atom:
`:max_depth_exceeded`, `:collection_too_large`, `:string_too_large` or
`:source_too_large`.

### Errors

JavaScript exceptions return:

```elixir
{:error, %{name: "TypeError", message: "boom"}}
```

Syntax errors return `name: "SyntaxError"` with the message and position.
Context usage errors return atoms such as `:context_closed`,
`:context_already_closed`, `:not_owner`, `:not_found`, `:not_callable`,
`:invalid_bindings` and `:unsupported_binding_value`.

## Compatibility

| Item | Version |
| --- | --- |
| Elixir | 1.19+ |
| OTP | 28+ |
| Zig | 0.17.x |
| Platform | Linux x86_64 |

Other platforms are not validated yet.

## Build

Requirements:

- Elixir/OTP 28+
- Zig 0.17.x

The Kiesel source is vendored in `native/ex_js_nif/vendor/kiesel`, so no path
configuration is needed:

```bash
mix deps.get
mix compile
mix test
```

To develop against a local Kiesel checkout:

```bash
export KIESEL_PATH=/path/to/kiesel
mix compile
```

To update the vendored Kiesel:

```bash
mix ex_js.vendor.update --ref <tag-or-commit>
```

The NIF is built with `enable-intl=false` and `enable-temporal=false` so no
Rust/cargo is required. `libregexp` is embedded from the QuickJS sources
fetched as a Zig dependency, and Kiesel's garbage collector (BDWGC) is
enabled.

The final binaries are installed in `priv/libex_js_nif.so` and
`priv/ex_js_runner`.

### Stress tests and benchmark

```bash
# Regular tests (stress excluded)
mix test

# Includes stress tests (500 contexts, concurrency, GC, Unicode/RegExp)
mix test --include stress

# Benchmark
mix run bench/bench.exs
```

For an ASan/UBSan build (development only):

```bash
cd native/ex_js_nif
zig build -Doptimize=Debug -Dsanitize=true
```

### Memory and concurrency

- Kiesel's `Agent`/runtime lives in BDWGC memory, not BEAM memory, so
  Kiesel's GC can trace JavaScript objects.
- Every BEAM thread that enters the NIF registers itself with BDWGC on first
  use.
- `eval`, `set`, `get`, `call`, `delete`, `keys` and `call_path` run as dirty
  CPU NIFs: long scripts do not block normal BEAM schedulers, but can still
  occupy dirty schedulers.
- Kiesel keeps some process-global state (for example the platform used to
  format `Date`). Because of that, engine operations are serialized by a
  global mutex, even across independent contexts. Per-context state isolation
  still exists; JavaScript execution across contexts is sequential.
- In `:isolated` mode, each context is a separate OS process; timeouts kill
  the process.
- Each context belongs to the process that created it.

## Limitations (v0.3)

- **`:embedded` requires trusted code.** There is no timeout or cooperative
  interruption; an infinite loop occupies a dirty scheduler indefinitely.
  Use `mode: :isolated` for untrusted code.
- **No ES modules in isolated mode.**
- **No filesystem module resolution.** Imports use only the in-memory
  registry (`put_module/3`).
- `call/3` and `put_module/3` accept simple names only; use `call_path/3` for
  paths.
- A context belongs to the process that created it; other processes receive
  `{:error, :not_owner}`.
- Initial target platform: Linux x86_64.

## License

MIT. The vendored Kiesel is also MIT; see
`native/ex_js_nif/vendor/kiesel/LICENSE`.
