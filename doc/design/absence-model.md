# The absence model

One vocabulary for null, undefined and non-existent that all twenty-three
ports can speak, and one corpus that can express it.

Surveyed against every port (source read, and executed where a toolchain
existed), then attacked from four directions: lua semantics, the fixed-arity
languages, sentinel soundness, and corpus ergonomics. Claims below marked
*measured* were produced by running code.

Status: designed, not started. Register item 4.2 is its first prerequisite.


## The problem

The corpus has been trying to express **three** states with two spellings.

| state | meaning | canonical JS | why it must be distinct |
|---|---|---|---|
| value | a real datum | `1`, `"x"`, `{}` | — |
| null | slot exists, holds JSON null | `null` | `typify(null)` → 4194432 |
| undefined | slot exists, holds no value | `undefined` | `typify()` → 1073741824 |
| absent | slot does not exist | key missing | `__EXISTS__` / `haskey` |

The evidence that this is real, not theoretical: voxgig/struct's corpus has
seventeen entries meaning *call the subject with no arguments*, each sitting
directly beside an `in: null` sibling with a **different** expected result.
struct's own in-situ runners read those seventeen **five** different ways —
python passes zero arguments, typescript/php/go pass one absent value, ruby
passes a `VoxgigStruct::UNDEF` sentinel, lua filters the entries out entirely,
and go additionally skips one on a hardcoded `T_noval` comparison. One corpus,
five meanings.


## The encouraging finding

**Twenty-one of twenty-three ports already implement the three-state model**,
independently and without coordination. Nine have a native third state; twelve
invented a sentinel for it, in twelve different languages, because each port
author hit the same wall. That convergence is the argument for the model — it
standardises something the codebase already believes.

| representation | ports |
|---|---|
| native | javascript, typescript (`undefined`); rust (`Value::Noval`); c (`VOXGIG_VAL_UNDEF`); cpp (`std::monostate`); swift (`Value.noval`); ocaml (`Noval`); haskell (`VNoval`); lean (`.noval`) |
| sentinel | python (`_ABSENT`); ruby (`UNDEF`); php (`Struct::undef()`); perl (three distinct values); java, kotlin (`Struct.UNDEF`); csharp (`StructUtils.NONE`); scala (`Noval`); clojure (`NOARG`); elixir (`:vox_noarg`); dart (`_noarg`); zig |
| **none** | **go**, **lua** |


## The model

Spell every state as a **value in the ordinary slot** — not a different field,
not a different arity, not a metadata tag — so the three read down one column:

```
isnode: set: [
  { in: {a:1},       out: true  }   # value
  { in: 1,           out: false }   # value
  { in: '__NULL__',  out: false }   # null
  { in: '__UNDEF__', out: false }   # undefined
]

typify: set: [
  { in: '__NULL__',  out: 4194432    }
  { in: '__UNDEF__', out: 1073741824 }
]
```

The runner converts `__UNDEF__` to the port's own representation at the
provider boundary. `args[0]` stays valid in every language, so no adapter
breaks.

Four rules:

1. **One vocabulary, both directions.** The same markers work in `out`.
   Without this the input side is unobservable — `fixjson(undefined)` and
   `fixjson(null)` both currently produce `"__NULL__"`, so the corpus could
   create a state it can never assert. This also fixes the **142 of 1397**
   struct entries that omit `out` and mean "null or absent, flag depending" —
   the identical sin on the output side.
2. **One capability, not three.** Keep only `undef-distinct`: the port's value
   model has a no-value distinct from null.
3. **Skips are a ratchet, not a menu.** A port declaring
   `undef-distinct: false` skips the entries requiring it — *counted and
   reported*. An undeclared skip is a failure. This kills the silent-skip class
   outright.
4. **Retire the `null` flag.** Once null is spelled explicitly, a per-group
   boolean living in 24 harness files that rewrites literal nulls into strings
   is a contradiction. It is why `{in: null}` means different things in
   `minor/isnode` and `minor/typify` today.

This is **spec format version 2**. Verified: `requires` is not in
`ENTRYFIELDS`, so every version-1 runner rejects it outright
(`omni: arity[0]: unknown entry field: requires`).


## What the stress tests killed

- **`zero-arity` is not a capability.** The canonical port cannot define it.
  Measured against struct's own build: `typify()`, `typify(undefined)`,
  `typify.apply(null,[])` and `typify.apply(null,[undefined])` all return
  `1073741824`. In JavaScript `f()` and `f(undefined)` are the same call. A
  distinction canonical cannot express cannot be a conformance capability.
- **`args: []` is not portable.** It shortens the argument vector, and the
  fixed-arity ports index it: five of nine omni adapters break, `omni/go`
  reporting `index out of range [0] with length 0` and **`omni/rust` aborting
  the process** with `panicked: index out of bounds`, reporting nothing. Tried
  and reverted in voxgig/struct 932a84d.
- **Deleting the "no `in`/`args`/`ctx`" rule changes nothing.** Zero of
  struct's 1397 entries and zero of omni's 68 lack all three.


## Prerequisites — the sentinel channel

The model leans on markers, and the channel has four defects. One is fixed.

1. ~~**A sentinel that accepts its own literal.**~~ Fixed in voxgig/omni#9:
   the sentinels are tested before the identity check, in canonical and all 23
   ports, each pinned by a `wrongundef` negative case.
2. **No escape hatch.** `__RAW__` is not started, so a literal sentinel cannot
   be asserted at all. DOCS §2.5 now states this.
3. **Real nulls corrupt in argument position.** `fixjson` normalises the whole
   spec including `args`, so a genuine JSON null reaches the subject as the
   *string* `"__NULL__"`, recursively. The model's null row is unimplementable
   until this is fixed.
4. **`__UNDEF__` already means four things.** omni canonical: satisfied only by
   a genuinely absent key. struct php and ruby: a present null also passes.
   struct go: any zero value passes.


## The two ports that need real work

**Go — a library change, not a runner hook.** struct/go has no undefined in its
value domain: `Typify(nil)` → `4194432`, never `T_noval`. Handing it a sentinel
makes things *worse* — a Go sentinel is a struct, so `reflect.Kind()` falls
through to the map branch and `Typify(sentinel)` → `8256`, "a map". Go needs a
package-level sentinel that `Typify`, `IsEmpty`, `Clone` and `Merge` recognise
*ahead of* the reflect dispatch — or it declares `undef-distinct: false` and
skips visibly.

**Lua — better than its own source claims.** `lua/src/struct.lua` documents
that it "cannot distinguish null from undefined at the value level". But
`select('#',...)` gives genuine arity, all 19 internal `typify` call sites pass
variables, and a measured ~10-line patch takes struct's lua suite to 85 passed
/ 0 failed. Lua still loses one distinction permanently: a table cannot store
nil, so absent and null collapse *inside containers* even though they are
distinct in an argument slot. That argues for splitting the capability along
that seam if the container case ever needs it — not today.


## Sequence

1. ~~Back out `args: []`~~ — done (voxgig/struct 932a84d).
2. **Fix the sentinel channel.** One of four done (voxgig/omni#9). Next:
   `__RAW__` as a symmetric whole-value escape, then stop `fixjson` rewriting
   real nulls in `args`/`in`/`ctx`. Pin each with a fib entry that goes red.
3. **Fix struct/lua's argument channel** when that port migrates — explicit
   `args.n` and `table.unpack(args, 1, args.n)`. A live correctness bug there,
   currently masked by its skip filter.
4. **Add `provider.undef()` and the `undef-distinct` capability.** Canonical
   first, then all 23 ports. Twenty-one wire an existing representation; go and
   lua declare or implement.
5. **Mint spec version 2 and migrate the corpora.** Mandatory `out`, the marker
   vocabulary in both directions, the `null` flag retired, entry-level
   `needs:`. Then resume the struct migration — the divergences it surfaces
   will finally have one right answer.
