# omni - Swift

Swift port of the canonical TypeScript implementation.

```sh
swift build && ./.build/debug/omnitest
```

## Use

```swift
let provider = Provider(subject: { name in subjects[name] })

let R = try makeRunner(specpath, provider).runner("fib")

try R.runset(R.set("basic"), FIB)
try R.runsetflags(R.set("nulls"), Flags.nonull(), FIBINFO)
```

A failing check throws `OmniError`, which XCTest reports as a failure.
`Sources/OmniTest/main.swift` is a dependency-free harness so that
`make test` needs no test target.

A subject is `([Json]) throws -> Json`.

## Layout

| File | Contents |
|---|---|
| `Sources/Omni/Runner.swift` | the runner |
| `Sources/Omni/Util.swift` | clone, deep equality, path lookup, walk, stringify |
| `Sources/Omni/Json.swift` | the JSON value model and parser |
| `Sources/OmniTest/Fib.swift` | the system under test |
| `Sources/OmniTest/main.swift` | the shared conformance suite |

## Notes

- The port carries its own `Json` enum and parser rather than using
  `JSONSerialization`, whose `NSNumber` bridge does not keep booleans and
  numbers distinct on every platform.
- `NSRegularExpression` (Foundation) provides `/pattern/` matching.
- `Json.absent` is a case of the value model, so "absent" and "null" are
  distinct by construction.
