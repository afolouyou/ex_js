# ExJS

Execução de JavaScript no Elixir via [Kiesel](https://kiesel.dev), um motor
JavaScript escrito em Zig, embutido como NIF.

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

| Função | Descrição |
| --- | --- |
| `new/0,1` | Cria um contexto JavaScript isolado |
| `eval/2` | Avalia um script e retorna o resultado |
| `eval/3` | Avalia um script injetando variáveis globais |
| `set/3` | Define uma variável global |
| `get/2` | Lê uma variável global |
| `call/3` | Chama uma função global |
| `info/1` | Retorna informações do contexto |
| `close/1` | Fecha o contexto explicitamente |

### Conversão de valores

Valores compatíveis com JSON são convertidos automaticamente:

| JavaScript | Elixir |
| --- | --- |
| `null` / `undefined` | `nil` |
| `true` / `false` | `true` / `false` |
| number inteiro seguro | `integer` |
| number fracionário | `float` |
| string | `binary` |
| array | `list` |
| objeto simples | `map` com chaves string |

Valores especiais: `NaN`, `Infinity` e `-Infinity` viram `:nan`, `:infinity`
e `:negative_infinity`. Funções, símbolos e `BigInt` retornam
`{:error, :unsupported_value}`.

Bindings (`eval/3`), `set/3` e argumentos de `call/3` aceitam mapas com chaves
atom ou string e os mesmos tipos JSON-compatíveis, incluindo listas e mapas
aninhados.

### Limites

`new/1` aceita limites para conter uso de memória e profundidade:

```elixir
ExJS.new(
  max_depth: 64,
  max_collection_size: 10_000,
  max_string_bytes: 1_048_576,
  max_source_bytes: 1_048_576
)
```

Ao exceder um limite, a operação retorna um átomo específico:
`:max_depth_exceeded`, `:collection_too_large`, `:string_too_large` ou
`:source_too_large`.

### Erros

Exceções JavaScript retornam:

```elixir
{:error, %{name: "TypeError", message: "boom"}}
```

Erros de sintaxe retornam `name: "SyntaxError"` com a mensagem e a posição.
Erros de uso do contexto retornam átomos como `:context_closed`,
`:context_already_closed`, `:not_owner`, `:not_found`, `:not_callable`,
`:invalid_bindings` e `:unsupported_binding_value`.

## Compatibilidade

| Item | Versão |
| --- | --- |
| Elixir | 1.19+ |
| OTP | 28+ |
| Zig | 0.17.x |
| Plataforma | Linux x86_64 |

Outras plataformas ainda não são validadas.

## Build

Requisitos:

- Elixir/OTP 28+
- Zig 0.17.x

O código-fonte do Kiesel já vem vendorizado em
`native/ex_js_nif/vendor/kiesel`, então não é necessário configurar caminhos:

```bash
mix deps.get
mix compile
mix test
```

Para desenvolver contra um checkout local do Kiesel:

```bash
export KIESEL_PATH=/caminho/para/kiesel
mix compile
```

Para atualizar o Kiesel vendorizado:

```bash
mix ex_js.vendor.update --ref <tag-ou-commit>
```

O NIF é compilado com `enable-intl=false` e `enable-temporal=false` para não
exigir Rust/cargo. `libregexp` é embutido a partir das fontes do QuickJS
baixadas como dependência Zig, e o garbage collector do Kiesel (BDWGC) é
habilitado.

O binário final é instalado em `priv/libex_js_nif.so`.

### Testes de stress e benchmark

```bash
# Testes normais (stress excluído)
mix test

# Inclui os testes de stress (500 contextos, concorrência, GC, Unicode/RegExp)
mix test --include stress

# Benchmark
mix run bench/bench.exs
```

Para um build com ASan/UBSan (desenvolvimento):

```bash
cd native/ex_js_nif
zig build -Doptimize=Debug -Dsanitize=true
```

### Memória e concorrência

- O `Agent`/runtime do Kiesel fica no heap do BDWGC, não no heap da BEAM, para
  que o GC do Kiesel consiga rastrear os objetos JavaScript.
- Cada thread do BEAM que entra no NIF é registrada no BDWGC na primeira
  chamada.
- `eval`, `set`, `get` e `call` rodam como dirty CPU NIFs: scripts longos não
  bloqueiam os schedulers normais do BEAM, mas ainda podem ocupar dirty
  schedulers.
- O Kiesel mantém parte de estado global (por exemplo, a plataforma usada na
  formatação de `Date`). Por isso as operações do engine são serializadas por
  um mutex global, mesmo com contexts independentes. O isolamento de estado
  por contexto continua existindo; a execução de JS entre contexts é
  sequencial.
- Cada contexto tem seu próprio estado e pertence ao processo que o criou.

## Limitações (v0.2)

- **Apenas scripts confiáveis.** Não há timeout nem interrupção cooperativa:
  um loop infinito ocupa um dirty scheduler indefinidamente. Para código não
  confiável, o caminho futuro é um backend isolado em subprocesso.
- **Sem módulos ES** (`import`/`export`).
- `call/3` aceita apenas nomes de funções globais, não paths como
  `"Math.max"`.
- Um contexto pertence ao processo que o criou; outros processos recebem
  `{:error, :not_owner}`.
- Plataforma alvo inicial: Linux x86_64.

## Licença

MIT. O Kiesel vendorizado também é MIT; veja
`native/ex_js_nif/vendor/kiesel/LICENSE`.
