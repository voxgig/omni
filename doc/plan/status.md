# Status — where the next session starts

Live snapshot, 2026-08-20. The register in [`progress.md`](progress.md) is the
per-item authority; this file says what is in flight right now, what is
blocked on a human, and what to pick up first. Update it at the end of a
session, or delete it once it goes stale — a wrong status file is worse than
none.


## In flight

| PR | State | What it is |
|---|---|---|
| [voxgig/omni#9](https://github.com/voxgig/omni/pull/9) | **green, 26/26** | Sentinels tested before the identity check in `match`. Canonical + all 22 ports + a `wrongundef` pin in each. Awaiting merge. |
| [voxgig/struct#86](https://github.com/voxgig/struct/pull/86) | **green, 120/120** | struct's python port off its 353-line in-situ runner. Awaiting merge. Takes struct to **2 of 24** migrated. |
| [voxgig/omni#7](https://github.com/voxgig/omni/pull/7) | open, stale | Docs-only, from an earlier session. **5 unresolved Codex threads, 2×P1.** See below. |

[voxgig/omni#8](https://github.com/voxgig/omni/pull/8) merged 2026-08-19: the
python compat shim, `voxgig_omni/compat/struct.py`.


## Pick up first

**1. Merge #9 and #86.** Both green, nothing outstanding on either. #86 should
merge first: it makes omni#7's P1 true rather than false (see below).

**2. Fix and merge omni#7.** Its P1 is correct — it flips struct's python row
to `IN PROGRESS` while nothing had merged in struct. Once #86 lands, python is
genuinely `DONE` and the row should say so, citing voxgig/struct#86. The three
P2s are cheap and correct: the note calls a zero-argument call *inexpressible*
when `args: []` already expresses it (the real gap is that *omitting* all three
fields defaults to one absent argument); it reports "99 of 100 passing" when
the breakdown is 96 passed, 3 skipped, 1 failed; and it claims `in: null`
passes a real null, which holds only under `{null: false}`. Do not resolve
those threads without making the edits — they have not been acted on.

**3. Continue the absence model.** Design and evidence:
[`../design/absence-model.md`](../design/absence-model.md). Next concrete step
is the `__RAW__` escape (register 4.2), because nothing can assert a literal
sentinel until it exists, and the model leans on markers.


## Blocked on a human, not on work

- **voxgig/station has no CI at all.** The workflow is parked in `ci/` because
  the authoring credential lacks the `workflow` OAuth scope. 16 ports and a
  40-entry conformance corpus are verified by nothing. Two commands, in
  `station/ci/README.md`. Cheapest high-value action in the programme.
- **omni `main` and struct `main` are both red** from external toolchain
  flakes — a six-hour `apt-get` hang on the `preinstalled` matrix (which
  carries no `timeout-minutes`), and a haskell-setup 503 that `fail-fast` amplified
  into three red legs. Neither is a code defect; both need a re-run. Adding
  `timeout-minutes: 15` to the preinstalled matrix turns a six-hour
  cancellation into a fast, obviously-infrastructural failure.
- **The `workflow` scope generally.** It blocked the `test-python` CI change on
  struct#86 (a maintainer applied it as f581a4f) and it is the same thing
  keeping station's CI parked. Worth clearing once at the org level.


## Known defects, recorded so they are not rediscovered

**In omni** — the three remaining sentinel-channel defects are in register
4.2's notes, with evidence.

**In voxgig/struct**, all pre-existing and all masked today:

- **struct/go silently skips corpus entries** on three predicates
  (`go/testutil/runner.go:160-195`), including a hardcoded comparison against
  the library constant `T_noval`. Roughly 108 of 1362 entry-executions are
  dropped with no report; its green suite overstates what it ran.
- **struct/csharp drops the 142 entries that carry no `out`**, and its `null`
  flag default is inverted (`csharp/tests/Runner.cs`).
- **struct/lua truncates calls.** `table.unpack({nil})` yields *zero* values,
  so a nil-valued argument slot silently shortens the call — and the match base
  then becomes `[]`, so a mutation assertion can pass while reporting a lie.
  Currently masked by the skip filter at `lua/test/runner.lua:96-105`; that
  filter goes away with the in-situ runner, so **fix this as part of the lua
  migration**, with an explicit `args.n` and `table.unpack(args, 1, args.n)`.
  Note omni/lua is *not* affected — it carries tagged `json.NULL`/`json.ABSENT`
  so no bare nil ever reaches the args list. Verified by probing all four
  spellings.

**Not a defect, but the thing that keeps biting:** struct's seventeen
zero-argument corpus entries are read **five** different ways by struct's own
runners — python passes zero args, typescript/php/go pass one absent value,
ruby passes its `UNDEF` sentinel, lua filters them out, and go additionally
skips one. Canonical settles it: `typify()` is `1073741824`,
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
- **The dev container lacks 9 of 23 toolchains** (clojure, scala, csharp,
  kotlin, zig, swift, dart, elixir, lean). `apt-get` works and is root, so
  lua5.4, ocaml, ghc and a JDK install in a couple of minutes and are worth
  installing — that takes local verification from 11 ports to 14.
- **`make test` cannot distinguish a missing toolchain from a real failure.**
  A pristine checkout reports `FAILED: lua csharp kotlin …` where every one is
  exit 127. Budget for the confusion, or check `command -v` first.
