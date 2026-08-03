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

    // The provider hosts the system under test. `shift` offsets the
    // Fibonacci index, so that a client-specific subject is observably
    // different.
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
        };
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
                // An empty container asserts an empty container, not "anything".
                "emptymatch", Map("set", List(
                    Map("in", 6.0, "match", Map("out", Map())))),
                // An empty-string match leaf must not substring-match anything.
                "emptystr", Map("set", List(
                    Map("in", 6.0, "match", Map("out", Map("label", "")))))));
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

    private static int Main(string[] args)
    {
        if (0 < args.Length)
        {
            only = args[0];
        }

        RunPack R = Runner.MakeRunner(SpecFile("fib.json"), FibProvider(0)).Run("fib");

        TestCase("basic", () => R.RunSet(R.Set("basic"), FIB));
        TestCase("seq", () => R.RunSet(R.Set("seq"), FIBSEQ));
        TestCase("range", () => R.RunSet(R.Set("range"), FIBRANGE));
        TestCase("info", () => R.RunSet(R.Set("info"), FIBINFO));
        TestCase("nulls", () => R.RunSetFlags(R.Set("nulls"), Flags.NoNull(), FIBINFO));
        TestCase("error", () => R.RunSet(R.Set("error"), FIB));
        TestCase("match", () => R.RunSet(R.Set("match"), FIB));
        TestCase("matchinfo", () => R.RunSet(R.Set("matchinfo"), FIBINFO));
        TestCase("client", () => R.RunSet(R.Set("client"), FIB));

        TestCase("detects wrong result", () => ExpectFail("wrongout", FIB));
        TestCase("detects missing error", () => ExpectFail("wrongerr", FIB));
        TestCase("detects failed match", () => ExpectFail("wrongmatch", FIB));
        TestCase("detects absent key", () => ExpectFail("missing", FIBINFO));
        TestCase("concrete leaf does not match missing key", () => ExpectFail("matchabsent", FIBINFO));
        TestCase("__UNDEF__ does not match present null", () => ExpectFail("undefonnull", FIBINFO));
        TestCase("__NULL__ does not match absent key", () => ExpectFail("nullonabsent", FIBINFO));
        TestCase("empty match container is not vacuous", () => ExpectFail("emptymatch", FIBINFO));
        TestCase("an empty-string match leaf is not a wildcard", () => ExpectFail("emptystr", FIBINFO));
        TestCase("reports entry index and id", CheckMessage);

        Console.WriteLine("\n" + passcount + " passed, " + failcount + " failed");

        return 0 == failcount ? 0 : 1;
    }
}
