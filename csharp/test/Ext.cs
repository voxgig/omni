// The capability suite: spec/ext.json requires ctxargs, fn and wait, and
// every port that carries them runs it, beside the runner flag `all`.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using Voxgig.Omni;
using Voxgig.Omni.Test;

internal static partial class Program
{
    // The ctxargs subject: the context comes first, and must arrive
    // contextified with its client attached.
    private static readonly Subject FIBSHIFTED = args =>
    {
        var ctx = args[0] as IDictionary<string, object>;
        if (null == ctx || !"CTX".Equals(ctx.ContainsKey("mark") ? ctx["mark"] : null) ||
            !ctx.ContainsKey("client") || null == ctx["client"])
        {
            throw new ArgumentException("fib: context not delivered");
        }
        double shift = Util.ToNum(ctx["shift"]);
        return Fib.FibRange(Util.ToNum(args[1]) + shift, Util.ToNum(args[2]) + shift);
    };

    private static RunPack ExtRunner(object spec) => Runner.MakeRunner(spec, FibProvider(0)).Run("fib");

    private static object V1(IList<object> requires, params object[] set) =>
        Map("OMNI", Map("version", 1.0, "requires", requires), "fib", Map("g", Map("set", List(set))));

    private static void Refuses(Action run, string pattern)
    {
        try
        {
            run();
        }
        catch (OmniError err)
        {
            if (!Regex.IsMatch(err.Message, pattern, RegexOptions.Singleline))
            {
                throw new InvalidOperationException("omni: message does not match [" + pattern + "]: " + err.Message);
            }
            return;
        }

        throw new InvalidOperationException("omni: expected OmniError matching: " + pattern);
    }

    private static IDictionary<string, object> WaitFlag(string id, string cause) =>
        Map(id, Map("cause", cause));

    private static void ExtSuite()
    {
        TestCase("ext capabilities", () =>
        {
            foreach (string cap in new[] { "ctxargs", "fn", "wait" })
            {
                if (!Runner.CAPABILITIES.Contains(cap))
                {
                    throw new InvalidOperationException("omni: missing capability: " + cap);
                }
            }
        });

        RunPack R = Runner.MakeRunner(SpecFile("ext.json"), FibProvider(0)).Run("fib");

        TestCase("ext ctxargs", () => R.RunSet(R.Set("ctxargs"), FIBSHIFTED));
        TestCase("ext fn", () => R.RunSet(R.Set("fn"), FIB));
        TestCase("ext wait", () => R.RunSet(R.Set("wait"), FIB));

        TestCase("a waiting entry that passes fails the set", () =>
        {
            RunPack W = ExtRunner(V1(List("wait"), Map("in", 5.0, "out", 5.0, "wait", Map("cause", "gone#1"))));
            Refuses(() => W.RunSet(W.Set("g"), FIB), @"\[0\]: stale wait: gone#1");
        });

        TestCase("the wait flag holds an entry by id", () =>
        {
            RunPack W = ExtRunner(V1(List(), Map("id", "a", "in", 6.0, "out", 9.0), Map("in", 7.0, "out", 13.0)));
            W.RunSetFlags(W.Set("g"), new Flags { Wait = WaitFlag("a", "flag#1") }, FIB);
        });

        TestCase("the wait flag fails when its entry passes", () =>
        {
            RunPack W = ExtRunner(V1(List(), Map("id", "a", "in", 6.0, "out", 8.0)));
            Refuses(() => W.RunSetFlags(W.Set("g"), new Flags { Wait = WaitFlag("a", "flag#1") }, FIB),
                "stale wait: flag#1");
        });

        TestCase("the wait flag must name an entry", () =>
        {
            RunPack W = ExtRunner(V1(List(), Map("id", "a", "in", 6.0, "out", 8.0)));
            Refuses(() => W.RunSetFlags(W.Set("g"), new Flags { Wait = WaitFlag("zz", "c") }, FIB),
                "wait names no entry: zz");
        });

        TestCase("a wait needs a cause", () =>
        {
            RunPack W = ExtRunner(V1(List("wait"), Map("in", 6.0, "out", 9.0, "wait", Map())));
            Refuses(() => W.RunSet(W.Set("g"), FIB), "entry wait has no cause");
        });

        TestCase("wait and fn are unknown fields unless required", () =>
        {
            RunPack W = ExtRunner(V1(List(), Map("in", 6.0, "out", 9.0, "wait", Map("cause", "c"))));
            Refuses(() => W.RunSet(W.Set("g"), FIB), "unknown entry field: wait");
            RunPack F = ExtRunner(V1(List(), Map("fn", "fib", "in", 6.0, "out", 8.0)));
            Refuses(() => F.RunSet(F.Set("g"), FIB), "unknown entry field: fn");
        });

        TestCase("an unknown fn is a spec error", () =>
        {
            RunPack W = ExtRunner(V1(List("fn"), Map("fn", "nope", "in", 6.0, "out", 8.0)));
            Refuses(() => W.RunSet(W.Set("g"), FIB), "unknown fn: nope");
        });

        TestCase("ctx with args needs ctxargs, and never takes in", () =>
        {
            RunPack N = ExtRunner(V1(List(), Map("ctx", Map("shift", 0.0), "args", List(0.0, 1.0), "out", List(0.0, 1.0))));
            Refuses(() => N.RunSet(N.Set("g"), FIBSHIFTED), "more than one of in, args, ctx");
            RunPack I = ExtRunner(V1(List("ctxargs"), Map("in", 1.0, "ctx", Map("shift", 0.0), "out", List(0.0))));
            Refuses(() => I.RunSet(I.Set("g"), FIBSHIFTED), "entry has in beside args or ctx");
        });

        TestCase("a legacy spec ignores fn and wait", () =>
        {
            RunPack W = ExtRunner(Map("fib", Map("g", Map("set", List(
                Map("in", 6.0, "out", 8.0, "fn", "nope", "wait", Map("cause", "c")))))));
            W.RunSet(W.Set("g"), FIB);
        });

        TestCase("all reports every failure at once", () =>
        {
            RunPack W = ExtRunner(V1(List(),
                Map("in", 5.0, "out", 6.0), Map("in", 6.0, "out", 8.0), Map("in", 7.0, "out", 14.0)));
            Refuses(() => W.RunSetFlags(W.Set("g"), new Flags { All = true }, FIB),
                @"^omni: fib: 2 of 3 entries failed\n.*fib\[0\]: result mismatch.*fib\[2\]: result mismatch");
            Refuses(() => W.RunSet(W.Set("g"), FIB), @"^omni: fib\[0\]: result mismatch");
        });
    }
}
