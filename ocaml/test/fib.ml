(* The system under test: a tiny Fibonacci library.

   Every omni port ships this same library, with the same behaviour and the
   same error messages, and tests it with the same spec file
   (spec/fib.json). *)

open Omni

(* The Fibonacci library's own error. A subject must never raise the
   runner's Omni_error - that exception is reserved for test failures. *)
exception Fib_error of string

(* The runner reads a subject's message with Printexc.to_string, so a
   custom exception registers its own printer - the idiomatic OCaml way to
   give an exception a message. *)
let () = Printexc.register_printer (function Fib_error message -> Some message | _ -> None)

(* Validate a Fibonacci index. The spec matches on these messages. *)
let fibindex value =
  match asnum value with
  | None -> raise (Fib_error ("fib: not a number: " ^ stringify value))
  | Some num ->
    if not (Float.is_integer num) then
      raise (Fib_error ("fib: non-integer index: " ^ stringify value));
    if num < 0.0 then raise (Fib_error ("fib: negative index: " ^ stringify value));
    int_of_float num

(* The nth Fibonacci number: fib(0)=0, fib(1)=1. *)
let fibnum index =
  if index = 0 then 0
  else begin
    let prev = ref 0 in
    let cur = ref 1 in
    for _step = 1 to index - 1 do
      let next = !prev + !cur in
      prev := !cur;
      cur := next
    done;
    !cur
  end

let fib value = Num (float_of_int (fibnum (fibindex value)))

(* The first n Fibonacci numbers. *)
let fibseq value =
  let count = fibindex value in
  JList (List.init count (fun index -> Num (float_of_int (fibnum index))))

(* The Fibonacci numbers from index start to index end, inclusive. *)
let fibrange start stop =
  let from = fibindex start in
  let upto = fibindex stop in
  if upto < from then JList []
  else JList (List.init (upto - from + 1) (fun step -> Num (float_of_int (fibnum (from + step)))))

(* A description of the nth Fibonacci number. `prev` is null at index 0,
   which exercises the runner's null handling. *)
let fibinfo value =
  let index = fibindex value in
  let num = fibnum index in

  JMap
    [
      ("n", Num (float_of_int index));
      ("val", Num (float_of_int num));
      ("even", Bool (num mod 2 = 0));
      ("prev", if index = 0 then Null else Num (float_of_int (fibnum (index - 1))));
      ( "label",
        Str ("fib(" ^ numstr (float_of_int index) ^ ")=" ^ numstr (float_of_int num)) );
    ]

(* The context-group subject: reports what the runner delivered - the
   contextify mark and the attached client - as plain data, so the spec
   can pin both with an ordinary `out` comparison in every port. *)
let fibctx ctx =
  JMap
    [
      ("n", jget ctx "n");
      ("val", fib (jget ctx "n"));
      ("mark", jget ctx "mark");
      ("hasclient", Bool (not (isnone (jget ctx "client"))));
    ]
