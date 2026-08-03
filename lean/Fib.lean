/-
The system under test: a tiny Fibonacci library.

Every omni port ships this same library, with the same behaviour and the
same error messages, and tests it with the same spec file (spec/fib.json).
-/

import Omni

open Lean

namespace Fib

open Omni

/-- Validate a Fibonacci index. The spec matches on these messages. -/
def fibindex (val : Omni.Val) : Except String Int :=
  match Omni.asnum val with
  | none => throw s!"fib: not a number: {Omni.stringify val}"
  | some num =>
    if num != num.floor then throw s!"fib: non-integer index: {Omni.stringify val}"
    else if num < 0.0 then throw s!"fib: negative index: {Omni.stringify val}"
    else pure (Int.ofNat num.toUInt64.toNat)

/-- Advance the Fibonacci pair `left` steps. -/
private def fibstep : Nat → Int → Int → Int
  | 0, _, cur => cur
  | left + 1, prev, cur => fibstep left cur (prev + cur)

/-- The nth Fibonacci number: fib(0)=0, fib(1)=1. -/
def fibnum (index : Nat) : Int :=
  if index == 0 then 0 else fibstep (index - 1) 0 1

def fib (val : Omni.Val) : Except String Json := do
  let index ← fibindex val
  pure (Omni.jnum (fibnum index.toNat))

/-- The first n Fibonacci numbers. -/
def fibseq (val : Omni.Val) : Except String Json := do
  let count ← fibindex val
  pure (Omni.jlist ((List.range count.toNat).map (fun index => Omni.jnum (fibnum index))))

/-- The Fibonacci numbers from index start to index end, inclusive. -/
def fibrange (start stop : Omni.Val) : Except String Json := do
  let low ← fibindex start
  let high ← fibindex stop
  let count := if high < low then 0 else (high - low + 1).toNat
  pure (Omni.jlist ((List.range count).map (fun step => Omni.jnum (fibnum (low.toNat + step)))))

/-- A description of the nth Fibonacci number. `prev` is null at index 0,
which exercises the runner's null handling. -/
def fibinfo (val : Omni.Val) : Except String Json := do
  let index ← fibindex val
  let num := fibnum index.toNat

  pure (Omni.jmap [
    ("n", Omni.jnum index),
    ("val", Omni.jnum num),
    ("even", Omni.jbool (num % 2 == 0)),
    ("prev", if index == 0 then Json.null else Omni.jnum (fibnum (index.toNat - 1))),
    ("label", Omni.jstr s!"fib({Omni.numstr index.toNat.toFloat})={Omni.numstr num.toNat.toFloat}")])

end Fib
