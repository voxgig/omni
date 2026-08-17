# The adoption plan

omni's goal: be the single multi-language test-spec utility of the voxgig
ecosystem. `voxgig/sekreto` already runs every port's conformance suite
through omni; `voxgig/struct` is to replace its 24 in-situ runners with
omni; `senecajs/Sekreto` is to validate omni from outside the sibling-
checkout world. This document is the plan; the live status is the register
in [`progress.md`](progress.md), which changes in the same commit as the
work it records (see AGENTS.md).

Two standing decisions frame everything below:

- **No package publishing for now.** omni is consumed as a **local
  checkout**, resolved via `$OMNI_HOME` and sibling paths and wired per
  language with gitignored links (symlinks, `go.work`, classpath,
  `-p:OmniPath=`) - the mechanism sekreto already uses in all ten ports,
  now documented as the supported path in DOCS.md §8.3. Publishing remains
  a possible later phase; nothing in this plan depends on it except the
  final shape of Phase 3.
- **Canonical-first, always.** Every runner change lands in the canonical
  TypeScript, then the spec, then every port - the repo's prime
  directives apply to plan work exactly as to bug fixes.

## Phase 0 - make omni consumable and trustworthy

1. Document the local-checkout consumption mechanism as the supported
   path (DOCS §8.3).
2. Close the spec's provider-surface holes: a `context` group (ctx +
   `contextify` + client-attach) and an `err.name` pin, so 23-port parity
   covers the paths struct's migration needs.
3. Reconcile DOCS with canonical semantics (inject's mutation contract,
   `__EXISTS__` vs null, the error-path match base, `nullmodifier`'s
   in-string rewrite, sentinel reservation).
4. Single-source `tools/build-spec.js`: omni owns it; sekreto (and struct,
   once its corpus build moves) call omni's copy via the checkout.
5. Pin the struct-compat CI checkout to a struct ref, or run the gate from
   struct's CI too, so the drop-in guarantee is versioned, not floating.

## Phase 1 - migrate struct, port by port

The template is sekreto. Per port: wire the local checkout, adapt the
provider (~30 lines), swap the runner import, delete `<lang>/test/runner.*`,
run the full suite - one port per commit, so a failure can only mean the
runners disagree. Audit the 59 `err` and 15 `match` corpus entries on each
swap; they exercise the paths most likely to differ.

Order: javascript (shim already validated by the struct-compat gate),
typescript (resolve the `makeContext`/`contextify` drift and the
`ctx.utility` attachment; coordinate with `@voxgig/sdkgen`, which copies
the version-stamped TS runner), then the remaining omni-covered ports.
boru needs a decision: an omni boru port, or a documented exception that
keeps its in-situ runner.

Per-port status lives in the register's struct table.

## Phase 2 - retire sekreto's scaffolding

Sekreto is done as an adopter; what remains is plumbing: depend on omni's
`build-spec` instead of its local copy, fix the "all 22 ports" comment in
`spec/def/resolve.aontu`, and (if publishing ever happens) swap path
discovery for the package.

## Phase 3 - the external validation use case (senecajs/Sekreto)

Decide and document the contract - most plausibly a TS/JS Sekreto
implementation (or a Seneca plugin wrapping `@voxgig/sekreto`) whose
conformance to `voxgig/sekreto`'s spec corpus is the validation signal.
Without publishing, "external" means: a repo outside the voxgig sibling
layout, consuming omni via `OMNI_HOME` in CI, running the spec under
**jest** (the first non-`node --test` consumer). Vendor a pinned copy of
`spec/sekreto.json` with a freshness check. Replace the SenecaConfig
scaffold (name, README, URLs, src, tests) first.

## Phase 4 - the spec-model improvement programme

From the 2026-08 model review
([`../design/model-review-2026-08.md`](../design/model-review-2026-08.md);
findings labelled A/B/C there). Sequenced so every later change can roll
out safely:

1. **C1 - versioning + strict validation** (the enabler): top-level `OMNI`
   `{version, requires}` block; version-1 strict entry validation; the
   format schema (`spec/omni-spec.schema.json`). Ships to all 23 ports
   while `requires` is empty and nothing can break.
2. **A1 - sentinel soundness**: `nullin`-style split so subjects receive
   real nulls; `__RAW__` escape; remove or justify the `nullmodifier`
   string splice. Default-flips ride a spec-version bump.
3. **A2 - out/err/match composition**: `outdefaulted` bookkeeping so an
   authored null `out` is always enforced; `args` in the error-path match
   base; the full composition table as normative DOCS text with fib
   counter-cases. (`err`+`out` rejection landed with C1.)
4. **A3 - err semantics**: `err: false` ≡ no error; `match.err` implies
   `err: true`; structured `err: {name, message}`; errify pinned to
   exactly `{name, message}`.
5. **A4 - match expressiveness**: `__EXACT__`/`__HAS__` leaf sentinels for
   exact and case-sensitive matching (also the escape for literal
   `/…/` strings).
6. **C2 - group-coverage check**: canonical `runcheck` + a static
   `check_coverage.py`, so an omitted group cannot stay silently green.
7. **C3 - skip/pending/only**: entry-level `skip`/`pending` (gated by a
   `requires` capability) and an `only` flag for single-entry debugging.
8. **C4 - declarative unpacking**: `DEF.subject.<name>.unpack` so ports
   stop hand-writing the same destructuring adapters per language.
9. **B-group naming coherence** (aliases, section-resolution strictness,
   `DEF.client.<name>.options` short form) - additive, unhurried.

Each item follows the standard workflow: canonical + spec + all 23 ports +
DOCS in one PR, and its register row flips in that PR.
