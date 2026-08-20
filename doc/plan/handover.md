# Handover — what the migration decided, and what it cost

The durable residue of the adoption work: the one open decision it turned
up, and the things a landed port taught that the register rows are too
short to carry. Companion to [`adoption.md`](adoption.md) (the plan) and
[`progress.md`](progress.md) (the register).

**This is not the live snapshot.** What is in flight right now, what is
blocked on a human, and what to pick up first is
[`status.md`](status.md) — read that first. This file only accumulates
what stays true after an item lands. Delete a section once its lesson has
been absorbed somewhere better.

Last updated: 2026-08-20.


## 1. What has landed

| Where | What |
|---|---|
| voxgig/omni#5 | C1 spec versioning (`OMNI: {version, requires}`), strict entry validation, the `context` group and the `err.name` pin, across the canonical TypeScript and all 23 ports. |
| voxgig/omni#6 | The spec-format shape moved from JSON Schema to aontu (`spec/def/omni-spec.aontu`, `make spec-check`); the ajv dependency dropped. |
| voxgig/omni#8 | Four struct compat shims — python (`voxgig_omni/compat/struct.py`), and in bb5ad6e the typescript (`typescript/compat/struct.ts`), go (`go/compat/struct/struct.go`) and ruby (`ruby/lib/voxgig_omni/compat/struct.rb`) peers. With `javascript/compat/struct.js` that is five ports whose omni side is ready — of which **javascript, python and ruby have since swapped** (voxgig/struct#84, #86, #88), leaving **two** pending: typescript and go. |
| voxgig/omni#9 | The sentinels tested before the identity check in `match`, canonical and all 23 ports, each pinned by a `wrongundef` negative case. |
| voxgig/struct#84 | The **javascript** port migrated to omni. In-situ runner deleted; `javascript/test/omni.js` resolves the local checkout. 95/95 — the same 95 the old runner passed. |
| voxgig/struct#85 | The `slice` bool/number bug (§4). |
| voxgig/struct#86 | The **python** port migrated. 100 tests, OK, 3 pre-existing skips. Takes struct to **2 of 24**. |
| voxgig/omni#12, #13 | The ruby and go shims' input sides, both missing from #8: ruby `undefargs` (the port's `VoxgigStruct::UNDEF` for the seventeen implicit entries) and go `fixnums` (struct's `fixJSON` integral-`float64`→`int` normalisation, on both sides) plus the port's own no-value reaching the subject. |
| voxgig/struct#88 | The **ruby** port migrated. 93 runs, 159 assertions, 0 failures. Takes struct to **3 of 24**. |

omni's `make struct-compat` gate runs struct's javascript suite against
omni on every omni PR. It is the only cross-repo gate that exists, and it
covers that one port.


## 2. The open decision (register 4.12, model review A6)

**An entry that omits `in`, `args` and `ctx` is called with one *absent*
argument, not with none.** `resolveargs` falls through to
`args = [clone(entry.in)]` (DOCS §2.2), so the implicit form silently
acquires an argument the author did not write.

The gap is that ambiguity, not an inexpressible operation: `args: []` does
produce a genuine zero-argument call, under omni's runner and under
struct's own. What has no portable spelling is the *distinction* — and
`args: []` is not it. An authored empty list shortens the argument vector,
which the fixed-arity ports index: five of nine omni adapters break,
`omni/go` reporting `index out of range [0] with length 0` and `omni/rust`
aborting the process outright. It was tried in struct and reverted
(voxgig/struct 932a84d). See
[`../design/absence-model.md`](../design/absence-model.md).

The ambiguity is invisible in JavaScript, where `f()` and `f(undefined)`
bind identically — which is why 23 ports agreed on the rule. It is visible
anywhere with default parameters. struct's corpus has two adjacent entries
in `struct/minor/typify` that exist to tell the two calls apart:

```
 9  {"in": null, "out": 4194432}     -> typify(None)
10  {"out": 1073741824}              -> typify()
```

struct's Python `typify` carries a `_TYPIFY_NO_ARG` sentinel default for
exactly this. struct's own python runner called with `args = []`; omni
calls with one absent value; entry 10 failed on the swap.

Measured blast radius — entries carrying none of `in`/`args`/`ctx`:

| Corpus | Implicit entries | Total |
|---|---|---|
| omni `spec/fib.json` | **0** | 68 |
| sekreto `spec/sekreto.json` | **0** | 110 |
| struct `build/test/test.json` | **17** | 1397 |

**Option (a) — change omni's rule.** The implicit form means a
zero-argument call. Cost: canonical `Runner.ts` + 23 ports + DOCS §2.2 + a
fib entry pinning it. No spec omni or sekreto has authored changes
meaning: both have zero implicit entries. The **17 struct entries do
change** — their invoked argument list goes from `[absent]` to `[]` — and
that is the point of the change, not a side effect of it. Only
`typify#10` has a subject that can observe the difference today; the other
sixteen are latent.

**Option (b) — keep the rule, make the corpus explicit.** Add `args: []`
to `struct/minor/typify#10`. One line, and it fixes the entry that fails
while leaving the other sixteen quietly reinterpreted. It also edits the
shared 24-port contract to suit the runner, brushing struct's prime
directive ("a port that disagrees with the corpus is the thing that's
wrong") — and `args: []` is the spelling that breaks the fixed-arity
adapters, so it cannot be the general answer.

**Option (c) — spell the state.** `in: '__UNDEF__'`, mapped by each port
to its own no-value; 21 of the 23 already carry one. This is what the
absence model settles on, and it needs the marker honoured in *input*
position first, so it rides a spec version bump. It is the recommendation
now; (a) and (b) are kept above because the register cites them.

**A note on the one-null-argument case.** `in: null` and `args: [null]`
pass a real null to the subject **only under `{null: false}`**. Under the
default `null: true` flag, `fixjson` normalises the whole group — inputs
included — so both spellings arrive as the *string* `"__NULL__"`
(AGENTS.md, "Gotchas"; DOCS §2.5). Any zero-vs-null distinction written in
the corpus has to say which flag its group runs under, or it is not
implementable as documented. That `fixjson` rewrites real nulls in
`args`/`in`/`ctx` is itself one of the four open sentinel-channel defects
under register 4.2.

The decision is no longer blocking: struct's python swap landed with the
reading preserved in memory, per port, by `compat.struct.zeroargs`
(voxgig/omni#8). That shim is a compat measure and does not scale — every
port with default parameters meets the same wall.


## 3. What the python migration proved

DOCS §8.3 claims a provider adapter is "about 30 lines". The python one
was the first non-JavaScript instance and the claim held — the four hooks
are 12 lines; the rest is the resolver and comments. Two things the
JavaScript port never exercised:

- `runpack['client']` must be handed back as something struct's test files
  can reach through for `client.utility().struct`. The shim satisfies both
  sides with a dict subclass that is also attribute-addressable
  (`compat.struct.Provider`), so neither omni's mapping access nor
  struct's attribute access has to change.
- struct's `walk` passes six arguments to a modifier where omni's takes
  three, so `nullModifier` needs a widening wrapper.

At the point the decision in §2 was recorded the suite stood at **96
passed, 3 skipped and 1 failed** of 100 — the single failure being
`struct/minor/typify#10`. With `zeroargs` it is 100 tests, OK, 3
pre-existing skips.

The CI wiring was the other half: struct's `test-python` job had no omni
checkout and no `OMNI_HOME`, so the import swap would have failed on all
12 matrix cells. Copying the two steps `test-javascript` already had
needs the `workflow` OAuth scope, which the authoring credential lacks; a
maintainer applied it as struct f581a4f. That scope is still the binding
constraint elsewhere — see `status.md`.


## 4. The `slice` bug this uncovered (voxgig/struct#85)

Not an omni issue — a real divergence from struct's canonical TypeScript,
found only because omni's `deepequal` refuses to conflate booleans with
numbers.

`voxgig_struct.slice` tested `isinstance(val, (int, float))`, and Python's
`bool` is a subclass of `int`, so a boolean took the numeric clamp path:

| Call | Canonical (TS/JS) | Python, before | after |
|---|---|---|---|
| `slice(true, 1)` | `true` | `1` | `true` |
| `slice(true, 0, 1)` | `true` | `0` | `true` |
| `slice(false, 1)` | `false` | `1` | `false` |

Canonical guards with `S_number === typeof val`, and `typeof true` is
`"boolean"`, so a boolean falls through to the container path and is
returned unchanged.

**struct's corpus cannot catch this in any port.** Its in-situ runners
compare with plain `==`, under which `1 == True`. omni's `deepequal`
rejects it. That is an argument for the migration in its own right, and it
suggests a corpus entry pinning `slice(true, 1) === true` once enough
ports are migrated to run it honestly. Perl and Lua were checked and guard
correctly; the other ports have not been audited for the same hazard.


## 5. Standing constraints

- **typescript is blocked downstream, not upstream.** omni's side shipped
  in #8 (`typescript/compat/struct.ts`, `contextify` first and
  `makeContext` as fallback). struct's swap has not been written; and
  `@voxgig/sdkgen` copies the version-stamped TS runner, so it needs the
  same swap and is outside the current repository scope.
- **Phase 3.1 is a product call, not an implementation one:** whether
  `senecajs/Sekreto` is an independent TS/JS Sekreto or a Seneca plugin
  wrapping `@voxgig/sekreto`. Nothing else in Phase 3 can start until it
  is answered.
- **Phase 0 leftovers are cheap and keep biting.** 0.4 (single-source
  `build-spec.js` — sekreto's copy has already needed a synchronized fix
  once) and 0.5 (pin the struct-compat CI checkout; it floats on struct's
  default branch, which is how struct#84's import change nearly broke
  omni's gate).
