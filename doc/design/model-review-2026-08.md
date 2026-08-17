# Spec-model review — omni (2026-08)

A critical review of the test-spec **model** — the ontology of the spec
format and runner semantics — as distinct from the implementation review
in [`review-2026-08.md`](review-2026-08.md) (OM-1..OM-5). Three
independent lenses were run (semantic consistency, developer experience,
formal portability) and converged on the same top findings. Every claim
below was verified against `typescript/src/Runner.ts`, the fib spec, and
the real downstream corpora (struct's `build/test/*.aontu`, sekreto's
`spec/def/*.aontu`); migration costs were checked by scanning all three
corpora for reliance on the behaviour in question.

The core judgment: the exact-comparison half of the model is excellent —
`deepequal` rejects every coercion trap, absent-vs-null is carried
honestly, ports prove they can go red. The defects cluster in three
places: **in-band signalling** (sentinels and mode switches living inside
the data domain), **underspecified composition** (what `out`+`err`+`match`
mean together), and **silence** (typos and omissions that pass instead of
failing — the one failure mode a test runner must not have).

The remediation sequence and status live in the plan
([`../plan/adoption.md`](../plan/adoption.md), Phase 4;
[`../plan/progress.md`](../plan/progress.md)). C1 goes first because it is
the mechanism every other change needs to roll out safely across 23
independently-updated runners.

## A — Soundness (the model can pass wrongly)

### A1 (high) — Sentinels are in-band strings, and the `null` flag rewrites subject inputs
Under default flags the whole group is normalised, so a spec's `in: null`
delivers the *string* `"__NULL__"` to the subject. Corpus scars: struct's
`walk.aontu` documents a test deleted for exactly this; struct's
`minor.aontu` `{in: null, out: false}` for `isnode` never tests a real
null; struct's canonical test file carries 29 `{null: false}` overrides to
protect inputs. On the output side a subject returning the literal string
`"__NULL__"` is indistinguishable from one returning null — in sekreto,
whose subjects return arbitrary secret strings and whose corpus writes
`out: '__NULL__'` for misses, that is a false-pass channel. And
`nullmodifier` rewrites `__NULL__` *inside* strings to `null`.
**Fix:** split the flag (`nullin`: deliver real nulls; default flipped
under a spec-version bump); reserve the sentinel strings with a
`__RAW__<text>` escape applied symmetrically in `fixjson`; remove or
document the string-splice. No corpus uses a sentinel as data, so the
reservation is free.

### A2 (high) — `out`/`err`/`match` composition is half-defined
(1) Omitted-`out` is rewritten to `NULLMARK` before checking, so an
*authored* `out: '__NULL__'` plus a `match` silently drops the out
assertion (a subject returning 42 passes). (2) When the subject errors,
`out` is never consulted — `err`+`out` entries carry a dead field, and
struct's validate corpus ships two. (3) The success-path match base is
`{in, args, out, ctx}` but the error-path base omits `args`.
(4) With `{null: false}`, a no-`out` entry accepts only an *absent*
result — a returned null fails — the opposite of the old DOCS text, and
"absent" is not a JSON concept, so ports define the central case by
accident. **Fix:** `outdefaulted` bookkeeping (match-only skip applies
only to genuinely omitted out); reject `err`+`out` (landed with C1); add
`args` to the error base; publish the full composition table as normative
DOCS text with fib counter-cases.

### A3 (medium) — `err` union trap; error identity unassertable
`err: false` *demands* an error (`null != entry.err`) that can then never
match — unsatisfiable one way, inverted the other. `match.err` is only
consulted when `err` is also set; the natural bare-`match.err` spelling
misdiagnoses as `unexpected error`. `errify`'s `{...err}` spread makes the
matchable surface differ per language, and there is no lightweight way to
pin an error's name/code — sekreto's miss-vs-failure taxonomy is pinned by
message text only. **Fix:** `err: false` ≡ no error; `match.err` implies
`err: true`; structured `err: {name, message}` with match-leaf semantics
per key; errify specified as exactly `{name, message}`.

### A4 (medium) — A match string's meaning is decided by its own content
`/…/` is irrevocably a case-sensitive regex; anything else is irrevocably
a case-insensitive substring over the *stringified* base (`match:{out:"5"}`
passes 55; map keys are matchable). Exact, case-sensitive, whole-string
equality is inexpressible — for match leaves and for `err` — so
"error messages are part of the contract" is unenforceable, and a literal
`"/tmp/"` cannot be written at all. **Fix:** extend the existing sentinel
family: `__EXACT__<text>` (whole-string, case-sensitive; also the escape
for literal `/…/`), optionally `__HAS__<text>` (case-sensitive
substring), recognised before the regex rule, valid in match and `err`.

### A5 (low) — The numeric model is unspecified at the edges
Half the ports are all-doubles; a spec entry near 2^53 means different
things in Python and Java, and the stringification algorithm match rules
4–5 depend on is unnamed. **Fix:** a normative Numbers clause (IEEE-754
doubles; integers |n| ≤ 2^53; ECMAScript shortest-round-trip naming) plus
fib entries pinning the observable edges, with honest §9 variance rows
where a port cannot comply.

## B — Category and naming coherence

### B1 (medium) — "client" names four concepts; the runner injects a live Provider under a plain data key
Entry field, `DEF.client` map, `RunPack.client` ("the root provider" per
its own comment), and an unconditional write of the Provider into the
contextified argument — clobbering any legitimate `client` data key, and
placing closures where matchval's function-leaf rule matches vacuously.
**Fix:** define "client" once (a named, configured provider); alias
`RunPack.provider`; inject under a reserved `$client` key with the bare
write kept in the struct shim; error on clobber; function-valued match
leaves fail.

### B2 (medium) — Section resolution falls back to the whole spec on a named miss
`runner('fibb')` silently returns the entire file; the eventual failure
misdiagnoses the typo, and a same-named top-level group could run the
wrong section. `primary` is reserved-in-practice but unstated. **Fix:**
named miss → `OmniError('unknown section')`; whole-spec only when the name
is omitted; document `primary` as reserved; the struct shim keeps the
lenient fallback.

### B3 (medium) — `in`/`args`/`ctx` exclusivity unenforced; the entry doubles as runner scratch space
An ignored `in` still appears in the match base; the runner writes
`entry.ctx` even on the `args` path; the failure printer strips `ctx`, so
a failing ctx-entry prints without the field that defined its arguments;
the cloning rules are asymmetric and half-stated. **Fix:** exclusivity
enforcement (landed with C1); move `res`/`thrown`/resolved-ctx bookkeeping
out of the author's namespace; state the cloning rules as one table.

### B4 (low) — `DEF` is a magic sibling; `test.options` is a struct fossil
A typo'd `DEFS:` block is silently dead; the `test` layer in
`DEF.client.<name>.test.options` carries no information in omni's
ontology. **Fix:** accept `DEF.client.<name>.options` as canonical (long
form kept for compat); state the reservation rule; warn on set-less
sibling maps under strict mode.

### B5 (low) — Flags misdescribe their categories
`null` names a value but toggles a transformation (and mutates the call —
A1); `name` is the failure-message label; unknown flags are ignored.
**Fix:** additive aliases (`nullmark`/`nullin`, `label`), legacy names
kept; warn on unknown flags under strict mode.

## C — Developer friendliness and evolution

### C1 (high) — The format was unversioned and unvalidated
Unknown entry fields silently ignored (a typo'd `matches:` can pass
*vacuously*); no schema; no version marker, so any format addition
degrades non-atomically across independently-updated runners — the exact
failure class the project exists to eliminate, at the meta level.
**Fix (landed 2026-08):** top-level `OMNI {version, requires}` block with
loud refusal of unknown capabilities; version-1 strict entry validation;
`spec/omni-spec.schema.json` + CI check. See DOCS §2.7.

### C2 (high) — Nothing checks that every group is run by every port
An omitted group is perfectly silent; with struct's 87 groups × 24 ports
the call-site count reaches ~2,000. **Fix:** canonical `runcheck(pack)`
listing never-run groups, plus a static `check_coverage.py`
cross-referencing spec groups against port test sources.

### C3 (medium) — First failure aborts the group; no skip/pending/only
One failure per compile-run cycle per port; per-port variance and
in-progress work cannot be expressed in the spec; no single-entry run.
**Fix:** `{all: true}` collect-mode; `{only: [...]}` by index or id;
entry-level `skip`/`pending` gated by a `requires` capability (which is
why C1 lands first).

### C4 (medium) — The entry→signature mapping is duplicated per language
Multi-parameter subjects are tested by packing a map into `in` and
hand-writing the same destructuring adapter in every port (sekreto: 14
bindings × 10 languages). **Fix:** optional `DEF.subject.<name>.unpack:
[keys]` — a capability-gated declarative unpacking hint, so a port's
binding reduces to naming the function.

### C5 (low) — `doc: true`'s real contract lives outside omni
struct's doc generator requires doc-entries to carry unique
`group#label`-style ids; none of that is stated in DOCS. **Fix:** document
the convention; enforce duplicate-id and doc-without-id in the lint layer.
