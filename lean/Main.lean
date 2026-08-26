/-
RUN: make test
RUN-SOME: ./.lake/build/bin/omnitest basic

The Fibonacci conformance suite: every omni port runs this same set of
groups, from the same spec/fib.json, against the same fib library.

No third-party test framework: a failing omni check is returned as a
message, which this harness reports.
-/

import Omni
import Fib

open Lean
open Omni

/-- Find the shared spec directory by walking up from the working dir. -/
partial def specfile (name : String) : IO String := do
  let rec search (dir : String) (step : Nat) : IO String := do
    if step >= 8 then
      throw (IO.userError s!"omni: spec not found: {name}")
    else
      let cand := s!"{dir}/spec/{name}"
      if ← System.FilePath.pathExists cand then
        pure cand
      else
        search s!"{dir}/.." (step + 1)
  search "." 0

-- `args` is a `List Val`, so `getD 0 none` is the argument itself, absent
-- and all; `.map some` lifts a subject that always has a value to answer.
def FIB : Subject := fun args => (Fib.fib (args.getD 0 none)).map some
def FIBSEQ : Subject := fun args => (Fib.fibseq (args.getD 0 none)).map some
def FIBRANGE : Subject := fun args =>
  (Fib.fibrange (args.getD 0 none) (args.getD 1 none)).map some
def FIBINFO : Subject := fun args => (Fib.fibinfo (args.getD 0 none)).map some

/-- The context-group subject: reports what the runner delivered - the
`contextify` mark and the attached client - as plain data, so the spec can
pin both with an ordinary `out` comparison. -/
def fibctx (ctx : Val) : Except String Json := do
  let nval := jget ctx "n"
  let val ← Fib.fib nval
  pure (jmap [
    ("n", nval.getD Json.null),
    ("val", val),
    ("mark", (jget ctx "mark").getD Json.null),
    ("hasclient", jbool (!isnone (jget ctx "client")))])

def FIBCTX : Subject := fun args => (fibctx (args.getD 0 none)).map some

/-- A subject that returns the sentinel spelling as ordinary string data,
so the negative test can prove that a literal "__UNDEF__" no longer
satisfies an assertion that the key is absent. -/
def FIBLITERALUNDEF : Subject := fun _args => pure (some (jmap [("a", jstr "__UNDEF__")]))

/-- The provider hosts the system under test. `shift` offsets the
Fibonacci index, so that a client-specific subject is observably
different. `contextify` marks the map, so the context group can prove the
hook ran. -/
partial def fibprovider (shift : Float) : Provider :=
  Omni.provider
    (subject := some (fun name =>
      match name with
      | "fib" => some (fun args =>
          match asnum (args.getD 0 none) with
          | some num =>
            (Fib.fib (some (jnum (Int.ofNat (num + shift).toUInt64.toNat)))).map some
          | none => (Fib.fib (args.getD 0 none)).map some)
      | "fibseq" => some FIBSEQ
      | "fibrange" => some FIBRANGE
      | "fibinfo" => some FIBINFO
      | _ => none))
    (client := some (fun options =>
      fibprovider ((asnum (jget (some options) "shift")).getD 0.0)))
    (contextify := some (fun val => jset val "mark" (jstr "CTX")))

structure Counts where
  pass : Nat := 0
  fail : Nat := 0

def testcase (only : Option String) (counts : IO.Ref Counts) (name : String)
    (body : Except String Unit) : IO Unit := do
  match only with
  | some wanted => if wanted != name then return ()
  | none => pure ()

  match body with
  | .ok () =>
    counts.modify (fun c => { c with pass := c.pass + 1 })
    IO.println s!"ok   - {name}"
  | .error message =>
    counts.modify (fun c => { c with fail := c.fail + 1 })
    IO.println s!"FAIL - {name}"
    IO.println message

/-- The runner must fail when the subject is wrong - otherwise a green
suite means nothing. -/
def badspec : Json :=
  jmap [("fib", jmap [
    ("wrongout", jmap [("set", jlist [
      jmap [("in", jnum 5), ("out", jnum 5)],
      jmap [("in", jnum 6), ("out", jnum 999)]])]),
    ("wrongerr", jmap [("set", jlist [
      jmap [("in", jnum 1), ("err", jstr "never happens")]])]),
    ("wrongmatch", jmap [("set", jlist [
      jmap [("in", jnum 6), ("match", jmap [("out", jnum 999)])]])]),
    -- A literal "__UNDEF__" in the data is ordinary data, not the absent
    -- sentinel: __UNDEF__ asserts the key is MISSING, so a present literal
    -- must fail. A sentinel that accepts its own literal is not a sentinel.
    ("wrongundef", jmap [("set", jlist [
      jmap [("in", jnum 6),
            ("match", jmap [("out", jmap [("a", jstr "__UNDEF__")])])]])]),
    ("missing", jmap [("set", jlist [
      jmap [("in", jnum 6),
            ("match", jmap [("out", jmap [("nope", jstr "__EXISTS__")])])]])]),
    -- A concrete match leaf against a missing key must fail, not
    -- substring-match the text "undefined".
    ("matchabsent", jmap [("set", jlist [
      jmap [("in", jnum 6),
            ("match", jmap [("out", jmap [("nope", jstr "fine")])])]])]),
    -- __UNDEF__ (absent) must not be satisfied by a present null.
    ("undefonnull", jmap [("set", jlist [
      jmap [("in", jnum 0),
            ("match", jmap [("out", jmap [("prev", jstr "__UNDEF__")])])]])]),
    -- __NULL__ (present null) must not be satisfied by an absent key.
    ("nullonabsent", jmap [("set", jlist [
      jmap [("in", jnum 6),
            ("match", jmap [("out", jmap [("nope", jstr "__NULL__")])])]])]),
    -- An empty-string match leaf is not a wildcard.
    ("emptystr", jmap [("set", jlist [
      jmap [("in", jnum 6),
            ("match", jmap [("out", jmap [("label", jstr "")])])]])])])]

def expectfail (setname : String) (subject : Subject) : Except String Unit := do
  let pack ← makeRunnerSpec badspec emptyProvider "fib"
  match pack.runset (pack.set setname) (some subject) with
  | .error _ => pure ()
  | .ok () => throw s!"omni: expected a failure for set: {setname}"

def checkmessage : Except String Unit := do
  let spec := jmap [("fib", jmap [("g", jmap [("set", jlist [
    jmap [("in", jnum 1), ("out", jnum 1)],
    jmap [("id", jstr "x#2"), ("in", jnum 2), ("out", jnum 42)]])])])]

  let pack ← makeRunnerSpec spec emptyProvider "fib"

  match pack.runset (pack.set "g") (some FIB) with
  | .ok () => throw "omni: expected a failure"
  | .error message =>
    let wants := ["fib[1] (x#2)", "expected: 42", "actual:   1"]
    let missing := wants.filter (fun want => (message.splitOn want).length == 1)
    if missing.isEmpty then pure ()
    else throw s!"omni: message missing {missing}: {message}"

-- Does `message` contain `want` as a substring? Mirrors the `wants` check
-- in `checkmessage`, for the single-substring negative tests below.
def hastext (message want : String) : Bool := 1 != (message.splitOn want).length

-- A version-1 spec is rejected as a whole (before any group runs), so
-- these build ad hoc specs with `jmap`/`jlist` rather than reusing
-- `badspec`, and check the refusal through `makeRunnerSpec` directly.

def testUnsupportedVersion : Except String Unit :=
  let spec := jmap [
    ("OMNI", jmap [("version", jnum 99)]),
    ("fib", jmap [("g", jmap [("set", jlist [])])])]
  match makeRunnerSpec spec emptyProvider "fib" with
  | .error message =>
    if hastext message "unsupported spec version" then pure ()
    else throw s!"omni: wrong refusal message: {message}"
  | .ok _ => throw "omni: expected a refusal for an unsupported spec version"

def testUnknownCapability : Except String Unit :=
  let spec := jmap [
    ("OMNI", jmap [("version", jnum 1), ("requires", jlist [jstr "nosuchfeature"])]),
    ("fib", jmap [("g", jmap [("set", jlist [])])])]
  match makeRunnerSpec spec emptyProvider "fib" with
  | .error message =>
    if hastext message "unsupported capability" then pure ()
    else throw s!"omni: wrong refusal message: {message}"
  | .ok _ => throw "omni: expected a refusal for an unknown required capability"

def testMalformedVersion : Except String Unit :=
  let spec := jmap [
    ("OMNI", jmap [("version", jstr "one")]),
    ("fib", jmap [("g", jmap [("set", jlist [])])])]
  match makeRunnerSpec spec emptyProvider "fib" with
  | .error message =>
    if hastext message "malformed OMNI" then pure ()
    else throw s!"omni: wrong refusal message: {message}"
  | .ok _ => throw "omni: expected a refusal for a malformed version block"

-- A present-but-null block is malformed; only a genuinely absent OMNI key
-- is legacy. A port that tests definedness rather than presence silently
-- skips strict mode here, so both cases are pinned.
def testNullOmniBlock : Except String Unit := do
  let specnull := jmap [
    ("OMNI", Json.null),
    ("fib", jmap [("g", jmap [("set", jlist [jmap [("in", jnum 1), ("out", jnum 1)]])])])]
  match makeRunnerSpec specnull emptyProvider "fib" with
  | .error message =>
    if hastext message "malformed OMNI" then pure ()
    else throw s!"omni: wrong refusal message for a null OMNI block: {message}"
  | .ok _ => throw "omni: expected a refusal for a null OMNI block"

  let specnullrequires := jmap [
    ("OMNI", jmap [("version", jnum 1), ("requires", Json.null)]),
    ("fib", jmap [("g", jmap [("set", jlist [jmap [("in", jnum 1), ("out", jnum 1)]])])])]
  match makeRunnerSpec specnullrequires emptyProvider "fib" with
  | .error message =>
    if hastext message "malformed OMNI requires list" then pure ()
    else throw s!"omni: wrong refusal message for a null requires list: {message}"
  | .ok _ => throw "omni: expected a refusal for a null OMNI requires list"

  let specabsent := jmap [
    ("fib", jmap [("g", jmap [("set", jlist [jmap [("in", jnum 1), ("out", jnum 1)]])])])]
  match makeRunnerSpec specabsent emptyProvider "fib" with
  | .ok _ => pure ()
  | .error message => throw s!"omni: an absent OMNI key should load fine, got: {message}"

def testStrictUnknownField : Except String Unit := do
  let spec := jmap [
    ("OMNI", jmap [("version", jnum 1)]),
    ("fib", jmap [("g", jmap [("set", jlist [
      jmap [("in", jnum 6), ("matches", jmap [("out", jnum 999)])]])])])]
  let pack ← makeRunnerSpec spec emptyProvider "fib"
  match pack.runset (pack.set "g") (some FIBINFO) with
  | .error message =>
    if hastext message "unknown entry field: matches" then pure ()
    else throw s!"omni: wrong refusal message: {message}"
  | .ok () => throw "omni: expected a failure for an unknown entry field"

def testStrictMultipleArgSources : Except String Unit := do
  let spec := jmap [
    ("OMNI", jmap [("version", jnum 1)]),
    ("fib", jmap [("g", jmap [("set", jlist [
      jmap [("in", jnum 5), ("args", jlist [jnum 5]), ("out", jnum 5)]])])])]
  let pack ← makeRunnerSpec spec emptyProvider "fib"
  match pack.runset (pack.set "g") (some FIB) with
  | .error message =>
    if hastext message "more than one of in, args, ctx" then pure ()
    else throw s!"omni: wrong refusal message: {message}"
  | .ok () => throw "omni: expected a failure for more than one of in, args, ctx"

def testStrictErrWithOut : Except String Unit := do
  let spec := jmap [
    ("OMNI", jmap [("version", jnum 1)]),
    ("fib", jmap [("g", jmap [("set", jlist [
      jmap [("in", jnum (-1)), ("err", jbool true), ("out", jnum 5)]])])])]
  let pack ← makeRunnerSpec spec emptyProvider "fib"
  match pack.runset (pack.set "g") (some FIB) with
  | .error message =>
    if hastext message "both err and out" then pure ()
    else throw s!"omni: wrong refusal message: {message}"
  | .ok () => throw "omni: expected a failure for err together with out"

-- This is the test that catches a checkset that validates the
-- already-normalised set: under default flags an authored `id: null`
-- becomes the string "__NULL__", which silently passes the non-string-id
-- rule unless validation reads the AUTHORED entry.
def testStrictNullId : Except String Unit := do
  let spec := jmap [
    ("OMNI", jmap [("version", jnum 1)]),
    ("fib", jmap [("g", jmap [("set", jlist [
      jmap [("in", jnum 1), ("out", jnum 1), ("id", Json.null)]])])])]
  let pack ← makeRunnerSpec spec emptyProvider "fib"
  match pack.runset (pack.set "g") (some FIB) with
  | .error message =>
    if hastext message "entry id is not a string" then pure ()
    else throw s!"omni: wrong refusal message: {message}"
  | .ok () => throw "omni: expected a failure for a null id"

def testStrictEmptySet : Except String Unit := do
  let spec := jmap [
    ("OMNI", jmap [("version", jnum 1)]),
    ("fib", jmap [
      ("g", jmap [("set", jlist [])]),
      ("h", jmap [("set", jlist []), ("empty", jbool true)])])]
  let pack ← makeRunnerSpec spec emptyProvider "fib"
  match pack.runset (pack.set "g") (some FIB) with
  | .error message =>
    if hastext message "empty test set" then pure ()
    else throw s!"omni: wrong refusal message: {message}"
  | .ok () => throw "omni: expected a failure for an empty set"
  pack.runset (pack.set "h") (some FIB)

def testLegacyLenient : Except String Unit := do
  let spec := jmap [
    ("fib", jmap [("g", jmap [("set", jlist [
      jmap [("in", jnum 6), ("matches", jmap [("out", jnum 999)]), ("out", jnum 8)]])])])]
  let pack ← makeRunnerSpec spec emptyProvider "fib"
  pack.runset (pack.set "g") (some FIB)

/-- Assert one `deepequal` answer, naming the pair in the failure. -/
def expectequal (a b : Val) (want : Bool) (what : String) : Except String Unit :=
  if want == deepequal a b then pure ()
  else throw s!"omni: deepequal({what}) should be {want}"

/-- deepequal is structural, not IEEE: `deepequal NaN NaN` is true in every
port, and nothing in spec/fib.json can pin that - JSON has no NaN literal.

This port cannot pin the NaN half of it either, and not for want of trying:
a `Lean.Json` number is a `JsonNumber`, a decimal `mantissa : Int` over
`exponent : Nat`, and no NaN can be built in it. There is no pair of NaNs to
hand `deepequal` here, so the NaN case is pinned by the ports whose value
model can hold one.

What is pinned here is the rest of the numeric rule those ports share, and
the reason the NaN case is missing, so that the next reader does not take
its absence for an oversight: the same number written two ways is equal, a
bool is never a number, and numbers that differ are not equal. -/
def testDeepEqualNumbers : Except String Unit := do
  -- `JsonNumber` is decimal, so 1 is ⟨1, 0⟩ and 1.0 is ⟨10, 1⟩: two
  -- spellings of one number, which deepequal must not tell apart.
  let one := jnum 1
  let onepointzero := Json.num (JsonNumber.mk 10 1)

  expectequal (some one) (some onepointzero) true "1, 1.0"
  expectequal (some (jlist [one])) (some (jlist [onepointzero])) true "[1], [1.0]"
  expectequal (some (jmap [("x", one)])) (some (jmap [("x", onepointzero)])) true
    "{x:1}, {x:1.0}"

  expectequal (some (jbool true)) (some one) false "true, 1"
  expectequal (some one) (some (jnum 2)) false "1, 2"

def main (argv : List String) : IO UInt32 := do
  let only := argv.head?
  let counts ← IO.mkRef ({} : Counts)
  let run := testcase only counts

  let path ← specfile "fib.json"
  let pack ← makeRunner path (fibprovider 0.0) "fib"

  run "basic" (pack.runset (pack.set "basic") (some FIB))
  run "seq" (pack.runset (pack.set "seq") (some FIBSEQ))
  run "range" (pack.runset (pack.set "range") (some FIBRANGE))
  run "info" (pack.runset (pack.set "info") (some FIBINFO))
  run "nulls" (pack.runsetflags (pack.set "nulls") Flags.nonull (some FIBINFO))
  run "error" (pack.runset (pack.set "error") (some FIB))
  run "match" (pack.runset (pack.set "match") (some FIB))
  run "matchinfo" (pack.runset (pack.set "matchinfo") (some FIBINFO))
  run "client" (pack.runset (pack.set "client") (some FIB))
  run "context" (pack.runset (pack.set "context") (some FIBCTX))

  run "detects wrong result" (expectfail "wrongout" FIB)
  run "detects missing error" (expectfail "wrongerr" FIB)
  run "detects failed match" (expectfail "wrongmatch" FIB)
  run "a literal __UNDEF__ in the data is not the absent sentinel"
    (expectfail "wrongundef" FIBLITERALUNDEF)
  run "detects absent key" (expectfail "missing" FIBINFO)
  run "a concrete match leaf does not match a missing key" (expectfail "matchabsent" FIBINFO)
  run "__UNDEF__ does not match a present null" (expectfail "undefonnull" FIBINFO)
  run "__NULL__ does not match an absent key" (expectfail "nullonabsent" FIBINFO)
  run "an empty-string match leaf is not a wildcard" (expectfail "emptystr" FIBINFO)
  run "reports entry index and id" checkmessage

  run "rejects an unsupported spec version" testUnsupportedVersion
  run "rejects an unknown required capability" testUnknownCapability
  run "rejects a malformed version block" testMalformedVersion
  run "rejects a null OMNI block, but accepts an absent one" testNullOmniBlock
  run "strict: an unknown entry field fails instead of passing vacuously" testStrictUnknownField
  run "strict: more than one of in, args, ctx fails" testStrictMultipleArgSources
  run "strict: err together with out fails" testStrictErrWithOut
  run "strict: a null id fails even under null-normalisation" testStrictNullId
  run "strict: an empty set fails unless marked empty" testStrictEmptySet
  run "a legacy spec (no OMNI block) stays lenient" testLegacyLenient
  run "deepequal is structural: numbers by value (Lean JSON has no NaN)"
    testDeepEqualNumbers

  let final ← counts.get
  IO.println s!"\n{final.pass} passed, {final.fail} failed"

  pure (if final.fail == 0 then 0 else 1)
