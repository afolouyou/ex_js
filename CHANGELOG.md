# Changelog

## 0.3.0

### Added

- `:isolated` backend via Port with real timeouts and infinite-loop killing.
- `ExJS.eval_file/2,3`.
- `ExJS.delete/2`, `ExJS.has?/2`, `ExJS.keys/1`.
- `ExJS.call_path/3` to call functions by path (`["Math", "max"]`).
- `ExJS.collect/1` for explicit GC collection.
- ES modules with an in-memory registry:
  - `ExJS.put_module/3`;
  - `ExJS.eval_module/3`, returning exports;
  - named imports, namespace imports and `export default`.
- Standalone runner (`priv/ex_js_runner`) for isolated mode.
- Isolated-mode tests (timeout, lifecycle, owner).

## 0.2.0

### Added

- `ExJS.set/3` to set global variables.
- `ExJS.get/2` to read global variables, distinguishing `:not_found` from
  `nil`.
- `ExJS.call/3` to call global functions with `globalThis` as `this`.
- Configurable limits in `new/1`: `max_depth`, `max_collection_size`,
  `max_string_bytes` and `max_source_bytes`.
- `ExJS.info/1` with an evaluation counter.
- Kiesel vendored in `native/ex_js_nif/vendor/kiesel`.
- `KIESEL_PATH` is now only a development override.
- `eval`, `set`, `get` and `call` run as dirty CPU NIFs.
- Kiesel's GC (BDWGC) enabled, with BEAM thread registration.
- Global engine mutex to protect Kiesel's process-global state.
- Stress tests (500 contexts, 50 concurrent processes, GC, Unicode, RegExp,
  large and deep objects).
- Benchmark in `bench/bench.exs`.
- Build option `-Dsanitize=true` for ASan/UBSan in development.
- `mix ex_js.vendor.update` task.
- CI workflow with build, tests (including stress) and a consumer smoke test.

### Fixed

- Independent contexts no longer share stdout/stderr buffers.

## 0.1.0

- Initial version: `new/0,1`, `eval/2,3` and `close/1`.
