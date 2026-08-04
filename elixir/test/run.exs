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
      end
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
end

only = List.first(System.argv())

fib = fn args -> Fib.fib(hd(args)) end
fibseq = fn args -> Fib.fibseq(hd(args)) end
fibrange = fn args -> Fib.fibrange(hd(args), Enum.at(args, 1)) end
fibinfo = fn args -> Fib.fibinfo(hd(args)) end

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

state = OmniTest.testcase("reports entry index and id", &OmniTest.checkmessage/0, state)

{_only, passcount, failcount} = state

IO.puts("\n#{passcount} passed, #{failcount} failed")

System.halt(if 0 == failcount, do: 0, else: 1)
