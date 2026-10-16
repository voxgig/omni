(* RUN: make test
   RUN-SOME: ./build/omnitest basic

   The Fibonacci conformance suite: every omni port runs this same set of
   groups, from the same spec/fib.json, against the same fib library.

   No third-party test framework: a failing omni check raises Omni_error,
   which alcotest or ounit reports as a failure. This harness keeps
   `make test` dependency-free. *)

open Omni

let only = ref None
let passcount = ref 0
let failcount = ref 0

(* Find the shared spec directory by walking up from the working dir. *)
let specfile name =
  let rec search dir step =
    if step >= 8 then raise (Omni_error ("omni: spec not found: " ^ name))
    else
      let cand = Filename.concat (Filename.concat dir "spec") name in
      if Sys.file_exists cand then cand else search (Filename.concat dir Filename.parent_dir_name) (step + 1)
  in
  search (Sys.getcwd ()) 0

let fibsub args = Fib.fib (List.nth args 0)
let fibseqsub args = Fib.fibseq (List.nth args 0)
let fibrangesub args = Fib.fibrange (List.nth args 0) (List.nth args 1)
let fibinfosub args = Fib.fibinfo (List.nth args 0)
let fibctxsub args = Fib.fibctx (List.nth args 0)

(* A subject that returns the literal string "__UNDEF__" as ordinary data -
   it must not satisfy an __UNDEF__ (absent) match assertion. *)
let undefsub _args = JMap [ ("a", Str "__UNDEF__") ]

(* The provider hosts the system under test. `shift` offsets the Fibonacci
   index, so that a client-specific subject is observably different.
   `contextify` marks the map, so the context group can prove the hook
   ran. *)
let rec fibprovider shift =
  {
    empty_provider with
    subject =
      Some
        (fun name ->
          match name with
          | "fib" ->
            Some
              (fun args ->
                match asnum (List.nth args 0) with
                | Some num -> Fib.fib (Num (num +. shift))
                | None -> Fib.fib (List.nth args 0))
          | "fibseq" -> Some fibseqsub
          | "fibrange" -> Some fibrangesub
          | "fibinfo" -> Some fibinfosub
          | _ -> None);
    client =
      Some
        (fun options ->
          match asnum (jget options "shift") with
          | Some num -> fibprovider num
          | None -> fibprovider 0.0);
    contextify = Some (fun ctxval -> jset ctxval "mark" (Str "CTX"));
  }

(* Derive fib's error code from its message. *)
let fiberrcode message =
  let has needle =
    let nlen = String.length needle and mlen = String.length message in
    let rec scan at = at + nlen <= mlen && (String.sub message at nlen = needle || scan (at + 1)) in
    scan 0
  in
  if has "negative index" then "fib_negative"
  else if has "non-integer" then "fib_noninteger"
  else if has "not a number" then "fib_notanumber"
  else "fib_unknown"

(* The same provider, plus the `errify` hook: fib's errors gain a CODE.

   A SECOND runner rather than a hook on [fibprovider], so that the
   `error` group keeps exercising the DEFAULT errify. *)
let fibcodedprovider () =
  {
    (fibprovider 0.0) with
    errify =
      Some
        (fun message ->
          JMap
            [
              ("name", Str "Error");
              ("message", Str message);
              ("code", Str (fiberrcode message));
            ]);
  }

let testcase name body =
  match !only with
  | Some wanted when wanted <> name -> ()
  | _ -> (
    match body () with
    | () ->
      incr passcount;
      print_endline ("ok   - " ^ name)
    | exception err ->
      incr failcount;
      print_endline ("FAIL - " ^ name);
      print_endline (errmessage err))

(* The runner must fail when the subject is wrong - otherwise a green suite
   means nothing. *)
let badspec =
  JMap
    [
      ( "fib",
        JMap
          [
            ( "wrongout",
              JMap
                [
                  ( "set",
                    JList
                      [
                        JMap [ ("in", Num 5.0); ("out", Num 5.0) ];
                        JMap [ ("in", Num 6.0); ("out", Num 999.0) ];
                      ] );
                ] );
            ( "wrongerr",
              JMap [ ("set", JList [ JMap [ ("in", Num 1.0); ("err", Str "never happens") ] ]) ] );
            ( "wrongmatch",
              JMap
                [
                  ( "set",
                    JList [ JMap [ ("in", Num 6.0); ("match", JMap [ ("out", Num 999.0) ]) ] ] );
                ] );
            ( "missing",
              JMap
                [
                  ( "set",
                    JList
                      [
                        JMap
                          [
                            ("in", Num 6.0);
                            ("match", JMap [ ("out", JMap [ ("nope", Str "__EXISTS__") ]) ]);
                          ];
                      ] );
                ] );
            (* A concrete match leaf against a missing key must fail, not
               substring-match the text "undefined". *)
            ( "matchabsent",
              JMap
                [
                  ( "set",
                    JList
                      [
                        JMap
                          [
                            ("in", Num 6.0);
                            ("match", JMap [ ("out", JMap [ ("nope", Str "fine") ]) ]);
                          ];
                      ] );
                ] );
            (* __UNDEF__ (absent) must not be satisfied by a present null. *)
            ( "undefonnull",
              JMap
                [
                  ( "set",
                    JList
                      [
                        JMap
                          [
                            ("in", Num 0.0);
                            ("match", JMap [ ("out", JMap [ ("prev", Str "__UNDEF__") ]) ]);
                          ];
                      ] );
                ] );
            (* __NULL__ (present null) must not be satisfied by an absent key. *)
            ( "nullonabsent",
              JMap
                [
                  ( "set",
                    JList
                      [
                        JMap
                          [
                            ("in", Num 6.0);
                            ("match", JMap [ ("out", JMap [ ("nope", Str "__NULL__") ]) ]);
                          ];
                      ] );
                ] );
            (* A subject returning the literal string "__UNDEF__" as
               ordinary data must not satisfy an __UNDEF__ (absent)
               assertion - the sentinel never accepts its own literal. *)
            ( "wrongundef",
              JMap
                [
                  ( "set",
                    JList
                      [
                        JMap
                          [
                            ("in", Num 6.0);
                            ("match", JMap [ ("out", JMap [ ("a", Str "__UNDEF__") ]) ]);
                          ];
                      ] );
                ] );
            (* An empty-string match leaf is not a wildcard. *)
            ( "emptystr",
              JMap
                [
                  ( "set",
                    JList
                      [
                        JMap
                          [
                            ("in", Num 6.0);
                            ("match", JMap [ ("out", JMap [ ("label", Str "") ]) ]);
                          ];
                      ] );
                ] );
          ] );
    ]

let expectfail setname subject =
  let pack = (make_runner_spec badspec empty_provider) "fib" None in
  match pack.runset (pack.set setname) (Some subject) with
  | () -> raise (Failure ("omni: expected a failure for set: " ^ setname))
  | exception Omni_error _ -> ()

(* Is `needle` a substring of `haystack`? Used to pin the reason inside an
   OmniError message, the same way checkmessage below pins one message in
   full. *)
let containsstr haystack needle =
  let hlen = String.length haystack and nlen = String.length needle in
  let rec search at = (at + nlen <= hlen) && (String.sub haystack at nlen = needle || search (at + 1)) in
  search 0

(* Assert that building a runner from `spec` fails at load time - before
   any group is named - with a message containing `want`. *)
let expectloadfail spec want =
  match make_runner_spec spec empty_provider with
  | _ -> raise (Failure ("omni: expected a load failure containing [" ^ want ^ "]"))
  | exception Omni_error message ->
    if not (containsstr message want) then
      raise (Failure ("omni: message missing [" ^ want ^ "]: " ^ message))

(* Assert that running `setname` out of `spec` fails with a message
   containing `want` - the strict (version >= 1) entry-validation cases. *)
let expectentryfail spec setname subject want =
  let pack = (make_runner_spec spec empty_provider) "fib" None in
  match pack.runset (pack.set setname) (Some subject) with
  | () -> raise (Failure ("omni: expected a failure for set: " ^ setname))
  | exception Omni_error message ->
    if not (containsstr message want) then
      raise (Failure ("omni: message missing [" ^ want ^ "]: " ^ message))

(* Specs used only by the version/strict-validation negative tests below. *)
let badversion =
  JMap [ ("OMNI", JMap [ ("version", Num 99.0) ]); ("fib", JMap [ ("g", JMap [ ("set", JList []) ]) ]) ]

let badcapability =
  JMap
    [
      ("OMNI", JMap [ ("version", Num 1.0); ("requires", JList [ Str "nosuchfeature" ]) ]);
      ("fib", JMap [ ("g", JMap [ ("set", JList []) ]) ]);
    ]

let badversiontype =
  JMap [ ("OMNI", JMap [ ("version", Str "one") ]); ("fib", JMap [ ("g", JMap [ ("set", JList []) ]) ]) ]

let strictunknownfield =
  JMap
    [
      ("OMNI", JMap [ ("version", Num 1.0) ]);
      ( "fib",
        JMap
          [ ("g", JMap [ ("set", JList [ JMap [ ("in", Num 6.0); ("matches", JMap [ ("out", Num 999.0) ]) ] ]) ]) ] );
    ]

let strictmultisource =
  JMap
    [
      ("OMNI", JMap [ ("version", Num 1.0) ]);
      ( "fib",
        JMap [ ("g", JMap [ ("set", JList [ JMap [ ("in", Num 5.0); ("args", JList [ Num 5.0 ]); ("out", Num 5.0) ] ]) ]) ] );
    ]

let stricterrandout =
  JMap
    [
      ("OMNI", JMap [ ("version", Num 1.0) ]);
      ( "fib",
        JMap
          [ ("g", JMap [ ("set", JList [ JMap [ ("in", Num (-1.0)); ("err", Bool true); ("out", Num 5.0) ] ]) ]) ] );
    ]

let strictnullid =
  JMap
    [
      ("OMNI", JMap [ ("version", Num 1.0) ]);
      ( "fib",
        JMap
          [ ("g", JMap [ ("set", JList [ JMap [ ("in", Num 1.0); ("out", Num 1.0); ("id", Null) ] ]) ]) ] );
    ]

let strictemptyset =
  JMap
    [
      ("OMNI", JMap [ ("version", Num 1.0) ]);
      ( "fib",
        JMap
          [
            ("g", JMap [ ("set", JList []) ]);
            ("h", JMap [ ("set", JList []); ("empty", Bool true) ]);
          ] );
    ]

let legacylenient =
  JMap
    [
      ( "fib",
        JMap
          [
            ( "g",
              JMap
                [
                  ( "set",
                    JList
                      [ JMap [ ("in", Num 6.0); ("matches", JMap [ ("out", Num 999.0) ]); ("out", Num 8.0) ] ] );
                ] );
          ] );
    ]

(* Rejects a null OMNI block (malformed), but accepts one that is simply
   absent (legacy) - the presence-vs-null distinction from Fix 2. *)
let checknullomni () =
  let nullomni =
    JMap
      [
        ("OMNI", Null);
        ("fib", JMap [ ("g", JMap [ ("set", JList [ JMap [ ("in", Num 1.0); ("out", Num 1.0) ] ]) ]) ]);
      ]
  in
  expectloadfail nullomni "malformed OMNI";

  let nullrequires =
    JMap
      [
        ("OMNI", JMap [ ("version", Num 1.0); ("requires", Null) ]);
        ("fib", JMap [ ("g", JMap [ ("set", JList [ JMap [ ("in", Num 1.0); ("out", Num 1.0) ] ]) ]) ]);
      ]
  in
  expectloadfail nullrequires "malformed OMNI requires list";

  let legacyabsent =
    JMap [ ("fib", JMap [ ("g", JMap [ ("set", JList [ JMap [ ("in", Num 1.0); ("out", Num 1.0) ] ]) ]) ]) ]
  in
  ignore (make_runner_spec legacyabsent empty_provider)

(* Strict: an empty set fails unless marked `empty: true`. *)
let checkstrictemptyset () =
  let pack = (make_runner_spec strictemptyset empty_provider) "fib" None in
  (match pack.runset (pack.set "g") (Some fibsub) with
  | () -> raise (Failure "omni: expected empty test set failure")
  | exception Omni_error message ->
    if not (containsstr message "empty test set") then
      raise (Failure ("omni: message missing [empty test set]: " ^ message)));
  pack.runset (pack.set "h") (Some fibsub)

let checkmessage () =
  let spec =
    JMap
      [
        ( "fib",
          JMap
            [
              ( "g",
                JMap
                  [
                    ( "set",
                      JList
                        [
                          JMap [ ("in", Num 1.0); ("out", Num 1.0) ];
                          JMap [ ("id", Str "x#2"); ("in", Num 2.0); ("out", Num 42.0) ];
                        ] );
                  ] );
            ] );
      ]
  in

  let pack = (make_runner_spec spec empty_provider) "fib" None in

  match pack.runset (pack.set "g") (Some fibsub) with
  | () -> raise (Failure "omni: expected a failure")
  | exception Omni_error message ->
    List.iter
      (fun want ->
        let wlen = String.length want in
        let mlen = String.length message in
        let rec search at =
          if at + wlen > mlen then false
          else if String.sub message at wlen = want then true
          else search (at + 1)
        in
        if not (search 0) then
          raise (Failure ("omni: message missing [" ^ want ^ "]: " ^ message)))
      [ "fib[1] (x#2)"; "expected: 42"; "actual:   1" ]

(* ---- deepequal: NaN is structurally equal to NaN ---------------------

   deepequal is structural, not IEEE: two NaNs are equal however each one
   was made (src/omni.ml: `Float.is_nan x && Float.is_nan y`). Nothing in
   spec/fib.json can pin that - JSON has no NaN literal - so it is pinned
   here.

   The two NaNs come from different expressions and differ bit for bit.
   A test that used one NaN constant twice could pass on an equality or
   sharing fast path while proving nothing, so the distinctness is
   asserted first: collapse the pair into a single shared constant and
   this test fails loudly instead of going quiet. *)

let nan1 = 0.0 /. 0.0
let nan2 = Int64.float_of_bits 0x7FF8000000000001L

let checkequal want a b label =
  if deepequal a b <> want then
    raise
      (Failure ("omni: deepequal " ^ label ^ ": expected " ^ (if want then "true" else "false")))

let checkdeepequalnan () =
  if not (Float.is_nan nan1 && Float.is_nan nan2) then
    raise (Failure "omni: nan1 and nan2 must both be NaN");
  if Int64.bits_of_float nan1 = Int64.bits_of_float nan2 then
    raise (Failure "omni: nan1 and nan2 must be two distinct NaN values");

  checkequal true (Num nan1) (Num nan2) "NaN, NaN";
  checkequal true (JList [ Num nan1 ]) (JList [ Num nan2 ]) "[NaN], [NaN]";
  checkequal true (JMap [ ("x", Num nan1) ]) (JMap [ ("x", Num nan2) ]) "{x: NaN}, {x: NaN}";

  (* Regressions: the NaN branch must not loosen anything else. OCaml has
     a single numeric constructor, so the int/float case is one Num value
     reached two ways. *)
  checkequal true (Num 1.0) (Num (float_of_int 1)) "1, 1.0";
  checkequal false (Num nan1) (Num 1.0) "NaN, 1.0";
  checkequal false (Bool true) (Num 1.0) "true, 1";
  checkequal false (Num 1.0) (Num 2.0) "1, 2"

let checkunicodepair () =
  let spec = loadspec "test/unicode.json" in
  let literal = jget spec "literal" in
  if literal <> Str "\xf0\x9f\x98\x80" then
    raise (Failure "omni: the literal must be the 4-byte UTF-8 of U+1F600");
  if not (deepequal (jget spec "escaped") literal && deepequal (jget spec "upper") literal)
  then raise (Failure "omni: an escaped pair must deep-equal the literal");
  if parse "\"\\u0041\\u00e9\\u20ac\"" <> Str "A\xc3\xa9\xe2\x82\xac" then
    raise (Failure "omni: a BMP escape must still encode as itself");
  if parse "\"a\\u0000b\"" <> Str "a\000b" then
    raise (Failure "omni: a \\u0000 escape must be kept")

let checkunicodelone () =
  List.iter
    (fun text ->
      match parse text with
      | _ -> raise (Failure ("omni: expected a parse error for " ^ text))
      | exception Omni_error msg when containsstr msg "lone surrogate" -> ())
    [ "\"\\ud800\""; "\"\\ude00\""; "\"\\ude00\\ud83d\""; "\"\\ud83dx\""; "\"\\ud83d\\u0041\"";
      "\"\\ud83d\\ud83d\"" ]

(* ---- capabilities (spec/ext.json) and the `all` flag ---------------- *)

(* The ctxargs subject: the context comes first, and must arrive
   contextified with its client attached. *)
let fibshifted args =
  match args with
  | [ ctx; start; stop ] when asstr (jget ctx "mark") = Some "CTX" && not (isnone (jget ctx "client")) ->
    let shift value =
      match (asnum value, asnum (jget ctx "shift")) with
      | Some num, Some by -> Num (num +. by)
      | _ -> value
    in
    Fib.fibrange (shift start) (shift stop)
  | _ -> raise (Fib.Fib_error "fib: context not delivered")

let extrunner spec = (make_runner_spec spec (fibprovider 0.0)) "fib" None

let v1 requires set =
  parse (Printf.sprintf {|{"OMNI":{"version":1,"requires":[%s]},"fib":{"g":{"set":[%s]}}}|} requires set)

let refuses run pattern =
  match run () with
  | () -> raise (Failure ("omni: expected a failure matching /" ^ pattern ^ "/"))
  | exception Omni_error message ->
    if not (regex_find pattern message) then
      raise (Failure ("omni: message does not match /" ^ pattern ^ "/: " ^ message))

let extsuite () =
  let pack = extrunner (loadspec (specfile "ext.json")) in

  testcase "ext capabilities" (fun () ->
      List.iter
        (fun cap -> if not (List.mem cap capabilities) then raise (Failure ("omni: missing capability: " ^ cap)))
        [ "ctxargs"; "fn"; "wait" ]);
  testcase "ext ctxargs" (fun () -> pack.runset (pack.set "ctxargs") (Some fibshifted));
  testcase "ext fn" (fun () -> pack.runset (pack.set "fn") (Some fibsub));
  testcase "ext wait" (fun () -> pack.runset (pack.set "wait") (Some fibsub));

  testcase "a waiting entry that passes fails the set" (fun () ->
      let pack = extrunner (v1 {|"wait"|} {|{"in":5,"out":5,"wait":{"cause":"gone#1"}}|}) in
      refuses (fun () -> pack.runset (pack.set "g") (Some fibsub)) {|\[0\]: stale wait: gone#1|});

  testcase "the wait flag holds an entry by id" (fun () ->
      let pack = extrunner (v1 "" {|{"id":"a","in":6,"out":9},{"in":7,"out":13}|}) in
      pack.runsetflags ~wait:(parse {|{"a":{"cause":"flag#1"}}|}) (pack.set "g") default_flags (Some fibsub));

  testcase "the wait flag fails when its entry passes" (fun () ->
      let pack = extrunner (v1 "" {|{"id":"a","in":6,"out":8}|}) in
      refuses
        (fun () ->
          pack.runsetflags ~wait:(parse {|{"a":{"cause":"flag#1"}}|}) (pack.set "g") default_flags (Some fibsub))
        "stale wait: flag#1");

  testcase "the wait flag must name an entry" (fun () ->
      let pack = extrunner (v1 "" {|{"id":"a","in":6,"out":8}|}) in
      refuses
        (fun () ->
          pack.runsetflags ~wait:(parse {|{"zz":{"cause":"c"}}|}) (pack.set "g") default_flags (Some fibsub))
        "wait names no entry: zz");

  testcase "a wait needs a cause" (fun () ->
      let pack = extrunner (v1 {|"wait"|} {|{"in":6,"out":9,"wait":{}}|}) in
      refuses (fun () -> pack.runset (pack.set "g") (Some fibsub)) "entry wait has no cause");

  testcase "wait and fn are unknown fields unless required" (fun () ->
      let wpack = extrunner (v1 "" {|{"in":6,"out":9,"wait":{"cause":"c"}}|}) in
      refuses (fun () -> wpack.runset (wpack.set "g") (Some fibsub)) "unknown entry field: wait";
      let fpack = extrunner (v1 "" {|{"fn":"fib","in":6,"out":8}|}) in
      refuses (fun () -> fpack.runset (fpack.set "g") (Some fibsub)) "unknown entry field: fn");

  testcase "an unknown fn is a spec error" (fun () ->
      let pack = extrunner (v1 {|"fn"|} {|{"fn":"nope","in":6,"out":8}|}) in
      refuses (fun () -> pack.runset (pack.set "g") (Some fibsub)) "unknown fn: nope");

  testcase "ctx with args needs ctxargs, and never takes in" (fun () ->
      let npack = extrunner (v1 "" {|{"ctx":{"shift":0},"args":[0,1],"out":[0,1]}|}) in
      refuses (fun () -> npack.runset (npack.set "g") (Some fibshifted)) "more than one of in, args, ctx";
      let ipack = extrunner (v1 {|"ctxargs"|} {|{"in":1,"ctx":{"shift":0},"out":[0]}|}) in
      refuses (fun () -> ipack.runset (ipack.set "g") (Some fibshifted)) "entry has in beside args or ctx");

  testcase "a legacy spec ignores fn and wait" (fun () ->
      let pack =
        extrunner (parse {|{"fib":{"g":{"set":[{"in":6,"out":8,"fn":"nope","wait":{"cause":"c"}}]}}}|})
      in
      pack.runset (pack.set "g") (Some fibsub));

  testcase "a raising hook is the entry's error, not the set's" (fun () ->
      let provider =
        {
          empty_provider with
          subject = Some (fun _ -> Some fibsub);
          contextify = Some (fun _ -> failwith "contextify boom");
        }
      in
      let run spec = (make_runner_spec spec provider) "fib" None in
      let epack = run (v1 "" {|{"ctx":{"n":6},"err":"contextify boom"}|}) in
      epack.runset (epack.set "g") (Some fibsub);
      let upack = run (v1 "" {|{"ctx":{"n":6},"out":8}|}) in
      refuses
        (fun () -> upack.runset (upack.set "g") (Some fibsub))
        {|\[0\]: unexpected error\n\s+actual:\s+contextify boom|};
      let wpack = run (v1 {|"wait"|} {|{"ctx":{"n":6},"out":8,"wait":{"cause":"hook#1"}}|}) in
      wpack.runset (wpack.set "g") (Some fibsub);
      let boom =
        {
          empty_provider with
          subject = Some (fun name -> if name = "boom" then failwith "subject boom" else Some fibsub);
        }
      in
      let fpack = (make_runner_spec (v1 {|"fn"|} {|{"fn":"boom","in":6,"err":"subject boom"}|}) boom) "fib" None in
      fpack.runset (fpack.set "g") (Some fibsub));

  testcase "a waiting entry holds a hook's error raised before the subject starts" (fun () ->
      let provider =
        {
          empty_provider with
          subject =
            Some
              (fun name ->
                if name = "boom" then failwith "subject boom" else if name = "fib" then Some fibsub else None);
        }
      in
      let run spec = (make_runner_spec spec provider) "fib" None in
      let hpack = run (v1 {|"fn","wait"|} {|{"fn":"boom","in":6,"out":8,"wait":{"cause":"hook#2"}}|}) in
      hpack.runset (hpack.set "g") (Some fibsub);
      let spack = run (v1 {|"fn","wait"|} {|{"fn":"boom","in":6,"err":"subject boom","wait":{"cause":"hook#3"}}|}) in
      refuses (fun () -> spack.runset (spack.set "g") (Some fibsub)) {|\[0\]: stale wait: hook#3|});

  testcase "fn needs no default subject, but an entry without fn does" (fun () ->
      let provider =
        { empty_provider with subject = Some (fun name -> if name = "fibx" then Some fibsub else None) }
      in
      let run spec = (make_runner_spec spec provider) "fib" None in
      let rpack = run (v1 {|"fn"|} {|{"fn":"fibx","in":6,"out":8}|}) in
      rpack.runset (rpack.set "g") None;
      let npack = run (v1 {|"fn"|} {|{"fn":"fibx","in":6,"out":8},{"in":6,"out":8}|}) in
      refuses (fun () -> npack.runset (npack.set "g") None) {|^omni: no test subject for: fib$|};
      let lpack = run (v1 "" {|{"in":6,"out":8}|}) in
      refuses (fun () -> lpack.runset (lpack.set "g") None) {|^omni: no test subject for: fib$|});

  testcase "a wait is found by an id the entry owns, never an inherited one" (fun () ->
      let pack = extrunner (v1 "" {|{"id":"constructor","in":6,"out":8},{"id":"toString","in":7,"out":13}|}) in
      pack.runset (pack.set "g") (Some fibsub);
      pack.runsetflags ~wait:(JMap []) (pack.set "g") default_flags (Some fibsub));

  testcase "all reports every failure at once" (fun () ->
      let pack = extrunner (v1 "" {|{"in":5,"out":6},{"in":6,"out":8},{"in":7,"out":14}|}) in
      refuses
        (fun () -> pack.runsetflags ~all:true (pack.set "g") default_flags (Some fibsub))
        {|^omni: fib: 2 of 3 entries failed\n.*fib\[0\]: result mismatch.*fib\[2\]: result mismatch|};
      refuses (fun () -> pack.runset (pack.set "g") (Some fibsub)) {|^omni: fib\[0\]: result mismatch|})

let () =
  if Array.length Sys.argv > 1 then only := Some Sys.argv.(1);

  let pack = (make_runner (specfile "fib.json") (fibprovider 0.0)) "fib" None in
  let codedpack = (make_runner (specfile "fib.json") (fibcodedprovider ())) "fib" None in

  testcase "basic" (fun () -> pack.runset (pack.set "basic") (Some fibsub));
  testcase "seq" (fun () -> pack.runset (pack.set "seq") (Some fibseqsub));
  testcase "range" (fun () -> pack.runset (pack.set "range") (Some fibrangesub));
  testcase "info" (fun () -> pack.runset (pack.set "info") (Some fibinfosub));
  testcase "nulls" (fun () -> pack.runsetflags (pack.set "nulls") nonull_flags (Some fibinfosub));
  testcase "error" (fun () -> pack.runset (pack.set "error") (Some fibsub));
  testcase "errcode" (fun () -> codedpack.runset (codedpack.set "errcode") (Some fibsub));
  testcase "match" (fun () -> pack.runset (pack.set "match") (Some fibsub));
  testcase "matchinfo" (fun () -> pack.runset (pack.set "matchinfo") (Some fibinfosub));
  testcase "client" (fun () -> pack.runset (pack.set "client") (Some fibsub));
  testcase "context" (fun () -> pack.runset (pack.set "context") (Some fibctxsub));

  testcase "detects wrong result" (fun () -> expectfail "wrongout" fibsub);
  testcase "detects missing error" (fun () -> expectfail "wrongerr" fibsub);
  testcase "detects failed match" (fun () -> expectfail "wrongmatch" fibsub);
  testcase "detects absent key" (fun () -> expectfail "missing" fibinfosub);
  testcase "a concrete match leaf does not match a missing key" (fun () ->
      expectfail "matchabsent" fibinfosub);
  testcase "__UNDEF__ does not match a present null" (fun () -> expectfail "undefonnull" fibinfosub);
  testcase "__NULL__ does not match an absent key" (fun () -> expectfail "nullonabsent" fibinfosub);
  testcase "an empty-string match leaf is not a wildcard" (fun () ->
      expectfail "emptystr" fibinfosub);
  (* The literal string "__UNDEF__" returned as data does not satisfy an
     __UNDEF__ (absent) assertion. *)
  testcase "the literal __UNDEF__ as data does not match __UNDEF__" (fun () ->
      expectfail "wrongundef" undefsub);
  testcase "reports entry index and id" checkmessage;
  testcase "deepequal: NaN equals NaN, structurally" checkdeepequalnan;
  testcase "parse: an escaped surrogate pair is the literal character" checkunicodepair;
  testcase "parse: a lone surrogate escape is refused" checkunicodelone;

  testcase "rejects an unsupported spec version" (fun () ->
      expectloadfail badversion "unsupported spec version");
  testcase "rejects an unknown required capability" (fun () ->
      expectloadfail badcapability "unsupported capability");
  testcase "rejects a malformed version block" (fun () -> expectloadfail badversiontype "malformed OMNI");
  testcase "rejects a null OMNI block, but accepts an absent one" checknullomni;
  testcase "strict: an unknown entry field fails instead of passing vacuously" (fun () ->
      expectentryfail strictunknownfield "g" fibinfosub "unknown entry field: matches");
  testcase "strict: more than one of in, args, ctx fails" (fun () ->
      expectentryfail strictmultisource "g" fibsub "more than one of in, args, ctx");
  testcase "strict: err together with out fails" (fun () ->
      expectentryfail stricterrandout "g" fibsub "both err and out");
  testcase "strict: a null id fails even under null-normalisation" (fun () ->
      expectentryfail strictnullid "g" fibsub "entry id is not a string");
  testcase "strict: an empty set fails unless marked empty" checkstrictemptyset;
  testcase "a legacy spec (no OMNI block) stays lenient" (fun () ->
      let pack = (make_runner_spec legacylenient empty_provider) "fib" None in
      pack.runset (pack.set "g") (Some fibsub));

  extsuite ();

  Printf.printf "\n%d passed, %d failed\n" !passcount !failcount;

  exit (if !failcount = 0 then 0 else 1)
