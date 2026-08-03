# omni - Dart

Dart port of the canonical TypeScript implementation.

```sh
dart run test/run.dart
```

## Use

```dart
final provider = Provider(subject: (name) => subjects[name]);

final R = makeRunner(specpath, provider).runner('fib');

R.runset(R.set('basic'), FIB);
R.runsetflags(R.set('nulls'), Flags.nonull, FIBINFO);
```

A failing check throws `OmniError`, which `package:test` reports as a
failure. `test/run.dart` is a dependency-free harness so that `make test`
needs no pub install.

A subject is `dynamic Function(List<dynamic> args)`.

## Layout

| File | Contents |
|---|---|
| `lib/runner.dart` | the runner |
| `lib/util.dart` | clone, deep equality, path lookup, walk, stringify |
| `lib/omni.dart` | the public API |
| `test/fib.dart` | the system under test |
| `test/run.dart` | the shared conformance suite |

## Notes

- Standard library only: `dart:convert` for parsing, `RegExp` for
  `/pattern/` matching.
- Absence is the `Absent` singleton (`ABSENT`); `null` is a real JSON null.
- `int` and `double` results both work: numbers compare by value.
