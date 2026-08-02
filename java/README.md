# omni - Java

Java port of the canonical TypeScript implementation. JDK only.

```sh
make test
```

## Use

```java
Runner.Provider provider = new Runner.Provider();
provider.subject = subjects::get;

RunPack R = Runner.makeRunner(specpath, provider).runner("fib");

R.runset(R.set("basic"), FIB);
R.runsetflags(R.set("nulls"), Runner.flags("null", false), FIBINFO);
```

A failing check throws `Runner.OmniError`, a `RuntimeException`, which
JUnit reports as a failure. `test/FibTest.java` is a dependency-free
harness so that `make test` needs no Maven or Gradle.

A subject is `Object call(Object... args) throws Exception`.

## Layout

| File | Contents |
|---|---|
| `src/com/voxgig/omni/Runner.java` | the runner |
| `src/com/voxgig/omni/Util.java` | clone, deep equality, path lookup, walk, stringify |
| `src/com/voxgig/omni/Json.java` | the JSON parser |
| `test/Fib.java` | the system under test |
| `test/FibTest.java` | the shared conformance suite |

## Notes

- No Gson, no Jackson, no JUnit. `Json.java` parses into
  `LinkedHashMap` / `ArrayList` / `String` / `Double` / `Boolean` / `null`.
- Numbers compare by `doubleValue()`, so `Long`, `Integer` and `Double`
  results all work; `Util.numstr` prints `5.0` as `5` so that messages
  match the other ports.
- Absence is `Json.ABSENT`; `getpath` returns it for a missing step.
