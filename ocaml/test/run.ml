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

let () =
  if Array.length Sys.argv > 1 then only := Some Sys.argv.(1);

  let pack = (make_runner (specfile "fib.json") (fibprovider 0.0)) "fib" None in

  testcase "basic" (fun () -> pack.runset (pack.set "basic") (Some fibsub));
  testcase "seq" (fun () -> pack.runset (pack.set "seq") (Some fibseqsub));
  testcase "range" (fun () -> pack.runset (pack.set "range") (Some fibrangesub));
  testcase "info" (fun () -> pack.runset (pack.set "info") (Some fibinfosub));
  testcase "nulls" (fun () -> pack.runsetflags (pack.set "nulls") nonull_flags (Some fibinfosub));
  testcase "error" (fun () -> pack.runset (pack.set "error") (Some fibsub));
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

  Printf.printf "\n%d passed, %d failed\n" !passcount !failcount;

  exit (if !failcount = 0 then 0 else 1)
