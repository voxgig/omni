# omni - Clojure

Clojure port of the canonical TypeScript implementation.

```sh
clojure -M -m voxgig.omni.test.main
```

## Use

```clojure
(def provider {:subject (fn [name] (get subjects name))})

(def R ((runner/make-runner specpath provider) "fib"))

((:runset R) ((:set R) "basic") FIB)
((:runsetflags R) ((:set R) "nulls") {:null false} FIBINFO)
```

A failing check throws an `ExceptionInfo` carrying `:omni true`, which
clojure.test reports as an error. Use `runner/omni-error?` to tell a test
failure from anything else.

A subject is `(fn [args] ...)` over a vector of JSON values.

## Layout

| File | Contents |
|---|---|
| `src/voxgig/omni/runner.clj` | the runner |
| `src/voxgig/omni/util.clj` | clone, deep equality, path lookup, walk, stringify |
| `src/voxgig/omni/json.clj` | the JSON parser |
| `test/voxgig/omni/test/fib.clj` | the system under test |
| `test/voxgig/omni/test/main.clj` | the shared conformance suite |

## Notes

- No `clojure.data.json`, no cheshire: `json.clj` parses into native maps
  (string keys), vectors, doubles, booleans and nil.
- `(= 5 5.0)` is false in Clojure, so `deepequal` compares numbers with
  `==`.
- Absence is the `::u/absent` keyword; `nil` is a real JSON null.
