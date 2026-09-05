# omni - C#

C# port of the canonical TypeScript implementation.

```sh
make test
```

## Use

```csharp
var provider = new Provider { SubjectFor = name => subjects[name] };

RunPack R = Runner.MakeRunner(specpath, provider).Run("fib");

R.RunSet(R.Set("basic"), FIB);
R.RunSetFlags(R.Set("nulls"), Flags.NoNull(), FIBINFO);
```

A failing check throws `OmniError`, which xUnit, NUnit, and MSTest all
report as a failure. `test/Program.cs` is a dependency-free harness so that
`make test` needs no test package.

A subject is `delegate object Subject(params object[] args)`.

## Layout

| File | Contents |
|---|---|
| `src/Runner.cs` | the runner |
| `src/Util.cs` | clone, deep equality, path lookup, walk, stringify, JSON parsing |
| `src/Fib.cs` | the system under test |
| `test/Program.cs` | the shared conformance suite |

## Notes

- BCL only: `System.Text.Json` for parsing,
  `System.Text.RegularExpressions` for `/pattern/` matching.
- Numbers are compared by `double` value, so `int`, `long` and `double`
  results all work.
- Absence is the `Absent` singleton; `GetPath` returns it for a missing
  step.
- `make test` runs the built binary rather than `dotnet run`, which
  forwards its own trailing flags to the program as arguments.
