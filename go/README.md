# omni - Go

Go port of the canonical TypeScript implementation.

```sh
go test ./...
```

## Use

```go
provider := &omni.Provider{
    Subject: func(name string) omni.Subject { return subjects[name] },
}

runner, err := omni.MakeRunner("spec/fib.json", provider)
R, err := runner("fib", nil)

if err := R.RunSet(R.Set("basic"), FIB); nil != err {
    t.Fatal(err)
}
if err := R.RunSetFlags(R.Set("nulls"), omni.Flags{"null": false}, FIBINFO); nil != err {
    t.Fatal(err)
}
```

Go has no exceptions, so a failing check is **returned**, as an
`*omni.OmniError`. Check `omni.IsOmniError(err)` to tell a test failure
from a spec error.

A subject is `func(args ...any) (any, error)`. A panic inside a subject is
recovered and treated as an error, so a spec can pin panicking behaviour
with `err`.

## Layout

| File | Contents |
|---|---|
| `omni.go` | the runner |
| `util.go` | clone, deep equality, path lookup, walk, stringify |
| `fib/fib.go` | the system under test |
| `fib_test.go` | the shared conformance suite |

## Notes

- Standard library only (`encoding/json`, `regexp`).
- Results are normalised through `FixJson`, which converts any Go container
  - including `[]int` or `map[string]int` - into the JSON model by
  reflection, so subjects can return natural Go types.
- Numbers compare by value across every numeric type: `int(5)`,
  `int64(5)` and `float64(5)` are equal.
- `encoding/json` does not preserve map key order; order is never
  significant for equality, and `JsonStr` sorts keys for messages.
