# omni - Lean 4

Lean 4 port of the canonical TypeScript implementation.

```sh
lake build && ./.lake/build/bin/omnitest
```

## Use

```lean
let pack ← makeRunner path (fibprovider 0.0) "fib"

match pack.runset (pack.set "basic") (some FIB) with
| .ok () => IO.println "ok"
| .error message => IO.println message
```

Lean's checks are pure, so a failing check is **returned** as
`Except.error message` rather than thrown. A subject reports failure the
same way: `Subject := List Json → Except String Json`.

## Layout

| File | Contents |
|---|---|
| `Omni.lean` | everything: value helpers, utilities, regex engine, runner |
| `Fib.lean` | the system under test |
| `Main.lean` | the shared conformance suite |

## Notes

- `Lean.Data.Json` provides the value model and parser; the regex engine is
  in-tree, because Lean's standard library has none.
- Absence is `Option Json` with `none` meaning absent, as distinct from
  `some Json.null`, a JSON null.
- The backtracking matcher is written with `partial def`: it terminates on
  every input the spec can express, but not structurally, so Lean's
  termination checker is not asked to prove it.
- A `Provider` is recursive (a client hook yields another provider), so it
  is an `inductive` with hand-written accessors rather than a `structure`.
