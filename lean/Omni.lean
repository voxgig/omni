/-
Omni: the shared multi-language test runner (Lean 4 port).

A test spec is plain JSON. The same spec file drives the same tests in
every language that ships an omni port.

Port of the canonical TypeScript implementation
(typescript/src/Runner.ts). Behaviour must match, case for case.

Lean has no exceptions in pure code, so a subject reports failure as
`Except.error message`, and a failing check is returned the same way.
-/

import Lean.Data.Json

open Lean

namespace Omni

/-- Value is JSON null. -/
def nullmark : String := "__NULL__"
/-- Value is not present. -/
def undefmark : String := "__UNDEF__"
/-- Value exists (not undefined). -/
def existsmark : String := "__EXISTS__"

/-- A JSON value, or absence. `none` is the marker for "no value at all",
as distinct from `some Json.null`. -/
abbrev Val := Option Json

def ismap (val : Val) : Bool :=
  match val with
  | some (.obj _) => true
  | _ => false

def islist (val : Val) : Bool :=
  match val with
  | some (.arr _) => true
  | _ => false

def isnode (val : Val) : Bool := ismap val || islist val

def isabsent (val : Val) : Bool := val.isNone

def isnull (val : Val) : Bool :=
  match val with
  | some .null => true
  | _ => false

def isnone (val : Val) : Bool := isabsent val || isnull val

def isnum (val : Val) : Bool :=
  match val with
  | some (.num _) => true
  | _ => false

def isstr (val : Val) : Bool :=
  match val with
  | some (.str _) => true
  | _ => false

def asnum (val : Val) : Option Float :=
  match val with
  | some (.num n) => some n.toFloat
  | _ => none

def asstr (val : Val) : Option String :=
  match val with
  | some (.str s) => some s
  | _ => none

def aslist (val : Val) : Option (Array Json) :=
  match val with
  | some (.arr a) => some a
  | _ => none

def asmap (val : Val) : Option (List (String × Json)) :=
  match val with
  | some (.obj kvs) => some (kvs.toArray.map (fun kv => (kv.1, kv.2))).toList
  | _ => none

/-- Read a map entry. Returns `none` (absent) when missing. -/
def jget (val : Val) (key : String) : Val :=
  match val with
  | some (.obj kvs) => kvs.find compare key
  | _ => none

/-- Is a map key present at all (even with a null value)? -/
def jhas (val : Val) (key : String) : Bool := (jget val key).isSome

/-- A copy of a map with one entry set (no-op for non-maps). -/
def jset (val : Json) (key : String) (entry : Json) : Json :=
  match val with
  | .obj kvs => .obj (kvs.insert compare key entry)
  | other => other

def jnum (val : Int) : Json := Json.num (JsonNumber.fromInt val)
def jstr (val : String) : Json := Json.str val
def jbool (val : Bool) : Json := Json.bool val
def jlist (entries : List Json) : Json := Json.arr entries.toArray
def jmap (entries : List (String × Json)) : Json := Json.mkObj entries

/-- Render a number the same way in every port: 5.0 prints as 5. -/
def numstr (val : Float) : String :=
  if val.isNaN || val.isInf then "null"
  else
    -- Lean prints a Float as "5.000000"; trim to the shortest exact form,
    -- so that 5.0 renders as 5 in every port.
    let text := toString val
    if text.contains '.' then
      let trimmed := text.dropRightWhile (· == '0')
      if trimmed.endsWith "." then trimmed.dropRight 1 else trimmed
    else text

/-- Render a string as a JSON string literal. -/
def quote (val : String) : String :=
  let escape (ch : Char) : String :=
    if ch == '"' then "\\\""
    else if ch == '\\' then "\\\\"
    else if ch == '\n' then "\\n"
    else if ch == '\r' then "\\r"
    else if ch == '\t' then "\\t"
    else if ch.toNat < 0x20 then "\\u00" ++ (Nat.toDigits 16 ch.toNat).asString
    else ch.toString
  "\"" ++ (val.toList.map escape |> String.join) ++ "\""

/-- Compact JSON text with map keys sorted, identical in every port. -/
partial def jsonstr (val : Val) : String :=
  match val with
  | none => "undefined"
  | some .null => "null"
  | some (.bool flag) => if flag then "true" else "false"
  | some (.num n) => numstr n.toFloat
  | some (.str text) => quote text
  | some (.arr entries) =>
    "[" ++ String.intercalate "," (entries.toList.map (fun e => jsonstr (some e))) ++ "]"
  | some (.obj kvs) =>
    -- Lean's object is key-ordered already, which is what omni wants.
    let pairs := kvs.toArray.toList.map (fun kv => quote kv.1 ++ ":" ++ jsonstr (some kv.2))
    "{" ++ String.intercalate "," pairs ++ "}"

/-- Strings verbatim, everything else as compact JSON. -/
def stringify (val : Val) : String :=
  match asstr val with
  | some text => text
  | none => jsonstr val

/-- Render a path as a dotted string. -/
def pathify (path : List String) : String := String.intercalate "." path

/-- Deep copy a JSON value (Lean values are immutable). -/
def clone (val : Val) : Val := val

/-- Deep structural equality: numbers by value, bools never numbers. -/
partial def deepequal (a b : Val) : Bool :=
  match a, b with
  | none, none => true
  | some x, some y =>
    match x, y with
    | .null, .null => true
    | .bool p, .bool q => p == q
    | .num p, .num q => p.toFloat == q.toFloat
    | .str p, .str q => p == q
    | .arr p, .arr q =>
      p.size == q.size &&
        (List.range p.size).all (fun index => deepequal (some p[index]!) (some q[index]!))
    | .obj p, .obj q =>
      let pl := p.toArray.toList
      let ql := q.toArray.toList
      pl.length == ql.length &&
        pl.all (fun kv =>
          match q.find compare kv.1 with
          | some other => deepequal (some kv.2) (some other)
          | none => false)
    | _, _ => false
  | _, _ => false

/-- Read a value by path. Returns `none` (absent) when a step is missing. -/
def getpath (val : Val) (path : List String) : Val :=
  path.foldl
    (fun current part =>
      match current with
      | some (.arr entries) =>
        match part.toNat? with
        | some index => if index < entries.size then some entries[index]! else none
        | none => none
      | some (.obj _) => jget current part
      | _ => none)
    val

/-- Depth-first walk: children first, then the containing node. -/
partial def walk (val : Json) (apply : Json → List String → Json)
    (path : List String := []) : Json :=
  let next :=
    match val with
    | .arr entries =>
      Json.arr (entries.mapIdx (fun index entry => walk entry apply (path ++ [toString index])))
    | .obj kvs =>
      Json.mkObj (kvs.toArray.toList.map (fun kv => (kv.1, walk kv.2 apply (path ++ [kv.1]))))
    | other => other
  apply next path

/-- Nulls (and absent values) become NULLMARK. Always a fresh copy. -/
partial def fixjson (val : Val) (donull : Bool) : Json :=
  if isnone val then
    (if donull then jstr nullmark else Json.null)
  else
    match val with
    | some (.arr entries) => Json.arr (entries.map (fun entry => fixjson (some entry) donull))
    | some (.obj kvs) =>
      Json.mkObj (kvs.toArray.toList.map (fun kv => (kv.1, fixjson (some kv.2) donull)))
    | some other => other
    | none => Json.null

/-- The JSON form of an error: always at least {name,message}. -/
def errify (message : String) : Json :=
  jmap [("name", jstr "Error"), ("message", jstr message)]

/- ---- regex engine --------------------------------------------------

Omni specs match error messages with `/pattern/` expectations, so every
port needs a regex. Lean has none in its standard library, so omni carries
this engine, a direct port of the Rust one (rust/src/regex.rs). -/

inductive ClassItem : Type where
  | char (ch : Char)
  | range (low high : Char)
  | digit (invert : Bool)
  | word (invert : Bool)
  | space (invert : Bool)

inductive Node : Type where
  | char (ch : Char)
  | any
  | cls (items : List ClassItem) (negated : Bool)
  | start
  | stop
  | seq (nodes : List Node)
  | alt (branches : List Node)
  | repeat (inner : Node) (min : Nat) (max : Option Nat) (greedy : Bool)

instance : Inhabited Node := ⟨.any⟩
instance : Inhabited ClassItem := ⟨.char 'x'⟩

private def escapeNode (escape : Char) : Node :=
  match escape with
  | 'd' => Node.cls [ClassItem.digit false] false
  | 'D' => Node.cls [ClassItem.digit false] true
  | 'w' => Node.cls [ClassItem.word false] false
  | 'W' => Node.cls [ClassItem.word false] true
  | 's' => Node.cls [ClassItem.space false] false
  | 'S' => Node.cls [ClassItem.space false] true
  | 'n' => Node.char '\n'
  | 'r' => Node.char '\r'
  | 't' => Node.char '\t'
  | other => Node.char other

private partial def parseClass (chars : List Char) : Option (Node × List Char) :=
  let (negated, rest) :=
    match chars with
    | '^' :: more => (true, more)
    | _ => (false, chars)
  let rec collect (acc : List ClassItem) (first : Bool) (left : List Char)
      : Option (Node × List Char) :=
    match left with
    | [] => none
    | ']' :: more => if first then collect (ClassItem.char ']' :: acc) false more
                     else some (Node.cls acc.reverse negated, more)
    | '\\' :: escape :: more =>
      let item :=
        match escape with
        | 'd' => ClassItem.digit false
        | 'w' => ClassItem.word false
        | 's' => ClassItem.space false
        | 'n' => ClassItem.char '\n'
        | 'r' => ClassItem.char '\r'
        | 't' => ClassItem.char '\t'
        | other => ClassItem.char other
      collect (item :: acc) false more
    | low :: '-' :: high :: more =>
      if high == ']' then collect (ClassItem.char low :: acc) false ('-' :: high :: more)
      else collect (ClassItem.range low high :: acc) false more
    | ch :: more => collect (ClassItem.char ch :: acc) false more
  collect [] true rest

private partial def parseCount (chars : List Char) : Option (Nat × Option Nat × List Char) :=
  let digits := chars.takeWhile Char.isDigit
  let rest := chars.dropWhile Char.isDigit
  if digits.isEmpty then none
  else
    let low := digits.asString.toNat!
    match rest with
    | '}' :: more => some (low, some low, more)
    | ',' :: more =>
      let highdigits := more.takeWhile Char.isDigit
      let afterhigh := more.dropWhile Char.isDigit
      match afterhigh with
      | '}' :: final =>
        some (low, (if highdigits.isEmpty then none else some highdigits.asString.toNat!), final)
      | _ => none
    | _ => none

mutual

private partial def parseAlt (chars : List Char) : Option (Node × List Char) := do
  let (first, rest) ← parseSeq chars
  let rec branches (acc : List Node) (left : List Char) : Option (Node × List Char) :=
    match left with
    | '|' :: more => do
      let (branch, rest) ← parseSeq more
      branches (branch :: acc) rest
    | _ => some (if acc.length == 1 then acc.head! else .alt acc.reverse, left)
  branches [first] rest

private partial def parseSeq (chars : List Char) : Option (Node × List Char) :=
  let rec collect (acc : List Node) (left : List Char) : Option (Node × List Char) :=
    match left with
    | [] => some (.seq acc.reverse, [])
    | '|' :: _ => some (.seq acc.reverse, left)
    | ')' :: _ => some (.seq acc.reverse, left)
    | _ => do
      let (atom, rest) ← parseAtom left
      let (node, more) ← parseRepeat atom rest
      collect (node :: acc) more
  collect [] chars

private partial def parseRepeat (atom : Node) (chars : List Char) : Option (Node × List Char) :=
  let build (min : Nat) (max : Option Nat) (rest : List Char) : Option (Node × List Char) :=
    match rest with
    | '?' :: more => some (.repeat atom min max false, more)
    | _ => some (.repeat atom min max true, rest)
  match chars with
  | '*' :: rest => build 0 none rest
  | '+' :: rest => build 1 none rest
  | '?' :: rest => build 0 (some 1) rest
  | '{' :: rest =>
    match parseCount rest with
    | some (min, max, more) => build min max more
    | none => some (atom, chars)
  | _ => some (atom, chars)

private partial def parseAtom (chars : List Char) : Option (Node × List Char) :=
  match chars with
  | [] => none
  | '(' :: rest => do
    let inner := match rest with
      | '?' :: ':' :: more => more
      | _ => rest
    let (node, more) ← parseAlt inner
    match more with
    | ')' :: final => some (node, final)
    | _ => none
  | '[' :: rest => parseClass rest
  | '.' :: rest => some (.any, rest)
  | '^' :: rest => some (.start, rest)
  | '$' :: rest => some (.stop, rest)
  | '\\' :: escape :: rest => some (escapeNode escape, rest)
  | ch :: rest => some (.char ch, rest)

end

private def isWordChar (ch : Char) : Bool := ch.isAlphanum || ch == '_'

private def classMatch (items : List ClassItem) (negated : Bool) (ch : Char) : Bool :=
  let hit := items.any fun item =>
    match item with
    | .char want => ch == want
    | .range low high => low ≤ ch && ch ≤ high
    | .digit invert => ch.isDigit != invert
    | .word invert => isWordChar ch != invert
    | .space invert => ch.isWhitespace != invert
  hit != negated

mutual

private partial def matchNode (node : Node) (text : Array Char) (pos : Nat)
    (cont : Nat → Bool) : Bool :=
  match node with
  | .char want => pos < text.size && text[pos]! == want && cont (pos + 1)
  | .any => pos < text.size && cont (pos + 1)
  | .cls items negated =>
    pos < text.size && classMatch items negated text[pos]! && cont (pos + 1)
  | .start => pos == 0 && cont pos
  | .stop => pos == text.size && cont pos
  | .seq nodes => matchSeq nodes text pos cont
  | .alt branches => branches.any (fun branch => matchNode branch text pos cont)
  | .repeat inner min max greedy => matchRepeat inner min max greedy 0 text pos cont

private partial def matchSeq (nodes : List Node) (text : Array Char) (pos : Nat)
    (cont : Nat → Bool) : Bool :=
  match nodes with
  | [] => cont pos
  | head :: rest => matchNode head text pos (fun next => matchSeq rest text next cont)

private partial def matchRepeat (inner : Node) (min : Nat) (max : Option Nat) (greedy : Bool)
    (count : Nat) (text : Array Char) (pos : Nat) (cont : Nat → Bool) : Bool :=
  let canmore := match max with
    | some limit => count < limit
    | none => true
  let takemore := fun _ =>
    canmore && matchNode inner text pos (fun next =>
      -- A zero-width repeat would loop forever.
      next > pos && matchRepeat inner min max greedy (count + 1) text next cont)
  let stopnow := fun _ => count >= min && cont pos
  if greedy then takemore () || stopnow () else stopnow () || takemore ()

end

/-- Is the pattern found anywhere in the text? -/
def regexFind (pattern text : String) : Bool :=
  match parseAlt pattern.toList with
  | some (root, []) =>
    let chars := text.toList.toArray
    (List.range (chars.size + 1)).any (fun start => matchNode root chars start (fun _ => true))
  | _ => false

/-- Match one leaf: /regex/ or case-insensitive substring for strings. -/
def matchval (check base : Val) : Bool :=
  if deepequal check base then true
  else
    let want :=
      match asstr check with
      | some text => if text == undefmark || text == nullmark then none else check
      | none => check
    if isnone want then
      isnone base || asstr base == some nullmark
    else
      match asstr want with
      | some text =>
        let basestr := stringify base
        if text.length > 2 && text.startsWith "/" && text.endsWith "/" then
          regexFind (text.drop 1 |>.dropRight 1) basestr
        else
          (basestr.toLower.splitOn text.toLower).length > 1
      | none => deepequal want base

/-- Convert NULLMARK sentinels back into real nulls. -/
def nullmodifier (val : Val) : Val :=
  match asstr val with
  | some text =>
    if text == nullmark then some Json.null
    else some (jstr (String.intercalate "null" (text.splitOn nullmark)))
  | none => val

/- ---- runner --------------------------------------------------------- -/

/-- The function under test. Arguments arrive as JSON values; failure is
reported as `Except.error message`. -/
abbrev Subject : Type := List Json → Except String Json

/-- Run-time options for a set of test entries. -/
structure Flags where
  null : Bool := true
  name : Option String := none

def Flags.nonull : Flags := { null := false }

/-- The host of the system under test. Every hook is optional.

A provider is recursive (a client hook yields another provider), so it is
an inductive rather than a structure. -/
inductive Provider : Type where
  | mk (subject : Option (String → Option Subject))
       (client : Option (Json → Provider))
       (contextify : Option (Json → Json))

def Provider.subject : Provider → Option (String → Option Subject)
  | .mk found _ _ => found

def Provider.client : Provider → Option (Json → Provider)
  | .mk _ found _ => found

def Provider.contextify : Provider → Option (Json → Json)
  | .mk _ _ found => found

/-- Build a provider from the hooks a host supplies. -/
def provider (subject : Option (String → Option Subject) := none)
    (client : Option (Json → Provider) := none)
    (contextify : Option (Json → Json) := none) : Provider :=
  .mk subject client contextify

/-- A provider with no hooks. -/
def emptyProvider : Provider := provider

instance : Inhabited Provider := ⟨emptyProvider⟩

/-- Find `primary.<name>`, then `<name>`, then the whole spec. -/
def resolvespec (name : String) (alltests : Json) : Json :=
  if name.isEmpty then alltests
  else
    match jget (jget (some alltests) "primary") name with
    | some found => found
    | none =>
      match jget (some alltests) name with
      | some found => found
      | none => alltests

-- The spec-defined part of an entry (drop runner bookkeeping).
private def entrysummary (entry : Json) : Json :=
  match entry with
  | .obj kvs =>
    Json.mkObj ((kvs.toArray.toList.map (fun kv => (kv.1, kv.2))).filter
      (fun kv => kv.1 != "res" && kv.1 != "thrown" && kv.1 != "ctx"))
  | other => other

-- The label of one entry, for failure messages.
private def entryref (label : String) (index : Nat) (entry : Json) : String :=
  let id := jget (some entry) "id"
  let idpart := if isabsent id then "" else s! " ({stringify id})"
  s!"{label}[{index}]{idpart}"

private def failure (label : String) (index : Nat) (entry : Json) (reason : String)
    (expected actual : Option String) : String :=
  let head := s!"omni: {entryref label index entry}: {reason}"
  let head := match expected with
    | some text => head ++ s!"\n  expected: {text}"
    | none => head
  let head := match actual with
    | some text => head ++ s!"\n  actual:   {text}"
    | none => head
  head ++ s!"\n  entry:    {stringify (some (entrysummary entry))}"

-- Check that every leaf of `check` is present, and matches, in `base`.
private partial def matchcheck (label : String) (index : Nat) (entry check base : Json)
    (path : List String) : Except String Unit := do
  match check with
  | .arr entries =>
    for idx in List.range entries.size do
      matchcheck label index entry entries[idx]! base (path ++ [toString idx])
  | .obj kvs =>
    for kv in kvs.toArray.toList do
      matchcheck label index entry kv.2 base (path ++ [kv.1])
  | leaf =>
    let baseval := getpath (some base) path
    let leafval := some leaf
    let ok :=
      deepequal leafval baseval
        || (asstr leafval == some undefmark && isabsent baseval)
        || (asstr leafval == some existsmark && !isnone baseval)
        || matchval leafval baseval
    if !ok then
      let place := if path.isEmpty then "<root>" else pathify path
      throw (failure label index entry s!"match failed at {place}"
        (some (stringify leafval)) (some (stringify baseval)))

private def checkresult (label : String) (index : Nat) (entry : Json) (args : List Json)
    (res : Json) : Except String Unit := do
  let entryerr := jget (some entry) "err"

  if !isnone entryerr then
    throw (failure label index entry "expected error did not occur"
      (some (stringify entryerr)) (some (stringify (some res))))

  let check := jget (some entry) "match"
  let matched := !isnone check

  if let some checkval := check then
    let base := jmap [
      ("in", (jget (some entry) "in").getD Json.null),
      ("args", jlist args),
      ("out", (jget (some entry) "res").getD Json.null),
      ("ctx", (jget (some entry) "ctx").getD Json.null)]
    matchcheck label index entry checkval base []

  let out := jget (some entry) "out"

  if deepequal (some res) out then
    pure ()
  -- NOTE: a match with no explicit out is a complete check on its own.
  else if matched && (isnone out || asstr out == some nullmark) then
    pure ()
  else
    throw (failure label index entry "result mismatch"
      (some (stringify out)) (some (stringify (some res))))

private def handleerror (label : String) (index : Nat) (entry : Json) (message : String)
    : Except String Unit := do
  let entryerr := jget (some entry) "err"

  if isnone entryerr then
    throw (failure label index entry "unexpected error" none (some message))

  let istrue := match entryerr with
    | some (.bool true) => true
    | _ => false

  if istrue || matchval entryerr (some (jstr message)) then
    if let some checkval := jget (some entry) "match" then
      let base := jmap [
        ("in", (jget (some entry) "in").getD Json.null),
        ("out", (jget (some entry) "res").getD Json.null),
        ("ctx", (jget (some entry) "ctx").getD Json.null),
        ("err", errify message)]
      matchcheck label index entry checkval base []
    pure ()
  else
    throw (failure label index entry "error mismatch"
      (some (stringify entryerr)) (some message))

/-- What a runner returns for one named spec section. -/
structure RunPack where
  spec : Json
  subject : Option Subject
  client : Provider
  clients : List (String × Provider)
  name : String

/-- A named group of the resolved spec. -/
def RunPack.set (pack : RunPack) (setname : String) : Json :=
  (jget (some pack.spec) setname).getD Json.null

/-- Run one set of test entries with flags. Returns the failure message. -/
partial def RunPack.runsetflags (pack : RunPack) (testspec : Json) (flags : Flags)
    (testsubject : Option Subject) : Except String Unit := do
  let label := flags.name.getD (if pack.name.isEmpty then "set" else pack.name)

  let usesubject ← match testsubject.orElse (fun _ => pack.subject) with
    | some found => pure found
    | none => throw s!"omni: no test subject for: {label}"

  let testspecmap := fixjson (some testspec) flags.null

  let testset ← match aslist (jget (some testspecmap) "set") with
    | some entries => pure entries
    | none => throw s!"omni: test spec has no set: {label}"

  for index in List.range testset.size do
    let rawentry := testset[index]!

    if !ismap (some rawentry) then
      throw s!"omni: {label}[{index}]: entry is not a map"

    -- An entry with no `out` expects a null (or absent) result.
    let entry :=
      if flags.null && isnone (jget (some rawentry) "out") then
        jset rawentry "out" (jstr nullmark)
      else rawentry

    let entrysubject ←
      match asstr (jget (some entry) "client") with
      | some clientname =>
        match pack.clients.lookup clientname with
        | none => throw s!"omni: unknown client: {clientname}"
        | some client =>
          match client.subject with
          | some resolve => pure ((resolve pack.name).getD usesubject)
          | none => pure usesubject
      | none => pure usesubject

    -- Build the argument list: `ctx`, `args`, or `in`.
    let hasctx := jhas (some entry) "ctx"
    let hasargs := jhas (some entry) "args"

    let args0 :=
      if hasctx then [(jget (some entry) "ctx").getD Json.null]
      else if hasargs then
        match aslist (jget (some entry) "args") with
        | some list => list.toList
        | none => [(jget (some entry) "args").getD Json.null]
      else [(jget (some entry) "in").getD Json.null]

    let (args, entry) :=
      if (hasctx || hasargs) && !args0.isEmpty && ismap (some args0.head!) then
        let first := match pack.client.contextify with
          | some contextify => contextify args0.head!
          | none => args0.head!
        (first :: args0.tail!, jset entry "ctx" first)
      else (args0, entry)

    match entrysubject args with
    | .ok rawres =>
      let res := fixjson (some rawres) flags.null
      checkresult label index (jset entry "res" res) args res
    | .error message => handleerror label index entry message

/-- Run one set of test entries. Returns the failure message. -/
def RunPack.runset (pack : RunPack) (testspec : Json) (testsubject : Option Subject)
    : Except String Unit :=
  pack.runsetflags testspec {} testsubject

/-- Make a runner for a spec value and a provider. -/
def makeRunnerSpec (alltests : Json) (provider : Provider) (name : String) : RunPack :=
  let spec := resolvespec name alltests

  -- A spec may define clients that a given test run never references.
  let clients :=
    match asmap (jget (jget (some spec) "DEF") "client"), provider.client with
    | some entries, some clientmaker =>
      entries.map (fun kv =>
        let copts := (jget (jget (some kv.2) "test") "options").getD (jmap [])
        (kv.1, clientmaker copts))
    | _, _ => []

  let subject :=
    if name.isEmpty then none
    else match provider.subject with
      | some resolve => resolve name
      | none => none

  { spec := spec, subject := subject, client := provider, clients := clients, name := name }

/-- Load a spec: a path to a JSON file. -/
def loadspec (path : String) : IO Json := do
  let text ← IO.FS.readFile path
  match Json.parse text with
  | .ok value => pure value
  | .error message => throw (IO.userError s!"omni: cannot parse spec: {path}: {message}")

/-- Make a runner for a spec file path and a provider. -/
def makeRunner (path : String) (provider : Provider) (name : String) : IO RunPack := do
  let alltests ← loadspec path
  pure (makeRunnerSpec alltests provider name)

end Omni
