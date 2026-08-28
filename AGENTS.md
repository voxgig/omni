# AGENTS.md - working in the `voxgig/omni` repo

Guidance for AI coding agents (and the humans reviewing them). Read this
before touching anything. User documentation is in
[`README.md`](README.md) (overview) and [`DOCS.md`](DOCS.md) (the
comprehensive guide).

> **TL;DR**
> 1. **TypeScript is canonical.** Behaviour is defined by
>    [`typescript/src/Runner.ts`](typescript/src/Runner.ts) and
>    [`typescript/src/Util.ts`](typescript/src/Util.ts). Every other port is
>    a translation of those two files.
> 2. **`spec/fib.aon` is the contract.** It runs against every port (via
>    the generated `spec/fib.json`). If a port disagrees with it, the port
>    is wrong.
> 3. **Change the canonical first, then propagate.** A behaviour change
>    means: edit the TypeScript, adjust the spec, then update *every* port
>    and re-run its tests.
> 4. **Keep parity.** `python3 tools/check_parity.py` must stay green.
> 5. **Zero runtime dependencies.** No port may add a third-party package -
>    not for JSON, not for regex, not for testing.


## What this repository is

omni is one test runner, defined once and ported faithfully to twenty-four
languages, so that a single JSON spec file produces identical pass/fail
results everywhere.

The value of the project *is* that uniformity. The job here is almost never
"make this port clever"; it is "make this port agree with the canonical
TypeScript, case for case, in idiomatic local style."


## Prime directives

1. **Do not change behaviour in a single port.** If a port's output looks
   wrong, check it against the canonical TypeScript. Either it is a port
   bug (fix the port) or a canonical change (change TypeScript + spec +
   *all* ports). Never let one port drift.
2. **Do not weaken the spec to make a failing port pass.**
   `spec/fib.aon` encodes canonical behaviour. Change it only when
   deliberately changing that behaviour, and verify the canonical
   TypeScript still passes first.
3. **The spec format has a shape, written in aontu.**
   [`spec/def/omni-spec.aon`](spec/def/omni-spec.aon) is unified with
   every spec source by `make spec-check`, so a typo'd entry field or a
   mistyped `id` fails with an error code, a spec path and a source file.
   It is checked separately from `make spec` on purpose - unifying it into
   the build would drop optional keys holding empty containers (`out: []`)
   and silently rewrite entries. The runner is still the authority.
4. **Never hand-edit `spec/*.json`.** It is generated from `spec/*.aon`
   by `make spec` and committed so that no port needs a Node toolchain to
   run its tests. Edit the aontu, run `make spec`, commit both. CI's
   `spec-freshness` job rebuilds and fails on any drift.
5. **Do not add dependencies.** Every port uses only its standard library.
   Where the standard library has no JSON parser or no regex engine (Rust,
   C, C++, Java, Kotlin, Scala, Clojure, Lua, Swift, Elixir, OCaml,
   Haskell, Zig), the port carries a small in-tree one. (`tools/` is build
   machinery, not a port — it may depend on `@voxgig/model`, and nothing
   at test time ever reaches it.)
6. **The runner may not use the library under test.** omni carries its own
   `clone`, `deepequal`, `getpath`, `walk`, `stringify` and JSON parsing.
   A runner that borrowed them could not test a library that provides them
   - and a bug in that library would hide itself.
7. **Every port must prove it can fail.** Each test file asserts that the
   runner raises on a wrong result, a missing error, a failed match, and an
   absent key. A green suite that cannot go red proves nothing.


## Repository map

```
.
├── README.md          # user-facing overview
├── DOCS.md            # comprehensive guide: spec format, semantics, API
├── AGENTS.md          # this file
├── Makefile           # aggregate targets
├── spec/
│   ├── fib.aon      # the shared test corpus - the contract, edit this
│   ├── fib.json       # generated from fib.aon; what the ports read
│   └── def/
│       └── omni-spec.aon  # the spec-format shape, in aontu
├── tools/
│   ├── build-spec.js      # compiles spec/*.aon -> spec/*.json
│   ├── check-spec-shape.js # unifies each spec with the format shape
│   ├── package.json       # tools/ is a node project (@voxgig/model)
│   ├── check_parity.py    # every port defines the canonical API
│   └── struct_compat.sh   # run voxgig/struct's own suite on omni
├── typescript/        # the canonical implementation
└── <lang>/            # one port per directory: library, test, Makefile, README
```

Each port directory holds the library source, a Fibonacci library (the
system under test), a test file running the shared spec, a `Makefile` with
at least `test`, and a `README.md`.


## Per-port quick reference

Run from the repository root: `make test-<lang>`. Or `cd` into the
directory and use its `Makefile`.

| Lang | Dir | Test | Notes |
|---|---|---|---|
| TypeScript | `typescript/` | `npm test` | canonical; `npm run build` runs first |
| JavaScript | `javascript/` | `npm test` | CommonJS; hosts `compat/struct.js` |
| Python | `python/` | `python3 -m unittest discover -s tests` | `OmniError` extends `AssertionError` |
| Ruby | `ruby/` | `ruby test/test_fib.rb` | minitest (stdlib) |
| PHP | `php/` | `php test/run.php` | assoc-array JSON model |
| Perl | `perl/` | `prove -Ilib -It t/` | `JSON::PP` + `Test::More` (core) |
| Lua | `lua/` | `lua5.4 test/run.lua` | in-tree JSON + regex; explicit NULL/ABSENT |
| Go | `go/` | `go test ./...` | errors returned, not panicked |
| Rust | `rust/` | `cargo test` | in-tree JSON + regex |
| Java | `java/` | `make test` | plain `javac`; in-tree JSON |
| C# | `csharp/` | `make test` | BCL only; runs the built binary, not `dotnet run` |
| Kotlin | `kotlin/` | `make test` | `kotlinc` to a jar; in-tree JSON |
| Scala | `scala/` | `make test` | Scala 3; immutable values |
| Clojure | `clojure/` | `make test` | in-tree JSON; `==` for numbers |
| C | `c/` | `make test` | C99, `-Werror`; pool allocator; POSIX regex |
| C++ | `cpp/` | `make test` | header-only C++17, `-Werror` |
| Zig | `zig/` | `make test` | 0.16 module flags; failures returned |
| Swift | `swift/` | `make test` | SwiftPM; in-tree JSON |
| Dart | `dart/` | `dart run test/run.dart` | |
| Elixir | `elixir/` | `make test` | `elixirc` to `build/`; test depends on build |
| OCaml | `ocaml/` | `make test` | `ocamlc`; in-tree JSON + regex |
| Haskell | `haskell/` | `make test` | `ghc`, base only; in-tree JSON + regex |
| Lean 4 | `lean/` | `make test` | `lake`; pure `Except String` failures |

Repository-wide: `make test`, `make parity`, `make struct-compat`,
`make pack-check`, `make pack-diff`, `make inspect`, `make clean`.

**The packages ship source.** omni is open source, and `files` carries
`src/` and `compat/` alongside the compiled `dist/`. A consumer who wants
to read the runner, or a porter translating it into a fourteenth
language, gets it from the package rather than having to find the repo.
The npm entry points all resolve to `dist/`; the sources ride along.
`make pack-diff` will refuse a release that drops any of them.

**omni is server-side only.** No port targets a browser, and the two
npm packages carry no `browser` export condition and no bundler build.
Nothing here should acquire one: the runner reads spec files from disk
and runs a system under test in-process, which is a server-side shape.
If a browser consumer ever appears it is a new decision, not an
oversight being corrected.

**Node 24 is the baseline.** Every `node-version` in `ci.yml` and
`release.yml` pins it, so that is the version the two Node ports are
tested and published on. Node 22 still passes the whole sweep and the
shipped library uses nothing newer, so neither manifest declares
`engines` - a floor we have not established would be over-claiming, and
it would warn consumers off for no reason. Node 20 does NOT work for
development: `node --test` only learned glob patterns in 22, so
`make test-typescript` fails there with a misleading
`Could not find 'dist/test/*.test.js'`.

`make pack-check` is the one that does not run against the working tree:
it packs the two npm ports, installs them into an empty directory outside
this repository and uses them there. Anything true only of a checkout -
a file the `files` list forgets, a path the shim assumes - is invisible
to every other target and shows up only once a consumer installs. Both
have already happened; `tools/pack_check.sh` names them.

`make pack-diff` is its network-bound companion, run at release time
rather than on every PR: it compares what a port would publish against
what is on the registry now and refuses a release that drops a file the
published version has. Adding files is ordinary; removing them silently
breaks whoever imported them, and 0.1.0 shipped three `src/*.ts` that a
release from main would have dropped.


## Standard workflows

### Fix a port that disagrees with the spec

1. Reproduce: `make test-<lang>` and read the failing entry.
2. Compare that port's logic to the canonical TypeScript for the same
   function.
3. Fix the **port**. Do not touch the spec.
4. `make test-<lang>` green, then `make test` to be sure nothing else moved.

### Change runner behaviour (affects everyone)

1. Edit `typescript/src/Runner.ts` (and `Util.ts` if needed).
2. Add or adjust the entries in `spec/fib.aon` that pin the new
   behaviour, then `make spec` to regenerate `spec/fib.json`.
3. `make test-typescript` - the canonical passes.
4. Propagate the same logic to **every** port; run each port's tests.
5. `make parity` and `make test` stay green.
6. If a port genuinely cannot express the behaviour, document it in
   [`DOCS.md`](DOCS.md#9-per-port-variance) - and, if it is an API name, in
   the `EXEMPT` table of `tools/check_parity.py`, with a reason.

### Add a public API name

1. Implement and export it in the canonical TypeScript.
2. Add it to `CANONICAL` in `tools/check_parity.py`.
3. Port it to every port, in local casing.
4. `make parity` must report every port `ok`.


## Conventions

- **Casing.** `makeRunner` (TS/JS/Python/PHP/Perl/Java/C++/Kotlin/Swift/
  Dart/Lua/Scala/Lean), `make_runner` (Ruby/Rust/Elixir/OCaml),
  `make-runner` (Clojure), `MakeRunner` (Go/C#), `omni_make_runner` (C).
  Parity is checked case-, hyphen- and underscore-insensitively, and
  ignores the C `omni_` prefix.
- **Naming inside the runner.** The internal helpers carry the same names
  in every port (`resolveentry`, `resolveargs`, `checkresult`,
  `handleerror`, `fixjson`, `entryref`, `fail`, `resolveversion`,
  `checkset`, `checkentry`), so the ports can be read side by side.
- **Failure text is API.** The message format in
  [`DOCS.md`](DOCS.md#6-failure-messages) is identical in every port and is
  asserted by each port's "reports entry index and id" test. Changing it
  means changing all twenty-four.
- **Comments explain why, not what.** Match the density of the surrounding
  code.
- **Commit messages.** Conventional and scoped: `fix(go): ...`,
  `feat(spec): ...`, `docs: ...`. Say what changed, why, and what tests
  were run.


## Gotchas

- **`null` is not "absent".** Group A of the sentinel rules exists because
  most JSON parsers conflate them. `getpath` returns an *absent* marker, not
  null, when a step is missing - `Json::Absent` in Rust, `ABSENT` in
  Python/Ruby/Perl/Go/Java/Lua/Dart/C#, `OMNI_ABSENT` in C,
  `Json::Type::Absent` in C++, `Absent` in Swift/Kotlin/Scala/OCaml/Haskell,
  `none` in Zig/Lean, `:"$omni_absent"` in Elixir, `::absent` in Clojure.
  Never collapse the two.
- **`fixjson` runs over the whole group, not just the result.** With
  `null: true`, nulls inside `in` and `args` also become `"__NULL__"`.
  A group whose inputs need real nulls must run with `{null: false}`.
- **`args` is deliberately not cloned.** A `match` on `args` asserts on
  in-place mutation by the subject. Cloning it would silently break those
  entries.
- **Booleans are not numbers.** `deepequal` must reject `true == 1`. This is
  a live hazard in Python (`bool` is a subclass of `int`) and Perl.
- **Number rendering must agree.** `5.0` prints as `5` everywhere, via
  `numstr`. Otherwise the same failure prints differently in Java and
  JavaScript.
- **Map key order is not significant** for equality, and `jsonstr` sorts
  keys so that messages are identical in ports with and without ordered
  maps.
- **A subject must never raise the runner's own failure type.** Each fib
  library defines its own error (`FibError`, `Fib_error`, ...). A subject
  that threw `OmniError` could fake a passing `err` expectation.
- **The regex engine is ported, not reimplemented.** Lua, Rust, OCaml,
  Haskell, Zig and Lean carry the same backtracking engine
  (`rust/src/regex.rs` is the reference); C uses POSIX ERE with escape
  translation; the rest use their standard library. Keep them in step.
- **Toolchains may be missing.** If a port cannot be built in your
  environment, say so - do not guess that a change works.


## The adoption plan register

The cross-repo plan for omni becoming the shared test-spec utility of
`voxgig/struct` and `voxgig/sekreto` (validated externally by
`senecajs/Sekreto`) lives in [`doc/plan/adoption.md`](doc/plan/adoption.md),
and its progress register in [`doc/plan/progress.md`](doc/plan/progress.md).
[`doc/plan/handover.md`](doc/plan/handover.md) carries what survives an
item landing - the open decisions and the lessons a migration left behind -
so they are not rediscovered from scratch.

**A work item's row in the register changes in the same commit that
changes its status.** For work landing in *this* repo that is a hard rule;
for rows tracking the other repos, update the row when the change merges
there, citing the PR. Do not let the register drift from reality - it is
the one place the whole goal is visible.


**Starting a session?** Read [`doc/plan/status.md`](doc/plan/status.md) first.
It says what is in flight, what is blocked on a human, and which known defects
have already been diagnosed. It is a live snapshot and is meant to be rewritten
or deleted as it goes stale; `handover.md` is the durable half.


## Where to look next

- Spec format and semantics: [`DOCS.md`](DOCS.md)
- Per-port specifics: `<lang>/README.md`
- The contract: [`spec/fib.aon`](spec/fib.aon) (compiled to
  [`spec/fib.json`](spec/fib.json) by `make spec`)
- The struct replacement path: [`DOCS.md`](DOCS.md#8-replacing-structs-in-situ-runners)
