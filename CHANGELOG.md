# Changelog

## 0.2.0

### Adicionado

- `ExJS.set/3` para definir variáveis globais.
- `ExJS.get/2` para ler variáveis globais, distinguindo `:not_found` de `nil`.
- `ExJS.call/3` para chamar funções globais com `globalThis` como `this`.
- Limites configuráveis em `new/1`: `max_depth`, `max_collection_size`,
  `max_string_bytes` e `max_source_bytes`.
- `ExJS.info/1` com contador de avaliações.
- Kiesel vendorizado em `native/ex_js_nif/vendor/kiesel`.
- `KIESEL_PATH` passa a ser apenas um override de desenvolvimento.
- `eval`, `set`, `get` e `call` rodam como dirty CPU NIFs.
- GC do Kiesel (BDWGC) habilitado, com registro das threads do BEAM.
- Mutex global do engine para proteger o estado process-global do Kiesel.
- Testes de stress (500 contextos, 50 processos concorrentes, GC, Unicode,
  RegExp, objetos grandes e profundos).
- Benchmark em `bench/bench.exs`.
- Opção de build `-Dsanitize=true` para ASan/UBSan em desenvolvimento.
- Task `mix ex_js.vendor.update`.
- Workflow de CI com build, testes (incluindo stress) e smoke test de
  consumidor.

### Corrigido

- Contextos independentes não compartilham mais buffers de stdout/stderr.

## 0.1.0

- Versão inicial: `new/0,1`, `eval/2,3` e `close/1`.
