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
| 0.2 Spec coverage: `context` group + `err.name` pin | IN PROGRESS | Canonical + spec landed; 13 of 23 ports propagated (voxgig/omni#5), 10 in flight. |
| 0.3 DOCS/code reconciliation | DONE | inject mutation contract, `__EXISTS__` incl. null, error-path match base, `nullmodifier` in-string rewrite, sentinel reservation. |
| 0.4 Single-source `build-spec.js` (sekreto/struct call omni's) | NOT STARTED | sekreto's copy already needed synchronized fixes once. |
| 0.5 Pin the struct-compat CI checkout to a struct ref | NOT STARTED | Gate currently floats on struct's default branch. |

## Phase 1 — struct migration (per port)

Wire local checkout → provider adapter → import swap → delete
`<lang>/test/runner.*` → full suite green. One port per commit.

| Port | Status | Notes |
|---|---|---|
| javascript | IN PROGRESS | Swap done and green (95/95 through the shim); voxgig/struct#84 open, awaiting merge. |
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
| 4.1 C1 versioning + strict validation + schema | IN PROGRESS | Canonical + spec + schema landed (voxgig/omni#5). Review found three defects — validation ran after null-normalisation, and three checks tested nullness where they had to test presence; both fixed and pinned. 13 of 23 ports propagated, 10 in flight. |
| 4.2 A1 sentinel soundness (`nullin`, `__RAW__`) | NOT STARTED | Default-flips ride a spec-version bump. |
| 4.3 A2 out/err/match composition | NOT STARTED | `err`+`out` rejection already landed with 4.1. |
| 4.4 A3 err semantics (`err:false`, structured err) | NOT STARTED | |
| 4.5 A4 `__EXACT__`/`__HAS__` match leaves | NOT STARTED | |
| 4.6 C2 group-coverage check (`runcheck` + static) | NOT STARTED | |
| 4.7 C3 skip/pending/only | NOT STARTED | Gated by a `requires` capability. |
| 4.8 C4 declarative unpacking (`DEF.subject.<name>.unpack`) | NOT STARTED | |
| 4.9 B-group naming coherence (aliases, strict section resolution, `options` short form) | NOT STARTED | |
