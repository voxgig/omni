# omni - Scala

Scala 3 port of the canonical TypeScript implementation.

```sh
make test
```

## Use

```scala
val provider = Provider(subject = Some(name => subjects.get(name)))

val R = Runner.makeRunner(specpath, provider).runner("fib")

R.runset(R.set("basic"), Some(FIB))
R.runsetflags(R.set("nulls"), Flags.nonull(), Some(FIBINFO))
```

A failing check throws `OmniError`, which ScalaTest and munit report as a
failure. `test/Main.scala` is a dependency-free harness so that `make test`
needs no sbt.

A subject is `List[Json] => Json`.

## Layout

| File | Contents |
|---|---|
| `src/Runner.scala` | the runner |
| `src/Util.scala` | clone, deep equality, path lookup, walk, stringify |
| `src/Json.scala` | the JSON value model and parser |
| `test/Fib.scala` | the system under test |
| `test/Main.scala` | the shared conformance suite |

## Notes

- Standard library only. `Json` is an `enum` with its own parser; maps are
  `ListMap`, so key order is insertion order.
- `java.util.regex` provides `/pattern/` matching.
- Values are immutable throughout: the runner rebuilds an entry rather than
  mutating it, which is why `runsetflags` threads the entry through.
- The Scala 3 launcher is a project runner, so `make test` uses
  `scala run --classpath build --main-class ...`.
