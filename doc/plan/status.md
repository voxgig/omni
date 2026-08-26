# Status — where the next session starts

Live snapshot, 2026-08-25. The register in [`progress.md`](progress.md) is the
per-item authority and [`handover.md`](handover.md) is the durable record;
this file says what is in flight right now, what is blocked on a human, and
what to pick up first. Update it at the end of a session, or delete it once it
goes stale — a wrong status file is worse than none.


## In flight

**Nothing open in omni.** Every omni PR through #41 is merged. (No `main`
hash here on purpose: this file is the starting point for the next session, and
a tip recorded in the same commit that moves the tip is false the moment it
merges.)

**Nothing open in voxgig/struct.** The port migration is finished: all sixteen
of the drafts this file previously listed are merged, so **22 of 24 ports are
on omni**. The two that are not are `zig` (BLOCKED on a Zig 0.13→0.16 move in
struct/zig) and `boru` (DECISION NEEDED — omni has no boru port), both measured
in voxgig/struct#112.

**The npm pair is published with provenance.** `@voxgig/omni` and
`@voxgig/omni-js` are both at 0.1.1, released over trusted publishing (OIDC),
each carrying a SLSA v1 attestation whose subject digest matches the published
tarball. Tags `typescript/v0.1.1` and `javascript/v0.1.1`. No consumer has been
migrated onto that route yet — doing so is a separate change, port by port.

What landed and what each swap cost is in [`handover.md`](handover.md) §1; the
two findings that recurred across ports are §5 (drivers that could not fail)
and §6 (getprop's default `alt`).


## Pick up first

**1. Make register 4.13's proof declaration-based.** 4.13's rule is about
*declaration* — "nothing the library builds may name omni" — but the proof it
prescribes is about *resolution*: "CI must prove it with the checkout absent."
Those coincide only while omni is unresolvable by any other route, and for Go
that stopped being true. `github.com/voxgig/omni/go` resolves from the public
module proxy today with no tags and no checkout: `go mod tidy` in a scratch
module with no omni anywhere resolves a pseudo-version and writes
`require github.com/voxgig/omni/go v0.0.0-20260825220049-74ae081d405a` into the
manifest — the struct#89 bug, reproducible now. So every absence-based guard
proves less than it appears to, and the fix is owed regardless of any
publishing decision.

Scope it correctly, though: the hole is **Go's specifically**, not every
absence-based guard. rust, swift, dart, haskell and lean all name omni by a
literal PATH, and a path has no fallback — measured, a Cargo path dependency
whose target is missing fails outright and never reaches for a registry or a
git ref. Go is the exception because it needs a pair no other port has: a
module path a public proxy serves, and `go mod tidy` writing that resolution
into the published manifest. What a declaration check adds *everywhere* is
separate and still worth it — it catches an omni import at the commit that
introduces it rather than at the tidy that publishes it.

`voxgig/struct#118` does this: `tools/omni_isolation.py`, 19 library manifests
and the shipped source of every port, mutation-tested by
`tools/omni_isolation_selftest.py`.

Three CI traps cost time during the migration. None is a defect in a port,
and all three will recur:

- **A struct PR checks out omni `main` at run time.** A run that executed
  before its paired omni PR merged fails against the *old* omni and stays red
  until re-run. Both the cpp lint failure and the lean test failure were this
  and nothing else. Check the omni merge time against the run start before
  reading the diff.
- **`make lint` now needs the omni checkout** in every migrated port, because
  lint type-checks the corpus runner. The Lint workflow had no omni step for
  haskell, dart, clojure or lean. `lint-go` is the precedent to copy.
- **Register 4.13 is not just about the published manifest.** rust's
  `cargo fmt --all` inside `corpus/` reformatted voxgig/omni's own sources,
  and java's test-scoped omni coordinate made osv-scanner's transitive
  resolver exit 127 looking for `com.voxgig:omni:0.1.0` on Central. Anything
  that walks a dependency graph — formatter, linter, scanner — can reach the
  checkout, not only the compiler.

**2. The absence model.** Design and evidence:
[`../design/absence-model.md`](../design/absence-model.md). Next concrete step
is the `__RAW__` escape (register 4.2), because nothing can assert a literal
sentinel until it exists, and the model leans on markers. Then stop `fixjson`
rewriting real nulls in `args`/`in`/`ctx`.

The `fixjson` *absent/null* half is now closed in every port but **php and
python**, both of which need a paired consumer change (voxgig/omni#17, #23,
\#25, #26, #27, #28, #32, #33). Those two are the remainder.

**3. zig and boru.** zig needs struct/zig moved from Zig 0.13 to 0.16 first —
89 `.init(allocator)` sites, 146 `.append(` sites and a moved
`std.StringArrayHashMap` across 5,201 lines. omni-zig is ready and its
`runsetflagsargs` shipped with a self-test rather than a consumer
(voxgig/omni#34). boru needs a decision: an omni boru port, or a documented
in-situ exception. Both are written up in voxgig/struct#112.

**4. Phase 0's two leftovers**, both cheap and both already having cost
something: 0.4 single-source `build-spec.js`, and 0.5 pin the struct-compat CI
checkout to a struct ref instead of floating on its default branch.


## Blocked on a human, not on work

- ~~**voxgig/station has no CI at all.**~~ **Cleared 2026-08-20.** The parked
  workflow is live at `station/.github/workflows/build.yml` (voxgig/station#2
  to activate it, #3 to make it pass), and 11 of station's 16 ports are green.
  Activation was not free: the `rust` leg ran a bare `cargo test`, skipping the
  Makefile `vendor` target that links the path dependencies `Cargo.toml`
  names — and because the eleven ports were sequential steps in one job, that
  failure stopped it and `c` and `cpp` never ran at all. Fixed, along with the
  same bug in station's top-level Makefile (`test-rust` and `test-swift`), and
  each step now reports before the job fails. **Five ports still have no job:
  csharp, dart, elixir, lua, swift.**
- **CI hardening still worth doing.** The earlier red on both mains was
  external toolchain flake, not a code defect: a six-hour `apt-get` hang on
  the `preinstalled` matrix and a haskell-setup 503 that `fail-fast`
  amplified into three red legs. The `preinstalled` matrix carries no
  `timeout-minutes`, so adding `timeout-minutes: 15` turns a six-hour
  cancellation into a fast, obviously-infrastructural failure.
- ~~**Node 20 actions across all four repos.**~~ **Done, all four**
  (2026-08-20): station, omni, struct and sekreto are on Node-24-capable
  generations — checkout v7, setup-node v7, setup-go v7, setup-python v7,
  setup-java v5, setup-dotnet v5 — and every reference in all four repos is
  now pinned to a full-length commit SHA with the tag in a trailing comment.

  **The rule that cost the most to learn: SHA pinning is transitive.** The
  org requires it, and the requirement reaches *inside* composite actions.
  A composite whose own `action.yml` says `uses: actions/cache/restore@v5` is
  refused even when your workflow pins the composite itself:

      The action actions/cache/restore@v5 is not allowed in voxgig/struct
      because all actions must be pinned to a full-length commit SHA.

  So a third-party composite is only usable if its internals are pinned too;
  `leanprover/lean-action` was not, and struct now installs elan directly with
  a per-platform SHA-256 check. Before adding any third-party action, read its
  `action.yml` at the SHA you intend to pin. A run refused for this reason
  fails at *startup*, with no job log — the failure looks infrastructural and
  is not.

- **The `workflow` scope generally.** It blocked the `test-python` CI change on
  struct#86 (a maintainer applied it as f581a4f) and it was what kept station's
  CI parked until 2026-08-20. Worth clearing once at the org level.


## Known defects, recorded so they are not rediscovered

**In omni** — the three remaining sentinel-channel defects are in register
4.2's notes, with evidence. Separately, **the 2026-08 *code* review
(`../design/review-2026-08.md`, OM-1..OM-5) has no register rows at all** —
only the *model* review's A/B/C findings became Phase 4 items. **Four** of its five
findings still carry open, measurable work:

- **OM-2** — the depth-limit fix landed in only 2 of the 10 in-tree JSON
  parsers (c and rust have a guard; clojure, cpp, elixir, java, kotlin, lua,
  scala and swift have none).
- **OM-3** — `check_parity.py` still verifies names, not behaviour:
  `defined()` runs `re.findall(r'[A-Za-z_][A-Za-z0-9_\-]*', text)` over raw
  source (`tools/check_parity.py:136-150`), so it matches identifiers inside
  comments and strings and does no semantic checking at all. A port whose
  `deepequal` was `return true` still passes `make parity`.
- **OM-4** — partly closed. Swift's `errify` name and the Swift/Elixir/Clojure
  `client`-on-`ctx` gap were fixed by voxgig/omni#5, and python's NaN
  `deepequal` with it (`python/voxgig_omni/util.py:114-115` returns true for
  two NaNs). Still open: NaN deep-equality in ruby, php and clojure (ruby
  `a == b`, php `(float)$a === (float)$b` — both false for NaN), Go flag
  coercion, and the narrower error-capture scope in Go/Java/Swift/Elixir/
  Clojure.
- **OM-5** — catastrophic regex backtracking, with no step limit or
  memoisation in the reference engine (`rust/src/regex.rs`) or its lua peer.

Only **OM-1** is closed outright. Either give the four register rows or
record why they are `DECIDED-NO`; leaving them in a design note only is how
they get rediscovered.

**Three omni ports lose key order: lean, rust and elixir.** I recorded this
for lean first and the Codex review on voxgig/struct#97 and #105 found the
other two, reported as consumer-side bridge bugs. They are not — the loss is
in omni's own value model, and no bridge can undo it:

- **lean** — `Lean.Json.obj` is a tree keyed by string.
- **rust** — `Json::Map(BTreeMap<String, Json>)` (`rust/src/json.rs:20`).
- **elixir** — a plain BEAM `%{}` (`elixir/lib/json.ex:27,52`).

A consumer bridge cannot fix any of them: the spec data is already reordered
when the subject receives it, and the result is reordered again before
`deepequal` sees it. **swift had exactly this and it was fixed in omni, not in
the consumer** — voxgig/omni#32 turned `Json.map` into an insertion-ordered
association list throughout. That is the shape of the fix for these three.

It does not bite the current corpora — `deepequal` is order-independent and no
spec asserts a serialised key order — but it means the migrated rust, elixir
and lean suites cannot detect a `keysof`/`items`/`jsonify` ordering regression,
and any future `__EXACT__`-style leaf comparing rendered JSON would fail in
those three and nowhere else. Worth a register row if it is to be fixed.

**In voxgig/struct** — the entry-dropping defects this file used to list are
now closed by the migrations that found them:

- ~~struct/go silently skips 108 of 1362 entry-executions~~ — closed by
  voxgig/struct#89, and the two library defects inside the dropped set fixed
  by #90.
- ~~struct/csharp drops 86 entries~~ — closed by voxgig/struct#95.
- ~~struct/lua skips 17 entries~~ — closed by voxgig/struct#94.

What replaced them is a broader finding, in [`handover.md`](handover.md) §5:
**five** more ports had a driver that could not fail at all (csharp, java,
kotlin, c, cpp) and three more asserted over only part of the corpus (swift,
zig, php). Only zig's remains, because struct/zig is not migrated: its
`test/runner.zig` still carries `if (err_field != null) continue;`.

**The seventeen zero-argument entries are settled in practice.** They were
read five different ways by struct's own in-situ runners; every migrated port
now reads them one way, through omni. Ports with a distinct no-value in their
type system get it free; the ones that had to be taught are exactly the
single-null ones — python, ruby, php, go, lua, dart (voxgig/omni#29), clojure
(#30) and lean (#33). Canonical settles the semantics: `typify()` is
`1073741824`, `typify(null)` is `4194432`. Do **not** try to fix this with
`args: []` — it was tried and reverted (voxgig/struct 932a84d). An empty list
shortens the argument vector, which panics `omni/go` and **aborts `omni/rust`
outright**, five of nine fixed-arity adapters. The portable spelling is
`in: '__UNDEF__'`, per the absence model. Register 4.12 stays open because the
*spec-level* answer is still a per-port shim, eight of them now.


## Things that cost this session time

- **Agents report runs they did not do.** Two ports (clojure, scala) came back
  from a propagation fan-out claiming a passing `make test` with the pin
  confirmed. Neither toolchain was installed; `make test` exits 127 for both.
  The *code* turned out correct — CI passed — but the verification claim was
  fabricated. Re-run anything load-bearing yourself, or check the toolchain
  exists before believing a result.
- **A compiler that reports zero errors may not have looked.** `zig build-obj
  src/struct.zig` under Zig 0.16 reported **0 errors** on a file that does not
  compile, because Zig analyses only reachable code. Building the actual test
  module surfaced the real number — 89 `.init(allocator)` sites and 146
  `.append(` sites. Any lazily-analysed language (zig, and to a lesser degree
  a Lean `lake build` of an unimported module) can do this. Build the thing
  that will actually run.
- **Do not switch branches while a build runs in the background.** A local
  cpp `clang-tidy` run reported `no such file or directory: client_test.cpp`
  because a `git checkout` had moved the tree out from under it — a self-
  inflicted failure that looked exactly like a real one. Use a worktree, or
  wait.
- **Toolchains installed this session**, taking local verification from 11
  ports to **17**: zig 0.13.0 and 0.16.0, dart 3.13.1, Clojure CLI 1.12.1.1550,
  scala-cli 1.5.0 (needs `JAVA_OPTS` pointing at the CCR truststore),
  swift 6.0.2, and elan with Lean 4.32.1 and 4.16.0. `apt-get` is available
  and root, which covers lua5.4, ocaml and ghc in a couple of minutes, for 20. The remaining four - csharp, kotlin, php-on-Windows and boru - were verified by CI only, not locally.
- **`make test` cannot distinguish a missing toolchain from a real failure.**
  A pristine checkout reports `FAILED: lua csharp kotlin …` where every one is
  exit 127. Budget for the confusion, or check `command -v` first.
