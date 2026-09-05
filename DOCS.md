# omni - the guide

omni runs one JSON test spec against a library in any of twenty-four
languages.
This document defines the spec format, the runner semantics, and the API
each port exposes. For a quick overview see [`README.md`](README.md).

TypeScript is canonical. A change in behaviour starts in
[`typescript/src/Runner.ts`](typescript/src/Runner.ts), is pinned in
[`spec/fib.aon`](spec/fib.aon), and is then carried to every port; a port
that disagrees with the spec is the thing that is wrong.

- [1. Concepts](#1-concepts)
- [2. The spec format](#2-the-spec-format)
- [3. Runner semantics](#3-runner-semantics)
- [4. The provider](#4-the-provider)
- [5. Flags](#5-flags)
- [6. Failure messages](#6-failure-messages)
- [7. The API, per port](#7-the-api-per-port)
- [8. Replacing struct's in-situ runners](#8-replacing-structs-in-situ-runners)
- [9. Per-port variance](#9-per-port-variance)


## 1. Concepts

**Spec.** A JSON file. Contains named sections; each section contains
named groups; each group contains a `set` of entries.

**Entry.** One test case: arguments in, expected result (or error) out.

**Subject.** The function under test. omni calls it with the entry's
arguments and compares what comes back.

**Runner.** The engine. Resolves a section, then runs groups against
subjects. One implementation per language, all behaving identically.

**Provider.** Optional. Supplies the runner with subjects by name, with
the clients a spec declares, and with the wrapping of context arguments.
A spec that names its subjects explicitly needs no provider.

The runner never imports the library under test, and never uses it to
implement itself. Each port carries its own JSON parsing, deep equality,
path lookup and regex, so that omni can test a JSON library, an equality
library, or a regex library without circularity.


## 2. The spec format

A runner reads plain JSON — that is all a port ever needs, and it is why a
port in any language can run the corpus with no toolchain beyond its own.

How that JSON is *written* is a separate question. omni's own corpus is
written in [aontu](https://github.com/voxgig/aontu) — see
[`spec/fib.aon`](spec/fib.aon) — and compiled to
[`spec/fib.json`](spec/fib.json) by `make spec`, which is what lets it carry
comments and share definitions. Your specs can be authored however you like;
the runner reads only the JSON.

### 2.1 Shape

```jsonc
{
  "primary": {
    "<section>": {
      "DEF": { "client": { "<name>": { "test": { "options": {} } } } },
      "<group>": {
        "set": [ /* entries */ ]
      }
    }
  }
}
```

Section resolution, for `runner("fib")`:

1. `primary.fib` if present,
2. otherwise `fib` if present,
3. otherwise the whole spec.

The `primary` wrapper exists so one file can hold several independent
suites. `DEF` is metadata, not a group; it is read before any group runs.

A spec may also carry a top-level `OMNI` block, a sibling of `primary`,
declaring its format version — see [2.7](#27-format-versions). `OMNI`,
like `DEF`, is a reserved metadata key, never a section.

A group is any map with a `set` list. Groups may be nested under other
keys - the runner only ever reads the group you hand to `runset`.

Specs are plain JSON. Any authoring format that compiles to JSON works;
`voxgig/struct` writes `.aon` files (JSON with comments and imports) and
compiles them to `test.json`.

### 2.2 Entries

| Field | Type | Meaning |
|---|---|---|
| `in` | any | Single argument. Deep-cloned before the call, so a subject may mutate it. |
| `args` | list | Explicit argument list. Not cloned - a `match` can then assert on in-place mutation. |
| `ctx` | map | Single context argument, passed through `provider.contextify`. |
| `out` | any | Expected result, compared with deep equality. |
| `err` | `true` or string | An error is expected. See [2.4](#24-errors). |
| `match` | any | Partial structure check. See [2.5](#25-match). |
| `client` | string | Resolve the subject from this `DEF.client` entry instead. |
| `id` | string | Identifier, echoed in failure messages. |
| `doc` | bool | Marks an entry as documentation-worthy. Ignored by the runner. |

One of `in`, `args` and `ctx` determines the arguments, resolved in the
order `ctx`, `args`, `in`. A version-1 spec ([2.7](#27-format-versions))
rejects an entry carrying more than one of them; a legacy spec silently
uses the highest-precedence field. An entry with none of them calls the
subject with a single absent value.

Fields outside this table are rejected by a version-1 spec — an
unrecognised key is almost always a mistyped assertion — and silently
ignored by a legacy spec.

An entry with no `out` expects a null (or absent) result - see
[5. Flags](#5-flags).

### 2.3 Sentinels

JSON cannot distinguish "the value null" from "no value", and a spec has
to. Three string sentinels do it:

| Sentinel | Meaning |
|---|---|
| `"__NULL__"` | A real JSON `null`. Every null in a result is normalised to this before comparison. |
| `"__UNDEF__"` | Absent: no value at all. Only meaningful inside `match`. |
| `"__EXISTS__"` | Present, whatever the value. Only meaningful inside `match`. |

So an expected map with a null field is written:

```json
{ "in": 0, "out": { "n": 0, "prev": "__NULL__" } }
```

Run the same group with `{"null": false}` and it is written the natural
way, with a real `null`. Both are in [`spec/fib.json`](spec/fib.json) - as
the `info` and `nulls` groups - precisely so that every port proves it
handles both.

The sentinel strings are **reserved words of the format**: a spec must not
use them as data values, and a subject whose real output can legitimately
contain them must be run with `{"null": false}`, where result nulls stay
null and the collision disappears. Note also that `nullmodifier` - the
helper that converts sentinels back into real nulls inside inputs -
rewrites occurrences *inside* string values too (`"a__NULL__b"` becomes
`"anullb"`), so the reservation applies to substrings as well as whole
values.

### 2.4 Errors

`err` says the subject must fail.

```json
{ "in": -1,  "err": true }
{ "in": -5,  "err": "negative" }
{ "in": -2,  "err": "fib: negative index: -2" }
{ "in": -3,  "err": "/negative index: -3$/" }
```

- `true` - any error passes.
- `"/pattern/"` - the error message must match the regular expression.
- any other string - case-insensitive substring of the error message.

If no error occurs, the entry fails with `expected error did not occur`.
If an error occurs where none was expected, the entry fails with
`unexpected error`.

Error messages are part of a library's contract. Because the match is a
substring by default, a spec can pin the meaningful part of a message
without pinning its full text in every port.

### 2.5 Match

`match` is a partial check: every *leaf* of the match structure must be
present, and must match, in the result base. Keys not mentioned are not
checked.

The base is:

```jsonc
{
  "in":   /* the entry's in */,
  "args": /* the argument list, after the call */,
  "out":  /* the result */,
  "ctx":  /* the context argument, after the call */,
  "err":  /* {name, message}, when the subject failed - or whatever
             `Provider.errify` returns, when the host supplies one */
}
```

```json
{ "in": 6, "match": { "out": { "val": 8, "even": true } } }
{ "in": 6, "match": { "out": { "label": "/^fib\\(6\\)=8$/" } } }
{ "in": 6, "match": { "out": { "nosuchkey": "__UNDEF__" } } }
{ "in": -1, "err": true, "match": { "err": { "message": "negative index" } } }
```

Leaf matching rules, in order:

1. `"__UNDEF__"` against an absent value;
2. `"__NULL__"` against a present null;
3. `"__EXISTS__"` against any present value, including null;
4. deep equality;
5. `"/pattern/"` as a regular expression over the stringified base value;
6. any other string as a case-insensitive substring of the stringified
   base value;
7. otherwise, deep equality of the two values.

The three sentinels are tested **before** deep equality, and that order
is deliberate. Were equality first, a subject returning the literal
string `"__UNDEF__"` as ordinary data would satisfy an assertion that the
key is *absent* - two mutually exclusive states passing one check. A
sentinel that accepts its own literal cannot distinguish what it exists to
distinguish.

The consequence is that a match leaf cannot currently assert a literal
sentinel string in the data: `match: { out: { a: "__UNDEF__" } }` always
means *absent*, never *the four-character-plus string*, in either null
mode. There is no escape for that yet; `__RAW__` is the planned one.
`"__NULL__"` keeps a second, narrower ambiguity for the same reason: under
the default `null` flag a real null has already been rewritten to that
string before the comparison, so a literal `"__NULL__"` and a genuine null
are indistinguishable at the leaf.

The base differs by outcome: on success it carries `in`, `args`, `out`
and `ctx`; when the subject fails it carries `in`, `out`, `ctx` and `err`
- and **not** `args`, so an in-place mutation assertion is only possible
on the success path.

Because `args` is in the success base and is *not* cloned, a match can
assert that a subject mutated its argument in place:

```json
{ "args": [ {"a": 1}, {"b": 2} ], "match": { "args": [ {"a":1,"b":2} ] } }
```

An entry with a `match` and no `out` is fully checked by the match alone.

### 2.6 Clients

`DEF.client` declares named clients. An entry that names one has its
subject resolved from that client instead of the default provider:

```json
"DEF": { "client": { "shift": { "test": { "options": { "shift": 2 } } } } },
"client": { "set": [
  { "in": 5, "out": 5 },
  { "client": "shift", "in": 5, "out": 13 }
] }
```

The runner passes `test.options` to `provider.client(options)` and uses the
returned provider to resolve the subject for that entry. If the provider
has no `client` hook, declared clients are simply not built - a spec may
declare clients that a given run never uses.

### 2.7 Format versions

A spec may declare its format version in a top-level `OMNI` block:

```json
{
  "OMNI": { "version": 1, "requires": [] },
  "primary": { }
}
```

**No block - version 0.** The original, lenient format, frozen forever:
unknown entry fields are ignored, an entry may carry several of
`in`/`args`/`ctx` (precedence decides), `err` beside `out` leaves the
`out` dead, and an empty `set` passes vacuously. Existing corpora keep
this behaviour untouched.

**`version: 1` - strict validation.** The runner rejects, with the entry
named in the failure:

- an entry field outside `in`, `args`, `ctx`, `out`, `err`, `match`,
  `client`, `id`, `doc`;
- more than one of `in`, `args`, `ctx`;
- `err` together with `out`;
- a non-string `id`;
- an empty `set` - unless the group carries `empty: true`, making the
  emptiness a stated fact rather than an accident.

Each of these is a mistake the lenient format converts into a silent pass
or a dead field; version 1 makes them loud.

**`requires`.** A list of capability strings beyond the version baseline.
A runner that does not recognise a listed capability refuses the whole
spec at load time (`spec requires unsupported capability`), so a port on
an older omni fails loudly instead of silently mis-running a spec whose
features it does not know. Future format features mint a string in the
runner's `CAPABILITIES` registry; the registry is currently empty.

A `version` newer than the runner's `SPECVERSION` is refused at load.

[`spec/def/omni-spec.aon`](spec/def/omni-spec.aon) expresses the
version-1 entry shape **in aontu**, the language the corpus is written in,
so checking a spec is unifying it with the shape rather than consulting a
separate description that can drift. `make spec-check` runs it (and
proves it can still go red); a violation is an ordinary aontu conflict,
reported with an error code, the exact spec path, and the source file.

It covers what a unifier can decide from the shape alone: the nine
permitted entry fields (the mistyped-key class — `matches:` silently
replacing `match:`) and the field types, including rejecting `id: null`. The
cross-field rules — at most one of `in`/`args`/`ctx`, `err` never beside
`out`, and a non-empty `set` — need `must()` and `length()`, which aontu
0.48.2 does not yet implement; the runner enforces those at run time and
remains the authority on spec semantics either way.


## 3. Runner semantics

The order of operations for one `runsetflags(group, flags, subject)` call.
Every port does exactly this.

1. **Resolve flags.** `null` defaults to true; `name` defaults to the
   runner's section name.
2. **Normalise the group.** The whole group is deep-copied and, when
   `null` is set, every null becomes `"__NULL__"` - including nulls inside
   `in` and `args`. A group can therefore be run repeatedly, with different
   flags, without contamination.
3. **Check the set.** The group must be a map with a `set` list. In a
   version-1 spec ([2.7](#27-format-versions)) the *authored* group is
   then validated up front, before any subject runs: an empty `set`
   (without `empty: true`), an unknown entry field, multiple argument
   sources, `err` with `out`, and a non-string `id` all fail here.
   Validation reads the original entries, not the normalised copies, so
   null-normalisation cannot mask an authored null.
4. For each entry, in order:
   1. **Default the expectation.** No `out` and `null` set means
      `out = "__NULL__"`.
   2. **Resolve the subject.** `entry.client` overrides the default.
   3. **Resolve the arguments.** `ctx`, else `args`, else `[clone(in)]`.
      For `ctx`/`args`, a leading map argument is cloned and passed through
      `provider.contextify`.
   4. **Call the subject.**
   5. **On failure** - go to `err` handling ([2.4](#24-errors)), then the
      `match` check against a base carrying `err`.
   6. **On success** - normalise the result the same way as the group,
      record it as `entry.res`, then:
      - if `err` was expected, fail;
      - if `match` is present, run it;
      - if the result deep-equals `out`, pass;
      - if a match ran and `out` is absent or `"__NULL__"`, pass;
      - otherwise fail with `result mismatch`.

**Ordering.** Entries run in spec order and the first failure stops the
group. Map key order is never significant for equality.

**Numbers.** Compared by value: `1` and `1.0` are equal. Booleans are never
equal to numbers.

**Errors from the runner itself** (unknown client, malformed spec) are
distinguishable from errors thrown by the subject - the runner raises its
own error type, and never treats it as a candidate for an `err`
expectation.


## 4. The provider

Every hook is optional.

| Hook | Signature | Purpose |
|---|---|---|
| `subject` | `(name) => Subject` | Resolve the default subject for a section, and the per-client subject for an entry with `client`. |
| `client` | `(options) => Provider` | Build a provider for a `DEF.client` entry. |
| `contextify` | `(val) => val` | Wrap a map argument before it is passed as `ctx`/`args[0]`. |
| `inject` | `(options, store) => void` | Resolve references in client options against the runner store, **mutating `options` in place** - the return value is ignored. |
| `errify` | `(err) => Json` | Build the `match.err` base, **replacing** the runner's own `errify`. |

The runner sets `client` on a contextified map argument, so a subject can
reach the provider that owns it.

**`errify` is how a library asserts on structured errors.** The default
base is `{name, message}` and nothing more, so a spec can only reach an
error's *prose*. A library whose errors carry a `code` (or a `status`, or
a `path`) supplies this hook and asserts on the field instead:

```json
{ "in": -1, "err": true, "match": { "err": { "code": "fib_negative" } } }
```

It **replaces** the default rather than adding to it, so a hook must
supply `name` and `message` too if the spec asserts on them.

What the hook receives is the most the port has at that point, and the
ports divide in two. TypeScript, JavaScript, Python, Ruby, PHP, Perl, Go,
Java, C#, Kotlin, Scala, Clojure, Swift, Dart, Elixir, and boru hand over
the **raised error**. Rust, C, C++, Zig, OCaml, Haskell, and Lean report a
subject failure as a message string and have nothing else to hand over,
so those receive the **message**. Lua sits with the first group. The
distinction is a property of each language's failure channel, not a
choice: widening it would change `Subject` in seven ports and break
consumers outside this repository.

Only JavaScript would otherwise get any of this for free, by spreading an
`Error`'s own enumerable properties into the base - which is why
`errify`'s spread is documented in the canonical as a contract rather
than left as an accident.

Providers are per-language values: a map of closures in the dynamic
languages, a struct of function fields in Go, C, C++, Java, and Rust.


## 5. Flags

| Flag | Default | Effect |
|---|---|---|
| `null` | `true` | Convert every JSON null - in the spec and in the result - to `"__NULL__"`. With `false`, nulls stay null and expectations are written literally. |
| `name` | section name | The label used in failure messages. |

`runset(group, subject)` is `runsetflags(group, {}, subject)`.

Turn `null` off when a group's inputs or outputs contain meaningful nulls
that the subject must receive as real nulls - as in the `nulls` group of
the Fibonacci spec.


## 6. Failure messages

One format, every port:

```
omni: <label>[<index>] (<id>): <reason>
  expected: <expected>
  actual:   <actual>
  entry:    <the spec entry>
```

The `(<id>)` part appears only when the entry has an `id`. Reasons are
`result mismatch`, `error mismatch`, `expected error did not occur`,
`unexpected error`, and `match failed at <path>`.

Values are rendered by `stringify`: strings verbatim, everything else as
compact JSON with map keys sorted. Sorting means the same failure prints
the same text in a language with ordered maps and one without.


## 7. The API, per port

The canonical API is the TypeScript export list
([`typescript/src/index.ts`](typescript/src/index.ts)). Every port defines
every name, in local casing;
[`tools/check_parity.py`](tools/check_parity.py) enforces it.

Runner: `makeRunner`, `runset`, `runsetflags`, `loadspec`, `resolvespec`,
`fixjson`, `errify`, `match`, `matchval`, `nullmodifier`, `OmniError`,
`SPECVERSION`, `CAPABILITIES`,
`NULLMARK`, `UNDEFMARK`, `EXISTSMARK`. Ports that cannot express one of
these are listed, with a reason, in the tool's `EXEMPT` table - today only
`OmniError`, in C, Zig and Lean, which all return failures rather than
throwing them.
Utilities: `clone`, `deepequal`, `getpath`, `walk`, `jsonstr`,
`stringify`, `pathify`.

### TypeScript / JavaScript

```ts
const runner = await makeRunner('spec/fib.json', provider)
const R = await runner('fib')
await R.runset(R.spec.basic, fib)
await R.runsetflags(R.spec.nulls, { null: false }, fibinfo)
```

Failures throw `OmniError`. Subjects may be async.

### Python

```python
R = makeRunner('spec/fib.json', provider)('fib')
R['runset'](R['spec']['basic'], fib)
R['runsetflags'](R['spec']['nulls'], {'null': False}, fibinfo)
```

`OmniError` extends `AssertionError`, so unittest and pytest report it as a
failure rather than an error. The provider is a dict of callables.

### Ruby

```ruby
R = VoxgigOmni.make_runner('spec/fib.json', provider).call('fib')
R[:runset].call(R[:spec]['basic'], FIB)
R[:runsetflags].call(R[:spec]['nulls'], { null: false }, FIBINFO)
```

### PHP

```php
$R = (Runner::makeRunner('spec/fib.json', $provider))('fib');
($R['runset'])($R['spec']['basic'], $fib);
($R['runsetflags'])($R['spec']['nulls'], ['null' => false], $fibinfo);
```

### Perl

```perl
my $R = makeRunner('spec/fib.json', $provider)->('fib');
$R->{runset}->( $R->{spec}{basic}, $FIB );
$R->{runsetflags}->( $R->{spec}{nulls}, { null => 0 }, $FIBINFO );
```

### Go

```go
runner, err := omni.MakeRunner("spec/fib.json", provider)
R, err := runner("fib", nil)
if err := R.RunSet(R.Set("basic"), FIB); nil != err { t.Fatal(err) }
if err := R.RunSetFlags(R.Set("nulls"), omni.Flags{"null": false}, FIBINFO); nil != err { t.Fatal(err) }
```

Go has no exceptions: failures are returned as `*omni.OmniError`, and a
subject is `func(args ...any) (any, error)`. Panics in a subject are
recovered and treated as errors.

### Rust

```rust
let runner = make_runner("spec/fib.json", provider)?;
let pack = runner.runner("fib", None)?;
pack.runset(&pack.set("basic"), Some(&fibsub))?;
pack.runsetflags(&pack.set("nulls"), &Flags::nonull(), Some(&infosub))?;
```

Failures are `Err(OmniError)`; a subject is
`Rc<dyn Fn(&[Json]) -> Result<Json, String>>`. The crate carries its own
JSON parser and regex engine, because the standard library has neither.

### Java

```java
RunPack R = Runner.makeRunner(specpath, provider).runner("fib");
R.runset(R.set("basic"), FIB);
R.runsetflags(R.set("nulls"), Runner.flags("null", false), FIBINFO);
```

Failures throw `Runner.OmniError` (a `RuntimeException`), which JUnit
reports as a failure. JSON parses to `LinkedHashMap`/`ArrayList`/`Double`.

### C

```c
omni_pool *pool = omni_pool_new();
omni_runner *runner = omni_make_runner(pool, path, NULL, provider, &err);
omni_runpack *pack = omni_runner_run(runner, "fib", NULL, &err);

if (0 != omni_runset(pack, omni_set(pack, "basic"), subject, &err)) {
  printf("%s\n", err);
}

omni_pool_free(pool);
```

Every value is allocated from the pool and freed in one call. A subject
returns `omni_result { val, err }`.

### C++

```cpp
omni::RunPack R = omni::makeRunner(specpath, provider).runner("fib");
R.runset(R.set("basic"), FIB);
R.runsetflags(R.set("nulls"), omni::Flags::nonull(), FIBINFO);
```

Header-only. Failures throw `omni::OmniError`; a subject is
`std::function<Json(const std::vector<Json>&)>`.

### C#

```csharp
RunPack R = Runner.MakeRunner(specpath, provider).Run("fib");
R.RunSet(R.Set("basic"), FIB);
R.RunSetFlags(R.Set("nulls"), Flags.NoNull(), FIBINFO);
```

Failures throw `OmniError`; a subject is `object Subject(params object[])`.

### Kotlin

```kotlin
val R = makeRunner(specpath, provider).runner("fib")
R.runset(R.set("basic"), FIB)
R.runsetflags(R.set("nulls"), Flags.nonull(), FIBINFO)
```

Failures throw `OmniError`; a subject is `(List<Json>) -> Json`.

### Scala

```scala
val R = Runner.makeRunner(specpath, provider).runner("fib")
R.runset(R.set("basic"), Some(FIB))
R.runsetflags(R.set("nulls"), Flags.nonull(), Some(FIBINFO))
```

Failures throw `OmniError`; a subject is `List[Json] => Json`. Values are
immutable, so the runner rebuilds each entry rather than mutating it.

### Clojure

```clojure
(def R ((runner/make-runner specpath provider) "fib"))
((:runset R) ((:set R) "basic") FIB)
((:runsetflags R) ((:set R) "nulls") {:null false} FIBINFO)
```

Failures throw an `ExceptionInfo` carrying `:omni true` - test for it with
`runner/omni-error?`. A subject is `(fn [args] ...)`.

### Lua

```lua
local R = runner.makeRunner(specpath, provider)('fib')
R.runset(R.set('basic'), FIB)
R.runsetflags(R.set('nulls'), { null = false }, FIBINFO)
```

Failures raise an OmniError table (`runner.isomnierror`). Lua tables cannot
hold `nil` and cannot tell an empty list from an empty map, so `u.NULL` and
`u.ABSENT` are explicit sentinels and containers are built with `u.map{}` /
`u.list{}`.

### Zig

```zig
const pack = try runner.runner("fib", null);
if (try pack.runset(pack.set("basic"), &FIB)) |failure| { ... }
```

Zig error values carry no payload, so a failure is **returned** as
`?[]const u8`. Zig has no closures, so a `Subject` is a function pointer
plus its own `data` pointer, as in C.

### Swift

```swift
let R = try makeRunner(specpath, provider).runner("fib")
try R.runset(R.set("basic"), FIB)
try R.runsetflags(R.set("nulls"), Flags.nonull(), FIBINFO)
```

Failures throw `OmniError`; a subject is `([Json]) throws -> Json`.

### Dart

```dart
final R = makeRunner(specpath, provider).runner('fib');
R.runset(R.set('basic'), FIB);
R.runsetflags(R.set('nulls'), Flags.nonull, FIBINFO);
```

Failures throw `OmniError`; a subject is `dynamic Function(List<dynamic>)`.

### Elixir

```elixir
pack = Runner.make_runner(specpath, provider).("fib", nil)
pack.runset.(pack.set.("basic"), fib)
pack.runsetflags.(pack.set.("nulls"), %{null: false}, fibinfo)
```

Failures raise `Voxgig.Omni.OmniError`; a subject is `fn args -> ... end`.

### OCaml

```ocaml
let pack = (make_runner specpath provider) "fib" None in
pack.runset (pack.set "basic") (Some fibsub)
```

Failures raise `Omni_error`; a subject is `json list -> json`. A custom
exception should register a printer, which is how the runner reads its
message.

### Haskell

```haskell
pack <- makeRunner specpath provider "fib"
runset pack (packSet pack "basic") (Just fibsub)
runsetflags pack (packSet pack "nulls") nonullFlags (Just fibinfosub)
```

Failures throw `OmniError`; a subject is `[Json] -> IO Json`, whose message
is `displayException`.

### Lean 4

```lean
let pack ← makeRunner path provider "fib"
match pack.runset (pack.set "basic") (some FIB) with
| .ok () => pure () | .error message => IO.println message
```

Lean's checks are pure, so a failure is **returned** as
`Except.error message`; a subject is `List Json → Except String Json`.


## 8. Replacing struct's in-situ runners

Every `voxgig/struct` port carries `<lang>/test/runner.*`: the same
algorithm, hand-ported more than twenty times. omni is that algorithm as a
library, so each struct port can delete its copy.

### 8.1 What struct's runner does that omni must do

| struct | omni |
|---|---|
| `makeRunner(testfile, client)` | `makeRunner(specref, provider)` |
| `runner(name, store)` → `{spec, runset, runsetflags, subject, client}` | same |
| subject from `client.utility()[name]` or `.struct[name]` | `provider.subject(name)` |
| clients from `spec.DEF.client[*].test.options` via `client.tester(opts)` | `provider.client(options)` |
| `utility.contextify(ctxmap)` | `provider.contextify(val)` |
| `structUtils.inject(copts, store)` | `provider.inject(options, store)` |
| `NULLMARK`/`UNDEFMARK`/`EXISTSMARK` | identical |
| `nullModifier` | `nullmodifier` |

The one structural difference: struct's runner implements `clone`, `walk`,
`getpath` and `stringify` by calling *the library under test*. omni carries
its own, so a bug in struct cannot hide itself by breaking the runner that
would have caught it.

### 8.2 The JavaScript shim

[`javascript/compat/struct.js`](javascript/compat/struct.js) exposes omni
behind struct's exact runner API. A struct port switches over by changing
one import:

```diff
-const { makeRunner, nullModifier, NULLMARK } = require('./runner')
+const { makeRunner, nullModifier, NULLMARK } = require('./omni')
```

where `./omni` is a ~20-line resolver that locates the local omni checkout
(see [8.3](#83-porting-the-rest)) and re-exports
`<checkout>/javascript/compat/struct.js`.

omni is **server-side only** — every port reads spec files from disk and
runs a system under test in-process, so no port targets a browser and
neither npm package carries a `browser` export condition.

The two Node ports are also published to npm, as `@voxgig/omni-js` and
`@voxgig/omni`, and for those the resolver is optional: the shim is a
declared subpath, so a consumer that adds omni as a **devDependency**
writes `require('@voxgig/omni-js/compat/struct')` (or, from TypeScript,
`require('@voxgig/omni/compat/struct')`) and needs no checkout at all.
The existing consumers all still resolve a checkout; moving any of them
over is a separate change, port by port. See
[8.3](#83-porting-the-rest) for the other twenty-two.

The shim wraps struct's SDK as an omni provider, and forwards `utility()`
and `tester()`, so test code that reaches through the returned `client`
keeps working.

Verify with:

```sh
make struct-compat STRUCT=../struct
```

which copies struct's own `struct.test.js` and `client.test.js`, rewrites
that single import, and runs them against struct's JavaScript library and
the real `build/test/test.json`. All 95 tests pass - the same 95 that pass
with struct's own runner.

### 8.3 Porting the rest

For each struct port:

1. Wire omni in as a **local checkout**. Only the two Node ports are
   published to a registry so far - the rest have no published
   artifact, not because they could not have one (python, rust and dart
   all have obvious homes) but because nobody has done the packaging
   work - so for them the checkout is the only mechanism. It is also the
   one `voxgig/sekreto` already uses in all ten of its ports: resolve
   the checkout from `$OMNI_HOME`, then sibling paths (`../../omni`,
   `../../../omni`), taking the first directory that contains
   `spec/fib.json`. Compiled languages link it without putting a
   machine-specific path in a checked-in file: Go generates a `go.work`,
   Rust symlinks `vendor/omni`, C# passes `-p:OmniPath=`, Java puts it on
   the classpath - all gitignored. A JavaScript or TypeScript consumer
   may instead take `@voxgig/omni-js` or `@voxgig/omni` from npm; there
   the isolation device is the **`devDependencies` block itself**, since
   npm never installs a devDependency transitively, and `npm ls --omit=dev`
   is what proves it.

   **Five ports can also be pinned by git ref.** `go`, `clojure`, `rust`,
   `dart` and `lean` carry release tags of the form `<port>/vX.Y.Z`, so a
   consumer may declare omni through that ecosystem's own package manager
   instead of resolving a checkout:

   | port | declaration |
   |---|---|
   | `go` | `require github.com/voxgig/omni/go vX.Y.Z` |
   | `rust` | `voxgig_omni = { git = "https://github.com/voxgig/omni", tag = "rust/vX.Y.Z" }` |
   | `dart` | `voxgig_omni: { git: { url: ..., ref: dart/vX.Y.Z, path: dart } }` |
   | `clojure` | `{:git/url ... :git/tag "clojure/vX.Y.Z" :git/sha "<40 chars>" :deps/root "clojure"}` |
   | `lean` | `[[require]] name = "omni", git = ..., rev = "lean/vX.Y.Z", subDir = "lean"` |

   The prefix is not cosmetic: Go **requires** a subdirectory module's tags
   to be named `<subdir>/vX.Y.Z` and ignores every tag without it. The other
   four impose no naming rule at all and follow the same shape for
   consistency; each can equally pin a bare commit SHA and skip tags
   entirely.

   `swift` is deliberately **not** in that list and cannot be. SwiftPM loads
   a source-control dependency's manifest from the repository ROOT
   (`packagePath: .root` is hard-coded, and no `.package(...)` overload takes
   a subdirectory), so serving `omni/swift` by ref would mean a
   `Package.swift` at `/` - making this polyglot repository read as "a Swift
   package" to every consumer of every other language. SwiftPM also rejects a
   prefixed tag, accepting only `1.2.3` or `v1.2.3`, which would collide with
   the scheme Go mandates. The remaining sixteen ports have no published
   artifact of any kind; the checkout is their only route.

   **A Go tag is a one-way door.** proxy.golang.org and sum.golang.org cache
   a version permanently, and moving or deleting a tag surfaces to users as a
   *security error*, not a missing version. Withdrawal is only via `retract`
   in a NEW version. Get the number right the first time.

   CI checks out `voxgig/omni` beside the
   consuming repository and exports `OMNI_HOME`. Only the *tests* depend on
   omni; the shipped library never does, so struct's zero-runtime-
   dependency rule is untouched.
2. Write the provider adapter - about 30 lines, mapping the four hooks in
   the table in [8.1](#81-what-structs-runner-does-that-omni-must-do) onto
   that port's SDK.
3. Replace the runner import in the port's test file.
4. Delete `<lang>/test/runner.*`.
5. Run the port's suite. Any difference is a real behavioural difference
   and worth understanding before it is papered over.

Do this one port at a time, keeping the corpus and the SDK untouched, so
that a failure can only mean "the runners disagree here".


## 9. Per-port variance

Places where a language cannot express what the spec can. Each is a
deliberate, documented limitation, not a bug to be fixed by diverging.

| Port | Variance |
|---|---|
| PHP | JSON decodes to associative arrays, so an empty map and an empty list are the same value. |
| Perl | Scalars are untyped: the string `"5"` and the number `5` are indistinguishable. Booleans come from `JSON::PP`. |
| C | Failures are messages, not an error type - there is no `OmniError`. Regex is POSIX ERE; `\d`, `\w` and `\s` are translated, but lookaround and lazy quantifiers are not available. |
| Go | Map key order is not preserved (`encoding/json`). Order is never significant for equality. |
| Rust | Maps are `BTreeMap`, so key order is sorted rather than insertion order. The regex engine supports the common subset: literals, classes, groups, alternation, `* + ? {m,n}`, `\d \w \s`, anchors. |
| Java, C++, C#, Kotlin, Swift | Numbers are all doubles, matching JSON. |
| Lua | Tables cannot hold `nil`, and an empty list and an empty map are the same table, so the port uses explicit `NULL`/`ABSENT` sentinels and tags every container with a metatable. |
| Zig | Error values carry no payload, so failures are returned as messages - there is no `OmniError`. For the same reason, spec-load refusals ([2.7](#27-format-versions)) surface as distinct typed errors (`error.MalformedOmniVersion`, `error.UnsupportedSpecVersion`, `error.MalformedOmniRequires`, `error.UnsupportedCapability`) rather than the canonical message strings. The failure modes are one-for-one; only the rendering differs. |
| Lean | Checks are pure: failures are returned as `Except String`, so there is no `OmniError`. The regex matcher is a `partial def`. |
| Clojure, Elixir, Scala, Lean | Map key order is not preserved (or is sorted). Order is never significant for equality. |
| OCaml, Haskell | An exception carries no message by default: OCaml registers a printer, Haskell defines `show`. |
| boru | One `none` plays both JSON null and "no value", so under `null: false` an entry with no `out` is satisfied by a null result as well as by no result - canonical `deepequal` holds those apart (*"undefined and null are distinct"*) and reports a mismatch for the first. Under `null: true` the question does not arise: both sides become `__NULL__` first. The regex engine behind `mini re` is RE2, so a `/.../` match leaf using a backreference or lookaround cannot behave as it does in TypeScript; the common subset - literals, classes, groups, alternation, `* + ? {m,n}`, `\d \w \s`, anchors - is what is available, as in Rust and C. |

Everything else - entry semantics, sentinels, match rules, flag behaviour,
failure text - is *intended* to be identical across all twenty-four ports,
and the Fibonacci suite proves it **only for the cases the corpus actually
exercises**.

That qualifier is the whole claim, and it is the limit of what is
checked. It is narrower than it may first appear, in two stacked ways.
First, the corpus is JSON, so a value JSON has no literal for cannot appear
in an entry at all, and port behaviour on such a value is unproven by
construction. Second - and this is the larger gap - `fib.aon` is a finite
set of entries, not an enumeration of JSON: a port can diverge on a
perfectly JSON-expressible value, magnitude, or nesting shape that simply is
not in the corpus, and every suite stays green. `tools/check_parity.py` does not close the gap either: it is
a NAME check by design and says so in its own docstring - it confirms each
canonical identifier appears as a token in a port's source, and a port
whose `deepequal` was `return true` would pass it.

**NaN is the worked example.** `deepequal(NaN, NaN)` must be `true` -
deepequal is structural, not IEEE - and six ports silently disagreed:
`php`, `ruby`, `lua`, `perl`, `clojure`, and `zig`. Every suite stayed
green throughout, because `spec/fib.json` contains no NaN and cannot: JSON
has no NaN literal, and the sentinel set (`__NULL__`, `__UNDEF__`,
`__EXISTS__`) has no member for it. Ruby was the sharpest case - it returned `true` for
`deepequal(Float::NAN, Float::NAN)` and `false` for two *distinct* NaNs,
because `Float::NAN` is a single constant object caught by an identity
fast-path. A test written the obvious way would have passed and proved
nothing.

The divergence is fixed. The structural point is not: where neither the
corpus nor the name check reaches, ports can drift silently, and no port
currently unit-tests `deepequal`, `clone`, `getpath`, `walk`, `jsonstr`,
`stringify` or `pathify` directly - the whole utility surface is exercised
only incidentally, through JSON-expressible values.
