# omni

**Shared multi language testing.** One test spec, written once as plain
JSON, run by the same runner in eleven languages.

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
| Go | [`go/`](go/) | `go test ./...` | errors returned, not thrown |
| Rust | [`rust/`](rust/) | `cargo test` | in-tree JSON parser + regex engine |
| Java | [`java/`](java/) | `make test` | JDK only, in-tree JSON parser |
| C | [`c/`](c/) | `make test` | C99 + POSIX regex, pooled allocation |
| C++ | [`cpp/`](cpp/) | `make test` | header-only, C++17 |

Run one port with `make test-<lang>`, all of them with `make test`.

**Zero runtime dependencies, everywhere.** No port depends on a
third-party package - not for JSON, not for regex, not for testing. A test
runner that pulls in a dependency tree is a test runner that cannot test
the dependency tree.


## The Fibonacci suite

Every port ships the same tiny Fibonacci library and tests it with the same
[`spec/fib.json`](spec/fib.json). It is the cross-language proof that the
runners agree: nine groups covering every runner feature.

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
$ make test-rust
======== rust ========
running 5 tests
test fib_conformance ... ok
test runner_detects_failures ... ok
...
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
omni is that algorithm, once.

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
├── spec/fib.json      # the shared Fibonacci corpus
├── typescript/        # the canonical implementation
├── <lang>/            # one directory per port: src, test, Makefile, README
├── tools/
│   ├── check_parity.py    # every port defines the canonical API
│   └── struct_compat.sh   # run struct's own suite on omni
├── Makefile           # test / build / parity / struct-compat
├── DOCS.md            # the comprehensive guide
└── AGENTS.md          # notes for agents working in this repo
```


## Licence

MIT. See [`LICENSE`](LICENSE).
