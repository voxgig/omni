# omni — boru

A [boru](https://github.com/boru-lang/boru) port of omni: the shared
multi-language test runner. One spec, `spec/fib.json`, run by the same
algorithm as every other port.

    make test

## Requirements

The [`boru`](https://github.com/boru-lang/boru) CLI on your PATH, or
`make test BORU=/path/to/boru`.

There is no release channel for it. Build from source:

    git clone --depth 1 https://github.com/boru-lang/boru /tmp/boru-lang
    (cd /tmp/boru-lang/cmd/go && go build -o /usr/local/bin/boru ./boru)

`cmd/go` is a module of its own, with `replace` directives pointing at
sibling modules in the repository, so `go install` refuses it
(*"the go.mod file for the module providing named packages contains one or
more replace directives"*). Clone and build in place, as above.

**Zero third-party dependencies.** The port uses only the engine's bundled
modules: `boru:io` reads the spec — `IO.read` parses JSON by extension, so
there is no JSON reader here — `boru:minilang` provides the RE2 matcher
behind `mini re`, and `boru:string-util` the string helpers.

## What is different about this port

Five engine properties shape the code. Each was measured, and each is
load-bearing.

**Absent is an atom, not `none`.** boru has one `none`, which plays JSON
null. The runner has to tell "no such key" from "key holding null" — that
distinction is the whole point of `__NULL__` and `__UNDEF__` — so ABSENT is
a quoted atom (`om-absent`), unforgeable by spec data in a way a string
marker would not be. `om-get` returns it for a missing slot.

The atom is the runner's own, though, and stops at the boundary. A subject
returning "nothing" has only `none` to say it with, so under `null: false`
an entry with no `out` is satisfied by a `none` result — the port's
rendering of the `undefined === undefined` every other port gets for free.
(Under `null: true` the question never arises: both sides become
`__NULL__` first.) A subject that receives ABSENT as its argument, for an
entry with no `in`, reads it as whatever its own language calls "not
given": voxgig/struct's boru port maps it to that library's `NOARG`.

**A callback receives its arguments as one list.** `apply` does not spread
on this engine: `[a b] f/v apply` hands the callee the list whatever its
declared arity. So a boru subject reads `av get 0`, `av get 1` — the same
shape omni-zig's `fn (self, args: []const Json)` and omni-go's `[]Json`
subjects already have. Every provider hook is called the same way.

**A callback runs in the runner's registry, not its author's.** It may use
core words and values captured from its defining frame, but *not* the
namespaces its own file imported. A consumer therefore builds subjects as
lambdas that capture the functions they need as **values**:

    def fibfn (Fib.fib/v)          # capture as a value
    def subject ([av:Any] => [
      def r (fibfn (av get 0))     # call the captured value directly
      r
    ])

Calling `Fib.fib` by name inside that lambda fails with `undefined word:
Fib` — and so does reaching a module-level `def` in the consumer's own file.
`test/run.boru` is the worked example. voxgig/struct's boru port records the
same rule for its walker callbacks.

**`raise` takes a fresh map, never a caught Error.** `raise (e)` on a value
from `do … error [var [[e] …]]` does not re-raise it — it dies with
*"cannot call `raise` — no signature matches the arguments"*, and whatever
verdict `e` was carrying is gone. The runner rebuilds instead:
`om-fail-raise (om-errmessage e)`. This one hid inside the negative tests
for a while, because a set that fails for the wrong reason still fails;
`test/run.boru` now pins the message, not just the failure.

**House rules that look redundant and are not.** Every function body ends
`def r (...)` then `r`, because a bare tail call loses a `none` result at
the return boundary — *except* where the value returned is itself a
Function, where a bare `r` is a call rather than a value (`om-unbox`). All
recursion lives in module-level `oml-*` loops with explicit parameters; a
named `def f fn …` inside a body corrupts recursion. `and`/`or` do not
short-circuit, so a type test never guards a typed call in the same
condition. Every `convert` is parenthesised: bare, it forward-collects and
the block yields two values.

## Layout

    src/omni.boru     the runner
    test/fib.boru     the Fibonacci library under test
    test/run.boru     the conformance suite
    test/main.boru    entry point (module-mediated code is the engine's good path)

## The suite

Ten groups from `spec/fib.json`, plus nine negative tests that assert the
runner *fails* when it should — a green suite that cannot go red proves
nothing — and two regressions those nine could not see, where the runner
failed for the wrong reason.

    $ make test
    ok   - basic
    ...
    ok   - a failing set reports its verdict
    21 passed, 0 failed

`make test` takes a group name to run one of them:

    $ boru run -no-check -no-compile test/main.boru basic
