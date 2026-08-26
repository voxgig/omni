# RUN: make test
# RUN-SOME: elixir -pa build test/run.exs basic
#
# The Fibonacci conformance suite: every omni port runs this same set of
# groups, from the same spec/fib.json, against the same fib library.
#
# No third-party test framework: a failing omni check raises
# Voxgig.Omni.OmniError, so ExUnit reports it as a failure. This harness keeps
# `make test` dependency-free.

alias Voxgig.Omni.OmniError
alias Voxgig.Omni.Fib
alias Voxgig.Omni.Runner
alias Voxgig.Omni.Util, as: U

defmodule OmniTest do
  @moduledoc "The omni conformance harness for the Elixir port."

  alias Voxgig.Omni.OmniError
  alias Voxgig.Omni.Fib
  alias Voxgig.Omni.Runner
  alias Voxgig.Omni.Util, as: U

  # Find the shared spec directory by walking up from the working dir.
  def specfile(name) do
    Enum.reduce_while(0..7, File.cwd!(), fn _step, dir ->
      cand = Path.join([dir, "spec", name])

      if File.exists?(cand) do
        {:halt, cand}
      else
        {:cont, Path.dirname(dir)}
      end
    end)
    |> case do
      path when is_binary(path) ->
        if String.ends_with?(path, name), do: path, else: raise("omni: spec not found: #{name}")
    end
  end

  # The provider hosts the system under test. `shift` offsets the Fibonacci
  # index, so that a client-specific subject is observably different.
  # `contextify` marks the map, so the context group can prove the hook ran.
  def fibprovider(shift) do
    %{
      subject: fn
        "fib" ->
          fn args ->
            val = hd(args)
            if U.isnum(val), do: Fib.fib(val + shift), else: Fib.fib(val)
          end

        "fibseq" ->
          fn args -> Fib.fibseq(hd(args)) end

        "fibrange" ->
          fn args -> Fib.fibrange(hd(args), Enum.at(args, 1)) end

        "fibinfo" ->
          fn args -> Fib.fibinfo(hd(args)) end

        _ ->
          nil
      end,
      client: fn options ->
        shiftval = U.get(options, "shift")
        fibprovider(if U.isnum(shiftval), do: shiftval, else: 0)
      end,
      contextify: fn val -> Map.put(val, "mark", "CTX") end
    }
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

  # The runner must fail when the subject is wrong - otherwise a green
  # suite means nothing.
  def badspec do
    %{
      "fib" => %{
        "wrongout" => %{"set" => [%{"in" => 5.0, "out" => 5.0}, %{"in" => 6.0, "out" => 999.0}]},
        "wrongerr" => %{"set" => [%{"in" => 1.0, "err" => "never happens"}]},
        "wrongmatch" => %{"set" => [%{"in" => 6.0, "match" => %{"out" => 999.0}}]},
        "missing" => %{
          "set" => [%{"in" => 6.0, "match" => %{"out" => %{"nope" => "__EXISTS__"}}}]
        },
        # A concrete match leaf against a missing key must fail, not
        # substring-match the text "undefined".
        "matchabsent" => %{
          "set" => [%{"in" => 6.0, "match" => %{"out" => %{"nope" => "fine"}}}]
        },
        # __UNDEF__ (absent) must not be satisfied by a present null.
        "undefonnull" => %{
          "set" => [%{"in" => 0.0, "match" => %{"out" => %{"prev" => "__UNDEF__"}}}]
        },
        # __NULL__ (present null) must not be satisfied by an absent key.
        "nullonabsent" => %{
          "set" => [%{"in" => 6.0, "match" => %{"out" => %{"nope" => "__NULL__"}}}]
        },
        # An empty-string match leaf is not a wildcard.
        "emptystr" => %{
          "set" => [%{"in" => 6.0, "match" => %{"out" => %{"label" => ""}}}]
        },
        # __UNDEF__ (absent) must not be satisfied by the literal string
        # "__UNDEF__" returned as ordinary data - a sentinel that accepts
        # its own literal is not a sentinel.
        "wrongundef" => %{
          "set" => [%{"in" => 6.0, "match" => %{"out" => %{"a" => "__UNDEF__"}}}]
        }
      }
    }
  end

  def expectfail(setname, subject) do
    bad = Runner.make_runner(badspec()).("fib", nil)

    try do
      bad.runset.(bad.set.(setname), subject)
      raise "omni: expected a failure for set: #{setname}"
    rescue
      _err in OmniError -> :ok
    end
  end

  # Run `build`, which must raise an OmniError whose message contains
  # `wantsubstring`. Any other outcome - no raise, or a message missing
  # the substring - fails the test.
  def expectraises(build, wantsubstring) do
    try do
      build.()
      raise "omni: expected a failure containing [#{wantsubstring}]"
    rescue
      err in OmniError ->
        if not String.contains?(err.message, wantsubstring) do
          raise "omni: message missing [#{wantsubstring}]: #{err.message}"
        end
    end
  end

  def rejects_unsupported_version do
    expectraises(
      fn ->
        Runner.make_runner(%{"OMNI" => %{"version" => 99.0}, "fib" => %{"g" => %{"set" => []}}})
      end,
      "unsupported spec version"
    )
  end

  def rejects_unknown_capability do
    expectraises(
      fn ->
        Runner.make_runner(%{
          "OMNI" => %{"version" => 1.0, "requires" => ["nosuchfeature"]},
          "fib" => %{"g" => %{"set" => []}}
        })
      end,
      "unsupported capability"
    )
  end

  def rejects_malformed_version_block do
    expectraises(
      fn ->
        Runner.make_runner(%{"OMNI" => %{"version" => "one"}, "fib" => %{"g" => %{"set" => []}}})
      end,
      "malformed OMNI"
    )
  end

  # A present-but-null OMNI block is malformed; only a genuinely absent
  # OMNI key is legacy. resolveversion must test presence, not
  # definedness, or this pair collapses into one case.
  def rejects_null_omni_block do
    expectraises(
      fn ->
        Runner.make_runner(%{
          "OMNI" => nil,
          "fib" => %{"g" => %{"set" => [%{"in" => 1.0, "out" => 1.0}]}}
        })
      end,
      "malformed OMNI"
    )

    expectraises(
      fn ->
        Runner.make_runner(%{
          "OMNI" => %{"version" => 1.0, "requires" => nil},
          "fib" => %{"g" => %{"set" => [%{"in" => 1.0, "out" => 1.0}]}}
        })
      end,
      "malformed OMNI requires list"
    )

    Runner.make_runner(%{"fib" => %{"g" => %{"set" => [%{"in" => 1.0, "out" => 1.0}]}}})
  end

  def strict_unknown_entry_field do
    strict =
      Runner.make_runner(%{
        "OMNI" => %{"version" => 1.0},
        "fib" => %{"g" => %{"set" => [%{"in" => 6.0, "matches" => %{"out" => 999.0}}]}}
      }).("fib", nil)

    expectraises(
      fn -> strict.runset.(strict.set.("g"), fn args -> Fib.fibinfo(hd(args)) end) end,
      "unknown entry field: matches"
    )
  end

  def strict_more_than_one_source do
    strict =
      Runner.make_runner(%{
        "OMNI" => %{"version" => 1.0},
        "fib" => %{"g" => %{"set" => [%{"in" => 5.0, "args" => [5.0], "out" => 5.0}]}}
      }).("fib", nil)

    expectraises(
      fn -> strict.runset.(strict.set.("g"), fn args -> Fib.fib(hd(args)) end) end,
      "more than one of in, args, ctx"
    )
  end

  def strict_err_with_out do
    strict =
      Runner.make_runner(%{
        "OMNI" => %{"version" => 1.0},
        "fib" => %{"g" => %{"set" => [%{"in" => -1.0, "err" => true, "out" => 5.0}]}}
      }).("fib", nil)

    expectraises(
      fn -> strict.runset.(strict.set.("g"), fn args -> Fib.fib(hd(args)) end) end,
      "both err and out"
    )
  end

  def strict_null_id do
    strict =
      Runner.make_runner(%{
        "OMNI" => %{"version" => 1.0},
        "fib" => %{"g" => %{"set" => [%{"in" => 1.0, "out" => 1.0, "id" => nil}]}}
      }).("fib", nil)

    expectraises(
      fn -> strict.runset.(strict.set.("g"), fn args -> Fib.fib(hd(args)) end) end,
      "entry id is not a string"
    )
  end

  def strict_empty_set do
    strict =
      Runner.make_runner(%{
        "OMNI" => %{"version" => 1.0},
        "fib" => %{
          "g" => %{"set" => []},
          "h" => %{"set" => [], "empty" => true}
        }
      }).("fib", nil)

    expectraises(
      fn -> strict.runset.(strict.set.("g"), fn args -> Fib.fib(hd(args)) end) end,
      "empty test set"
    )

    strict.runset.(strict.set.("h"), fn args -> Fib.fib(hd(args)) end)
  end

  def legacy_stays_lenient do
    legacy =
      Runner.make_runner(%{
        "fib" => %{
          "g" => %{"set" => [%{"in" => 6.0, "matches" => %{"out" => 999.0}, "out" => 8.0}]}
        }
      }).("fib", nil)

    legacy.runset.(legacy.set.("g"), fn args -> Fib.fib(hd(args)) end)
  end

  def checkmessage do
    spec = %{
      "fib" => %{
        "g" => %{
          "set" => [
            %{"in" => 1.0, "out" => 1.0},
            %{"id" => "x#2", "in" => 2.0, "out" => 42.0}
          ]
        }
      }
    }

    bad = Runner.make_runner(spec).("fib", nil)

    try do
      bad.runset.(bad.set.("g"), fn args -> Fib.fib(hd(args)) end)
      raise "omni: expected a failure"
    rescue
      err in OmniError ->
        Enum.each(["fib[1] (x#2)", "expected: 42", "actual:   1"], fn want ->
          if not String.contains?(err.message, want) do
            raise "omni: message missing [#{want}]: #{err.message}"
          end
        end)
    end
  end

  # deepequal is structural, not IEEE: NaN equals NaN, as canonical. Nothing
  # in spec/fib.json can reach that rule - JSON has no NaN literal - so each
  # port pins it in its own suite.
  #
  # Erlang floats CANNOT represent NaN. There is no NaN value to hand to
  # deepequal and no expression that yields one, so this port cannot carry
  # the two-distinct-NaNs assertions the other ports carry. What it pins
  # instead is the reason: every route to a NaN raises or refuses. If a
  # future runtime ever admits NaN, this test goes red rather than quietly
  # skipping the contract, and whoever sees it must add the real cases here -
  # deepequal(n1, n2), deepequal([n1], [n2]), deepequal(%{"x" => n1},
  # %{"x" => n2}) all true, and deepequal(n1, 1.0) false, with n1 and n2 built
  # by two DIFFERENT expressions. The number regressions below run either way.
  def checkdeepequal(label, got, want) do
    if want != got do
      raise "omni: deepequal #{label}: expected #{inspect(want)}, got #{inspect(got)}"
    end
  end

  # `build` must raise ArithmeticError. It is called through an anonymous
  # function so the compiler cannot fold the arithmetic away at build time -
  # a folded expression would fail at compile time, not here.
  def expectnonan(label, build) do
    try do
      got = build.()
      raise "omni: #{label} produced #{inspect(got)} - this runtime now has NaN"
    rescue
      _err in ArithmeticError -> :ok
    end
  end

  def nan_is_unrepresentable do
    divide = fn a, b -> a / b end
    log = fn val -> :math.log(val) end

    expectnonan("0.0 / 0.0", fn -> divide.(0.0, 0.0) end)
    # And no infinity to subtract from itself, either.
    expectnonan("1.0 / 0.0", fn -> divide.(1.0, 0.0) end)
    expectnonan(":math.log(-1.0)", fn -> log.(-1.0) end)

    if :error != Float.parse("nan") do
      raise ~s|omni: Float.parse("nan") no longer refuses NaN|
    end

    # Bit syntax refuses to decode the IEEE-754 quiet-NaN pattern as a float.
    try do
      <<_::float-64>> = <<0x7F, 0xF8, 0, 0, 0, 0, 0, 0>>
      raise "omni: bit syntax now decodes NaN as a float"
    rescue
      _err in MatchError -> :ok
    end
  end

  def deepequal_structural do
    nan_is_unrepresentable()

    # Numbers compare by value across int/float, and bools are never numbers.
    checkdeepequal("1, 1.0", U.deepequal(1, 1.0), true)
    checkdeepequal("[1], [1.0]", U.deepequal([1], [1.0]), true)
    checkdeepequal(~s|{"x" => 1}, {"x" => 1.0}|, U.deepequal(%{"x" => 1}, %{"x" => 1.0}), true)
    checkdeepequal("true, 1", U.deepequal(true, 1), false)
    checkdeepequal("1, 2", U.deepequal(1, 2), false)
  end
end

only = List.first(System.argv())

fib = fn args -> Fib.fib(hd(args)) end
fibseq = fn args -> Fib.fibseq(hd(args)) end
fibrange = fn args -> Fib.fibrange(hd(args), Enum.at(args, 1)) end
fibinfo = fn args -> Fib.fibinfo(hd(args)) end

# A subject that returns the literal sentinel string as ordinary data.
fibundef = fn _args -> %{"a" => "__UNDEF__"} end

# The context-group subject: reports what the runner delivered - the
# contextify mark and the attached client - as plain data, so the spec can
# pin both with an ordinary `out` comparison in every port.
fibctx = fn args ->
  ctx = hd(args)

  %{
    "n" => U.get(ctx, "n"),
    "val" => Fib.fib(U.get(ctx, "n")),
    "mark" => U.get(ctx, "mark"),
    "hasclient" => not U.isnone(U.get(ctx, "client"))
  }
end

pack = Runner.make_runner(OmniTest.specfile("fib.json"), OmniTest.fibprovider(0)).("fib", nil)

state = {only, 0, 0}

state = OmniTest.testcase("basic", fn -> pack.runset.(pack.set.("basic"), fib) end, state)
state = OmniTest.testcase("seq", fn -> pack.runset.(pack.set.("seq"), fibseq) end, state)
state = OmniTest.testcase("range", fn -> pack.runset.(pack.set.("range"), fibrange) end, state)
state = OmniTest.testcase("info", fn -> pack.runset.(pack.set.("info"), fibinfo) end, state)

state =
  OmniTest.testcase(
    "nulls",
    fn -> pack.runsetflags.(pack.set.("nulls"), %{null: false}, fibinfo) end,
    state
  )

state = OmniTest.testcase("error", fn -> pack.runset.(pack.set.("error"), fib) end, state)
state = OmniTest.testcase("match", fn -> pack.runset.(pack.set.("match"), fib) end, state)

state =
  OmniTest.testcase("matchinfo", fn -> pack.runset.(pack.set.("matchinfo"), fibinfo) end, state)

state = OmniTest.testcase("client", fn -> pack.runset.(pack.set.("client"), fib) end, state)

state =
  OmniTest.testcase("context", fn -> pack.runset.(pack.set.("context"), fibctx) end, state)

state =
  OmniTest.testcase("detects wrong result", fn -> OmniTest.expectfail("wrongout", fib) end, state)

state =
  OmniTest.testcase("detects missing error", fn -> OmniTest.expectfail("wrongerr", fib) end, state)

state =
  OmniTest.testcase("detects failed match", fn -> OmniTest.expectfail("wrongmatch", fib) end, state)

state =
  OmniTest.testcase("detects absent key", fn -> OmniTest.expectfail("missing", fibinfo) end, state)

state =
  OmniTest.testcase(
    "a concrete match leaf does not match a missing key",
    fn -> OmniTest.expectfail("matchabsent", fibinfo) end,
    state
  )

state =
  OmniTest.testcase(
    "__UNDEF__ does not match a present null",
    fn -> OmniTest.expectfail("undefonnull", fibinfo) end,
    state
  )

state =
  OmniTest.testcase(
    "__NULL__ does not match an absent key",
    fn -> OmniTest.expectfail("nullonabsent", fibinfo) end,
    state
  )

state =
  OmniTest.testcase(
    "an empty-string match leaf is not a wildcard",
    fn -> OmniTest.expectfail("emptystr", fibinfo) end,
    state
  )

state =
  OmniTest.testcase(
    "__UNDEF__ does not match the literal string \"__UNDEF__\"",
    fn -> OmniTest.expectfail("wrongundef", fibundef) end,
    state
  )

state = OmniTest.testcase("reports entry index and id", &OmniTest.checkmessage/0, state)

state =
  OmniTest.testcase(
    "rejects an unsupported spec version",
    &OmniTest.rejects_unsupported_version/0,
    state
  )

state =
  OmniTest.testcase(
    "rejects an unknown required capability",
    &OmniTest.rejects_unknown_capability/0,
    state
  )

state =
  OmniTest.testcase(
    "rejects a malformed version block",
    &OmniTest.rejects_malformed_version_block/0,
    state
  )

state =
  OmniTest.testcase(
    "rejects a null OMNI block, but accepts an absent one",
    &OmniTest.rejects_null_omni_block/0,
    state
  )

state =
  OmniTest.testcase(
    "strict: an unknown entry field fails instead of passing vacuously",
    &OmniTest.strict_unknown_entry_field/0,
    state
  )

state =
  OmniTest.testcase(
    "strict: more than one of in, args, ctx fails",
    &OmniTest.strict_more_than_one_source/0,
    state
  )

state =
  OmniTest.testcase("strict: err together with out fails", &OmniTest.strict_err_with_out/0, state)

state =
  OmniTest.testcase(
    "strict: a null id fails even under null-normalisation",
    &OmniTest.strict_null_id/0,
    state
  )

state =
  OmniTest.testcase(
    "strict: an empty set fails unless marked empty",
    &OmniTest.strict_empty_set/0,
    state
  )

state =
  OmniTest.testcase(
    "a legacy spec (no OMNI block) stays lenient",
    &OmniTest.legacy_stays_lenient/0,
    state
  )

state =
  OmniTest.testcase(
    "deepequal: NaN equals NaN (no NaN in this runtime), number regressions",
    &OmniTest.deepequal_structural/0,
    state
  )

{_only, passcount, failcount} = state

IO.puts("\n#{passcount} passed, #{failcount} failed")

System.halt(if 0 == failcount, do: 0, else: 1)
