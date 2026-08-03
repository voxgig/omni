# omni - Kotlin

Kotlin port of the canonical TypeScript implementation.

```sh
make test
```

## Use

```kotlin
val provider = Provider(subject = { name -> subjects[name] })

val R = makeRunner(specpath, provider).runner("fib")

R.runset(R.set("basic"), FIB)
R.runsetflags(R.set("nulls"), Flags.nonull(), FIBINFO)
```

A failing check throws `OmniError`, which JUnit and kotlin.test report as a
failure. `test/Main.kt` is a dependency-free harness so that `make test`
needs no Gradle or Maven.

A subject is `(List<Json>) -> Json`.

## Layout

| File | Contents |
|---|---|
| `src/Runner.kt` | the runner |
| `src/Util.kt` | clone, deep equality, path lookup, walk, stringify |
| `src/Json.kt` | the JSON value model and parser |
| `test/Fib.kt` | the system under test |
| `test/Main.kt` | the shared conformance suite |

## Notes

- No kotlinx.serialization, no Gson: `Json.kt` is a sealed class plus a
  small parser, which keeps booleans and numbers distinct by construction.
- `java.util.regex` provides `/pattern/` matching.
- `Json.Absent` is a variant of the value model, so "absent" and "null" are
  distinct.
