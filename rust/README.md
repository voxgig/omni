# omni - Rust

Rust port of the canonical TypeScript implementation.

```sh
cargo test
```

## Use

```rust
use std::rc::Rc;
use voxgig_omni::{make_runner, Flags, Json, Provider, Subject};

let provider = Provider {
    subject: Some(Rc::new(|name: &str| subjects(name))),
    ..Provider::default()
};

let runner = make_runner("spec/fib.json", provider)?;
let pack = runner.runner("fib", None)?;

pack.runset(&pack.set("basic"), Some(&fibsub))?;
pack.runsetflags(&pack.set("nulls"), &Flags::nonull(), Some(&infosub))?;
```

Rust has no exceptions, so a failing check is returned as `Err(OmniError)`.
A subject is `Rc<dyn Fn(&[Json]) -> Result<Json, String>>` - the `Err`
string is the message an `err` expectation matches.

## Layout

| File | Contents |
|---|---|
| `src/runner.rs` | the runner |
| `src/util.rs` | clone, deep equality, path lookup, walk, stringify |
| `src/json.rs` | the JSON value model and parser |
| `src/regex.rs` | a small backtracking regex engine |
| `src/lib.rs` | the public API |
| `tests/common/mod.rs` | the system under test |
| `tests/fib.rs` | the shared conformance suite |

## Notes

- **No dependencies at all** - not even serde. The standard library has
  neither a JSON parser nor a regex engine, so the crate carries both.
- The regex engine supports literals, `.`, `^`, `$`, `|`, groups, classes,
  `* + ? {m,n}` (greedy and lazy) and `\d \w \s` with their negations. It
  is exercised directly by `tests/fib.rs`.
- `Json::Absent` is a variant of the value model, so "absent" and "null"
  are distinct by construction.
- Maps are `BTreeMap`, so key order is sorted rather than insertion order.
  Order is never significant for equality.
