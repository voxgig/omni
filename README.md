# omni

**Shared multi language testing.** One test spec, written once as plain
JSON, run by the same runner in twenty-four languages.

Write the behaviour of a library once. Verify it everywhere.

```json
{ "primary": { "fib": { "basic": { "set": [
  { "in": 0,  "out": 0  },
  { "in": 10, "out": 55 },
  { "in": -1, "err": "negative" }
] } } } }
```

```ts
const R = await (await makeRunner('spec/fib.json'))('fib')
await R.runset(R.spec.basic, fib) // TypeScript
```

```python
R = makeRunner('spec/fib.json')('fib')
R['runset'](R['spec']['basic'], fib)   # Python
```

```go
R, _ := runner("fib", nil)
err := R.RunSet(R.Set("basic"), FIB) // Go
```

Same file. Same entries. Same pass/fail. In every port.


## Why

A library that ships in many languages has one hard problem: keeping the
ports honest. Per-language test suites drift, because each one is written
by hand against its own idea of the behaviour.

omni removes the hand-written part. The behaviour lives in a JSON spec;
each language ships a *runner* that executes that spec against the local
implementation. A port that disagrees with the spec fails, in its own test
framework, with a message that names the entry.

This is the mechanism [`voxgig/struct`](https://github.com/voxgig/struct)
uses to keep 20+ ports in agreement. omni extracts it into a standalone
library, so any project can use it - and so struct's own per-port runners
can be replaced by one shared implementation (see
[Replacing struct's runners](#replacing-structs-runners)).


## Ports

| Language | Directory | Test | Notes |
|---|---|---|---|
| TypeScript | [`typescript/`](typescript/) | `npm test` | **canonical** - every port is a translation of this |
| JavaScript | [`javascript/`](javascript/) | `npm test` | CommonJS; also hosts the struct compat shim |
| Python | [`python/`](python/) | `python3 -m unittest discover -s tests` | |
| Ruby | [`ruby/`](ruby/) | `ruby test/test_fib.rb` | minitest |
| PHP | [`php/`](php/) | `php test/run.php` | |
| Perl | [`perl/`](perl/) | `prove -Ilib -It t/` | core modules only |
| Lua | [`lua/`](lua/) | `lua5.4 test/run.lua` | in-tree JSON parser + regex engine |
| Go | [`go/`](go/) | `go test ./...` | errors returned, not thrown |
| Rust | [`rust/`](rust/) | `cargo test` | in-tree JSON parser + regex engine |
| Java | [`java/`](java/) | `make test` | JDK only, in-tree JSON parser |
| C# | [`csharp/`](csharp/) | `make test` | BCL only |
| Kotlin | [`kotlin/`](kotlin/) | `make test` | in-tree JSON parser |
| Scala | [`scala/`](scala/) | `make test` | Scala 3; immutable values throughout |
| Clojure | [`clojure/`](clojure/) | `make test` | in-tree JSON parser; native maps/vectors |
| C | [`c/`](c/) | `make test` | C99 + POSIX regex, pooled allocation |
| C++ | [`cpp/`](cpp/) | `make test` | header-only, C++17 |
| Zig | [`zig/`](zig/) | `make test` | failures returned; in-tree regex engine |
| Swift | [`swift/`](swift/) | `make test` | in-tree JSON parser; NSRegularExpression |
| Dart | [`dart/`](dart/) | `dart run test/run.dart` | |
| Elixir | [`elixir/`](elixir/) | `make test` | in-tree JSON parser |
| OCaml | [`ocaml/`](ocaml/) | `make test` | in-tree JSON parser + regex engine |
| Haskell | [`haskell/`](haskell/) | `make test` | base only; in-tree JSON parser + regex engine |
| Lean 4 | [`lean/`](lean/) | `make test` | pure: failures returned as `Except String` |
| boru | [`boru/`](boru/) | `make test` | concatenative; subjects are lambdas capturing values |

Run one port with `make test-<lang>`, all of them with `make test`.

**Zero runtime dependencies, everywhere.** No port depends on a
third-party package - not for JSON, not for regex, not for testing. A test
runner that pulls in a dependency tree is a test runner that cannot test
the dependency tree.


## The Fibonacci suite

Every port ships the same tiny Fibonacci library and tests it with the same
[`spec/fib.json`](spec/fib.json). It is the cross-language proof that the
runners agree: nine groups covering every runner feature.

The corpus is written in [aontu](https://github.com/voxgig/aontu) —
[`spec/fib.aontu`](spec/fib.aontu) is the source of truth, and `fib.json` is
compiled from it by `make spec` and committed, so that no port needs a Node
toolchain to run its tests. Edit the aontu, never the JSON.

| Group | Exercises |
|---|---|
| `basic` | `in`/`out` with scalar results |
| `seq` | list results, deep equality |
| `range` | the `args` form (multiple arguments) |
| `info` | map results, and `null` as `__NULL__` |
| `nulls` | the same map results with `{null: false}` |
| `error` | `err: true`, substring and `/regex/` error matching |
| `match` | partial matching against the result |
| `matchinfo` | `__EXISTS__`, `__UNDEF__`, `__NULL__`, regex leaves |
| `client` | `DEF.client`: per-entry subject substitution |

Each port additionally asserts that the runner *fails* when it should - a
green suite that cannot go red proves nothing.

```
$ make test
======== typescript ========
# pass 14
...
======== lean ========
14 passed, 0 failed

all ports passed
```


## Spec format, in one screen

```jsonc
{
  "primary": {
    "fib": {                        // a named section: runner('fib')
      "DEF": { "client": { } },     // optional named clients
      "basic": {                    // a group: R.spec.basic
        "set": [                    // the entries
          { "in": 10, "out": 55 }
        ]
      }
    }
  }
}
```

| Entry field | Meaning |
|---|---|
| `in` | single argument, deep-cloned before the call |
| `args` | explicit argument list |
| `ctx` | single context argument (passed through the provider) |
| `out` | expected result (deep equality) |
| `err` | `true` for any error, or a string matched as substring or `/regex/` |
| `match` | partial structure check against `{in, args, out, ctx, err}` |
| `client` | name of a `DEF.client` entry to resolve the subject from |
| `id`, `doc` | metadata: `id` appears in failure messages |

Three sentinels bridge what JSON cannot say:

| Sentinel | Meaning |
|---|---|
| `"__NULL__"` | a real JSON `null` (results are normalised to this) |
| `"__UNDEF__"` | absent - no value at all |
| `"__EXISTS__"` | present, whatever the value |

Full details, including flags and the provider protocol, are in
[`DOCS.md`](DOCS.md).


## Failure messages

Identical in every port, so a difference between two languages is a real
difference and not a formatting artefact:

```
omni: fib[1] (x#2): result mismatch
  expected: 42
  actual:   1
  entry:    {"id":"x#2","in":2,"out":42}
```


## Replacing struct's runners

Each `voxgig/struct` port carries its own copy of a runner
(`<lang>/test/runner.*`) - the same algorithm, re-implemented 20+ times.
omni is that algorithm, once, in every language struct ships in.

The JavaScript port ships a compatibility shim with struct's exact runner
API, so a struct port switches over by changing one import:

```diff
-const { makeRunner, nullModifier, NULLMARK } = require('./runner')
+const { makeRunner, nullModifier, NULLMARK } = require('@voxgig/omni-js/compat/struct')
```

Nothing else changes - not the corpus, not the SDK, not the test file.

```
$ make struct-compat STRUCT=../struct
omni: running struct's suite with omni's runner
# tests 95
# pass 95
# fail 0
```

All 95 of struct's JavaScript tests - the full `build/test/test.json`
corpus across getpath, merge, walk, inject, transform, validate, select,
minor, sentinels and regex - pass unchanged on omni's runner. See
[`DOCS.md`](DOCS.md#replacing-structs-in-situ-runners) for the porting
guide and the provider adapter.


## Repository map

```
.
├── spec/
│   ├── fib.aontu      # the Fibonacci corpus - source of truth
│   └── fib.json       # compiled from fib.aontu; what the ports read
├── typescript/        # the canonical implementation
├── <lang>/            # one directory per port: src, test, Makefile, README
├── tools/
│   ├── build-spec.js      # compiles spec/*.aontu -> spec/*.json
│   ├── check_parity.py    # every port defines the canonical API
│   └── struct_compat.sh   # run struct's own suite on omni
├── Makefile           # test / build / parity / spec / struct-compat
├── DOCS.md            # the comprehensive guide
└── AGENTS.md          # notes for agents working in this repo
```


## Licence

MIT. See [`LICENSE`](LICENSE).
