# omni - Haskell

Haskell port of the canonical TypeScript implementation.

```sh
make test
```

## Use

```haskell
pack <- makeRunner specpath (fibprovider 0) "fib"

runset pack (packSet pack "basic") (Just fibsub)
runsetflags pack (packSet pack "nulls") nonullFlags (Just fibinfosub)
```

A failing check throws `OmniError`, which hspec and tasty report as a
failure. `test/Run.hs` is a dependency-free harness so that `make test`
needs no cabal or stack project.

A subject is `[Json] -> IO Json`, reporting failure by throwing.

## Layout

| File | Contents |
|---|---|
| `src/Omni.hs` | everything: value model, parser, utilities, regex engine, runner |
| `test/Fib.hs` | the system under test |
| `test/Run.hs` | the shared conformance suite |

## Notes

- **base only** - no aeson, no regex-tdfa: the port carries its own JSON
  parser and a backtracking regex engine.
- A subject's message is `displayException`, so a custom exception should
  define `show` to return the message (as `FibError` does).
- `Absent` is a constructor of the `Json` type, so "absent" and "null" are
  distinct by construction.
