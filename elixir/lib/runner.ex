# Omni: the shared multi-language test runner (Elixir port).
#
# Port of the canonical TypeScript implementation
# (typescript/src/Runner.ts). Behaviour must match, case for case.

defmodule Voxgig.Omni.OmniError do
  @moduledoc """
  A test failure (or a malformed spec). Distinct from an exception raised
  by the subject under test, which is a candidate for an `err` expectation.
  """
  defexception [:message, :entry]
end

defmodule Voxgig.Omni.Runner do
  @moduledoc "The omni test runner."

  alias Voxgig.Omni.OmniError
  alias Voxgig.Omni.Json
  alias Voxgig.Omni.Util, as: U

  @doc """
  The newest spec format version this runner understands. A spec with no
  OMNI block is version 0: the original, lenient format, frozen forever.
  Version 1 turns on strict entry validation (see checkentry/3).
  """
  def specversion, do: 1

  @doc """
  Capability strings this runner supports beyond the version baseline. A
  spec's OMNI.requires list is checked against this: an unknown capability
  refuses the spec loudly at load time, instead of a lagging port silently
  mis-running it. (Empty today; future format features mint a string here.)
  """
  def capabilities, do: []

  # The complete set of fields an entry may carry. Under version 1 anything
  # else is an error: an unrecognised key is almost always a typo'd
  # assertion, and a typo'd assertion is a test that silently stopped
  # testing.
  @entryfields ~w(in args ctx out err match client id doc)

  @doc "Load a spec: a path to a JSON file."
  def loadspec(path) do
    case File.read(path) do
      {:ok, text} -> Json.parse(text)
      {:error, _} -> raise OmniError, message: "omni: cannot read spec: #{path}"
    end
  end

  # Read the spec's format version from its optional top-level OMNI block,
  # and refuse a spec this runner cannot faithfully run: a version newer
  # than specversion/0, or a required capability not in capabilities/0.
  defp resolveversion(alltests) do
    hasomni = U.ismap(alltests) and Map.has_key?(alltests, "OMNI")

    if not hasomni do
      0
    else
      meta = Map.get(alltests, "OMNI")
      version = U.get(meta, "version")
      numversion = if U.isnum(version), do: version / 1, else: nil

      if not U.ismap(meta) or is_nil(numversion) or Float.round(numversion) != numversion do
        raise OmniError, message: "omni: malformed OMNI version block"
      end

      if version < 0 or specversion() < version do
        raise OmniError, message: "omni: unsupported spec version: #{U.stringify(version)}"
      end

      if U.has(meta, "requires") do
        requires = U.get(meta, "requires")

        if not U.islist(requires) do
          raise OmniError, message: "omni: malformed OMNI requires list"
        end

        Enum.each(requires, fn cap ->
          if not (U.isstr(cap) and cap in capabilities()) do
            raise OmniError,
              message: "omni: spec requires unsupported capability: #{U.stringify(cap)}"
          end
        end)
      end

      version
    end
  end

  # Strict entry validation, applied when the spec declares version 1 or
  # later. The lenient format converts each of these mistakes into a
  # silent pass or a dead field; here they fail with the entry named.
  defp checkentry(label, index, entry) do
    if not U.ismap(entry) do
      raise fail(label, index, entry, "entry is not a map", nil, nil)
    end

    Enum.each(Map.keys(entry), fn key ->
      if key not in @entryfields do
        raise fail(label, index, entry, "unknown entry field: #{key}", nil, nil)
      end
    end)

    argsources = Enum.count(["in", "args", "ctx"], &Map.has_key?(entry, &1))

    if argsources > 1 do
      raise fail(label, index, entry, "entry has more than one of in, args, ctx", nil, nil)
    end

    entryerr = U.get(entry, "err")

    if not U.isnone(entryerr) and Map.has_key?(entry, "out") do
      raise fail(label, index, entry, "entry has both err and out", nil, nil)
    end

    if Map.has_key?(entry, "id") and not U.isstr(U.get(entry, "id")) do
      raise fail(label, index, entry, "entry id is not a string", nil, nil)
    end
  end

  # Validate a version-1 group up front, against the AUTHORED entries -
  # null-normalisation would otherwise rewrite an authored null (e.g.
  # id: null) into a sentinel string and hide it from validation. A
  # malformed spec is a spec error, not a test result, so it fails
  # before any subject runs.
  defp checkset(label, testspec, normalset) do
    origset =
      if U.ismap(testspec) and U.islist(U.get(testspec, "set")) do
        U.get(testspec, "set")
      else
        normalset
      end

    emptyflag = if U.ismap(testspec), do: U.get(testspec, "empty"), else: U.absent()

    if [] == origset and true != emptyflag do
      raise OmniError, message: "omni: empty test set: #{label}"
    end

    origset
    |> Enum.with_index()
    |> Enum.each(fn {entry, index} -> checkentry(label, index, entry) end)
  end

  @doc "Find `primary.<name>`, then `<name>`, then the whole spec."
  def resolvespec(name, alltests) do
    primary = U.get(U.get(alltests, "primary"), name)
    section = U.get(alltests, name)

    cond do
      is_nil(name) or "" == name -> alltests
      not U.isabsent(primary) -> primary
      not U.isabsent(section) -> section
      true -> alltests
    end
  end

  @doc "Nulls (and absent values) become NULLMARK. Always a fresh copy."
  def fixjson(val, donull) do
    cond do
      # Canonical returns the value UNCHANGED when donull is false
      # (typescript/src/Runner.ts): absent stays absent and nil stays nil.
      # Answering nil for both collapsed two states the corpus distinguishes,
      # so a subject that correctly returned nothing was compared against null
      # and marked wrong. Same defect the other ports carried (#17, #23, #25,
      # #26); this one was missed because no consumer had exercised it.
      U.isnone(val) -> if donull, do: U.nullmark(), else: val
      U.islist(val) -> Enum.map(val, &fixjson(&1, donull))
      U.ismap(val) -> Map.new(val, fn {key, entry} -> {key, fixjson(entry, donull)} end)
      true -> val
    end
  end

  @doc "The JSON form of an error: always at least {name,message}."
  def errify(err) do
    %{"name" => err.__struct__ |> Module.split() |> List.last(), "message" => errmessage(err)}
  end

  @doc "The message an `err` expectation matches."
  def errmessage(%{message: message}) when is_binary(message), do: message
  def errmessage(err) when is_exception(err), do: Exception.message(err)
  def errmessage(err), do: to_string(err)

  @doc "Match one leaf: /regex/ or case-insensitive substring for strings."
  def matchval(check, base) do
    want =
      if check == U.undefmark() or check == U.nullmark() do
        nil
      else
        check
      end

    cond do
      U.deepequal(check, base) ->
        true

      is_nil(want) ->
        U.isnone(base) or U.nullmark() == base

      # An empty want is not a wildcard: the empty string is a substring of
      # everything, so `match:{out:""}` (or `err:""`) would accept any value.
      U.isstr(want) and "" == want ->
        "" == base

      U.isstr(want) ->
        basestr = U.stringify(base)

        if 2 < String.length(want) and String.starts_with?(want, "/") and
             String.ends_with?(want, "/") do
          pattern = String.slice(want, 1..-2//1)

          case Regex.compile(pattern) do
            {:ok, regex} -> Regex.match?(regex, basestr)
            {:error, _} -> false
          end
        else
          String.contains?(String.downcase(basestr), String.downcase(want))
        end

      true ->
        U.deepequal(want, base)
    end
  end

  @doc "Convert NULLMARK sentinels back into real nulls."
  def nullmodifier(val) do
    cond do
      U.nullmark() == val -> nil
      U.isstr(val) -> String.replace(val, U.nullmark(), "null")
      true -> val
    end
  end

  @doc """
  Make a runner for a spec file path (or spec value) and a provider.

  Returns a function of `(name, store)` producing a run pack: a map with
  `:spec`, `:set`, `:runset`, `:runsetflags`, `:subject` and `:client`.
  """
  def make_runner(specref, provider \\ %{}) do
    alltests = if is_binary(specref), do: loadspec(specref), else: specref
    specversion = resolveversion(alltests)

    fn name, store ->
      spec = resolvespec(name, alltests)
      clients = resolveclients(provider, spec, store)

      subject =
        case Map.get(provider, :subject) do
          nil -> nil
          resolve -> resolve.(name)
        end

      runpack = %{
        spec: spec,
        subject: subject,
        provider: provider,
        clients: clients,
        name: name,
        specversion: specversion
      }

      runsetflags = fn testspec, flags, testsubject ->
        run_set_flags(runpack, testspec, flags, testsubject, false)
      end

      runsetflags_args = fn testspec, flags, testsubject ->
        run_set_flags(runpack, testspec, flags, testsubject, true)
      end

      %{
        spec: spec,
        subject: subject,
        client: provider,
        set: fn setname -> U.get(spec, setname) end,
        runsetflags: runsetflags,
        runsetflags_args: runsetflags_args,
        runset: fn testspec, testsubject -> runsetflags.(testspec, %{}, testsubject) end
      }
    end
  end

  # A spec may define clients that a given test run never references.
  defp resolveclients(provider, spec, store) do
    defclient = U.get(U.get(spec, "DEF"), "client")
    clientmaker = Map.get(provider, :client)

    if U.ismap(defclient) and not is_nil(clientmaker) do
      Map.new(defclient, fn {clientname, cdef} ->
        copts = U.get(U.get(cdef, "test"), "options")
        copts = if U.isabsent(copts), do: %{}, else: copts

        copts =
          case Map.get(provider, :inject) do
            nil -> copts
            inject -> if U.ismap(store), do: inject.(copts, store), else: copts
          end

        {clientname, clientmaker.(copts)}
      end)
    else
      %{}
    end
  end

  # `argsmode` selects the subject contract: a plain subject returns the
  # result, while an ARGS subject returns `{args, result}`.
  #
  # `match.args` asserts an IN-PLACE rewrite - `minor/setpath` in eight of its
  # nine entries, `merge/integrity` in all six - and nothing on the BEAM is
  # mutable, so a consumer holding a converted copy cannot write through the
  # argument list. Returning it is the only channel there is. omni-rust,
  # omni-cpp and omni-ocaml carry the same second entry point, for the same
  # reason; the dynamic ports need none, because the value is shared.
  defp run_set_flags(runpack, testspec, flags, testsubject, argsmode) do
    donull = Map.get(flags, :null, true)
    label = Map.get(flags, :name) || if("" == runpack.name, do: "set", else: runpack.name)

    usesubject = testsubject || runpack.subject

    if is_nil(usesubject) do
      raise OmniError, message: "omni: no test subject for: #{label}"
    end

    testspecmap = fixjson(testspec, donull)
    testset = U.get(testspecmap, "set")

    if not U.islist(testset) do
      raise OmniError, message: "omni: test spec has no set: #{label}"
    end

    if 1 <= runpack.specversion do
      checkset(label, testspec, testset)
    end

    testset
    |> Enum.with_index()
    |> Enum.each(fn {rawentry, index} ->
      if not U.ismap(rawentry) do
        raise OmniError, message: "omni: #{label}[#{index}]: entry is not a map"
      end

      run_entry(runpack, label, index, rawentry, donull, usesubject, argsmode)
    end)
  end

  defp run_entry(runpack, label, index, rawentry, donull, usesubject, argsmode) do
    # An entry with no `out` expects a null (or absent) result.
    entry =
      if donull and U.isnone(U.get(rawentry, "out")) do
        Map.put(rawentry, "out", U.nullmark())
      else
        rawentry
      end

    testpack = resolvetestpack(runpack, entry, usesubject)
    {args, entry} = resolveargs(runpack, entry, testpack)

    try do
      if argsmode do
        {:ok, testpack.subject.(args)}
      else
        {:ok, {args, testpack.subject.(args)}}
      end
    rescue
      omnierr in OmniError -> reraise(omnierr, __STACKTRACE__)
      err -> {:error, err}
    end
    |> case do
      {:ok, {callargs, rawres}} ->
        res = fixjson(rawres, donull)
        checkresult(label, index, Map.put(entry, "res", res), callargs, res)

      {:error, err} ->
        handleerror(label, index, entry, err)
    end
  end

  # Resolve the client and subject for one entry: the entry's own `client`
  # override when present (looked up in the spec's DEF.client clients),
  # else the root provider.
  defp resolvetestpack(runpack, entry, usesubject) do
    case U.get(entry, "client") do
      clientname when is_binary(clientname) ->
        client =
          Map.get(runpack.clients, clientname) ||
            raise(OmniError, message: "omni: unknown client: #{clientname}", entry: entry)

        subject =
          case Map.get(client, :subject) do
            nil -> usesubject
            resolve -> resolve.(runpack.name) || usesubject
          end

        %{client: client, subject: subject}

      _ ->
        %{client: runpack.provider, subject: usesubject}
    end
  end

  # Build the argument list: `ctx`, `args`, or `in`. A map `ctx`/`args[0]`
  # is passed through the provider's contextify hook, then stamped with
  # the resolved client (the one testpack.subject will actually run
  # against), so a context-aware subject can see what served it.
  defp resolveargs(runpack, entry, testpack) do
    hasctx = U.has(entry, "ctx")
    hasargs = U.has(entry, "args")

    args =
      cond do
        hasctx ->
          [U.get(entry, "ctx")]

        hasargs ->
          raw = U.get(entry, "args")
          if U.islist(raw), do: raw, else: [raw]

        true ->
          [U.clone(U.get(entry, "in"))]
      end

    if (hasctx or hasargs) and [] != args and U.ismap(hd(args)) do
      first =
        case Map.get(runpack.provider, :contextify) do
          nil -> hd(args)
          contextify -> contextify.(hd(args))
        end

      first = Map.put(first, "client", testpack.client)

      {[first | tl(args)], Map.put(entry, "ctx", first)}
    else
      {args, entry}
    end
  end

  defp checkresult(label, index, entry, args, res) do
    entryerr = U.get(entry, "err")
    check = U.get(entry, "match")

    if not U.isnone(entryerr) do
      raise fail(label, index, entry, "expected error did not occur",
              U.stringify(entryerr), U.stringify(res))
    end

    matched =
      if not U.isnone(check) do
        base = %{
          "in" => U.get(entry, "in"),
          "args" => args,
          "out" => U.get(entry, "res"),
          "ctx" => U.get(entry, "ctx")
        }

        match(label, index, entry, check, base)
        true
      else
        false
      end

    out = U.get(entry, "out")

    cond do
      U.deepequal(res, out) ->
        :ok

      # NOTE: a match with no explicit out is a complete check on its own.
      matched and (U.isnone(out) or U.nullmark() == out) ->
        :ok

      true ->
        raise fail(label, index, entry, "result mismatch", U.stringify(out), U.stringify(res))
    end
  end

  defp handleerror(label, index, entry, err) do
    entryerr = U.get(entry, "err")
    message = errmessage(err)

    if U.isnone(entryerr) do
      raise fail(label, index, entry, "unexpected error", nil, message)
    end

    if true == entryerr or matchval(entryerr, message) do
      check = U.get(entry, "match")

      if not U.isnone(check) do
        base = %{
          "in" => U.get(entry, "in"),
          "out" => U.get(entry, "res"),
          "ctx" => U.get(entry, "ctx"),
          "err" => errify(err)
        }

        match(label, index, entry, check, base)
      end

      :ok
    else
      raise fail(label, index, entry, "error mismatch", U.stringify(entryerr), message)
    end
  end

  @doc "Check that every leaf of `check` is present, and matches, in `base`."
  def match(label, index, entry, check, base, path \\ []) do
    where = if [] == path, do: "<root>", else: U.pathify(path)

    cond do
      U.islist(check) ->
        check
        |> Enum.with_index()
        |> Enum.each(fn {subcheck, at} ->
          match(label, index, entry, subcheck, base, path ++ [to_string(at)])
        end)

      U.ismap(check) ->
        Enum.each(check, fn {key, subcheck} ->
          match(label, index, entry, subcheck, base, path ++ [key])
        end)

      true ->
        baseval = U.getpath(base, path)

        # The sentinels are tested BEFORE the identity check below.
        # Otherwise a subject returning the literal string "__UNDEF__"
        # satisfies an assertion that the key is absent - two mutually
        # exclusive states passing one check. A sentinel that accepts its
        # own literal is not a sentinel. (NULLMARK still accepts NULLMARK:
        # under the default null flag a real null has already been
        # normalised to it, so the two are genuinely indistinguishable
        # here - that one needs a raw-value escape, not an ordering
        # change.)
        cond do
          # Explicitly absent: satisfied only by a genuinely missing key,
          # never by a present null (the distinction the sentinels keep).
          U.undefmark() == check ->
            if U.isabsent(baseval) do
              :ok
            else
              raise fail(label, index, entry, "expected absent at #{where}",
                      "absent", U.stringify(baseval))
            end

          # Explicitly null: satisfied only by a present null.
          U.nullmark() == check ->
            if is_nil(baseval) or U.nullmark() == baseval do
              :ok
            else
              raise fail(label, index, entry, "expected null at #{where}",
                      "null", U.stringify(baseval))
            end

          # Explicitly present: any present value, including null.
          U.existsmark() == check ->
            if not U.isabsent(baseval) do
              :ok
            else
              raise fail(label, index, entry, "expected present at #{where}",
                      "present", "absent")
            end

          # Identical values match. This sits below the sentinel branches
          # on purpose - see the note above.
          U.deepequal(check, baseval) ->
            :ok

          # A concrete expectation never matches a missing key - a match
          # leaf against an absent value must fail, not substring-match.
          U.isabsent(baseval) ->
            raise fail(label, index, entry, "match failed at #{where}",
                    U.stringify(check), "absent")

          matchval(check, baseval) ->
            :ok

          true ->
            raise fail(label, index, entry, "match failed at #{where}",
                    U.stringify(check), U.stringify(baseval))
        end
    end
  end

  # The spec-defined part of an entry (drop runner bookkeeping). A
  # checkentry failure can hand this a non-map entry (e.g. "entry is not
  # a map" itself) - pass those through unchanged rather than crash.
  defp entrysummary(entry) do
    if U.ismap(entry), do: Map.drop(entry, ["res", "thrown", "ctx"]), else: entry
  end

  # The label of one entry, for failure messages.
  defp entryref(label, index, entry) do
    id = U.get(entry, "id")
    idpart = if U.isabsent(id), do: "", else: " (#{U.stringify(id)})"
    "#{label}[#{index}]#{idpart}"
  end

  defp fail(label, index, entry, reason, expected, actual) do
    message = "omni: #{entryref(label, index, entry)}: #{reason}"
    message = if expected, do: message <> "\n  expected: #{expected}", else: message
    message = if actual, do: message <> "\n  actual:   #{actual}", else: message
    message = message <> "\n  entry:    #{U.stringify(entrysummary(entry))}"

    %OmniError{message: message, entry: entry}
  end
end
