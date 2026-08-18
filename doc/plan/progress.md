# The adoption progress register

Live status of [`adoption.md`](adoption.md). **A row changes in the same
commit that changes its status** for work landing in this repo; rows
tracking other repos are updated when the change merges there, citing the
PR. Statuses: `NOT STARTED`, `IN PROGRESS`, `DONE`, `DECIDED-NO` (with a
reason).

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
**1 of 24 migrated.** omni's struct-compat gate covers the
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
| typescript | NOT STARTED | Resolve `makeContext`/`contextify` drift + `ctx.utility`; coordinate with @voxgig/sdkgen first. |
| python | NOT STARTED | |
| go | NOT STARTED | |
| php | NOT STARTED | |
| ruby | NOT STARTED | |
| lua | NOT STARTED | |
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
| 2.2 Fix "all 22 ports" comment in `spec/def/resolve.aontu` | NOT STARTED | |

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
| 4.2 A1 sentinel soundness (`nullin`, `__RAW__`) | NOT STARTED | Default-flips ride a spec-version bump. |
| 4.3 A2 out/err/match composition | NOT STARTED | `err`+`out` rejection already landed with 4.1. |
| 4.4 A3 err semantics (`err:false`, structured err) | NOT STARTED | |
| 4.5 A4 `__EXACT__`/`__HAS__` match leaves | NOT STARTED | |
| 4.6 C2 group-coverage check (`runcheck` + static) | NOT STARTED | |
| 4.7 C3 skip/pending/only | NOT STARTED | Gated by a `requires` capability. |
| 4.8 C4 declarative unpacking (`DEF.subject.<name>.unpack`) | NOT STARTED | |
| 4.9 B-group naming coherence (aliases, strict section resolution, `options` short form) | NOT STARTED | |
| 4.10 Shape check: cross-field rules once aontu supports them | NOT STARTED | `must()` and `length()` are absent in aontu 0.48.2 (Band B / sizing atoms). When they land, move one-of in/args/ctx, err-with-out and non-empty-set into `spec/def/omni-spec.aontu` so a malformed spec fails at build, not only at test. |
| 4.11 Share the shape with downstream corpora | NOT STARTED | struct and sekreto author their own specs; decide how they import omni's shape across the local-checkout boundary (struct's corpus is legacy v0, so it needs a v0 variant or an opt-in). |
