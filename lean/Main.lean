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

def FIB : Subject := fun args => Fib.fib (args.head?)
def FIBSEQ : Subject := fun args => Fib.fibseq (args.head?)
def FIBRANGE : Subject := fun args => Fib.fibrange (args.head?) (args.get? 1)
def FIBINFO : Subject := fun args => Fib.fibinfo (args.head?)

/-- The provider hosts the system under test. `shift` offsets the
Fibonacci index, so that a client-specific subject is observably
different. -/
partial def fibprovider (shift : Float) : Provider :=
  Omni.provider
    (subject := some (fun name =>
      match name with
      | "fib" => some (fun args =>
          match asnum (args.head?) with
          | some num => Fib.fib (some (jnum (Int.ofNat (num + shift).toUInt64.toNat)))
          | none => Fib.fib (args.head?))
      | "fibseq" => some FIBSEQ
      | "fibrange" => some FIBRANGE
      | "fibinfo" => some FIBINFO
      | _ => none))
    (client := some (fun options =>
      fibprovider ((asnum (jget (some options) "shift")).getD 0.0)))

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

def expectfail (setname : String) (subject : Subject) : Except String Unit :=
  let pack := makeRunnerSpec badspec emptyProvider "fib"
  match pack.runset (pack.set setname) (some subject) with
  | .error _ => pure ()
  | .ok () => throw s!"omni: expected a failure for set: {setname}"

def checkmessage : Except String Unit :=
  let spec := jmap [("fib", jmap [("g", jmap [("set", jlist [
    jmap [("in", jnum 1), ("out", jnum 1)],
    jmap [("id", jstr "x#2"), ("in", jnum 2), ("out", jnum 42)]])])])]

  let pack := makeRunnerSpec spec emptyProvider "fib"

  match pack.runset (pack.set "g") (some FIB) with
  | .ok () => throw "omni: expected a failure"
  | .error message =>
    let wants := ["fib[1] (x#2)", "expected: 42", "actual:   1"]
    let missing := wants.filter (fun want => (message.splitOn want).length == 1)
    if missing.isEmpty then pure ()
    else throw s!"omni: message missing {missing}: {message}"

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

  run "detects wrong result" (expectfail "wrongout" FIB)
  run "detects missing error" (expectfail "wrongerr" FIB)
  run "detects failed match" (expectfail "wrongmatch" FIB)
  run "detects absent key" (expectfail "missing" FIBINFO)
  run "a concrete match leaf does not match a missing key" (expectfail "matchabsent" FIBINFO)
  run "__UNDEF__ does not match a present null" (expectfail "undefonnull" FIBINFO)
  run "__NULL__ does not match an absent key" (expectfail "nullonabsent" FIBINFO)
  run "an empty-string match leaf is not a wildcard" (expectfail "emptystr" FIBINFO)
  run "reports entry index and id" checkmessage

  let final ← counts.get
  IO.println s!"\n{final.pass} passed, {final.fail} failed"

  pure (if final.fail == 0 then 0 else 1)
