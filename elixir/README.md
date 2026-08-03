# omni - Elixir

Elixir port of the canonical TypeScript implementation.

```sh
make test
```

## Use

```elixir
provider = %{subject: fn name -> subjects[name] end}

pack = Runner.make_runner(specpath, provider).("fib", nil)

pack.runset.(pack.set.("basic"), fib)
pack.runsetflags.(pack.set.("nulls"), %{null: false}, fibinfo)
```

A failing check raises `Voxgig.Omni.OmniError`, which ExUnit reports as a
failure. `test/run.exs` is a dependency-free harness so that `make test`
needs no mix project.

A subject is `fn args -> ... end` over a list of JSON values.

## Layout

| File | Contents |
|---|---|
| `lib/runner.ex` | the runner |
| `lib/util.ex` | clone, deep equality, path lookup, walk, stringify |
| `lib/json.ex` | the JSON parser |
| `lib/fib.ex` | the system under test |
| `test/run.exs` | the shared conformance suite |

## Notes

- No Jason, no Poison: `json.ex` parses into native maps (string keys),
  lists, floats, booleans and nil. Elixir gained a built-in JSON module
  only in 1.18; omni supports older releases too.
- `Regex` provides `/pattern/` matching.
- Absence is the `:"$omni_absent"` atom; `nil` is a real JSON null.
