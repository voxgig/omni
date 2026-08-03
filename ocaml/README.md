# omni - OCaml

OCaml port of the canonical TypeScript implementation.

```sh
make test
```

## Use

```ocaml
let pack = (make_runner specpath provider) "fib" None in
pack.runset (pack.set "basic") (Some fibsub);
pack.runsetflags (pack.set "nulls") nonull_flags (Some fibinfosub)
```

A failing check raises `Omni_error`, which alcotest and ounit report as a
failure. `test/run.ml` is a dependency-free harness so that `make test`
needs no opam install.

A subject is `json list -> json`, reporting failure by raising.

## Layout

| File | Contents |
|---|---|
| `src/omni.ml` | everything: value model, parser, utilities, regex engine, runner |
| `test/fib.ml` | the system under test |
| `test/run.ml` | the shared conformance suite |

## Notes

- **No dependencies at all** - not even Str: the port carries its own JSON
  parser and a backtracking regex engine, so `/pattern/` expectations use
  the same dialect as every other port.
- The runner reads a subject's message with `Printexc.to_string`, so a
  custom exception should register a printer:
  `Printexc.register_printer (function Fib_error m -> Some m | _ -> None)`.
  That is the idiomatic OCaml way to give an exception a message.
- `Absent` is a constructor of the `json` type, so "absent" and "null" are
  distinct by construction.
