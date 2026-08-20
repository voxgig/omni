# Status — where the next session starts

Live snapshot, 2026-08-20. The register in [`progress.md`](progress.md) is the
per-item authority and [`handover.md`](handover.md) is the durable record;
this file says what is in flight right now, what is blocked on a human, and
what to pick up first. Update it at the end of a session, or delete it once it
goes stale — a wrong status file is worse than none.


## In flight

Nothing. The three open items at the last snapshot have all landed:

| PR | Outcome |
|---|---|
| [voxgig/omni#9](https://github.com/voxgig/omni/pull/9) | Merged. Sentinels tested before the identity check in `match`, canonical + all 23 ports, each pinned by a `wrongundef` negative case. Closes one of register 4.2's four channel defects. |
| [voxgig/struct#86](https://github.com/voxgig/struct/pull/86) | Merged. struct's python port off its 353-line in-situ runner — 100 tests, OK, 3 pre-existing skips. struct is now **2 of 24** migrated. |
| [voxgig/omni#7](https://github.com/voxgig/omni/pull/7) | Merged, after its five Codex threads were acted on and the note reconciled with what had landed since. |

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

**2. Get struct's CI wiring un-blocked, then keep migrating ports.** `go` and
`ruby` are the natural next swaps — toolchains present, no external coupling.
`typescript` is *not* next despite omni's side being ready
(`typescript/compat/struct.ts`, shipped in #8): struct's swap has not been
written, and `@voxgig/sdkgen` copies the version-stamped TS runner, which is
outside the current repository scope.

**3. Phase 0's two leftovers**, both cheap and both already having cost
something: 0.4 single-source `build-spec.js`, and 0.5 pin the struct-compat CI
checkout to a struct ref instead of floating on its default branch.


## Blocked on a human, not on work

- **voxgig/station has no CI at all.** The workflow is parked in `ci/` because
  the authoring credential lacks the `workflow` OAuth scope. 16 ports and a
  40-entry conformance corpus are verified by nothing. Two commands, in
  `station/ci/README.md`. Cheapest high-value action in the programme.
- **Both mains are green again** — omni run #36 (26/26) and struct's Build
  and Test, Lint and Security runs, all on 2026-08-20. The earlier red was
  external toolchain flake, not a code defect: a six-hour `apt-get` hang on
  the `preinstalled` matrix and a haskell-setup 503 that `fail-fast`
  amplified into three red legs. **The hardening is still worth doing** —
  the `preinstalled` matrix carries no `timeout-minutes`, so adding
  `timeout-minutes: 15` turns a six-hour cancellation into a fast,
  obviously-infrastructural failure.
- **The `workflow` scope generally.** It blocked the `test-python` CI change on
  struct#86 (a maintainer applied it as f581a4f) and it is the same thing
  keeping station's CI parked. Worth clearing once at the org level.


## Known defects, recorded so they are not rediscovered

**In omni** — the three remaining sentinel-channel defects are in register
4.2's notes, with evidence. Separately, **the 2026-08 *code* review
(`../design/review-2026-08.md`, OM-1..OM-5) has no register rows at all** —
only the *model* review's A/B/C findings became Phase 4 items. Two of its
findings are still open and measurable: **OM-2**, where the depth-limit fix
landed in only 2 of the 10 in-tree JSON parsers (c and rust have a guard;
clojure, cpp, elixir, java, kotlin, lua, scala and swift have none), and
**OM-5**, catastrophic regex backtracking, with no step limit or memoisation
in the reference engine (`rust/src/regex.rs`) or its lua peer. Either give
them register rows or record why they are `DECIDED-NO`; leaving them in a
design note only is how they get rediscovered.

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
- **struct/lua skips 17 entries; it does not truncate calls.** The earlier
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
