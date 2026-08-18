# Handover — where the adoption work stopped

Companion to [`adoption.md`](adoption.md) (the plan) and
[`progress.md`](progress.md) (the register). The register says *what* the
status of each item is; this file says *where the work physically
stopped* and what a new session needs in front of it to carry on. Delete
sections as they are consumed.

Last updated: 2026-08-18.


## 1. What has landed

| Where | What |
|---|---|
| voxgig/omni#5 | C1 spec versioning (`OMNI: {version, requires}`), strict entry validation, the `context` group and the `err.name` pin, across the canonical TypeScript and all 23 ports. |
| voxgig/omni#6 | The spec-format shape moved from JSON Schema to aontu (`spec/def/omni-spec.aontu`, `make spec-check`); the ajv dependency dropped. |
| voxgig/struct#84 | The **javascript** port migrated to omni. Its in-situ runner is deleted; `javascript/test/omni.js` resolves the local checkout. 95/95 — the same 95 the old runner passed. |

omni's `make struct-compat` gate runs struct's javascript suite against
omni on every omni PR. It is the only cross-repo gate that exists, and it
covers that one port.


## 2. The blocking decision (register 4.12, model review A6)

**omni cannot express "call the subject with no arguments."** An entry
with no `in`/`args`/`ctx` calls the subject with a single *absent* value
(`resolveargs` → `args = [clone(entry.in)]`, DOCS §2.2).

This is invisible in JavaScript, where `f()` and `f(undefined)` bind
identically — which is why 23 ports agreed on it. It is visible anywhere
with default parameters. struct's corpus has two adjacent entries in
`struct/minor/typify` that exist to tell the two calls apart:

```
 9  {"in": null, "out": 4194432}     -> typify(None)
10  {"out": 1073741824}              -> typify()
```

struct's Python `typify` carries a `_TYPIFY_NO_ARG` sentinel default for
exactly this. struct's own runner calls with `args = []`; omni calls with
one absent value; entry 10 fails.

Measured blast radius:

| Corpus | Entries with no `in`/`args`/`ctx` | Total |
|---|---|---|
| omni `spec/fib.json` | **0** | 68 |
| sekreto `spec/sekreto.json` | **0** | 110 |
| struct `build/test/test.json` | **17** | 1397 |

So changing omni's rule cannot affect any spec omni or sekreto has
authored. The 17 struct entries are listed in the review; only `typify#10`
has a subject that can observe the difference today.

**Option (a) — change omni's rule** (recommended). The implicit form means
a zero-argument call; `in: null` and `args: [null]` remain the way to
pass one null argument. Cost: canonical `Runner.ts` + 23 ports + DOCS §2.2
+ a fib entry pinning it. No existing spec changes meaning.

**Option (b) — keep the rule, make the corpus explicit.** Add `args: []`
to `struct/minor/typify#10`. Cost: one line. But it edits the shared
24-port contract to suit the runner, brushing struct's prime directive
("a port that disagrees with the corpus is the thing that's wrong"), and
it leaves the other sixteen implicit entries quietly reinterpreted —
fixing the symptom that fails today and none of the latent ones.

`args: []` was verified to produce a zero-argument call under **both**
runners, so it is a safe expression of intent either way; the question is
whether the *default* should have to be spelled out.

Until this is decided, the python migration cannot land.


## 3. The python migration, ready to resume

Written and working — **99 of 100 tests pass**, 3 skipped, one failure,
and that failure is exactly §2:

```
omni: struct[10]: result mismatch
  expected: 1073741824
  actual:   4194432
  entry:    {"out":1073741824}
```

Reproduce from a struct checkout with omni beside it:

```
cd struct/python && OMNI_HOME=/path/to/omni python3 -m unittest discover -s tests
```

### 3.1 What the migration consists of

1. **`python/tests/omni.py`** (new) — checkout resolver *and* provider
   adapter. Recorded verbatim in §6 below; it is not committed anywhere.
2. **`python/tests/test_voxgig_struct.py`**, **`test_voxgig_client.py`** —
   two import lines: `from runner import (` → `from omni import (`, and
   `from .runner import (` → `from .omni import (`.
3. **`python/tests/runner.py`** — delete once 1–2 are green.
4. **`.github/workflows/build.yml`** — the `test-python` job has **no omni
   checkout and no `OMNI_HOME`**. Without that wiring the swap fails at
   import on all 12 matrix cells. Copy the two steps the `test-javascript`
   job already has (`actions/checkout@v4` with `repository: voxgig/omni,
   path: .omni`, and `OMNI_HOME: ${{ github.workspace }}/.omni` on the run
   step). This is why the work was not pushed as-is.

### 3.2 What it proved

DOCS §8.3 claims a provider adapter is "about 30 lines". The python one
is the first non-JavaScript instance and the claim holds — the four hooks
are 12 lines; the rest is the resolver and comments. Two things the
JavaScript port never exercised:

- `runpack['client']` must be handed back as the **struct SDK**, not
  omni's provider, because struct's test files reach through it for
  `client.utility().struct`.
- struct's `walk` passes six arguments to a modifier where omni's takes
  three, so `nullModifier` needs a widening wrapper.


## 4. The `slice` bug this uncovered (fixed, pushed separately)

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

**struct's corpus cannot catch this in any port.** Its in-situ runner
compares with plain `==`, under which `1 == True`. omni's `deepequal`
rejects it. That is an argument for the migration in its own right, and it
suggests a corpus entry pinning `slice(true, 1) === true` once enough
ports are migrated to run it honestly. Perl and Lua were checked and guard
correctly; the other ports have not been audited for the same hazard.


## 5. Next steps, in order

1. **Decide 4.12** (§2). Everything in Phase 1 beyond JavaScript waits on
   it, because every port with default parameters hits it.
2. Land the python migration (§3), CI wiring included, and update the
   register's python row.
3. Continue Phase 1 port by port. **typescript is blocked** on
   `@voxgig/sdkgen` (out of the current repository scope) — resolve the
   `makeContext`/`contextify` drift and `ctx.utility` there first. `go`
   and `ruby` are the natural next ones: toolchains present, no external
   coupling.
4. Phase 0 leftovers: 0.4 (single-source `build-spec.js` — sekreto's copy
   has already needed a synchronized fix once) and 0.5 (pin the
   struct-compat CI checkout; it currently floats on struct's default
   branch, which is how struct#84's import change nearly broke omni's
   gate).
5. Phase 3.1 is a product call, not an implementation one: whether
   `senecajs/Sekreto` is an independent TS/JS Sekreto or a Seneca plugin
   wrapping `@voxgig/sekreto`. Nothing else in Phase 3 can start until it
   is answered.


## 6. `python/tests/omni.py`, verbatim

Drop this into `struct/python/tests/omni.py` to resume §3.

```python
"""The shared test runner, from voxgig/omni.

omni is consumed as a local checkout - it is deliberately not published to
a package index (yet). The checkout is resolved the same way voxgig/sekreto's
ports resolve it: $OMNI_HOME first, then sibling paths, taking the first
directory that carries spec/fib.json. Set OMNI_HOME if yours lives elsewhere.
Only the tests depend on omni; the library never does.

This module is the python counterpart of javascript/test/omni.js, and it
also carries the provider adapter that the JavaScript port gets from
omni's javascript/compat/struct.js: it presents omni's runner behind
struct's own `makeRunner(testfile, client)` API, so the test files change
by one import line and nothing else.
"""

import os
import sys
from typing import Any

_MARKER = os.path.join('spec', 'fib.json')


def omnihome() -> str:
    """The local voxgig/omni checkout."""
    here = os.path.dirname(os.path.abspath(__file__))

    candidates = []
    if os.environ.get('OMNI_HOME'):
        # Resolved against the cwd: a relative OMNI_HOME must not be left to
        # resolve against this file instead.
        candidates.append(os.path.abspath(os.environ['OMNI_HOME']))

    candidates += [
        os.path.abspath(os.path.join(here, '..', '..', '..', 'omni')),
        os.path.abspath(os.path.join(here, '..', '..', '..', '..', 'omni')),
        '/workspace/omni',
        '/home/user/omni',
    ]

    for candidate in candidates:
        if os.path.exists(os.path.join(candidate, _MARKER)):
            return candidate

    raise RuntimeError('struct: voxgig/omni checkout not found - set OMNI_HOME')


sys.path.insert(0, os.path.join(omnihome(), 'python'))

from voxgig_omni import makeRunner as _omni_makeRunner  # noqa: E402
from voxgig_omni import nullmodifier as _omni_nullmodifier  # noqa: E402


def _structprovider(sdk: Any) -> dict:
    """Wrap a struct SDK as an omni provider.

    The four hooks omni asks for, mapped onto the SDK struct's test harness
    already exposes. omni's runner carries its own clone/walk/getpath, so
    unlike struct's in-situ runner none of this reaches back into the
    library under test.
    """
    utility = sdk.utility()

    return {
        # struct resolves a subject from the utility, or from utility.struct.
        'subject': lambda name: getattr(
            utility, name, getattr(utility.struct, name, None)
        ),
        # A DEF.client entry's options build another SDK, wrapped again.
        'client': lambda options: _structprovider(sdk.tester(options)),
        'contextify': utility.contextify,
        # struct's inject mutates the options in place; omni ignores the
        # return value, which is the same contract.
        'inject': utility.struct.inject,
    }


def makeRunner(testfile: str, client: Any):
    """struct's runner API, backed by omni.

    `testfile` keeps struct's meaning: a path relative to this test
    directory, not to the working directory.
    """
    specpath = os.path.join(os.path.dirname(os.path.abspath(__file__)), testfile)
    omnirunner = _omni_makeRunner(specpath, _structprovider(client))

    def runner(name: str, store: Any = None) -> dict:
        runpack = omnirunner(name, store)

        # struct's test files reach through the returned client for the
        # library under test (client.utility().struct), so hand back the SDK
        # rather than omni's provider.
        runpack['client'] = client

        return runpack

    return runner


def nullModifier(val, key, parent, _state=None, _current=None, _store=None):
    """struct's spelling of omni's nullmodifier.

    struct's walk passes more arguments than omni's callback takes.
    """
    return _omni_nullmodifier(val, key, parent)
```
