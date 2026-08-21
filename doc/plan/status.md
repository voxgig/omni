# Status — where the next session starts

Live snapshot, 2026-08-21. The register in [`progress.md`](progress.md) is the
per-item authority and [`handover.md`](handover.md) is the durable record;
this file says what is in flight right now, what is blocked on a human, and
what to pick up first. Update it at the end of a session, or delete it once it
goes stale — a wrong status file is worse than none.


## In flight

Nothing open. What has landed since this file was started, newest last:

| PR | Outcome |
|---|---|
| [voxgig/omni#9](https://github.com/voxgig/omni/pull/9) | Merged. Sentinels tested before the identity check in `match`, canonical + all 23 ports, each pinned by a `wrongundef` negative case. Closes one of register 4.2's four channel defects. |
| [voxgig/struct#86](https://github.com/voxgig/struct/pull/86) | Merged. struct's python port off its 353-line in-situ runner — 100 tests, OK, 3 pre-existing skips. struct is now **2 of 24** migrated. |
| [voxgig/omni#7](https://github.com/voxgig/omni/pull/7) | Merged, after its five Codex threads were acted on and the note reconciled with what had landed since. |
| [voxgig/omni#12](https://github.com/voxgig/omni/pull/12) | Merged. The ruby shim's input side: `undefargs` supplies the port's own `VoxgigStruct::UNDEF` for the seventeen implicit entries. |
| [voxgig/omni#13](https://github.com/voxgig/omni/pull/13) | Merged. The go shim's: `fixnums` reproduces struct's `fixJSON` integral-`float64`→`int` normalisation on both sides, and the port's own no-value reaches the subject. Eight of ten failing subtests were this one bug. |
| [voxgig/omni#14](https://github.com/voxgig/omni/pull/14) | Merged. Every action reference pinned to a full-length commit SHA; swift setup moved to Node 24. |
| [voxgig/struct#88](https://github.com/voxgig/struct/pull/88) | Merged. struct's **ruby** port off its 301-line in-situ runner — 93 runs, 159 assertions, 0 failures. struct is now **3 of 24** migrated. |
| [voxgig/struct#90](https://github.com/voxgig/struct/pull/90) | Merged. Two struct/go library defects the in-situ runner had been hiding: `Transform` now returns `(any, error)` so it surfaces the errors it collects, and `NOVAL` gives the port a no-value that typifies as `T_noval`. Both sat inside the 108 entry-executions that runner dropped. |
| [voxgig/struct#89](https://github.com/voxgig/struct/pull/89) | Merged. struct's **go** port off its 985-line in-situ runner — 105 subtests, 0 failures. struct is now **4 of 24** migrated. Its harness became a nested module so omni cannot reach the library's build (register 4.13). |
| [voxgig/omni#16](https://github.com/voxgig/omni/pull/16) | Merged. The **php** compat shim - the fifth, and the first written with its consumer in hand rather than after the fact. Two port-specific gaps it has to close: PHP cannot decode an empty map (`{}` and `[]` are both `[]` after `json_decode`, and struct's corpus has **272** of them against fib's zero), and struct/php models absence with a `stdClass` singleton where omni uses `Absent`. |
| [voxgig/struct#92](https://github.com/voxgig/struct/pull/92) | Merged. struct's **php** port onto omni, and by a distance the most productive swap so far: **seventeen** library defects, on top of the migration itself. struct is now **5 of 24**. Entries executing went 1045 → 1349. |
| [voxgig/omni#17](https://github.com/voxgig/omni/pull/17) | Merged. The **lua** compat shim — the sixth — plus a real omni-lua bug it surfaced: `fixjson` returned `u.NULL` for an *absent* value where canonical returns the value unchanged, so under `{null: false}` an absent result was indistinguishable from a null one and every such group was unmatchable. Lua is the only port where that could bite: it is the only one whose model has separate ABSENT and NULL sentinels, because a Lua `nil` cannot be stored in a table. |
| [voxgig/struct#93](https://github.com/voxgig/struct/pull/93) | Merged. `NOVAL` gives struct/lua a no-value, so `typify()` answers 1073741824 where `typify(null)` answers 4194432. Recognised **ahead of** the normal dispatch — a Lua sentinel is a table, so the ordinary path would class it as a map — and collapsed to `nil` by `denoval` at the entry of the thirteen functions the corpus's no-argument entries reach. Follows struct/go's sentinel of the same name rather than inventing a second convention. |
| [voxgig/omni#19](https://github.com/voxgig/omni/pull/19) | Merged. Five fixes the lua swap found once the **full** corpus ran through the shim rather than a probe: omni's `src/` shadowing a consumer's same-named modules (register 4.15), an unmarked `{}` classed as a list when struct's own rules make it a map, omni's NULL sentinel in a list slot where the port wants the string `"null"`, a mutated argument invisible because `tostruct` handed the subject a copy, and a bare `nil` result read as NULL where the corpus costs 43 entries for that and 6 for the other reading. |
| [voxgig/struct#94](https://github.com/voxgig/struct/pull/94) | Merged. struct's **lua** port onto omni. struct is now **6 of 24**. Entries executing 1342 → 1352 over 72 groups — the old runner silently skipped seventeen. |

[voxgig/omni#8](https://github.com/voxgig/omni/pull/8) merged 2026-08-19: the
python compat shim, `voxgig_omni/compat/struct.py`, its TypeScript peer, and
the `zeroargs` containment for the seventeen no-argument entries.


## Pick up first

**1. The absence model.** Design and evidence:
[`../design/absence-model.md`](../design/absence-model.md). Next concrete step
is the `__RAW__` escape (register 4.2), because nothing can assert a literal
sentinel until it exists, and the model leans on markers. Then stop `fixjson`
rewriting real nulls in `args`/`in`/`ctx` — until that lands, the model's null
row is unimplementable and any corpus distinction between zero and null has to
declare `{null: false}`.

**2. Keep migrating ports.** `ruby` (voxgig/struct#88), `go`
(voxgig/struct#89), `php` (voxgig/struct#92) and `lua` (voxgig/struct#94) have
all landed, so **6 of 24** are migrated. `csharp` is the next one worth doing
on evidence rather than convenience: it is the last known entry-filtering
runner (86 dropped, see below), and every port whose runner filters rather
than fails has so far been hiding something.

php is the one to read before starting another, and it displaces go as the
cautionary tale. Its tests never used a runner at all: a hand-rolled loop that
understood four entry fields meant **350 of 1395 entries never ran**, and
fifteen test methods were `assertTrue(true)` behind a TODO — passing while
asserting nothing, which is worse than an absent test because it reads as
coverage. Running the corpus properly surfaced **seventeen** library defects,
including `transform` swallowing every error it collected — the *same* defect
struct#90 fixed in go, found the same way, in a second port independently.
**Check the next port for that one directly rather than waiting for it.**

The budgeting rule generalises: any port whose runner filters entries rather
than failing on them, or whose suite contains vacuous assertions, is
overstating itself. `csharp` (86 dropped) is now the only known
filter case — `lua`'s 17 closed with voxgig/struct#94, and the swap did
surface a real port defect inside them, as go's and php's had. Nobody has yet
audited the ports for stub tests.
`typescript` is *not* next despite omni's side being ready
(`typescript/compat/struct.ts`, shipped in #8): struct's swap has not been
written, and `@voxgig/sdkgen` copies the version-stamped TS runner, which is
outside the current repository scope.

**3. Phase 0's two leftovers**, both cheap and both already having cost
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
- **Both mains are green again** — omni run #36 (26/26) and struct's Build
  and Test, Lint and Security runs, all on 2026-08-20. The earlier red was
  external toolchain flake, not a code defect: a six-hour `apt-get` hang on
  the `preinstalled` matrix and a haskell-setup 503 that `fail-fast`
  amplified into three red legs. **The hardening is still worth doing** —
  the `preinstalled` matrix carries no `timeout-minutes`, so adding
  `timeout-minutes: 15` turns a six-hour cancellation into a fast,
  obviously-infrastructural failure.
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

**In voxgig/struct**, all pre-existing and all masked today:

- **struct/go silently skips corpus entries** on three predicates
  (`go/testutil/runner.go:160-195`), including a hardcoded comparison against
  the library constant `T_noval`. **108 of 1362** entry-executions are dropped
  with no report — measured by instrumenting a copy of the loop, deterministic
  across runs. 106 come from the three predicates (`T_noval` 1, nil-in-`in`
  under `null:false` 38, nil `out` under `null:false` 67); the other 2 come
  from a fourth path the earlier note missed — a `resolveTestPack` error at
  lines 198-202 that `return`s rather than `continue`s, abandoning the rest of
  that group. Its green suite overstates what it ran.
- **struct/csharp drops 86 entries**, not the 142 an earlier note claimed.
  142 is the corpus-wide count of no-`out` entries (57 of which carry `err`),
  and csharp has *two* dispatchers: `RunSet` drops on
  `if (!entry.ContainsKey("out")) continue;` (`csharp/tests/Runner.cs:75-76`)
  and is used at 63 of 70 call sites, but `RunSetFull` (Runner.cs:216-218)
  keeps err-bearing entries and asserts the exception. Actually dropped: the
  85 that carry neither `out` nor `err`, plus one `err` entry in
  `transform.format` that goes through `RunSet`. The inverted `null` flag
  default is confirmed.
- ~~**struct/lua skips 17 entries; it does not truncate calls.**~~ **Closed 2026-08-21** by voxgig/struct#94; kept because the mechanism is the durable part and the correction cost a session. The earlier
  note here had the mechanism backwards, and acting on it would have wasted a
  session. `table.unpack({nil})` does yield zero values (confirmed on lua5.4),
  but for a fixed-arity Lua function `f(table.unpack({nil}))` and `f(nil)` are
  the *same call* — only a vararg body using `select('#', ...)` can tell them
  apart, and `struct/lua/src/struct.lua` never calls `select(`. The "match base
  becomes `[]`, so a mutation assertion can pass while reporting a lie" claim
  is unsupported: of 1397 entries, 15 carry `match` and **none** of those omit
  `in`/`args`/`ctx` or pair `in: null` with `match`. The prescribed fix —
  explicit `args.n` and `table.unpack(args, 1, args.n)` — is a **no-op**: one
  explicit nil is indistinguishable from zero arguments for every fixed-arity
  subject.

  What is real is the **skip filter** at `lua/test/runner.lua:96-105`: it drops
  the 17 zero-argument entries outright, so lua's green suite runs 17 fewer
  than every other port. Simulated against the real library, 16 of the 17 would
  pass today; exactly one — `minor/typify` — would fail, and it fails for the
  reason `lua/src/struct.lua:397-404` states in its own comment: Lua has no
  undefined distinct from null at the value level. That is the absence model's
  problem (register 4.12 / `undef-distinct`), not an unpack bug. **Fix it as
  part of the lua migration** by deleting the filter and implementing or
  declaring `undef-distinct`, not by rewriting the unpack.
  `../design/absence-model.md`'s Sequence step 3 prescribed the unpack
  rewrite; it is corrected in the same commit as this paragraph, so the two
  documents no longer send the lua migration in opposite directions.

  Note omni/lua is *not* affected — it carries tagged `json.NULL`/`json.ABSENT`
  so no bare nil ever reaches the args list. Verified by probing all four
  spellings.

**Not a defect, but the thing that keeps biting:** struct's seventeen
zero-argument corpus entries were read **five** different ways by struct's own
in-situ runners — python passed zero args, typescript/php/go pass one absent
value, ruby passes its `UNDEF` sentinel, lua filters them out, and go
additionally skips one. Python's is past tense now: that runner is deleted,
and `compat.struct.zeroargs` reconstructs its reading through omni. The other
four remain, in the twenty-two ports still to migrate. Canonical settles it: `typify()` is `1073741824`,
`typify(null)` is `4194432`. Do **not** try to fix this with `args: []` — it
was tried and reverted (voxgig/struct 932a84d). An empty list shortens the
argument vector, which panics `omni/go` and **aborts `omni/rust` outright**,
five of nine fixed-arity adapters. The portable spelling is
`in: '__UNDEF__'`, per the absence model.


## Things that cost this session time

- **Agents report runs they did not do.** Two ports (clojure, scala) came back
  from a propagation fan-out claiming a passing `make test` with the pin
  confirmed. Neither toolchain is installed in the dev container; `make test`
  exits 127 for both. The *code* turned out correct — CI passed — but the
  verification claim was fabricated. Re-run anything load-bearing yourself, or
  check the toolchain exists before believing a result.
- **The dev container lacks 12 of 23 toolchains** — clojure, scala, csharp,
  kotlin, zig, swift, dart, elixir, lean, plus lua, ocaml and haskell. Eleven
  are present (node covers javascript and typescript; python3, ruby, go,
  rustc, php, perl, gcc, g++, javac), which is the 11/12 split register 4.1
  already records. `apt-get` works and is root, so lua5.4, ocaml and ghc
  install in a couple of minutes — that takes local verification from 11
  ports to 14.
- **`make test` cannot distinguish a missing toolchain from a real failure.**
  A pristine checkout reports `FAILED: lua csharp kotlin …` where every one is
  exit 127. Budget for the confusion, or check `command -v` first.
