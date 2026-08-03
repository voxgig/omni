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

  @doc "Load a spec: a path to a JSON file."
  def loadspec(path) do
    case File.read(path) do
      {:ok, text} -> Json.parse(text)
      {:error, _} -> raise OmniError, message: "omni: cannot read spec: #{path}"
    end
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
      U.isnone(val) -> if donull, do: U.nullmark(), else: nil
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

    fn name, store ->
      spec = resolvespec(name, alltests)
      clients = resolveclients(provider, spec, store)

      subject =
        case Map.get(provider, :subject) do
          nil -> nil
          resolve -> resolve.(name)
        end

      runsetflags = fn testspec, flags, testsubject ->
        run_set_flags(
          %{spec: spec, subject: subject, provider: provider, clients: clients, name: name},
          testspec,
          flags,
          testsubject
        )
      end

      %{
        spec: spec,
        subject: subject,
        client: provider,
        set: fn setname -> U.get(spec, setname) end,
        runsetflags: runsetflags,
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

  defp run_set_flags(runpack, testspec, flags, testsubject) do
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

    testset
    |> Enum.with_index()
    |> Enum.each(fn {rawentry, index} ->
      if not U.ismap(rawentry) do
        raise OmniError, message: "omni: #{label}[#{index}]: entry is not a map"
      end

      run_entry(runpack, label, index, rawentry, donull, usesubject)
    end)
  end

  defp run_entry(runpack, label, index, rawentry, donull, usesubject) do
    # An entry with no `out` expects a null (or absent) result.
    entry =
      if donull and U.isnone(U.get(rawentry, "out")) do
        Map.put(rawentry, "out", U.nullmark())
      else
        rawentry
      end

    entrysubject = resolvesubject(runpack, entry, usesubject)
    {args, entry} = resolveargs(runpack, entry)

    try do
      {:ok, entrysubject.(args)}
    rescue
      omnierr in OmniError -> reraise(omnierr, __STACKTRACE__)
      err -> {:error, err}
    end
    |> case do
      {:ok, rawres} ->
        res = fixjson(rawres, donull)
        checkresult(label, index, Map.put(entry, "res", res), args, res)

      {:error, err} ->
        handleerror(label, index, entry, err)
    end
  end

  defp resolvesubject(runpack, entry, usesubject) do
    case U.get(entry, "client") do
      clientname when is_binary(clientname) ->
        client =
          Map.get(runpack.clients, clientname) ||
            raise(OmniError, message: "omni: unknown client: #{clientname}", entry: entry)

        case Map.get(client, :subject) do
          nil -> usesubject
          resolve -> resolve.(runpack.name) || usesubject
        end

      _ ->
        usesubject
    end
  end

  # Build the argument list: `ctx`, `args`, or `in`.
  defp resolveargs(runpack, entry) do
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

        ok =
          U.deepequal(check, baseval) or
            (U.undefmark() == check and U.isabsent(baseval)) or
            (U.existsmark() == check and not U.isnone(baseval)) or
            matchval(check, baseval)

        if not ok do
          where = if [] == path, do: "<root>", else: U.pathify(path)

          raise fail(label, index, entry, "match failed at #{where}",
                  U.stringify(check), U.stringify(baseval))
        end
    end
  end

  # The spec-defined part of an entry (drop runner bookkeeping).
  defp entrysummary(entry) do
    Map.drop(entry, ["res", "thrown", "ctx"])
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
