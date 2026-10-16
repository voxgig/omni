(* Omni: the shared multi-language test runner (OCaml port).

   A test spec is plain JSON. The same spec file drives the same tests in
   every language that ships an omni port.

   Port of the canonical TypeScript implementation
   (typescript/src/Runner.ts). Behaviour must match, case for case.

   Self-contained by design: the runner carries its own JSON value model,
   parser and regex engine, so that it can test *any* library - including
   one that provides those same operations - and adds no dependencies. *)

(* ---- the JSON value model ------------------------------------------ *)

(* `Absent` is the marker for "no value at all", as distinct from `Null`. *)
type json =
  | Absent
  | Null
  | Bool of bool
  | Num of float
  | Str of string
  | JList of json list
  | JMap of (string * json) list

let nullmark = "__NULL__" (* Value is JSON null. *)
let undefmark = "__UNDEF__" (* Value is not present. *)
let existsmark = "__EXISTS__" (* Value exists (not undefined). *)

let ismap = function JMap _ -> true | _ -> false
let islist = function JList _ -> true | _ -> false
let isnode val_ = ismap val_ || islist val_
let isabsent = function Absent -> true | _ -> false
let isnull = function Null -> true | _ -> false
let isnone val_ = isabsent val_ || isnull val_
let isnum = function Num _ -> true | _ -> false
let isstr = function Str _ -> true | _ -> false

let asnum = function Num v -> Some v | _ -> None
let asstr = function Str v -> Some v | _ -> None
let aslist = function JList v -> Some v | _ -> None
let asmap = function JMap v -> Some v | _ -> None

(* Read a map entry. Returns Absent when missing. *)
let jget val_ key =
  match val_ with
  | JMap entries -> (try List.assoc key entries with Not_found -> Absent)
  | _ -> Absent

(* Is a map key present at all (even with a null value)? *)
let jhas val_ key =
  match val_ with JMap entries -> List.mem_assoc key entries | _ -> false

(* A copy of a map with one entry set (no-op for non-maps). *)
let jset val_ key entry =
  match val_ with
  | JMap entries ->
    if List.mem_assoc key entries then
      JMap (List.map (fun (k, e) -> if k = key then (k, entry) else (k, e)) entries)
    else JMap (entries @ [ (key, entry) ])
  | other -> other

(* ---- errors -------------------------------------------------------- *)

(* A test failure (or a malformed spec). Distinct from an exception raised
   by the subject under test, which is a candidate for an `err`
   expectation. *)
exception Omni_error of string

let omni_error message = Omni_error message

(* ---- number and string rendering ----------------------------------- *)

(* Render a number the same way in every port: 5.0 prints as 5. *)
let numstr value =
  if Float.is_nan value || Float.is_integer value = false then
    if Float.is_nan value || value = Float.infinity || value = Float.neg_infinity then "null"
    else Printf.sprintf "%.17g" value
  else if Float.abs value < 9007199254740992.0 then Printf.sprintf "%.0f" value
  else Printf.sprintf "%.17g" value

(* Render a string as a JSON string literal. *)
let quote value =
  let buf = Buffer.create (String.length value + 2) in
  Buffer.add_char buf '"';
  String.iter
    (fun ch ->
      match ch with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | _ ->
        if Char.code ch < 0x20 then Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code ch))
        else Buffer.add_char buf ch)
    value;
  Buffer.add_char buf '"';
  Buffer.contents buf

(* Compact JSON text with map keys sorted, identical in every port. *)
let rec jsonstr value =
  match value with
  | Absent -> "undefined"
  | Null -> "null"
  | Bool flag -> if flag then "true" else "false"
  | Num entry -> numstr entry
  | Str text -> quote text
  | JList entries -> "[" ^ String.concat "," (List.map jsonstr entries) ^ "]"
  | JMap entries ->
    let sorted = List.sort (fun (a, _) (b, _) -> compare a b) entries in
    "{" ^ String.concat "," (List.map (fun (key, e) -> quote key ^ ":" ^ jsonstr e) sorted) ^ "}"

(* Strings verbatim, everything else as compact JSON. *)
let stringify value = match value with Str text -> text | other -> jsonstr other

(* Render a path as a dotted string. *)
let pathify path = String.concat "." path

(* ---- json parser --------------------------------------------------- *)

let parse text =
  let len = String.length text in
  let pos = ref 0 in

  let fail reason = raise (Omni_error (Printf.sprintf "omni: %s at %d" reason !pos)) in

  let skipws () =
    while
      !pos < len
      && (match text.[!pos] with ' ' | '\t' | '\n' | '\r' -> true | _ -> false)
    do
      incr pos
    done
  in

  let word want value =
    let wlen = String.length want in
    if !pos + wlen <= len && String.sub text !pos wlen = want then (
      pos := !pos + wlen;
      value)
    else fail "bad JSON literal"
  in

  let hex4 () =
    if !pos + 4 > len then fail "bad JSON unicode escape";
    (* Exactly four hex digits: int_of_string would accept '_'
       separators and raise Failure on other junk. *)
    let hexdigit ch =
      match ch with
      | '0' .. '9' -> Char.code ch - Char.code '0'
      | 'a' .. 'f' -> Char.code ch - Char.code 'a' + 10
      | 'A' .. 'F' -> Char.code ch - Char.code 'A' + 10
      | _ -> fail "bad JSON unicode escape"
    in
    let code = ref 0 in
    for step = 0 to 3 do
      code := (!code * 16) + hexdigit text.[!pos + step]
    done;
    pos := !pos + 4;
    !code
  in

  let parsestring () =
    if !pos >= len || text.[!pos] <> '"' then fail "expected string";
    incr pos;
    let buf = Buffer.create 16 in
    let result = ref None in
    while !result = None do
      if !pos >= len then fail "unterminated JSON string";
      let ch = text.[!pos] in
      incr pos;
      if ch = '"' then result := Some (Buffer.contents buf)
      else if ch <> '\\' then Buffer.add_char buf ch
      else begin
        if !pos >= len then fail "unterminated JSON string";
        let escape = text.[!pos] in
        incr pos;
        match escape with
        | '"' -> Buffer.add_char buf '"'
        | '\\' -> Buffer.add_char buf '\\'
        | '/' -> Buffer.add_char buf '/'
        | 'b' -> Buffer.add_char buf '\b'
        | 'f' -> Buffer.add_char buf '\012'
        | 'n' -> Buffer.add_char buf '\n'
        | 'r' -> Buffer.add_char buf '\r'
        | 't' -> Buffer.add_char buf '\t'
        | 'u' ->
          let lone = "bad JSON unicode escape (lone surrogate)" in
          let code = hex4 () in
          let code =
            if code >= 0xD800 && code <= 0xDBFF then begin
              if !pos + 2 > len || text.[!pos] <> '\\' || text.[!pos + 1] <> 'u' then fail lone;
              pos := !pos + 2;
              let low = hex4 () in
              if low < 0xDC00 || low > 0xDFFF then fail lone;
              0x10000 + ((code - 0xD800) lsl 10) + (low - 0xDC00)
            end
            else if code >= 0xDC00 && code <= 0xDFFF then fail lone
            else code
          in
          Buffer.add_utf_8_uchar buf (Uchar.of_int code)
        | _ -> fail "bad JSON escape"
      end
    done;
    match !result with Some text -> text | None -> fail "unterminated JSON string"
  in

  let parsenumber () =
    let start = !pos in
    if !pos < len && (text.[!pos] = '-' || text.[!pos] = '+') then incr pos;
    while
      !pos < len
      && (match text.[!pos] with
         | '0' .. '9' | '.' | 'e' | 'E' | '-' | '+' -> true
         | _ -> false)
    do
      incr pos
    done;
    let span = String.sub text start (!pos - start) in
    match float_of_string_opt span with
    | Some value -> Num value
    | None -> fail ("bad JSON number [" ^ span ^ "]")
  in

  let rec parsevalue () =
    if !pos >= len then fail "unexpected end of JSON";
    match text.[!pos] with
    | '{' -> parsemap ()
    | '[' -> parselist ()
    | '"' -> Str (parsestring ())
    | 't' -> word "true" (Bool true)
    | 'f' -> word "false" (Bool false)
    | 'n' -> word "null" Null
    | _ -> parsenumber ()
  and parsemap () =
    incr pos;
    skipws ();
    if !pos < len && text.[!pos] = '}' then begin
      incr pos;
      JMap []
    end
    else begin
      let entries = ref [] in
      let running = ref true in
      while !running do
        skipws ();
        let key = parsestring () in
        skipws ();
        if !pos >= len || text.[!pos] <> ':' then fail "expected ':'";
        incr pos;
        skipws ();
        let value = parsevalue () in
        (* A duplicate key overrides the earlier value (last wins), as in
           the canonical implementation. *)
        if List.mem_assoc key !entries then
          entries := List.map (fun (k, e) -> if k = key then (k, value) else (k, e)) !entries
        else entries := !entries @ [ (key, value) ];
        skipws ();
        if !pos >= len then fail "unterminated JSON object";
        if text.[!pos] = ',' then incr pos
        else if text.[!pos] = '}' then begin
          incr pos;
          running := false
        end
        else fail "expected ',' or '}'"
      done;
      JMap !entries
    end
  and parselist () =
    incr pos;
    skipws ();
    if !pos < len && text.[!pos] = ']' then begin
      incr pos;
      JList []
    end
    else begin
      let entries = ref [] in
      let running = ref true in
      while !running do
        skipws ();
        entries := !entries @ [ parsevalue () ];
        skipws ();
        if !pos >= len then fail "unterminated JSON array";
        if text.[!pos] = ',' then incr pos
        else if text.[!pos] = ']' then begin
          incr pos;
          running := false
        end
        else fail "expected ',' or ']'"
      done;
      JList !entries
    end
  in

  skipws ();
  let value = parsevalue () in
  skipws ();
  if !pos < len then fail "trailing JSON content";
  value

(* ---- util ---------------------------------------------------------- *)

(* Deep copy a JSON value (the value model is immutable). *)
let clone value = value

(* Read a value by path. Returns Absent when any step is missing. *)
let rec getpath value path =
  match path with
  | [] -> value
  | part :: rest ->
    let next =
      match value with
      | JList entries -> (
        match int_of_string_opt part with
        | Some index when index >= 0 && index < List.length entries -> List.nth entries index
        | _ -> Absent)
      | JMap _ -> jget value part
      | _ -> Absent
    in
    if isabsent next then Absent else getpath next rest

(* Depth-first walk: children first, then the containing node. *)
let rec walk value apply path =
  let next =
    match value with
    | JList entries ->
      JList (List.mapi (fun index entry -> walk entry apply (path @ [ string_of_int index ])) entries)
    | JMap entries -> JMap (List.map (fun (key, entry) -> (key, walk entry apply (path @ [ key ]))) entries)
    | other -> other
  in
  apply next path

(* Deep structural equality: numbers by value, bools never numbers. *)
let rec deepequal a b =
  match (a, b) with
  | Absent, Absent -> true
  | Null, Null -> true
  | Bool x, Bool y -> x = y
  | Num x, Num y -> x = y || (Float.is_nan x && Float.is_nan y)
  | Str x, Str y -> x = y
  | JList x, JList y -> List.length x = List.length y && List.for_all2 deepequal x y
  | JMap x, JMap y ->
    List.length x = List.length y
    && List.for_all
         (fun (key, entry) -> List.mem_assoc key y && deepequal entry (List.assoc key y))
         x
  | _ -> false

(* ---- regex engine --------------------------------------------------- *)

(* Omni specs match error messages with `/pattern/` expectations, so every
   port needs a regex. OCaml's Str has a different dialect, so omni carries
   this engine, a direct port of the Rust one (rust/src/regex.rs). *)

type reitem =
  | IChar of char
  | IRange of char * char
  | IDigit of bool
  | IWord of bool
  | ISpace of bool

type renode =
  | RChar of char
  | RAny
  | RClass of reitem list * bool
  | RStart
  | REnd
  | RSeq of renode list
  | RAlt of renode list
  | RRepeat of renode * int * int option * bool

exception Regex_error of string

let regex_parse pattern =
  let len = String.length pattern in
  let pos = ref 0 in

  let escapenode escape =
    match escape with
    | 'd' -> RClass ([ IDigit false ], false)
    | 'D' -> RClass ([ IDigit false ], true)
    | 'w' -> RClass ([ IWord false ], false)
    | 'W' -> RClass ([ IWord false ], true)
    | 's' -> RClass ([ ISpace false ], false)
    | 'S' -> RClass ([ ISpace false ], true)
    | 'n' -> RChar '\n'
    | 'r' -> RChar '\r'
    | 't' -> RChar '\t'
    | other -> RChar other
  in

  let parseclass () =
    incr pos;
    let negated = !pos < len && pattern.[!pos] = '^' in
    if negated then incr pos;
    let items = ref [] in
    let first = ref true in
    let result = ref None in
    while !result = None do
      if !pos >= len then raise (Regex_error "omni: unterminated regex class");
      let ch = pattern.[!pos] in
      if ch = ']' && not !first then begin
        incr pos;
        result := Some (RClass (!items, negated))
      end
      else begin
        first := false;
        if ch = '\\' && !pos + 1 < len then begin
          let escape = pattern.[!pos + 1] in
          pos := !pos + 2;
          items :=
            !items
            @ [ (match escape with
                | 'd' -> IDigit false
                | 'w' -> IWord false
                | 's' -> ISpace false
                | 'n' -> IChar '\n'
                | 'r' -> IChar '\r'
                | 't' -> IChar '\t'
                | other -> IChar other) ]
        end
        else begin
          incr pos;
          if !pos + 1 < len && pattern.[!pos] = '-' && pattern.[!pos + 1] <> ']' then begin
            items := !items @ [ IRange (ch, pattern.[!pos + 1]) ];
            pos := !pos + 2
          end
          else items := !items @ [ IChar ch ]
        end
      end
    done;
    match !result with Some node -> node | None -> raise (Regex_error "omni: bad regex class")
  in

  let parsecount () =
    let start = !pos in
    incr pos;
    let digits = Buffer.create 4 in
    while !pos < len && pattern.[!pos] >= '0' && pattern.[!pos] <= '9' do
      Buffer.add_char digits pattern.[!pos];
      incr pos
    done;
    if Buffer.length digits = 0 then begin
      pos := start;
      None
    end
    else begin
      (* A count too large for an int degrades to a literal `{`, rather
         than leaking a Failure out of the parser. *)
      match int_of_string_opt (Buffer.contents digits) with
      | None ->
        pos := start;
        None
      | Some min ->
        if !pos < len && pattern.[!pos] = '}' then begin
          incr pos;
          Some (min, Some min)
        end
        else if !pos < len && pattern.[!pos] = ',' then begin
          incr pos;
          let maxdigits = Buffer.create 4 in
          while !pos < len && pattern.[!pos] >= '0' && pattern.[!pos] <= '9' do
            Buffer.add_char maxdigits pattern.[!pos];
            incr pos
          done;
          if !pos < len && pattern.[!pos] = '}' then begin
            incr pos;
            if Buffer.length maxdigits = 0 then Some (min, None)
            else
              match int_of_string_opt (Buffer.contents maxdigits) with
              | Some maxval -> Some (min, Some maxval)
              | None ->
                pos := start;
                None
          end
          else begin
            pos := start;
            None
          end
        end
        else begin
          pos := start;
          None
        end
    end
  in

  let rec parsealt () =
    let branches = ref [ parseseq () ] in
    while !pos < len && pattern.[!pos] = '|' do
      incr pos;
      branches := !branches @ [ parseseq () ]
    done;
    match !branches with [ single ] -> single | many -> RAlt many
  and parseseq () =
    let nodes = ref [] in
    while !pos < len && pattern.[!pos] <> '|' && pattern.[!pos] <> ')' do
      let atom = parseatom () in
      nodes := !nodes @ [ parserepeat atom ]
    done;
    RSeq !nodes
  and parserepeat atom =
    if !pos >= len then atom
    else
      let bounds =
        match pattern.[!pos] with
        | '*' ->
          incr pos;
          Some (0, None)
        | '+' ->
          incr pos;
          Some (1, None)
        | '?' ->
          incr pos;
          Some (0, Some 1)
        | '{' -> parsecount ()
        | _ -> None
      in
      match bounds with
      | None -> atom
      | Some (min, max) ->
        let greedy = not (!pos < len && pattern.[!pos] = '?') in
        if not greedy then incr pos;
        RRepeat (atom, min, max, greedy)
  and parseatom () =
    let ch = pattern.[!pos] in
    if ch = '(' then begin
      incr pos;
      if !pos + 1 < len && pattern.[!pos] = '?' && pattern.[!pos + 1] = ':' then pos := !pos + 2;
      let inner = parsealt () in
      if !pos >= len || pattern.[!pos] <> ')' then raise (Regex_error "omni: unbalanced regex group");
      incr pos;
      inner
    end
    else if ch = '[' then parseclass ()
    else if ch = '.' then begin
      incr pos;
      RAny
    end
    else if ch = '^' then begin
      incr pos;
      RStart
    end
    else if ch = '$' then begin
      incr pos;
      REnd
    end
    else if ch = '\\' then begin
      incr pos;
      if !pos >= len then raise (Regex_error "omni: trailing backslash in regex");
      let escape = pattern.[!pos] in
      incr pos;
      escapenode escape
    end
    else begin
      incr pos;
      RChar ch
    end
  in

  let root = parsealt () in
  if !pos < len then raise (Regex_error ("omni: bad regex: " ^ pattern));
  root

let isword ch =
  (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch = '_'

let isdigitch ch = ch >= '0' && ch <= '9'
let isspacech ch = ch = ' ' || ch = '\t' || ch = '\n' || ch = '\r' || ch = '\012'

let classmatch items negated ch =
  let hit =
    List.exists
      (fun item ->
        match item with
        | IChar want -> ch = want
        | IRange (from, upto) -> from <= ch && ch <= upto
        | IDigit invert -> isdigitch ch <> invert
        | IWord invert -> isword ch <> invert
        | ISpace invert -> isspacech ch <> invert)
      items
  in
  hit <> negated

let rec matchnode node text pos cont =
  let len = String.length text in
  match node with
  | RChar want -> pos < len && text.[pos] = want && cont (pos + 1)
  | RAny -> pos < len && cont (pos + 1)
  | RClass (items, negated) -> pos < len && classmatch items negated text.[pos] && cont (pos + 1)
  | RStart -> pos = 0 && cont pos
  | REnd -> pos = len && cont pos
  | RSeq nodes -> matchseq nodes text pos cont
  | RAlt branches -> List.exists (fun branch -> matchnode branch text pos cont) branches
  | RRepeat (inner, min, max, greedy) -> matchrepeat inner min max greedy 0 text pos cont

and matchseq nodes text pos cont =
  match nodes with
  | [] -> cont pos
  | head :: rest -> matchnode head text pos (fun next -> matchseq rest text next cont)

and matchrepeat inner min max greedy count text pos cont =
  let canmore = match max with None -> true | Some limit -> count < limit in
  let takemore () =
    canmore
    && matchnode inner text pos (fun next ->
           (* A zero-width repeat would loop forever. *)
           next > pos && matchrepeat inner min max greedy (count + 1) text next cont)
  in
  let stopnow () = count >= min && cont pos in
  if greedy then takemore () || stopnow () else stopnow () || takemore ()

(* Is the pattern found anywhere in the text? *)
let regex_find pattern text =
  match regex_parse pattern with
  | exception Regex_error _ -> false
  | root ->
    let len = String.length text in
    let rec attempt start =
      if start > len then false
      else if matchnode root text start (fun _ -> true) then true
      else attempt (start + 1)
    in
    attempt 0

(* ---- runner -------------------------------------------------------- *)

(* The function under test. Arguments arrive as JSON values; failure is
   reported by raising. *)
type subject = json list -> json

(* A subject that may MUTATE its arguments, which `match.args` can then assert
   on. `minor/setpath` is the case in point: eight of its nine entries assert
   that the store was rewritten in place, and `merge/integrity` all six.

   OCaml's `json` is immutable, so a consumer holding a converted copy has no
   way to write through a `json list`. The arguments arrive as an ARRAY it may
   overwrite in place, and the runner reads it back after the call.

   Separate from `subject` rather than replacing it: a signature change would
   break every consumer for a capability most subjects do not need. omni-rust
   and omni-cpp carry the same pair, for the same reason. Dynamic-language
   ports need neither - their shims write the mutation back into omni's own
   object, because the value is shared. *)
type subject_args = json array -> json

type testsubject = Subject of subject | Subject_args of subject_args

(* Run-time options for a set of test entries. The canonical flags `all` and
   `wait` are optional arguments of `runsetflags` instead, so that a record
   literal of these two fields still builds. *)
type flags = { null : bool; name : string option }

let default_flags = { null = true; name = None }
let nonull_flags = { null = false; name = None }

(* The host of the system under test. Every hook is optional. *)
type provider = {
  subject : (string -> subject option) option;
  client : (json -> provider) option;
  contextify : (json -> json) option;
  inject : (json -> json -> json) option;
  (* Build the `match.err` base from the failure, REPLACING [errify].

     OCaml reports a subject failure as its message and nothing else, so a
     library whose errors carry a code has no other way to put one in the
     base. The hook receives that message and returns the base, letting a
     spec assert [match: {err: {code: "x"}}] instead of pattern-matching
     prose. *)
  errify : (string -> json) option;
}

let empty_provider =
  { subject = None; client = None; contextify = None; inject = None; errify = None }

(* The newest spec format version this runner understands. A spec with no
   OMNI block is version 0: the original, lenient format, frozen forever.
   Version 1 turns on strict entry validation (see checkentry). *)
let specversion = 1

(* Capability strings this runner supports beyond the version baseline. A
   spec's OMNI.requires list is checked against this: an unknown
   capability refuses the spec loudly at load time, instead of a lagging
   port silently mis-running it. A spec turns each on only by requiring
   it. *)
let capabilities : string list = [ "ctxargs"; "fn"; "wait" ]

(* The complete set of fields an entry may carry. Under version 1 anything
   else is an error: an unrecognised key is almost always a typo'd
   assertion, and a typo'd assertion is a test that silently stopped
   testing. *)
let entryfields = [ "in"; "args"; "ctx"; "out"; "err"; "match"; "client"; "id"; "doc" ]

(* Entry fields a capability adds, permitted only in a spec that requires it. *)
let capfields = [ ("fn", "fn"); ("wait", "wait") ]

(* Load a spec: a path to a JSON file. *)
let loadspec path =
  if not (Sys.file_exists path) then raise (Omni_error ("omni: cannot read spec: " ^ path));
  let channel = open_in_bin path in
  let length = in_channel_length channel in
  let text = really_input_string channel length in
  close_in channel;
  parse text

(* Read the spec's format version from its optional top-level OMNI block,
   and refuse a spec this runner cannot faithfully run: a version newer
   than specversion, or a required capability not in capabilities. Only a
   genuinely absent OMNI key is legacy - `OMNI: null` (or a malformed
   requires/version) is a spec error, checked by presence, not by a null
   test, so a present null is never mistaken for absence. *)
let resolveversion alltests =
  if not (jhas alltests "OMNI") then 0
  else
    let meta = jget alltests "OMNI" in
    if not (ismap meta) then raise (Omni_error "omni: malformed OMNI version block");

    let version =
      match jget meta "version" with
      | Num v when Float.is_integer v -> v
      | _ -> raise (Omni_error "omni: malformed OMNI version block")
    in

    if version < 0.0 || float_of_int specversion < version then
      raise (Omni_error ("omni: unsupported spec version: " ^ numstr version));

    (if jhas meta "requires" then
       match jget meta "requires" with
       | JList items ->
         List.iter
           (fun cap ->
             match cap with
             | Str text when List.mem text capabilities -> ()
             | _ -> raise (Omni_error ("omni: spec requires unsupported capability: " ^ stringify cap)))
           items
       | _ -> raise (Omni_error "omni: malformed OMNI requires list"));

    int_of_float version

(* The capabilities a spec requires, which resolveversion has already
   checked against capabilities. *)
let resolverequires alltests =
  match jget (jget alltests "OMNI") "requires" with
  | JList items -> List.filter_map asstr items
  | _ -> []

(* Find `primary.<name>`, then `<name>`, then the whole spec. *)
let resolvespec name alltests =
  if name = "" then alltests
  else
    let primary = jget (jget alltests "primary") name in
    if not (isabsent primary) then primary
    else
      let section = jget alltests name in
      if not (isabsent section) then section else alltests

(* Nulls (and absent values) become NULLMARK. Always a fresh copy. *)
let rec fixjson value donull =
  (* Canonical returns the value UNCHANGED when donull is false
     (typescript/src/Runner.ts): absent stays absent and null stays null.
     Answering Null for both collapsed two states the corpus distinguishes, so
     a subject that correctly returned nothing was compared against null and
     marked wrong - `minor/clone#13`, `minor/getprop#4`, `minor/getelem#9`.
     Same defect the other ports carried (#17, #23, #25); this one was missed
     because no consumer had exercised it. *)
  if isnone value then (if donull then Str nullmark else value)
  else
    match value with
    | JList entries -> JList (List.map (fun entry -> fixjson entry donull) entries)
    | JMap entries -> JMap (List.map (fun (key, entry) -> (key, fixjson entry donull)) entries)
    | other -> other

(* The JSON form of an error: always at least {name,message}. *)
let errify message = JMap [ ("name", Str "Error"); ("message", Str message) ]

(* The message an `err` expectation matches. *)
let errmessage err =
  match err with
  | Omni_error message -> message
  | Failure message -> message
  | other -> Printexc.to_string other

(* Match one leaf: /regex/ or case-insensitive substring for strings. *)
let matchval check base =
  if deepequal check base then true
  else
    let want =
      match asstr check with
      | Some text when text = undefmark || text = nullmark -> Null
      | _ -> check
    in
    if isnone want then isnone base || asstr base = Some nullmark
    else
      match asstr want with
      (* An empty want is not a wildcard: the empty string is a substring of
         everything, so `match:{out:""}` (or `err:""`) would accept any value. *)
      | Some "" -> asstr base = Some ""
      | Some text ->
        let basestr = stringify base in
        let tlen = String.length text in
        if tlen > 2 && text.[0] = '/' && text.[tlen - 1] = '/' then
          regex_find (String.sub text 1 (tlen - 2)) basestr
        else
          let lowbase = String.lowercase_ascii basestr in
          let lowwant = String.lowercase_ascii text in
          let blen = String.length lowbase in
          let wlen = String.length lowwant in
          let rec search at =
            if at + wlen > blen then false
            else if String.sub lowbase at wlen = lowwant then true
            else search (at + 1)
          in
          wlen = 0 || search 0
      | None -> deepequal want base

(* Convert NULLMARK sentinels back into real nulls. *)
let nullmodifier value =
  match asstr value with
  | Some text when text = nullmark -> Null
  | Some text ->
    let buf = Buffer.create (String.length text) in
    let mlen = String.length nullmark in
    let at = ref 0 in
    while !at < String.length text do
      if !at + mlen <= String.length text && String.sub text !at mlen = nullmark then begin
        Buffer.add_string buf "null";
        at := !at + mlen
      end
      else begin
        Buffer.add_char buf text.[!at];
        incr at
      end
    done;
    Str (Buffer.contents buf)
  | None -> value

(* The spec-defined part of an entry (drop runner bookkeeping). *)
let entrysummary entry =
  match entry with
  | JMap entries ->
    JMap (List.filter (fun (key, _) -> key <> "res" && key <> "thrown" && key <> "ctx") entries)
  | other -> other

(* The label of one entry, for failure messages. *)
let entryref label index entry =
  let id = jget entry "id" in
  let idpart = if isabsent id then "" else " (" ^ stringify id ^ ")" in
  Printf.sprintf "%s[%d]%s" label index idpart

let fail label index entry reason expected actual =
  let buf = Buffer.create 128 in
  Buffer.add_string buf (Printf.sprintf "omni: %s: %s" (entryref label index entry) reason);
  (match expected with
  | Some text -> Buffer.add_string buf ("\n  expected: " ^ text)
  | None -> ());
  (match actual with Some text -> Buffer.add_string buf ("\n  actual:   " ^ text) | None -> ());
  Buffer.add_string buf ("\n  entry:    " ^ stringify (entrysummary entry));
  Omni_error (Buffer.contents buf)

let iswait wait = match jget wait "cause" with Str cause -> cause <> "" | _ -> false

(* Strict entry validation, applied when the spec declares version 1 or
   later. The lenient format converts each of these mistakes into a
   silent pass or a dead field; here they fail with the entry named. *)
let checkentry label index entry requires =
  (match entry with
  | JMap fields ->
    List.iter
      (fun (key, _) ->
        let capfield =
          match List.assoc_opt key capfields with Some cap -> List.mem cap requires | None -> false
        in
        if not (List.mem key entryfields || capfield) then
          raise (fail label index entry ("unknown entry field: " ^ key) None None))
      fields
  | _ -> raise (fail label index entry "entry is not a map" None None));

  (if List.mem "ctxargs" requires then begin
     if jhas entry "in" && (jhas entry "args" || jhas entry "ctx") then
       raise (fail label index entry "entry has in beside args or ctx" None None)
   end
   else
     let argsources = List.length (List.filter (fun key -> jhas entry key) [ "in"; "args"; "ctx" ]) in
     if 1 < argsources then
       raise (fail label index entry "entry has more than one of in, args, ctx" None None));

  (match jget entry "fn" with
  | Absent -> ()
  | Str fn when fn <> "" -> ()
  | _ -> raise (fail label index entry "entry fn is not a name" None None));

  (match jget entry "wait" with
  | Absent -> ()
  | wait -> if not (iswait wait) then raise (fail label index entry "entry wait has no cause" None None));

  (* `err` here is a presence-and-non-null check (an `err: null` entry is
     not "expects an error"), but `out` is presence alone - the two
     sentinels the rest of the runner distinguishes throughout. *)
  if (not (isnone (jget entry "err"))) && jhas entry "out" then
    raise (fail label index entry "entry has both err and out" None None);

  if jhas entry "id" && not (isstr (jget entry "id")) then
    raise (fail label index entry "entry id is not a string" None None)

(* Validate a version-1 group up front, against the AUTHORED entries -
   null-normalisation would otherwise rewrite an authored null (e.g. id:
   null) into a sentinel string and hide it from validation. A malformed
   spec is a spec error, not a test result, so it fails before any
   subject runs. *)
let checkset label testspec normalset requires =
  let origset =
    if ismap testspec then
      match aslist (jget testspec "set") with Some entries -> entries | None -> normalset
    else normalset
  in

  let emptyflag = match jget testspec "empty" with Bool true -> true | _ -> false in

  if [] = origset && not emptyflag then raise (Omni_error ("omni: empty test set: " ^ label));

  List.iteri (fun index entry -> checkentry label index entry requires) origset

(* Check that every leaf of `check` is present, and matches, in `base`. *)
let rec matchcheck label index entry check base path =
  let where = if path = [] then "<root>" else pathify path in
  match check with
  | JList entries ->
    List.iteri
      (fun at subcheck -> matchcheck label index entry subcheck base (path @ [ string_of_int at ]))
      entries
  | JMap entries ->
    List.iter (fun (key, subcheck) -> matchcheck label index entry subcheck base (path @ [ key ])) entries
  | leaf ->
    let baseval = getpath base path in
    (* The sentinels are tested BEFORE the identity check below. Otherwise a
       subject returning the literal string "__UNDEF__" satisfies an
       assertion that the key is absent - two mutually exclusive states
       passing one check. A sentinel that accepts its own literal is not a
       sentinel. (NULLMARK still accepts NULLMARK: under the default null
       flag a real null has already been normalised to it, so the two are
       genuinely indistinguishable here - that one needs a raw-value escape,
       not an ordering change.) *)

    (* Explicitly absent: satisfied only by a genuinely missing key, never
       by a present null (the distinction the sentinels exist to keep). *)
    if asstr leaf = Some undefmark then begin
      if not (isabsent baseval) then
        raise
          (fail label index entry ("expected absent at " ^ where) (Some "absent")
             (Some (stringify baseval)))
    end
      (* Explicitly null: satisfied only by a present null. *)
    else if asstr leaf = Some nullmark then begin
      if not (isnull baseval || asstr baseval = Some nullmark) then
        raise
          (fail label index entry ("expected null at " ^ where) (Some "null")
             (Some (stringify baseval)))
    end
      (* Explicitly present: any present value, including null. *)
    else if asstr leaf = Some existsmark then begin
      if isabsent baseval then
        raise
          (fail label index entry ("expected present at " ^ where) (Some "present") (Some "absent"))
    end
      (* Identical values match. This sits below the sentinel branches on
         purpose - see the note above. *)
    else if deepequal leaf baseval then ()
      (* A concrete expectation never matches a missing key - a match leaf
         against an absent value must fail, not substring-match "undefined". *)
    else if isabsent baseval then
      raise
        (fail label index entry ("match failed at " ^ where) (Some (stringify leaf)) (Some "absent"))
    else if not (matchval leaf baseval) then
      raise
        (fail label index entry ("match failed at " ^ where) (Some (stringify leaf))
           (Some (stringify baseval)))

let checkresult label index entry args res =
  let entryerr = jget entry "err" in
  if not (isnone entryerr) then
    raise
      (fail label index entry "expected error did not occur" (Some (stringify entryerr))
         (Some (stringify res)));

  let check = jget entry "match" in
  let matched = not (isnone check) in

  if matched then begin
    let base =
      JMap
        [
          ("in", jget entry "in");
          ("args", JList args);
          ("out", jget entry "res");
          ("ctx", jget entry "ctx");
        ]
    in
    matchcheck label index entry check base []
  end;

  let out = jget entry "out" in

  if deepequal res out then ()
    (* NOTE: a match with no explicit out is a complete check on its own. *)
  else if matched && (isnone out || asstr out = Some nullmark) then ()
  else raise (fail label index entry "result mismatch" (Some (stringify out)) (Some (stringify res)))

(* The error base a `match.err` sees: the provider's own, when it has one. *)
let errbase message (provider : provider) =
  match provider.errify with Some hook -> hook message | None -> errify message

let handleerror label index entry message provider =
  let entryerr = jget entry "err" in

  if isnone entryerr then
    raise (fail label index entry "unexpected error" None (Some message))
  else
    let istrue = match entryerr with Bool true -> true | _ -> false in
    if istrue || matchval entryerr (Str message) then begin
      let check = jget entry "match" in
      if not (isnone check) then
        let base =
          JMap
            [
              ("in", jget entry "in");
              ("out", jget entry "res");
              ("ctx", jget entry "ctx");
              ("err", errbase message provider);
            ]
        in
        matchcheck label index entry check base []
    end
    else
      raise (fail label index entry "error mismatch" (Some (stringify entryerr)) (Some message))

(* What a runner returns for one named spec section. *)
type runpack = {
  spec : json;
  set : string -> json;
  runset : json -> subject option -> unit;
  runsetflags : ?all:bool -> ?wait:json -> json -> flags -> subject option -> unit;
  (* Everything runsetflags does, for a subject that may rewrite its
     arguments. See `subject_args`. *)
  runsetflags_args : ?all:bool -> ?wait:json -> json -> flags -> subject_args -> unit;
  defsubject : subject option;
  client : provider;
}

let resolvesubject name (provider : provider) =
  if name = "" then None
  else match provider.subject with None -> None | Some resolve -> resolve name

(* An entry with no `out` expects a null (or absent) result. *)
let resolveentry entry (flags : flags) =
  if flags.null && isnone (jget entry "out") then jset entry "out" (Str nullmark) else entry

let resolvetestpack name entry subject (provider : provider) clients fnon =
  let client, subject =
    match asstr (jget entry "client") with
    | None -> (provider, subject)
    | Some clientname -> (
      match List.assoc_opt clientname clients with
      | None -> raise (Omni_error ("omni: unknown client: " ^ clientname))
      | Some client ->
        (client, match resolvesubject name client with Some found -> Some (Subject found) | None -> subject))
  in
  match asstr (jget entry "fn") with
  | Some fn when fnon -> (
    match resolvesubject fn client with
    | Some found -> Some (Subject found)
    | None -> raise (Omni_error ("omni: unknown fn: " ^ fn)))
  | _ -> subject

(* Build the argument list: `ctx`, `args`, or `in`. Under `ctxargs` an
   entry with both passes the context first, then each argument. *)
let resolveargs entry (provider : provider) ctxargs =
  let hasctx = jhas entry "ctx" in
  let hasargs = jhas entry "args" in
  let listargs () = match jget entry "args" with JList list -> list | other -> [ other ] in
  let args =
    if ctxargs && hasctx && hasargs then jget entry "ctx" :: listargs ()
    else if hasctx then [ jget entry "ctx" ]
    else if hasargs then listargs ()
    else [ clone (jget entry "in") ]
  in
  match args with
  | first :: rest when (hasctx || hasargs) && ismap first ->
    let first = match provider.contextify with Some contextify -> contextify first | None -> first in
    (* json has no variant to hold a live provider, so the canonical
       `first.client = testpack.client` becomes presence, not identity. *)
    let first = jset first "client" (Bool true) in
    (first :: rest, jset entry "ctx" first)
  | _ -> (args, entry)

(* The runner-side waits: entry id to its declaration. Each must name an
   entry of the set, so a declaration cannot outlive the entry it held. *)
let resolvewaits label wait origset =
  match wait with
  | None | Some (Absent | Null) -> []
  | Some (JMap waits) ->
    let ids = List.filter_map (fun entry -> asstr (jget entry "id")) origset in
    List.iter
      (fun (id, decl) ->
        if not (List.mem id ids) then
          raise (Omni_error ("omni: " ^ label ^ ": wait names no entry: " ^ id));
        if not (iswait decl) then
          raise (Omni_error ("omni: " ^ label ^ ": wait for " ^ id ^ " has no cause")))
      waits;
    waits
  | Some _ -> raise (Omni_error ("omni: " ^ label ^ ": wait flag is not a map"))

(* A raw error is the entry's, for an `err` expectation to meet; the
   runner's own failure passes through. *)
let entryerror label index entry (provider : provider) err =
  match err with
  | Omni_error _ -> raise err
  | _ -> handleerror label index entry (errmessage err) provider

let runentry label (flags : flags) index entry subject (provider : provider) ctxargs =
  (* An args-subject may overwrite its argument array; the runner reads it
     back so `match.args` sees what the subject actually did. *)
  let invoke args =
    match subject with
    | Subject call -> (args, call args)
    | Subject_args call ->
      let cells = Array.of_list args in
      let res = call cells in
      (Array.to_list cells, res)
  in
  match resolveargs entry provider ctxargs with
  | exception err -> entryerror label index entry provider err
  | args, entry -> (
    match invoke args with
    | args, res ->
      let fixed = fixjson res flags.null in
      checkresult label index (jset entry "res" fixed) args fixed
    | exception err -> entryerror label index entry provider err)

(* Make a runner for a spec value and a provider. Resolving the version
   here - outside the returned closure - fails fast: a spec this runner
   cannot faithfully run is refused as soon as the runner is made, before
   any group name is even chosen. *)
let make_runner_spec alltests (provider : provider) =
  let specversion = resolveversion alltests in
  let requires = resolverequires alltests in
  let ctxargs = List.mem "ctxargs" requires in
  let fnon = List.mem "fn" requires in
  let waiton = List.mem "wait" requires in
  fun name store ->
   let spec = resolvespec name alltests in

   (* A spec may define clients that a given test run never references. *)
   let clients =
     match (asmap (jget (jget spec "DEF") "client"), provider.client) with
     | Some entries, Some clientmaker ->
       List.map
         (fun (clientname, cdef) ->
           let copts = jget (jget cdef "test") "options" in
           let copts = if isabsent copts then JMap [] else copts in
           let copts =
             match (provider.inject, store) with
             | Some inject, Some storeval when ismap storeval -> inject copts storeval
             | _ -> copts
           in
           (clientname, clientmaker copts))
         entries
     | _ -> []
   in

   let defsubject = resolvesubject name provider in

   let drive all wait testspec (flags : flags) testsubject =
     let label =
       match flags.name with Some text -> text | None -> if name = "" then "set" else name
     in

     let subject =
       match testsubject with
       | Some _ -> testsubject
       | None -> Option.map (fun found -> Subject found) defsubject
     in
     if Option.is_none subject && not fnon then
       raise (Omni_error ("omni: no test subject for: " ^ label));

     let testspecmap = fixjson testspec flags.null in
     let testset =
       match aslist (jget testspecmap "set") with
       | Some entries -> entries
       | None -> raise (Omni_error ("omni: test spec has no set: " ^ label))
     in

     (* Validated against the AUTHORED `testspec`, not the null-normalised
        `testset` above - see checkset. *)
     if 1 <= specversion then checkset label testspec testset requires;

     let origset = match aslist (jget testspec "set") with Some entries -> entries | None -> testset in
     let waits = resolvewaits label wait origset in

     let runone index rawentry =
       if not (ismap rawentry) then
         raise (Omni_error (Printf.sprintf "omni: %s[%d]: entry is not a map" label index));

       let entry = resolveentry rawentry flags in

       (* A hook's raw error before the subject starts is still the entry's,
          and runs through the held path like any other failure. *)
       let resolved =
         match resolvetestpack name entry subject provider clients fnon with
         | Some entrysubject -> Ok entrysubject
         | None -> raise (Omni_error ("omni: no test subject for: " ^ label))
         | exception (Omni_error _ as err) -> raise err
         | exception prestart -> Error prestart
       in

       let held =
         if waiton && jhas entry "wait" then Some (jget entry "wait")
         else Option.bind (asstr (jget entry "id")) (fun id -> List.assoc_opt id waits)
       in

       let run () =
         match resolved with
         | Ok entrysubject -> runentry label flags index entry entrysubject provider ctxargs
         | Error prestart -> handleerror label index entry (errmessage prestart) provider
       in

       match held with
       | None -> run ()
       | Some heldwait -> (
         match run () with
         | () ->
           raise (fail label index entry ("stale wait: " ^ stringify (jget heldwait "cause")) None None)
         | exception Omni_error _ -> ())
     in

     let failures = ref [] in
     List.iteri
       (fun index rawentry ->
         match runone index rawentry with
         | () -> ()
         | exception Omni_error message when all -> failures := message :: !failures)
       testset;

     match List.rev !failures with
     | [] -> ()
     | messages ->
       raise
         (Omni_error
            (Printf.sprintf "omni: %s: %d of %d entries failed\n%s" label (List.length messages)
               (List.length testset) (String.concat "\n" messages)))
   in

   let runsetflags ?(all = false) ?wait testspec flags testsubject =
     drive all wait testspec flags (Option.map (fun found -> Subject found) testsubject)
   in
   let runsetflags_args ?(all = false) ?wait testspec flags argsubject =
     drive all wait testspec flags (Some (Subject_args argsubject))
   in

   {
     spec;
     set = (fun setname -> jget spec setname);
     runset = (fun testspec testsubject -> runsetflags testspec default_flags testsubject);
     runsetflags;
     runsetflags_args;
     defsubject;
     client = provider;
   }

(* Make a runner for a spec file path and a provider. *)
let make_runner path (provider : provider) = make_runner_spec (loadspec path) provider
