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

**`make test` skips any port listed in `HOLD` in the root `Makefile`** —
`boru` today, because its engine has no release channel and a mismatched
build fails as a bare `undefined word`. The sweep names what it skipped and
counts what it ran, so a held port cannot pass for a full run, and `make
test-boru` still exercises it. **CI is held too**, since 2026-09-04: the
`boru` job in `.github/workflows/ci.yml` runs only on a manual dispatch, so
nothing gates the port against a pinned engine on a push or a pull request.
Dispatching the workflow by hand still runs it.

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


## Release and publish

Twenty-four ports, **seven of which have a release route**. Those seven go
two different ways:

| ports | released by | tag |
| --- | --- | --- |
| `typescript/` → npm `@voxgig/omni`, `javascript/` → npm `@voxgig/omni-js` | `release.yml` — publish **and** tag | `<port>/v<version>` |
| `go`, `clojure`, `rust`, `dart`, `lean` | `tag.yml` — **the tag IS the release** | `<port>/v<version>` |

The second row has no registry: those ports are consumed by git ref (register
4.16, `DOCS.md` §8.3), so a release there is a tag and nothing else. That is
why it is not in `release.yml` — that file is registered with npm trusted
publishing against its **filename**, and nothing needing no registry
credential belongs near it.

**The other seventeen ports have no release route at all**, and that is
settled rather than pending. `swift` is deliberately excluded and *cannot* use
the tag scheme: SwiftPM loads a source-control dependency's manifest from the
repository ROOT, so serving `omni/swift` by ref would mean a `Package.swift`
at `/` and this polyglot repository reading as "a Swift package" to every
other consumer — and SwiftPM rejects a prefixed tag anyway, colliding with the
scheme Go mandates. The remaining sixteen have no published artifact of any
kind; **the checkout is their only route** (`DOCS.md` §8.3).

**The `<port>/` prefix is load-bearing.** Go resolves a subdirectory module's
version from `go/vX.Y.Z` and **ignores** every tag without the prefix. Cargo,
pub, tools.deps and Lake impose no rule and take the same shape for
consistency.

### Releasing

**Actions → release → Run workflow** on `main`, choosing the `port` — or
**Actions → tag** for a registry-less port, giving port and version.

**The two paths take their version from different places, and this is the
easiest thing here to get wrong:**

- `release.yml` reads the npm port's own `package.json`, so **bump it first in
  a reviewed PR** and dispatch afterwards.
- `tag.yml` does **not** read any manifest. The version is a required
  operator-typed input (`X.Y.Z`), and the tag is built straight from it as
  `<port>/v<version>`. There is nothing to bump beforehand — `go`, `clojure`
  and `lean` declare no package version anywhere, and `rust`'s `Cargo.toml`
  and `dart`'s `pubspec.yaml` do carry one that this workflow ignores. Read
  the last tag for that port and pick the next number deliberately.

`release.yml` also takes `allow_removals`. A release that would **remove**
files from the published package fails unless you say it is deliberate:
adding files is ordinary, silently dropping three source files is how a patch
release breaks consumers. `make pack-diff` is the same check by hand.

### Three jobs, each with the least it needs

npm binds a trusted publisher to a single workflow **filename**, so the tag
must live in the same file as the publish; they cannot be split across two
files, because a ref pushed with `GITHUB_TOKEN` starts no further workflow
run — "tag in A, publish on the tag" publishes nothing, silently. An
unregistered workflow's OIDC token is refused as **404, not 403**.

| job | holds | runs |
| --- | --- | --- |
| `build` | `contents: read` | install, build, tests, packaging checks — all project code and every dependency lifecycle script. Uploads the tarball. |
| `publish` | `id-token: write`, `contents: read` | downloads that tarball and publishes it. **No checkout at all.** |
| `tag` | `contents: write` | git, and nothing else. |

The `publish` job's `contents: read` is belt-and-braces: it never checks out,
so nothing there reads the repository, and the grant could be dropped. It is
listed because a permissions table that omits a grant is worse than no table —
anyone auditing the OIDC isolation from it would conclude the job holds no
repository credential at all.

`id-token: write` is a **job-level** grant — it reaches every process in the
job — so a compromised `postinstall` during `npm install` could mint a publish
credential. The publish job therefore never checks out the repository.

### Irreversible

- **npm never allows republishing a version.** If a run publishes then fails
  before tagging, re-dispatch: the registry check skips the completed publish
  and retries the tag.
- **A Go tag cannot be taken back.** `proxy.golang.org` and `sum.golang.org`
  cache a version permanently; moving or deleting the tag reaches users as a
  **security error**, not a missing version. Withdrawal is only via `retract`
  in a NEW version — a Go directive, so this remedy is Go's alone.
- **The other four tag ports have no such proxy**, so a `clojure`, `rust`,
  `dart` or `lean` tag can technically be moved or deleted. Do not treat that
  as a licence to: anyone who pinned the ref silently gets different code, and
  no `retract` equivalent exists to tell them. Bump to the next version
  instead; the difference from Go is who finds out, not whether it is safe.

`voxgig/apidef`'s `docs/how-to/release-and-tag.md` carries the fullest
write-up of the shared design.


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
