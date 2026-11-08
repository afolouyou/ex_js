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
| `eval_file/2,3` | Avalia um arquivo `.js` |
| `set/3` | Define uma variável global |
| `get/2` | Lê uma variável global |
| `delete/2` | Remove uma variável global |
| `has?/2` | Verifica se uma variável existe |
| `keys/1` | Lista chaves enumeráveis de `globalThis` |
| `call/3` | Chama uma função global |
| `call_path/3` | Chama uma função por caminho (`["Math", "max"]`) |
| `put_module/3` | Registra um módulo ES em memória |
| `eval_module/3` | Avalia um módulo ES e retorna exports |
| `collect/1` | Executa coleta explícita do GC |
| `info/1` | Retorna informações do contexto |
| `close/1` | Fecha o contexto explicitamente |

## Modos de execução

### `:embedded` (padrão)

NIF com Kiesel dentro do processo BEAM. Menor latência, indicado para código
confiável.

```elixir
{:ok, ctx} = ExJS.new()
```

### `:isolated`

Processo separado via Port, com timeout real e kill de loops infinitos.
Indicado para código não confiável.

```elixir
{:ok, ctx} = ExJS.new(mode: :isolated, timeout: 1_000)

{:error, :timeout} = ExJS.eval(ctx, "while (true) {}")
{:error, :context_closed} = ExJS.eval(ctx, "1")
```

No modo isolado, valores são transportados como JSON: `NaN`/`Infinity` viram
`nil` e funções não podem ser retornadas. Módulos ES não são suportados nesse
modo.

## Módulos ES

Imports são resolvidos apenas contra módulos registrados em memória — sem
acesso ao filesystem.

```elixir
{:ok, ctx} = ExJS.new()

:ok = ExJS.put_module(ctx, "math", "export const sum = (a, b) => a + b")

{:ok, %{"default" => 3}} =
  ExJS.eval_module(ctx, ~s|import { sum } from "math"; export default sum(1, 2)|)
```

## Limites

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

## Limitações (v0.3)

- **`:embedded` exige código confiável.** Não há timeout nem interrupção
  cooperativa; um loop infinito ocupa um dirty scheduler indefinidamente.
  Use `mode: :isolated` para código não confiável.
- **Sem módulos ES no modo isolado.**
- **Sem resolução de módulos no filesystem.** Imports usam apenas o registry
  em memória (`put_module/3`).
- `call/3` e `put_module/3` aceitam apenas nomes simples; use `call_path/3`
  para caminhos.
- Um contexto pertence ao processo que o criou; outros processos recebem
  `{:error, :not_owner}`.
- Plataforma alvo inicial: Linux x86_64.

## Licença

MIT. O Kiesel vendorizado também é MIT; veja
`native/ex_js_nif/vendor/kiesel/LICENSE`.
