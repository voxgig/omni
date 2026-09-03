// RUN: dotnet run --project test
// RUN-SOME: dotnet run --project test -- basic
//
// The Fibonacci conformance suite: every omni port runs this same set of
// groups, from the same spec/fib.json, against the same fib library.
//
// No third-party test framework: a failing omni check throws OmniError, so
// any host framework (xUnit, NUnit, MSTest) reports it as a failure. This
// harness keeps `make test` dependency-free.

using System;
using System.Collections.Generic;
using System.IO;
using Voxgig.Omni;
using Voxgig.Omni.Test;

internal static class Program
{
    private static string only;
    private static int passcount;
    private static int failcount;

    // Find the shared spec directory by walking up from the working dir.
    private static string SpecFile(string name)
    {
        var dir = new DirectoryInfo(Directory.GetCurrentDirectory());

        for (int step = 0; step < 8 && null != dir; step++)
        {
            string cand = Path.Combine(dir.FullName, "spec", name);
            if (File.Exists(cand))
            {
                return cand;
            }
            dir = dir.Parent;
        }

        throw new OmniError("omni: spec not found: " + name);
    }

    private static readonly Subject FIB = args => Fib.FibOf(args[0]);
    private static readonly Subject FIBSEQ = args => Fib.FibSeq(args[0]);
    private static readonly Subject FIBRANGE = args => Fib.FibRange(args[0], args[1]);
    private static readonly Subject FIBINFO = args => Fib.FibInfo(args[0]);

    // A subject that returns the literal string "__UNDEF__" as ordinary
    // data, to prove the sentinel is not satisfied by its own literal.
    private static readonly Subject FIBUNDEFLITERAL = args =>
        new Dictionary<string, object> { ["n"] = args[0], ["a"] = Util.UNDEFMARK };

    // The context-group subject: reports what the runner delivered - the
    // contextify mark and the attached client - as plain data, so the spec
    // can pin both with an ordinary `out` comparison in every port.
    private static readonly Subject FIBCTX = args =>
    {
        var ctx = (IDictionary<string, object>)args[0];
        return new Dictionary<string, object>
        {
            ["n"] = ctx.ContainsKey("n") ? ctx["n"] : null,
            ["val"] = Fib.FibOf(ctx.ContainsKey("n") ? ctx["n"] : null),
            ["mark"] = ctx.ContainsKey("mark") ? ctx["mark"] : null,
            ["hasclient"] = ctx.ContainsKey("client") && null != ctx["client"],
        };
    };

    // The provider hosts the system under test. `shift` offsets the
    // Fibonacci index, so that a client-specific subject is observably
    // different. `contextify` marks the map, so the context group can prove
    // the hook ran.
    private static Provider FibProvider(double shift)
    {
        var subjects = new Dictionary<string, Subject>
        {
            ["fib"] = args => Util.IsNum(args[0])
                ? Fib.FibOf(Util.ToNum(args[0]) + shift)
                : Fib.FibOf(args[0]),
            ["fibseq"] = FIBSEQ,
            ["fibrange"] = FIBRANGE,
            ["fibinfo"] = FIBINFO,
        };

        return new Provider
        {
            SubjectFor = name => subjects.ContainsKey(name) ? subjects[name] : null,
            Client = options =>
            {
                double clientshift = 0;
                if (options is IDictionary<string, object> map && map.ContainsKey("shift") &&
                    Util.IsNum(map["shift"]))
                {
                    clientshift = Util.ToNum(map["shift"]);
                }
                return FibProvider(clientshift);
            },
            Contextify = val =>
            {
                var outmap = new Dictionary<string, object>((IDictionary<string, object>)val)
                {
                    ["mark"] = "CTX",
                };
                return outmap;
            },
        };
    }

    /// <summary>Derive fib's error code from its message.</summary>
    private static string FibErrCode(string message)
    {
        if (message.Contains("negative index")) { return "fib_negative"; }
        if (message.Contains("non-integer")) { return "fib_noninteger"; }
        if (message.Contains("not a number")) { return "fib_notanumber"; }
        return "fib_unknown";
    }

    /// <summary>
    /// The same provider, plus the Errify hook: fib's errors gain a CODE.
    ///
    /// A SECOND runner rather than a hook on FibProvider, so that the
    /// <c>error</c> group keeps exercising the DEFAULT Errify.
    /// </summary>
    private static Provider FibCodedProvider()
    {
        Provider provider = FibProvider(0);
        provider.Errify = err =>
        {
            string message = err is Exception ex ? ex.Message : Convert.ToString(err);
            return new Dictionary<string, object>
            {
                ["name"] = "Error",
                ["message"] = message,
                ["code"] = FibErrCode(message),
            };
        };
        return provider;
    }

    private static void TestCase(string name, Action body)
    {
        if (null != only && name != only)
        {
            return;
        }

        try
        {
            body();
            passcount++;
            Console.WriteLine("ok   - " + name);
        }
        catch (Exception err)
        {
            failcount++;
            Console.WriteLine("FAIL - " + name);
            Console.WriteLine(err.Message);
        }
    }

    // The runner must fail when the subject is wrong - otherwise a green
    // suite means nothing.
    private static object BadSpec()
    {
        return Map(
            "fib", Map(
                "wrongout", Map("set", List(
                    Map("in", 5.0, "out", 5.0),
                    Map("in", 6.0, "out", 999.0))),
                "wrongerr", Map("set", List(
                    Map("in", 1.0, "err", "never happens"))),
                "wrongmatch", Map("set", List(
                    Map("in", 6.0, "match", Map("out", 999.0)))),
                "missing", Map("set", List(
                    Map("in", 6.0, "match", Map("out", Map("nope", "__EXISTS__"))))),
                // A concrete match leaf against a missing key must fail, not
                // substring-match the text "undefined".
                "matchabsent", Map("set", List(
                    Map("in", 6.0, "match", Map("out", Map("nope", "fine"))))),
                // __UNDEF__ (absent) must not be satisfied by a present null.
                "undefonnull", Map("set", List(
                    Map("in", 0.0, "match", Map("out", Map("prev", "__UNDEF__"))))),
                // __NULL__ (present null) must not be satisfied by an absent key.
                "nullonabsent", Map("set", List(
                    Map("in", 6.0, "match", Map("out", Map("nope", "__NULL__"))))),
                // An empty-string match leaf must not substring-match anything.
                "emptystr", Map("set", List(
                    Map("in", 6.0, "match", Map("out", Map("label", ""))))),
                // __UNDEF__ (absent) must not be satisfied by a subject
                // returning the literal string "__UNDEF__" as ordinary data.
                "wrongundef", Map("set", List(
                    Map("in", 6.0, "match", Map("out", Map("a", "__UNDEF__")))))));
    }

    private static IDictionary<string, object> Map(params object[] pairs)
    {
        var map = new Dictionary<string, object>();
        for (int index = 0; index + 1 < pairs.Length; index += 2)
        {
            map[(string)pairs[index]] = pairs[index + 1];
        }
        return map;
    }

    private static IList<object> List(params object[] entries) => new List<object>(entries);

    private static void ExpectFail(string setname, Subject subject)
    {
        RunPack bad = Runner.MakeRunner(BadSpec()).Run("fib");

        try
        {
            bad.RunSet(bad.Set(setname), subject);
        }
        catch (OmniError)
        {
            return;
        }

        throw new InvalidOperationException("omni: expected OmniError for set: " + setname);
    }

    // MakeRunner itself must refuse a spec it cannot faithfully run - a
    // version check, so a lagging port fails loudly at load time instead of
    // silently mis-running a spec whose features it does not know.
    private static void ExpectMakeRunnerFail(object spec, string mustcontain)
    {
        try
        {
            Runner.MakeRunner(spec);
        }
        catch (OmniError err)
        {
            if (!err.Message.Contains(mustcontain))
            {
                throw new InvalidOperationException("omni: message missing [" + mustcontain + "]: " + err.Message);
            }
            return;
        }

        throw new InvalidOperationException("omni: expected OmniError containing: " + mustcontain);
    }

    private static void ExpectRunSetFail(object spec, string setname, Subject subject, string mustcontain)
    {
        RunPack r = Runner.MakeRunner(spec).Run("fib");

        try
        {
            r.RunSet(r.Set(setname), subject);
        }
        catch (OmniError err)
        {
            if (!err.Message.Contains(mustcontain))
            {
                throw new InvalidOperationException("omni: message missing [" + mustcontain + "]: " + err.Message);
            }
            return;
        }

        throw new InvalidOperationException("omni: expected OmniError containing: " + mustcontain);
    }

    private static void CheckMessage()
    {
        object spec = Map("fib", Map("g", Map("set", List(
            Map("in", 1.0, "out", 1.0),
            Map("id", "x#2", "in", 2.0, "out", 42.0)))));

        RunPack bad = Runner.MakeRunner(spec).Run("fib");

        try
        {
            bad.RunSet(bad.Set("g"), FIB);
        }
        catch (OmniError err)
        {
            foreach (string want in new[] { "fib[1] (x#2)", "expected: 42", "actual:   1" })
            {
                if (!err.Message.Contains(want))
                {
                    throw new InvalidOperationException("omni: message missing [" + want + "]: " + err.Message);
                }
            }
            return;
        }

        throw new InvalidOperationException("omni: expected OmniError");
    }

    // deepequal is structural, not IEEE: NaN equals NaN, at the top level
    // and nested inside containers. spec/fib.json cannot pin this - JSON
    // has no NaN literal - so it is pinned here instead.
    //
    // The two NaNs come from two DIFFERENT expressions and are boxed
    // separately, so neither the ReferenceEquals fast-path at the top of
    // DeepEqual nor one shared NaN constant can be what makes the
    // comparison come out true.
    private static void NanEquality()
    {
        double zero = 0.0;
        double huge = double.PositiveInfinity;
        double nan1 = zero / zero; // 0.0 / 0.0
        double nan2 = huge - huge; // INFINITY - INFINITY

        ExpectEqual(double.IsNaN(nan1) && double.IsNaN(nan2), true, "two NaN values");
        ExpectEqual(nan1 == nan2, false, "the two NaNs IEEE-equal");

        object n1 = nan1;
        object n2 = nan2;

        ExpectEqual(ReferenceEquals(n1, n2), false, "the two boxed NaNs one object");

        ExpectEqual(Util.DeepEqual(n1, n2), true, "DeepEqual(NaN, NaN)");
        ExpectEqual(Util.DeepEqual(List(n1), List(n2)), true, "DeepEqual([NaN], [NaN])");
        ExpectEqual(Util.DeepEqual(Map("x", n1), Map("x", n2)), true,
            "DeepEqual({x:NaN}, {x:NaN})");

        ExpectEqual(Util.DeepEqual(1, 1.0), true, "DeepEqual(1, 1.0)");
        ExpectEqual(Util.DeepEqual(n1, 1.0), false, "DeepEqual(NaN, 1.0)");
        ExpectEqual(Util.DeepEqual(true, 1), false, "DeepEqual(true, 1)");
        ExpectEqual(Util.DeepEqual(1, 2), false, "DeepEqual(1, 2)");
    }

    private static void ExpectEqual(bool got, bool want, string what)
    {
        if (got != want)
        {
            throw new InvalidOperationException(
                "omni: expected " + what + " to be " + (want ? "true" : "false"));
        }
    }

    private static int Main(string[] args)
    {
        if (0 < args.Length)
        {
            only = args[0];
        }

        RunPack R = Runner.MakeRunner(SpecFile("fib.json"), FibProvider(0)).Run("fib");
        RunPack RC = Runner.MakeRunner(SpecFile("fib.json"), FibCodedProvider()).Run("fib");

        TestCase("basic", () => R.RunSet(R.Set("basic"), FIB));
        TestCase("seq", () => R.RunSet(R.Set("seq"), FIBSEQ));
        TestCase("range", () => R.RunSet(R.Set("range"), FIBRANGE));
        TestCase("info", () => R.RunSet(R.Set("info"), FIBINFO));
        TestCase("nulls", () => R.RunSetFlags(R.Set("nulls"), Flags.NoNull(), FIBINFO));
        TestCase("error", () => R.RunSet(R.Set("error"), FIB));
        TestCase("errcode", () => RC.RunSet(RC.Set("errcode"), FIB));
        TestCase("match", () => R.RunSet(R.Set("match"), FIB));
        TestCase("matchinfo", () => R.RunSet(R.Set("matchinfo"), FIBINFO));
        TestCase("client", () => R.RunSet(R.Set("client"), FIB));
        TestCase("context", () => R.RunSet(R.Set("context"), FIBCTX));

        TestCase("detects wrong result", () => ExpectFail("wrongout", FIB));
        TestCase("detects missing error", () => ExpectFail("wrongerr", FIB));
        TestCase("detects failed match", () => ExpectFail("wrongmatch", FIB));
        TestCase("detects absent key", () => ExpectFail("missing", FIBINFO));
        TestCase("concrete leaf does not match missing key", () => ExpectFail("matchabsent", FIBINFO));
        TestCase("__UNDEF__ does not match present null", () => ExpectFail("undefonnull", FIBINFO));
        TestCase("__NULL__ does not match absent key", () => ExpectFail("nullonabsent", FIBINFO));
        TestCase("an empty-string match leaf is not a wildcard", () => ExpectFail("emptystr", FIBINFO));
        TestCase("__UNDEF__ does not match a literal \"__UNDEF__\" in the data",
            () => ExpectFail("wrongundef", FIBUNDEFLITERAL));
        TestCase("reports entry index and id", CheckMessage);

        TestCase("rejects an unsupported spec version", () =>
            ExpectMakeRunnerFail(
                Map("OMNI", Map("version", 99.0), "fib", Map("g", Map("set", List()))),
                "unsupported spec version"));

        TestCase("rejects an unknown required capability", () =>
            ExpectMakeRunnerFail(
                Map("OMNI", Map("version", 1.0, "requires", List("nosuchfeature")),
                    "fib", Map("g", Map("set", List()))),
                "unsupported capability"));

        TestCase("rejects a malformed version block", () =>
            ExpectMakeRunnerFail(
                Map("OMNI", Map("version", "one"), "fib", Map("g", Map("set", List()))),
                "malformed OMNI"));

        TestCase("strict: an unknown entry field fails instead of passing vacuously", () =>
            ExpectRunSetFail(
                Map("OMNI", Map("version", 1.0),
                    "fib", Map("g", Map("set", List(Map("in", 6.0, "matches", Map("out", 999.0)))))),
                "g", FIBINFO, "unknown entry field: matches"));

        TestCase("strict: more than one of in, args, ctx fails", () =>
            ExpectRunSetFail(
                Map("OMNI", Map("version", 1.0),
                    "fib", Map("g", Map("set", List(Map("in", 5.0, "args", List(5.0), "out", 5.0))))),
                "g", FIB, "more than one of in, args, ctx"));

        TestCase("strict: err together with out fails", () =>
            ExpectRunSetFail(
                Map("OMNI", Map("version", 1.0),
                    "fib", Map("g", Map("set", List(Map("in", -1.0, "err", true, "out", 5.0))))),
                "g", FIB, "both err and out"));

        TestCase("strict: a null id fails even under null-normalisation", () =>
            ExpectRunSetFail(
                Map("OMNI", Map("version", 1.0),
                    "fib", Map("g", Map("set", List(Map("in", 1.0, "out", 1.0, "id", null))))),
                "g", FIB, "entry id is not a string"));

        TestCase("strict: an empty set fails unless marked empty", () =>
        {
            object spec = Map("OMNI", Map("version", 1.0), "fib", Map(
                "g", Map("set", List()),
                "h", Map("set", List(), "empty", true)));
            ExpectRunSetFail(spec, "g", FIB, "empty test set");
            RunPack r = Runner.MakeRunner(spec).Run("fib");
            r.RunSet(r.Set("h"), FIB);
        });

        TestCase("a legacy spec (no OMNI block) stays lenient", () =>
        {
            object spec = Map("fib", Map("g", Map("set", List(
                Map("in", 6.0, "matches", Map("out", 999.0), "out", 8.0)))));
            RunPack r = Runner.MakeRunner(spec).Run("fib");
            r.RunSet(r.Set("g"), FIB);
        });

        TestCase("deepequal: two distinct NaNs are structurally equal", NanEquality);

        Console.WriteLine("\n" + passcount + " passed, " + failcount + " failed");

        return 0 == failcount ? 0 : 1;
    }
}
