# RUN: make test
# RUN-SOME: elixir -pa build test/ext.exs ctxargs
#
# The capability suite: spec/ext.json requires ctxargs, fn and wait, and
# every port that carries them runs it, beside the runner flag `all`.

defmodule OmniExtTest do
  @moduledoc "The omni capability harness for the Elixir port."

  alias Voxgig.Omni.OmniError
  alias Voxgig.Omni.Fib
  alias Voxgig.Omni.FibError
  alias Voxgig.Omni.Runner
  alias Voxgig.Omni.Util, as: U

  def specfile(name) do
    Enum.reduce_while(0..7, File.cwd!(), fn _step, dir ->
      cand = Path.join([dir, "spec", name])
      if File.exists?(cand), do: {:halt, cand}, else: {:cont, Path.dirname(dir)}
    end)
    |> case do
      path when is_binary(path) ->
        if String.ends_with?(path, name), do: path, else: raise("omni: spec not found: #{name}")
    end
  end

  def fib(args), do: Fib.fib(hd(args))

  def fibprovider do
    subjects = %{
      "fib" => &fib/1,
      "fibseq" => fn args -> Fib.fibseq(hd(args)) end,
      "fibrange" => fn args -> Fib.fibrange(hd(args), Enum.at(args, 1)) end,
      "fibinfo" => fn args -> Fib.fibinfo(hd(args)) end
    }

    %{
      subject: fn name -> Map.get(subjects, name) end,
      contextify: fn val -> Map.put(val, "mark", "CTX") end
    }
  end

  # The ctxargs subject: the context comes first, and must arrive
  # contextified with its client attached.
  def fibshifted(args) do
    ctx = Enum.at(args, 0)

    if "CTX" != U.get(ctx, "mark") or U.isnone(U.get(ctx, "client")) do
      raise FibError, message: "fib: context not delivered"
    end

    shift = U.get(ctx, "shift")
    Fib.fibrange(Enum.at(args, 1) + shift, Enum.at(args, 2) + shift)
  end

  def runner(spec), do: Runner.make_runner(spec, fibprovider()).("fib", nil)

  def v1(requires, set) do
    %{"OMNI" => %{"version" => 1, "requires" => requires}, "fib" => %{"g" => %{"set" => set}}}
  end

  def refuses(run, pattern) do
    try do
      run.()
      raise "omni: expected a failure matching #{inspect(pattern)}"
    rescue
      err in OmniError ->
        if not Regex.match?(pattern, err.message) do
          raise "omni: message does not match #{inspect(pattern)}: #{err.message}"
        end
    end
  end

  def testcase(name, body, state) do
    {only, pass, fail} = state

    if nil != only and name != only do
      state
    else
      try do
        body.()
        IO.puts("ok   - #{name}")
        {only, pass + 1, fail}
      rescue
        err ->
          IO.puts("FAIL - #{name}")
          IO.puts(Exception.message(err))
          {only, pass, fail + 1}
      end
    end
  end

  def capabilities do
    Enum.each(["ctxargs", "fn", "wait"], fn cap ->
      if cap not in Runner.capabilities() do
        raise "omni: capability missing: #{cap}"
      end
    end)
  end

  def stale_entry_wait do
    r = runner(v1(["wait"], [%{"in" => 5, "out" => 5, "wait" => %{"cause" => "gone#1"}}]))
    refuses(fn -> r.runset.(r.set.("g"), &fib/1) end, ~r/\[0\]: stale wait: gone#1/)
  end

  def wait_flag_holds do
    r = runner(v1([], [%{"id" => "a", "in" => 6, "out" => 9}, %{"in" => 7, "out" => 13}]))
    r.runsetflags.(r.set.("g"), %{wait: %{"a" => %{"cause" => "flag#1"}}}, &fib/1)
  end

  def wait_flag_stale do
    r = runner(v1([], [%{"id" => "a", "in" => 6, "out" => 8}]))

    refuses(
      fn -> r.runsetflags.(r.set.("g"), %{wait: %{"a" => %{"cause" => "flag#1"}}}, &fib/1) end,
      ~r/stale wait: flag#1/
    )
  end

  def wait_flag_names_entry do
    r = runner(v1([], [%{"id" => "a", "in" => 6, "out" => 8}]))

    refuses(
      fn -> r.runsetflags.(r.set.("g"), %{wait: %{"zz" => %{"cause" => "c"}}}, &fib/1) end,
      ~r/wait names no entry: zz/
    )
  end

  def wait_needs_cause do
    r = runner(v1(["wait"], [%{"in" => 6, "out" => 9, "wait" => %{}}]))
    refuses(fn -> r.runset.(r.set.("g"), &fib/1) end, ~r/entry wait has no cause/)
  end

  def unknown_unless_required do
    w = runner(v1([], [%{"in" => 6, "out" => 9, "wait" => %{"cause" => "c"}}]))
    refuses(fn -> w.runset.(w.set.("g"), &fib/1) end, ~r/unknown entry field: wait/)
    f = runner(v1([], [%{"fn" => "fib", "in" => 6, "out" => 8}]))
    refuses(fn -> f.runset.(f.set.("g"), &fib/1) end, ~r/unknown entry field: fn/)
  end

  def unknown_fn do
    r = runner(v1(["fn"], [%{"fn" => "nope", "in" => 6, "out" => 8}]))
    refuses(fn -> r.runset.(r.set.("g"), &fib/1) end, ~r/unknown fn: nope/)
  end

  def ctx_with_args do
    n = runner(v1([], [%{"ctx" => %{"shift" => 0}, "args" => [0, 1], "out" => [0, 1]}]))

    refuses(
      fn -> n.runset.(n.set.("g"), &fibshifted/1) end,
      ~r/more than one of in, args, ctx/
    )

    i = runner(v1(["ctxargs"], [%{"in" => 1, "ctx" => %{"shift" => 0}, "out" => [0]}]))

    refuses(
      fn -> i.runset.(i.set.("g"), &fibshifted/1) end,
      ~r/entry has in beside args or ctx/
    )
  end

  def legacy_ignores do
    r =
      runner(%{
        "fib" => %{
          "g" => %{
            "set" => [%{"in" => 6, "out" => 8, "fn" => "nope", "wait" => %{"cause" => "c"}}]
          }
        }
      })

    r.runset.(r.set.("g"), &fib/1)
  end

  def raising_hook do
    boom = fn _val -> raise "contextify boom" end
    provider = %{subject: fn _name -> &fib/1 end, contextify: boom}
    run = fn spec -> Runner.make_runner(spec, provider).("fib", nil) end

    e = run.(v1([], [%{"ctx" => %{"n" => 6}, "err" => "contextify boom"}]))
    e.runset.(e.set.("g"), &fib/1)

    u = run.(v1([], [%{"ctx" => %{"n" => 6}, "out" => 8}]))

    refuses(
      fn -> u.runset.(u.set.("g"), &fib/1) end,
      ~r/\[0\]: unexpected error\n\s+actual:\s+contextify boom/
    )

    w = run.(v1(["wait"], [%{"ctx" => %{"n" => 6}, "out" => 8, "wait" => %{"cause" => "hook#1"}}]))
    w.runset.(w.set.("g"), &fib/1)

    subject = fn
      "boom" -> raise "subject boom"
      _name -> &fib/1
    end

    f =
      Runner.make_runner(
        v1(["fn"], [%{"fn" => "boom", "in" => 6, "err" => "subject boom"}]),
        %{subject: subject}
      ).("fib", nil)

    f.runset.(f.set.("g"), &fib/1)
  end

  def prestart_held do
    subject = fn
      "boom" -> raise "subject boom"
      "fib" -> &fib/1
      _name -> nil
    end

    run = fn spec -> Runner.make_runner(spec, %{subject: subject}).("fib", nil) end

    h =
      run.(
        v1(["fn", "wait"], [
          %{"fn" => "boom", "in" => 6, "out" => 8, "wait" => %{"cause" => "hook#2"}}
        ])
      )

    h.runset.(h.set.("g"), &fib/1)

    s =
      run.(
        v1(["fn", "wait"], [
          %{"fn" => "boom", "in" => 6, "err" => "subject boom", "wait" => %{"cause" => "hook#3"}}
        ])
      )

    refuses(fn -> s.runset.(s.set.("g"), &fib/1) end, ~r/\[0\]: stale wait: hook#3/)
  end

  def fn_no_default do
    provider = %{subject: fn name -> if "fibx" == name, do: &fib/1, else: nil end}
    run = fn spec -> Runner.make_runner(spec, provider).("fib", nil) end

    r = run.(v1(["fn"], [%{"fn" => "fibx", "in" => 6, "out" => 8}]))
    r.runset.(r.set.("g"), nil)

    n = run.(v1(["fn"], [%{"fn" => "fibx", "in" => 6, "out" => 8}, %{"in" => 6, "out" => 8}]))
    refuses(fn -> n.runset.(n.set.("g"), nil) end, ~r/\Aomni: no test subject for: fib\z/)

    l = run.(v1([], [%{"in" => 6, "out" => 8}]))
    refuses(fn -> l.runset.(l.set.("g"), nil) end, ~r/\Aomni: no test subject for: fib\z/)
  end

  def wait_own_id do
    r =
      runner(
        v1([], [
          %{"id" => "constructor", "in" => 6, "out" => 8},
          %{"id" => "toString", "in" => 7, "out" => 13}
        ])
      )

    r.runset.(r.set.("g"), &fib/1)
    r.runsetflags.(r.set.("g"), %{wait: %{}}, &fib/1)
  end

  def all_failures do
    r =
      runner(
        v1([], [
          %{"in" => 5, "out" => 6},
          %{"in" => 6, "out" => 8},
          %{"in" => 7, "out" => 14}
        ])
      )

    refuses(
      fn -> r.runsetflags.(r.set.("g"), %{all: true}, &fib/1) end,
      ~r/\Aomni: fib: 2 of 3 entries failed\n.*fib\[0\]: result mismatch.*fib\[2\]: result mismatch/s
    )

    refuses(fn -> r.runset.(r.set.("g"), &fib/1) end, ~r/\Aomni: fib\[0\]: result mismatch/)
  end
end

only = List.first(System.argv())

fib = &OmniExtTest.fib/1
pack = OmniExtTest.runner(OmniExtTest.specfile("ext.json"))

state = {only, 0, 0}

state = OmniExtTest.testcase("capabilities", &OmniExtTest.capabilities/0, state)

state =
  OmniExtTest.testcase(
    "ctxargs",
    fn -> pack.runset.(pack.set.("ctxargs"), &OmniExtTest.fibshifted/1) end,
    state
  )

state = OmniExtTest.testcase("fn", fn -> pack.runset.(pack.set.("fn"), fib) end, state)
state = OmniExtTest.testcase("wait", fn -> pack.runset.(pack.set.("wait"), fib) end, state)

state =
  OmniExtTest.testcase(
    "a waiting entry that passes fails the set",
    &OmniExtTest.stale_entry_wait/0,
    state
  )

state =
  OmniExtTest.testcase("the wait flag holds an entry by id", &OmniExtTest.wait_flag_holds/0, state)

state =
  OmniExtTest.testcase(
    "the wait flag fails when its entry passes",
    &OmniExtTest.wait_flag_stale/0,
    state
  )

state =
  OmniExtTest.testcase(
    "the wait flag must name an entry",
    &OmniExtTest.wait_flag_names_entry/0,
    state
  )

state = OmniExtTest.testcase("a wait needs a cause", &OmniExtTest.wait_needs_cause/0, state)

state =
  OmniExtTest.testcase(
    "wait and fn are unknown fields unless required",
    &OmniExtTest.unknown_unless_required/0,
    state
  )

state = OmniExtTest.testcase("an unknown fn is a spec error", &OmniExtTest.unknown_fn/0, state)

state =
  OmniExtTest.testcase(
    "ctx with args needs ctxargs, and never takes in",
    &OmniExtTest.ctx_with_args/0,
    state
  )

state =
  OmniExtTest.testcase("a legacy spec ignores fn and wait", &OmniExtTest.legacy_ignores/0, state)

state =
  OmniExtTest.testcase(
    "a raising hook is the entry's error, not the set's",
    &OmniExtTest.raising_hook/0,
    state
  )

state =
  OmniExtTest.testcase(
    "a waiting entry holds a hook's error raised before the subject starts",
    &OmniExtTest.prestart_held/0,
    state
  )

state =
  OmniExtTest.testcase(
    "fn needs no default subject, but an entry without fn does",
    &OmniExtTest.fn_no_default/0,
    state
  )

state =
  OmniExtTest.testcase(
    "a wait is found by an id the entry owns, never an inherited one",
    &OmniExtTest.wait_own_id/0,
    state
  )

state =
  OmniExtTest.testcase("all reports every failure at once", &OmniExtTest.all_failures/0, state)

{_only, passcount, failcount} = state

IO.puts("\n#{passcount} passed, #{failcount} failed")

System.halt(if 0 == failcount, do: 0, else: 1)
