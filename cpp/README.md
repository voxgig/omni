# omni - C++

Header-only C++17 port of the canonical TypeScript implementation.

```sh
make test
```

Builds with `-Wall -Wextra -Werror`.

## Use

```cpp
#include "omni.hpp"

auto provider = std::make_shared<omni::Provider>();
provider->subject = [](const std::string& name) { return subjects.at(name); };

omni::RunPack R = omni::makeRunner("spec/fib.json", provider).runner("fib");

R.runset(R.set("basic"), FIB);
R.runsetflags(R.set("nulls"), omni::Flags::nonull(), FIBINFO);
```

A failing check throws `omni::OmniError`, which Catch2 and GoogleTest both
report as a failure. `test/run.cpp` is a dependency-free harness so that
`make test` needs no test framework.

A subject is `std::function<Json(const std::vector<Json>&)>`, and reports
failure by throwing - `what()` is the message an `err` expectation matches.

## Layout

| File | Contents |
|---|---|
| `src/omni.hpp` | the runner (include this) |
| `src/util.hpp` | clone, deep equality, path lookup, walk, stringify |
| `src/json.hpp` | the JSON value model and parser |
| `test/fib.hpp` | the system under test |
| `test/run.cpp` | the shared conformance suite |

## Notes

- Standard library only - no nlohmann/json, no Boost. `<regex>` provides
  ECMAScript patterns, which is the widest dialect of any port.
- `omni::Json` has value semantics: copy, compare and pass by value.
  Maps preserve insertion order (`std::vector<std::pair<...>>`), and
  `jsonstr` sorts keys for messages.
- `Json::Type::Absent` is a variant of the value model, so "absent" and
  "null" are distinct by construction.
