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
as distinct from `some Json.null`.

`Lean.Json` stores objects in a SORTED tree, so key order is not preserved:
a spec whose maps are written out of key order reaches a consumer reordered.
Every map in voxgig/struct's corpus happens to be key-sorted, so nothing
notices today - but a consumer whose own maps are insertion-ordered (most
are) cannot rely on that. omni-swift carried the same defect and its value
model was its own to change (#32); this one is Lean's. -/
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

/-- Read a map entry. Returns `none` (absent) when missing.

`getObjVal?` rather than reaching into the `.obj` payload directly: the
container behind it is Lean's own business and it has already changed once
(`RBNode` through v4.16, `Std.TreeMap.Raw` by v4.32), taking `find`'s
signature with it. A consumer pinned to a newer toolchain than this one -
struct/lean is on v4.32 - could not compile the runner at all. -/
def jget (val : Val) (key : String) : Val :=
  match val with
  | some json => (json.getObjVal? key).toOption
  | _ => none

/-- Is a map key present at all (even with a null value)? -/
def jhas (val : Val) (key : String) : Bool := (jget val key).isSome

/-- A copy of a map with one entry set (no-op for non-maps). -/
def jset (val : Json) (key : String) (entry : Json) : Json :=
  match val with
  | .obj _ => val.setObjVal! key entry
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
          match (Json.obj q).getObjVal? kv.1 with
          | .ok other => deepequal (some kv.2) (some other)
          | .error _ => false)
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
partial def fixjson (val : Val) (donull : Bool) : Val :=
  if isnone val then
    -- Canonical returns the value UNCHANGED when donull is false
    -- (typescript/src/Runner.ts): absent stays absent and null stays null.
    -- Answering `Json.null` for both collapsed two states the corpus
    -- distinguishes - and the old return type, `Json`, could not say
    -- "absent" at all. Same defect the other ports carried (#17, #23, #25,
    -- #26, #27, #28, #32).
    (if donull then some (jstr nullmark) else val)
  else
    match val with
    | some (.arr entries) =>
      some (Json.arr (entries.map (fun entry => (fixjson (some entry) donull).getD Json.null)))
    | some (.obj kvs) =>
      some (Json.mkObj (kvs.toArray.toList.map
        (fun kv => (kv.1, (fixjson (some kv.2) donull).getD Json.null))))
    | some other => some other
    | none => none

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
      -- An empty want is not a wildcard: the empty string is a substring of
      -- everything, so `match:{out:""}` (or `err:""`) would accept any value.
      | some "" => asstr base == some ""
      | some text =>
        let basestr := stringify base
        if text.length > 2 && text.startsWith "/" && text.endsWith "/" then
          -- Through the char list rather than `dropRight`: that one is
          -- deprecated by v4.32 and now answers a `String.Slice`, which is a
          -- different type, so a consumer on a newer toolchain cannot build
          -- this. `String.mk` and `List.dropLast` are stable across both.
          regexFind (String.mk (text.toList.drop 1 |>.dropLast)) basestr
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

/-- The newest spec format version this runner understands. A spec with no
`OMNI` block is version 0: the original, lenient format, frozen forever.
Version 1 turns on strict entry validation (see `checkentry`). -/
def SPECVERSION : Nat := 1

/-- Capability strings this runner supports beyond the version baseline. A
spec's `OMNI.requires` list is checked against this: an unknown capability
refuses the spec loudly at load time, instead of a lagging port silently
mis-running it. (Empty today; future format features mint a string here.) -/
def CAPABILITIES : List String := []

/-- The complete set of fields an entry may carry. Under version 1 anything
else is an error: an unrecognised key is almost always a typo'd assertion,
and a typo'd assertion is a test that silently stopped testing. -/
private def ENTRYFIELDS : List String :=
  ["in", "args", "ctx", "out", "err", "match", "client", "id", "doc"]

-- A capability that is not a string, or not in CAPABILITIES, is one this
-- runner does not recognise.
private def unsupportedcap (cap : Json) : Bool :=
  match asstr (some cap) with
  | some capstr => !(CAPABILITIES.contains capstr)
  | none => true

/-- The `requires` half of `resolveversion`: a present-but-non-list is
malformed, and any listed capability this runner does not recognise
refuses the whole spec. An absent `requires` is fine - it only narrows,
never widens, what a version already permits. -/
private def checkrequires (requires : Val) (version : Nat) : Except String Nat :=
  if isabsent requires then
    pure version
  else
    match aslist requires with
    | none => throw "omni: malformed OMNI requires list"
    | some caps =>
      match caps.toList.find? unsupportedcap with
      | some badcap =>
        throw s!"omni: spec requires unsupported capability: {stringify (some badcap)}"
      | none => pure version

/-- Read the spec's format version from its optional top-level `OMNI`
block, and refuse a spec this runner cannot faithfully run: a version
newer than `SPECVERSION`, or a required capability not in `CAPABILITIES`.
These are runner refusals, never candidates for an `err` expectation.

Only a genuinely absent `OMNI` key is legacy; a present null (or anything
else that is not a map) is malformed - the presence/definedness
distinction the sentinel system exists to preserve applies to the
runner's own validation too. -/
def resolveversion (alltests : Json) : Except String Nat :=
  -- Not `meta`: that became a reserved token by Lean v4.32, so the binding
  -- fails to parse on a newer toolchain than this file pins.
  let omniblock := jget (some alltests) "OMNI"
  if isabsent omniblock then
    pure 0
  else
    match omniblock with
    | some (.obj _) =>
      match asnum (jget omniblock "version") with
      | some num =>
        if num != num.floor then
          throw "omni: malformed OMNI version block"
        else if num < 0.0 || SPECVERSION.toFloat < num then
          throw s!"omni: unsupported spec version: {numstr num}"
        else
          checkrequires (jget omniblock "requires") num.toUInt64.toNat
      | none => throw "omni: malformed OMNI version block"
    | _ => throw "omni: malformed OMNI version block"

/-- The function under test. Arguments arrive as `Val` - JSON values, or
absence - and failure is reported as `Except.error message`.

`Val`, not `Json`, on both sides. An entry that supplies no `in` means the
subject is called with NO argument, which the corpus distinguishes from one
called with null: struct's `minor/typify` has both `{in: null}` and `{}`
(register 4.12). And a subject that legitimately returns nothing needs to be
able to say so under `{null: false}`. -/
abbrev Subject : Type := List Val → Except String Val

/-- A subject that may REPLACE its arguments, which `match.args` can then
assert on. `minor/setpath` is the case in point: eight of its nine entries
assert that the store was rewritten in place, and `merge/integrity` all six.

Lean is pure, so a consumer's nodes are its own - struct/lean keeps them in a
heap threaded through `SIO` - and nothing it does is visible through this
runner's argument list. Returning the arguments alongside the result is the
only channel there is.

Separate from `Subject` rather than replacing it: a signature change would
break every consumer for a capability most subjects do not need. omni-rust,
-cpp, -ocaml, -elixir, -haskell, -clojure, -scala and -swift carry the same
pair, for the same reason. -/
abbrev SubjectArgs : Type := List Val → Except String (List Val × Val)

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
       -- Build the `match.err` base from the failure, REPLACING `errify`.
       --
       -- Lean reaches this point with a message and nothing else, so a
       -- library whose errors carry a code has no other way to put one in
       -- the base. The hook receives that message and returns the base,
       -- letting a spec assert `match: {err: {code: "x"}}` instead of
       -- pattern-matching prose.
       (errify : Option (String → Json))

def Provider.subject : Provider → Option (String → Option Subject)
  | .mk found _ _ _ => found

def Provider.client : Provider → Option (Json → Provider)
  | .mk _ found _ _ => found

def Provider.contextify : Provider → Option (Json → Json)
  | .mk _ _ found _ => found

def Provider.errify : Provider → Option (String → Json)
  | .mk _ _ _ found => found

/-- Build a provider from the hooks a host supplies. -/
def provider (subject : Option (String → Option Subject) := none)
    (client : Option (Json → Provider) := none)
    (contextify : Option (Json → Json) := none)
    (errify : Option (String → Json) := none) : Provider :=
  .mk subject client contextify errify

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

-- Strict entry validation, applied when the spec declares version 1 or
-- later. The lenient format converts each of these mistakes into a silent
-- pass or a dead field; here they fail with the entry named.
private def checkentry (label : String) (index : Nat) (entry : Json) : Except String Unit := do
  if !ismap (some entry) then
    throw (failure label index entry "entry is not a map" none none)

  let entrykeys := (asmap (some entry)).getD []
  match entrykeys.find? (fun kv => !(ENTRYFIELDS.contains kv.1)) with
  | some badkv => throw (failure label index entry s!"unknown entry field: {badkv.1}" none none)
  | none => pure ()

  let argsources := (["in", "args", "ctx"].filter (fun key => jhas (some entry) key)).length
  if 1 < argsources then
    throw (failure label index entry "entry has more than one of in, args, ctx" none none)

  -- `err` must be present AND non-null; `out` only needs to be present -
  -- an authored `out: null` still collides with an `err` expectation.
  let errpresent := !isnone (jget (some entry) "err")
  let outpresent := jhas (some entry) "out"
  if errpresent && outpresent then
    throw (failure label index entry "entry has both err and out" none none)

  let idval := jget (some entry) "id"
  if !isabsent idval && (asstr idval).isNone then
    throw (failure label index entry "entry id is not a string" none none)
  else
    pure ()

-- Validate a version-1 group up front, against the AUTHORED entries -
-- null-normalisation would otherwise rewrite an authored null (e.g.
-- `id: null`) into a sentinel string and hide it from validation. A
-- malformed spec is a spec error, not a test result, so it fails before
-- any subject runs.
private def checkset (label : String) (testspec : Json) (normalset : Array Json)
    : Except String Unit := do
  let origset :=
    match aslist (jget (some testspec) "set") with
    | some entries => entries
    | none => normalset

  let emptyflag := match jget (some testspec) "empty" with
    | some (.bool true) => true
    | _ => false

  if origset.size == 0 && !emptyflag then
    throw s!"omni: empty test set: {label}"

  for index in List.range origset.size do
    checkentry label index origset[index]!

-- Check that every leaf of `check` is present, and matches, in `base`.
private partial def matchcheck (label : String) (index : Nat) (entry check base : Json)
    (path : List String) : Except String Unit := do
  let place := if path.isEmpty then "<root>" else pathify path
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
    -- The sentinels are tested BEFORE the identity check below. Otherwise
    -- a subject returning the literal string "__UNDEF__" satisfies an
    -- assertion that the key is absent - two mutually exclusive states
    -- passing one check. A sentinel that accepts its own literal is not a
    -- sentinel. (NULLMARK still accepts NULLMARK: under the default null
    -- flag a real null has already been normalised to it, so the two are
    -- genuinely indistinguishable here - that one needs a raw-value
    -- escape, not an ordering change.)
    -- Explicitly absent: satisfied only by a genuinely missing key, never
    -- by a present null (the distinction the sentinels exist to keep).
    if asstr leafval == some undefmark then
      if isabsent baseval then pure ()
      else throw (failure label index entry s!"expected absent at {place}"
        (some "absent") (some (stringify baseval)))
    -- Explicitly null: satisfied only by a present null.
    else if asstr leafval == some nullmark then
      if isnull baseval || asstr baseval == some nullmark then pure ()
      else throw (failure label index entry s!"expected null at {place}"
        (some "null") (some (stringify baseval)))
    -- Explicitly present: any present value, including null.
    else if asstr leafval == some existsmark then
      if !isabsent baseval then pure ()
      else throw (failure label index entry s!"expected present at {place}"
        (some "present") (some "absent"))
    -- Identical values match. This sits below the sentinel branches on
    -- purpose - see the note above.
    else if deepequal leafval baseval then
      pure ()
    -- A concrete expectation never matches a missing key - a match leaf
    -- against an absent value must fail, not substring-match "undefined".
    else if isabsent baseval then
      throw (failure label index entry s!"match failed at {place}"
        (some (stringify leafval)) (some "absent"))
    else if matchval leafval baseval then
      pure ()
    else
      throw (failure label index entry s!"match failed at {place}"
        (some (stringify leafval)) (some (stringify baseval)))

private def checkresult (label : String) (index : Nat) (entry : Json) (args : List Val)
    (res : Val) : Except String Unit := do
  let entryerr := jget (some entry) "err"

  if !isnone entryerr then
    throw (failure label index entry "expected error did not occur"
      (some (stringify entryerr)) (some (stringify res)))

  let check := jget (some entry) "match"
  let matched := !isnone check

  if let some checkval := check then
    let base := jmap [
      ("in", (jget (some entry) "in").getD Json.null),
      -- A match block reads arguments as JSON, and an absent one renders as
      -- null there the way canonical's JSON round-trip does.
      ("args", jlist (args.map (fun arg => arg.getD Json.null))),
      ("out", (jget (some entry) "res").getD Json.null),
      ("ctx", (jget (some entry) "ctx").getD Json.null)]
    matchcheck label index entry checkval base []

  let out := jget (some entry) "out"

  if deepequal res out then
    pure ()
  -- NOTE: a match with no explicit out is a complete check on its own.
  else if matched && (isnone out || asstr out == some nullmark) then
    pure ()
  else
    throw (failure label index entry "result mismatch"
      (some (stringify out)) (some (stringify res)))

/-- The error base a `match.err` sees: the provider's own, when it has one. -/
def errbase (message : String) (prov : Provider) : Json :=
  match prov.errify with
  | some hook => hook message
  | none => errify message

private def handleerror (label : String) (index : Nat) (entry : Json) (message : String)
    (prov : Provider) : Except String Unit := do
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
        ("err", errbase message prov)]
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
  -- The spec's resolved format version (see `resolveversion`). 0 for a
  -- legacy spec with no `OMNI` block, in which case strict validation
  -- (`checkset`/`checkentry`) never runs.
  specversion : Nat

/-- A named group of the resolved spec. -/
def RunPack.set (pack : RunPack) (setname : String) : Json :=
  (jget (some pack.spec) setname).getD Json.null

/-- Run one set of test entries with flags, for a subject that may replace
its arguments. See `SubjectArgs`. -/
partial def RunPack.drive (pack : RunPack) (testspec : Json) (flags : Flags)
    (testsubject : Option Subject) (argsubject : Option SubjectArgs)
    : Except String Unit := do
  let label := flags.name.getD (if pack.name.isEmpty then "set" else pack.name)

  let usesubject ← match argsubject with
    | some _ => pure none
    | none =>
      match testsubject.orElse (fun _ => pack.subject) with
      | some found => pure (some found)
      | none => throw s!"omni: no test subject for: {label}"

  let testspecmap := fixjson (some testspec) flags.null

  let testset ← match aslist (jget testspecmap "set") with
    | some entries => pure entries
    | none => throw s!"omni: test spec has no set: {label}"

  -- Validate the AUTHORED group (testspec, not testspecmap) once, before
  -- any subject runs - see checkset for why this must read the
  -- pre-normalisation entries.
  if 1 <= pack.specversion then
    checkset label testspec testset

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
      match usesubject, asstr (jget (some entry) "client") with
      | none, _ => pure none
      | some found, some clientname =>
        match pack.clients.lookup clientname with
        | none => throw s!"omni: unknown client: {clientname}"
        | some client =>
          match client.subject with
          | some resolve => pure (some ((resolve pack.name).getD found))
          | none => pure (some found)
      | some found, none => pure (some found)

    -- Build the argument list: `ctx`, `args`, or `in`.
    let hasctx := jhas (some entry) "ctx"
    let hasargs := jhas (some entry) "args"

    -- `Val`, so an entry with no `in` reaches the subject as ABSENT rather
    -- than as null - the distinction `minor/typify` asserts (register 4.12).
    let args0 : List Val :=
      if hasctx then [jget (some entry) "ctx"]
      else if hasargs then
        match aslist (jget (some entry) "args") with
        | some list => list.toList.map some
        | none => [jget (some entry) "args"]
      else [jget (some entry) "in"]

    let (args, entry) :=
      if (hasctx || hasargs) && !args0.isEmpty && ismap args0.head! then
        let head := args0.head!.getD Json.null
        let contextified := match pack.client.contextify with
          | some contextify => contextify head
          | none => head
        -- Canonical attaches the resolved client onto ctx/args[0]
        -- (testpack.client) so a context subject can tell it was invoked
        -- through one. Json has no case for a live Provider reference,
        -- and the resolved client is never absent (it defaults to the
        -- root provider), so a boolean marker carries the same
        -- observable meaning the corpus checks for - presence, never
        -- identity.
        let first := jset contextified "client" (jbool true)
        (some first :: args0.tail!, jset entry "ctx" first)
      else (args0, entry)

    -- An args-subject returns its arguments alongside the result, so
    -- `match.args` sees what the subject actually did with them.
    let outcome : Except String (List Val × Val) :=
      match argsubject, entrysubject with
      | some call, _ => call args
      | none, some call => (call args).map (fun res => (args, res))
      | none, none => throw s!"omni: no test subject for: {label}"

    match outcome with
    | .ok (callargs, rawres) =>
      let res := fixjson rawres flags.null
      let done := match res with
        | some value => jset entry "res" value
        | none => entry
      checkresult label index done callargs res
    | .error message => handleerror label index entry message pack.client

/-- Run one set of test entries with flags. Returns the failure message. -/
def RunPack.runsetflags (pack : RunPack) (testspec : Json) (flags : Flags)
    (testsubject : Option Subject) : Except String Unit :=
  pack.drive testspec flags testsubject none

/-- Everything `runsetflags` does, for a subject that may replace its
arguments. See `SubjectArgs`. -/
def RunPack.runsetflagsargs (pack : RunPack) (testspec : Json) (flags : Flags)
    (argsubject : SubjectArgs) : Except String Unit :=
  pack.drive testspec flags none (some argsubject)

/-- Run one set of test entries. Returns the failure message. -/
def RunPack.runset (pack : RunPack) (testspec : Json) (testsubject : Option Subject)
    : Except String Unit :=
  pack.runsetflags testspec {} testsubject

/-- Make a runner for a spec value and a provider. Resolves the spec's
format version first (see `resolveversion`) and refuses to build a runner
at all for a version this port cannot faithfully run - fail fast, before
any group or client is resolved. -/
def makeRunnerSpec (alltests : Json) (provider : Provider) (name : String)
    : Except String RunPack := do
  let specversion ← resolveversion alltests

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

  pure { spec := spec, subject := subject, client := provider, clients := clients,
         name := name, specversion := specversion }

/-- Load a spec: a path to a JSON file. -/
def loadspec (path : String) : IO Json := do
  let text ← IO.FS.readFile path
  match Json.parse text with
  | .ok value => pure value
  | .error message => throw (IO.userError s!"omni: cannot parse spec: {path}: {message}")

/-- Make a runner for a spec file path and a provider. A version refusal
from `makeRunnerSpec` surfaces the same way a spec-load failure already
does: a thrown `IO.userError`, so a caller can guard one `makeRunner` call
regardless of which stage failed. -/
def makeRunner (path : String) (provider : Provider) (name : String) : IO RunPack := do
  let alltests ← loadspec path
  match makeRunnerSpec alltests provider name with
  | .ok pack => pure pack
  | .error message => throw (IO.userError message)

end Omni
