# The adoption progress register

Live status of [`adoption.md`](adoption.md). **A row changes in the same
commit that changes its status** for work landing in this repo; rows
tracking other repos are updated when the change merges there, citing the
PR. Statuses: `NOT STARTED`, `IN PROGRESS`, `DONE`, `DECISION NEEDED`
(waiting on a call that is not the implementer's to make), `DECIDED-NO`
(with a reason).

What is in flight right now is in [`status.md`](status.md); the decisions and
lessons a landed item left behind are in [`handover.md`](handover.md).

## Phase 0 — make omni consumable and trustworthy

| Item | Status | Notes |
|---|---|---|
| 0.1 Local-checkout consumption documented (DOCS §8.3) | DONE | No publishing for now, by decision; `$OMNI_HOME` + sibling paths + gitignored per-language wiring, as in sekreto. |
| 0.2 Spec coverage: `context` group + `err.name` pin | DONE | All 23 ports run the `context` group (ctx + `contextify` + client-attach) and the `err.name` pin (voxgig/omni#5). Clojure's missing ctx-client attach and Python's NaN `deepequal`, both flagged by the 2026-08 review, surfaced and were fixed. |
| 0.3 DOCS/code reconciliation | DONE | inject mutation contract, `__EXISTS__` incl. null, error-path match base, `nullmodifier` in-string rewrite, sentinel reservation. |
| 0.4 Single-source `build-spec.js` (sekreto/struct call omni's) | NOT STARTED | sekreto's copy already needed synchronized fixes once. |
| 0.5 Pin the struct-compat CI checkout to a struct ref | NOT STARTED | Gate currently floats on struct's default branch. |

## Phase 1 — struct migration (per port)

Wire local checkout → provider adapter → import swap → delete
`<lang>/test/runner.*` → full suite green. One port per commit.
**6 of 24 migrated.** omni's struct-compat gate covers the
**JavaScript** swap only: it copies struct's `javascript/test` files,
rewrites both `require('./runner')` (not yet migrated) and
`require('./omni')` (migrated), and runs them under Node — so it holds
either side of *that* port's swap, and nothing more. No equivalent
cross-repo gate exists for the other ports; each one's own suite,
run before and after, is the check that its swap preserved behaviour.
Whether to add per-port gates is open — see 1.1 below.

| Port | Status | Notes |
|---|---|---|
| javascript | DONE | In-situ runner deleted; test/omni.js resolves the local checkout. 95/95 through the shim — the same 95 the old runner passed. Merged as voxgig/struct#84. |
| typescript | NOT STARTED | omni's side is ready — `typescript/compat/struct.ts` ships in voxgig/omni#8, resolving the `makeContext`/`contextify` drift (`contextify` first, `makeContext` as fallback). struct's own swap has not merged and no struct PR exists for it: `struct/typescript/test/runner.ts` is still the in-situ runner. @voxgig/sdkgen copies the version-stamped TS runner and needs the same swap. |
| python | DONE | In-situ runner deleted; `tests/omni.py` resolves the local checkout and re-exports omni's python compat shim. 100 tests, OK, 3 pre-existing skips — against the unmodified corpus. Merged as voxgig/struct#86 (CI wiring — the omni checkout and `OMNI_HOME` the `test-python` job lacked — applied by a maintainer as struct f581a4f). The swap turned on 4.12: the seventeen no-argument entries are kept at struct's python reading by `compat.struct.zeroargs`, in memory and for this port only (voxgig/omni#8). It also exposed a real port bug in `slice` — Python's `bool` is a subclass of `int` — fixed as voxgig/struct#85. |
| go | DONE | In-situ runner deleted — the 985-line `testutil/runner.go` — replaced by 187 lines across `testutil/omni.go` (omni's shim re-exported under struct's names), `sdkapi.go` (the types that name struct's own API, so the shim can reach it by reflection without importing it) and `helpers.go`; the test files are unchanged. omni is consumed as a sibling checkout via `go work init`, so `go.mod` gains no dependency. 105 subtests, 0 failures. Merged as voxgig/struct#89. The most expensive swap so far, and the one that proves the point of the programme: the in-situ runner **silently dropped 108 of 1362 entry-executions**, and two real library defects sat inside what it dropped (voxgig/struct#90 — `Transform` swallowed every error it collected, so `transform/format` never ran at all; and the port had no no-value, so `typify()` could not be expressed as distinct from `typify(null)`, `NOVAL` now being Go's). Eight further failures were the shim's own gap (voxgig/omni#13). struct/go's harness is now a **nested module**, so omni's import cannot reach `go build ./...` or be written into struct's published `go.mod` by `go mod tidy` — see 4.13. |
| php | DONE | The swap that was worth the most and looked the least like the others. This port's corpus tests never used a runner at all: they hand-rolled a loop over `$tests->set` that understood `in`, `args`, `err` and `out` and nothing else - no `ctx`, no `match`, no `client`, no NULL/UNDEF marks, no `null` flag - so a group needing any of those simply had no test method. **350 of 1395 entries never ran**, and *fifteen* test methods were `assertTrue(true)` behind a TODO, passing while asserting nothing. The 288-line `tests/Runner.php` is deleted; `tests/omni.php` resolves the local checkout and delegates to omni's shim (voxgig/omni#16), so `Runner::makeRunner` still works and `ClientTest` changed by one require line. Group list, per-group `null` flags and subject bindings now mirror `javascript/test/struct.test.js`, which caught four old bindings that quietly differed from it - `inject/string` passed a **no-op** modifier, which is why this port had never once exercised the modify hook. Entries executing: **1045 → 1349** (58 → 71 groups). Merged as voxgig/struct#92, which also carries **seventeen** library defects the swap surfaced - see 4.14 and the note below. |
| ruby | DONE | In-situ runner deleted — the 301-line `voxgig_runner.rb` — and `ruby/omni.rb` resolves the local checkout, presenting omni's shim under struct's own `VoxgigRunner` namespace; the test files change by one require line. 93 runs, 159 assertions, 0 failures — the same 93 the in-situ runner passed. Merged as voxgig/struct#88. Needed voxgig/omni#12 first: `undefargs` supplies `VoxgigStruct::UNDEF` for the seventeen implicit entries, the input-side peer of python's `zeroargs`; without it `minor/typify#10` was the single failure. |
| lua | DONE | In-situ runner deleted — the 554-line `test/runner.lua` — and `test/omni.lua` resolves the local checkout. 85 tests, 85 passing. Merged as voxgig/struct#94, on top of voxgig/struct#93 (the port's `NOVAL`) and voxgig/omni#17 + #19 (the shim). Entries executing: **1342 → 1352** over the same 72 groups — a net figure that hides the trade, and the trade is the interesting part. The old runner **skipped seventeen entries outright** ("Lua has no undefined value; skip entries where 'in' or 'out' is absent"), so the suite reported clean while never running them; sixteen of those fall in groups this port covers and now run, `typify()` among them. Six go the other way and are dropped **by entry, with guards**, because this port has ONE `nil` for both "returned nothing" and "returned JSON null" and the runner must read it one way. Measured entry by entry: reading it as null costs **43** (getprop 21 of 54, getelem 20 of 29 — every missing-key and out-of-range case, where canonical answers undefined), reading it as absent costs **6** (the genuine-null cases). Absent, therefore, and the six are named in struct/lua's own test file rather than four whole groups being marked pending, which would have cost ~150 more entries. The swap also surfaced a real port defect the in-situ runner could not see — `keysof`, `items`, `select` and `re_find_all` returned a bare `{}`, which by this port's own rules is a **map** (`ismap({})` is true, `islist({})` false) — because that runner compared both sides through the same dkjson round-trip. Two rocks left with it: `dkjson` and `luafilesystem`. |
| rust | NOT STARTED | |
| c | NOT STARTED | |
| csharp | NOT STARTED | |
| zig | NOT STARTED | |
| cpp | NOT STARTED | |
| perl | NOT STARTED | |
| swift | NOT STARTED | |
| clojure | NOT STARTED | |
| ocaml | NOT STARTED | |
| scala | NOT STARTED | |
| java | NOT STARTED | |
| kotlin | NOT STARTED | |
| dart | NOT STARTED | |
| elixir | NOT STARTED | |
| haskell | NOT STARTED | |
| lean | NOT STARTED | |
| boru | NOT STARTED | Decision needed: omni boru port, or documented in-situ exception. |

| Item | Status | Notes |
|---|---|---|
| 1.1 per-port compat gates | NOT STARTED | Only JavaScript has a cross-repo gate (`make struct-compat`). Decide whether each migrated port needs an equivalent, or whether its own suite passing before and after the swap is sufficient evidence. |

## Phase 2 — sekreto scaffolding retirement

| Item | Status | Notes |
|---|---|---|
| 2.1 Depend on omni's build-spec (drop local copy) | NOT STARTED | Pairs with 0.4. |
| 2.2 Fix "all 22 ports" comment in `spec/def/resolve.aontu` | NOT STARTED | sekreto has **10** ports (csharp, go, java, javascript, perl, php, python, ruby, rust, typescript). 22 is wrong on every reading — omni has 23 implementations, struct 24 with boru. |

## Phase 3 — senecajs/Sekreto validation use case

| Item | Status | Notes |
|---|---|---|
| 3.1 Contract decided and documented | NOT STARTED | Independent TS/JS Sekreto vs Seneca plugin wrapping @voxgig/sekreto. |
| 3.2 Scaffold replaced (name, README, URLs, src, tests) | NOT STARTED | Repo is still the SenecaConfig template. |
| 3.3 Vendored, pinned `spec/sekreto.json` + freshness check | NOT STARTED | |
| 3.4 omni consumed under jest via `OMNI_HOME` | NOT STARTED | First non-`node --test` consumer. |

## Phase 4 — spec-model improvements

Findings and rationale:
[`../design/model-review-2026-08.md`](../design/model-review-2026-08.md).

| Item | Status | Notes |
|---|---|---|
| 4.1 C1 versioning + strict validation + shape check | DONE | All 23 ports (voxgig/omni#5); `make parity` reports every port complete. Review found three defects — validation ran after null-normalisation, and three checks tested nullness where they had to test presence — both fixed and pinned by negative tests. 11 suites executed locally; the 12 ports whose toolchains are absent from the dev environment were verified by CI — all 26 checks on voxgig/omni#5 green, including every port job, `api parity`, `struct compatibility` and spec freshness. The format check is now aontu (`spec/def/omni-spec.aontu`) rather than JSON Schema: the shape is unified with each spec source, so it cannot drift from a second description of the format, and it drops the ajv dependency. Cross-field rules (one-of in/args/ctx, err-with-out, non-empty set) await aontu `must()`/`length()` — see 4.10. |
| 4.2 A1 sentinel soundness (`nullin`, `__RAW__`) | IN PROGRESS | One of the four channel defects closed: the sentinels are now tested **before** the identity check in `match`, in canonical and all 23 ports, each pinned by a `wrongundef` negative case (voxgig/omni#9). Previously a subject returning the literal `"__UNDEF__"` as data satisfied an assertion that the key was *absent* — two mutually exclusive states passing one check. Three defects remain, and they gate the absence model: no `__RAW__` escape (so a literal sentinel cannot be asserted at all — now stated in DOCS §2.5); `fixjson` rewriting real nulls in `args`/`in`/`ctx` to the string `"__NULL__"` before the subject sees them; and `__UNDEF__` meaning four different things across the shipped consumer runners (canonical requires a genuinely absent key, struct php and ruby also accept a present null, struct go accepts any zero value). |
| 4.3 A2 out/err/match composition | NOT STARTED | `err`+`out` rejection already landed with 4.1. |
| 4.4 A3 err semantics (`err:false`, structured err) | NOT STARTED | |
| 4.5 A4 `__EXACT__`/`__HAS__` match leaves | NOT STARTED | |
| 4.6 C2 group-coverage check (`runcheck` + static) | NOT STARTED | |
| 4.7 C3 skip/pending/only | NOT STARTED | Gated by the entry-level `needs:` field — **not** `requires`, which is already the top-level `OMNI.requires` capability list checked against `CAPABILITIES` in `Runner.ts`. Settled in `../design/absence-model.md`. |
| 4.8 C4 declarative unpacking (`DEF.subject.<name>.unpack`) | NOT STARTED | |
| 4.9 B-group naming coherence (aliases, strict section resolution, `options` short form) | NOT STARTED | |
| 4.10 Shape check: cross-field rules once aontu supports them | NOT STARTED | `must()` and `length()` are absent in aontu 0.48.2 (Band B / sizing atoms). When they land, move one-of in/args/ctx, err-with-out and non-empty-set into `spec/def/omni-spec.aontu` so a malformed spec fails at build, not only at test. |
| 4.11 Share the shape with downstream corpora | NOT STARTED | struct and sekreto author their own specs; decide how they import omni's shape across the local-checkout boundary (struct's corpus is legacy v0, so it needs a v0 variant or an opt-in). |
| 4.12 Zero-argument calls (model review A6) | **DECISION NEEDED** | An entry carrying none of `in`/`args`/`ctx` is called with one *absent* argument (`resolveargs` → `args = [clone(entry.in)]`, DOCS §2.2); struct's corpus uses that form to mean *no arguments*, in 17 of its 1397 entries. No longer blocking — struct's python swap landed with the reading preserved in-memory by `compat.struct.zeroargs` (voxgig/omni#8) — but the shim is per-port and does not scale. Zero effect on fib (0 implicit entries of 68) or sekreto (0 of 110); the 17 struct entries change their invoked argument list either way. Superseded in approach by [`../design/absence-model.md`](../design/absence-model.md): the portable spelling is `in: '__UNDEF__'`, not `args: []` (which shortens the argument vector and breaks five of nine fixed-arity adapters) and not a silent default. Rides the spec version bump; 4.2 is its prerequisite. lua is now the sixth port to answer it locally and the one that answers it most cheaply: omni-lua passes an explicit `ABSENT` sentinel (a Lua `nil` cannot be stored in a table), the shim trims a trailing absent argument, and the port sees the zero-arity call `select('#', ...)` can tell from `f(nil)` — peer of python's `zeroargs`, ruby's `undefargs`, go's `NOVAL` and php's stdClass singleton. Six per-port shims now carry this reading; the point that it does not scale stands. |
| 4.14 omni's php runner cannot express PHP reference semantics | **DECISION NEEDED** | omni's php port models maps as PHP **arrays**, which are values. Every other omni port gets reference semantics free - JS objects, Python dicts, Ruby hashes, Go maps are all handles - so PHP is the odd one out, and two corpus behaviours fall through the gap. **Empty maps**: `json_decode($json, true)` cannot tell `{}` from `[]`, and struct's corpus has 272 empty maps against fib's zero; solved at the shim boundary with a marker string (voxgig/omni#16). **In-place mutation**: `minor/setpath`'s nine entries assert, via `match.args`, that the store was mutated in place - an object store mutates and an array store does not, so the mutation is invisible to the runner, which holds a copy. That one CANNOT be solved at the boundary: the mutation has to be visible to omni itself, and `Util::getpath` returns Absent for an object. Marked incomplete in struct#92 rather than skipped silently. The fix is to make omni-php model maps as objects, which changes that port's value model for every consumer - hence a decision, not a task. **Sharpened by lua (voxgig/omni#19):** Lua tables are references, so the same nine `minor/setpath` entries **do** run there — but only after the shim was fixed to splice a mutated argument back into omni's own table in place, because `tostruct` had handed the subject a copy. So the mutation problem has two halves: a *value-model* half that only php has, and a *conversion* half that any shim re-tagging values at the boundary will have. The second is fixable at the boundary; php's first is not. |
| 4.13 Keep the omni import out of each port's *library* build | IN PROGRESS | A compiled port with a module system can leak the test-time dependency into what it publishes. struct/go did: the migration put `omni/go/compat/struct` in `go/testutil`, a normal package, so `go build ./...` compiled it - a fresh checkout with no sibling omni failed outright, and `go mod tidy` **succeeded**, resolving omni from the proxy (it is a public repo) and writing `require github.com/voxgig/omni/go` into the published `go.mod`. Fixed in voxgig/struct#89 by making the harness a nested module: `./...` in the parent skips it, so neither can happen. Caught in review, not by CI - **no port's CI checks this**, because CI always has the omni checkout. The open work is the other compiled ports with module systems (rust, java, kotlin, scala, csharp, swift, dart) as they swap: decide the equivalent isolation *before* the swap, and add a build-without-omni check so it is CI's job and not a reviewer's. |
| 4.15 A shim must not put its own `src/` on a consumer's module path | DONE | Found by the lua swap and **not** lua-specific. omni's `src/util.lua` and `src/runner.lua` used bare `require('json')`/`require('regex')`, so a consumer had to add omni's `src/` to `package.path` for the shim to load at all — and that **shadows the consumer's own modules of the same name**. omni ships `src/regex.lua`; so does struct/lua. With omni's `src/` ahead on the path, `struct.lua`'s own `require("regex")` fallback silently loaded *omni's* regex and `re_test`, `re_find`, `re_find_all`, `re_replace` and `re_escape` all became `nil` — five groups dying on "attempt to call a nil value", a message pointing nowhere near path resolution. Fixed in voxgig/omni#19: each module derives its own prefix from the name it was required under (`(...):match('^(.*%.)[^.]*$')`), so omni's harness keeps its bare requires and a consumer needs exactly one directory on the path. **The general rule for every remaining shim: resolve siblings relative to yourself, and have the consumer add one directory, appended not prepended.** Any language resolving imports by a search path the consumer also owns can hit this — python (`sys.path`), ruby (`$LOAD_PATH`), perl (`@INC`) — and the failure is silent shadowing, not an import error. |
