// Omni: the shared multi-language test runner (C# port).
//
// Port of the canonical TypeScript implementation
// (typescript/src/Runner.ts). Behaviour must match, case for case.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Voxgig.Omni
{
    /// <summary>The function under test. Arguments arrive as JSON values.</summary>
    public delegate object Subject(params object[] args);

    /// <summary>A test failure (or a malformed spec).</summary>
    public class OmniError : Exception
    {
        public object Entry { get; }

        public OmniError(string message) : this(message, null) { }

        public OmniError(string message, object entry) : base(message)
        {
            Entry = entry;
        }
    }

    /// <summary>Run-time options for a set of test entries.</summary>
    public class Flags
    {
        public bool Null { get; set; } = true;
        public string Name { get; set; }

        /// <summary>Run every entry, then fail once, listing every failure.</summary>
        public bool All { get; set; }

        /// <summary>A map from entry id to <c>{cause}</c>, holding those entries.</summary>
        public object Wait { get; set; }

        public static Flags NoNull() => new Flags { Null = false };
    }

    /// <summary>The host of the system under test. Every hook is optional.</summary>
    public class Provider
    {
        /// <summary>Resolve a test subject by name.</summary>
        public Func<string, Subject> SubjectFor { get; set; }

        /// <summary>Build a sub-provider from a DEF.client entry's options.</summary>
        public Func<object, Provider> Client { get; set; }

        /// <summary>Wrap a map argument as a call context.</summary>
        public Func<object, object> Contextify { get; set; }

        /// <summary>Resolve references in client options against the store.</summary>
        public Func<object, object, object> Inject { get; set; }

        /// <summary>
        /// Build the <c>match.err</c> base from the raised error, REPLACING
        /// <see cref="Runner.Errify"/>. A library whose errors carry a code
        /// can then assert on it with <c>match: {err: {code: "x"}}</c>
        /// instead of pattern-matching prose.
        /// </summary>
        public Func<object, object> Errify { get; set; }
    }

    /// <summary>What a runner returns for one named spec section.</summary>
    public class RunPack
    {
        public object Spec { get; }
        public Subject Subject { get; }
        public Provider Client { get; }

        private readonly Provider provider;
        private readonly Dictionary<string, Provider> clients;
        private readonly string name;
        private readonly int specversion;
        private readonly string[] requires;
        private readonly bool ctxargs;
        private readonly bool fnon;
        private readonly bool waiton;

        internal RunPack(object spec, Subject subject, Provider provider,
                         Dictionary<string, Provider> clients, string name, int specversion,
                         string[] requires)
        {
            Spec = spec;
            Subject = subject;
            Client = provider;
            this.provider = provider;
            this.clients = clients;
            this.name = name;
            this.specversion = specversion;
            this.requires = requires;
            ctxargs = requires.Contains("ctxargs");
            fnon = requires.Contains("fn");
            waiton = requires.Contains("wait");
        }

        /// <summary>A named group of the resolved spec.</summary>
        public object Set(string setname)
        {
            return Spec is IDictionary<string, object> map && map.ContainsKey(setname) ? map[setname] : null;
        }

        /// <summary>Run one set of test entries.</summary>
        public void RunSet(object testspec, Subject testsubject = null)
        {
            RunSetFlags(testspec, new Flags(), testsubject);
        }

        /// <summary>Run one set of test entries with flags.</summary>
        public void RunSetFlags(object testspec, Flags flags, Subject testsubject = null)
        {
            var useflags = new Flags
            {
                Null = null == flags ? true : flags.Null,
                Name = null == flags || string.IsNullOrEmpty(flags.Name)
                    ? (string.IsNullOrEmpty(name) ? "set" : name)
                    : flags.Name,
                All = null != flags && flags.All,
                Wait = flags?.Wait,
            };

            Subject subject = testsubject ?? Subject;
            if (null == subject && !fnon)
            {
                throw new OmniError("omni: no test subject for: " + useflags.Name);
            }

            var testspecmap = Runner.FixJson(testspec, useflags.Null) as IDictionary<string, object>;
            if (null == testspecmap || !(testspecmap.ContainsKey("set") && testspecmap["set"] is IList<object>))
            {
                throw new OmniError("omni: test spec has no set: " + useflags.Name);
            }

            var testset = (IList<object>)testspecmap["set"];

            if (1 <= specversion)
            {
                Runner.CheckSet(useflags, testspec, testset, requires);
            }

            IList<object> origset =
                testspec is IDictionary<string, object> specmap &&
                specmap.ContainsKey("set") && specmap["set"] is IList<object> authored
                    ? authored
                    : testset;
            var waits = Runner.ResolveWaits(useflags, origset);
            var failures = new List<string>();

            for (int index = 0; index < testset.Count; index++)
            {
                try
                {
                    if (!(testset[index] is IDictionary<string, object> entry))
                    {
                        throw new OmniError("omni: " + useflags.Name + "[" + index + "]: entry is not a map");
                    }

                    (Provider client, Subject subject) testpack = default;
                    Exception prestart = null;

                    // A hook's raw error before the subject starts is still the entry's.
                    try
                    {
                        ResolveEntry(entry, useflags);
                        testpack = ResolveTestPack(entry, subject);
                    }
                    catch (Exception err) when (!(err is OmniError))
                    {
                        prestart = err;
                    }

                    if (null == prestart && null == testpack.subject)
                    {
                        throw new OmniError("omni: no test subject for: " + useflags.Name);
                    }

                    bool haswait = waiton && entry.ContainsKey("wait");
                    object wait = haswait ? entry["wait"] : null;
                    if (!haswait && entry.ContainsKey("id") && entry["id"] is string id && waits.ContainsKey(id))
                    {
                        haswait = true;
                        wait = waits[id];
                    }

                    Action run = null == prestart
                        ? () => RunEntry(useflags, index, entry, testpack)
                        : () => Runner.HandleError(useflags, index, entry, prestart, provider);

                    if (!haswait)
                    {
                        run();
                    }
                    else
                    {
                        bool held = false;
                        try
                        {
                            run();
                        }
                        catch (OmniError)
                        {
                            held = true;
                        }
                        if (!held)
                        {
                            string cause = wait is IDictionary<string, object> waitmap &&
                                waitmap.ContainsKey("cause") && waitmap["cause"] is string text ? text : "";
                            throw Runner.Fail(useflags, index, entry, "stale wait: " + cause);
                        }
                    }
                }
                catch (OmniError err) when (useflags.All)
                {
                    failures.Add(err.Message);
                }
            }

            if (0 < failures.Count)
            {
                throw new OmniError("omni: " + useflags.Name + ": " +
                    failures.Count.ToString(CultureInfo.InvariantCulture) + " of " +
                    testset.Count.ToString(CultureInfo.InvariantCulture) + " entries failed\n" +
                    string.Join("\n", failures));
            }
        }

        // An entry with no `out` expects a null (or absent) result.
        private static void ResolveEntry(IDictionary<string, object> entry, Flags flags)
        {
            if (flags.Null && (!entry.ContainsKey("out") || null == entry["out"]))
            {
                entry["out"] = Util.NULLMARK;
            }
        }

        private (Provider client, Subject subject) ResolveTestPack(IDictionary<string, object> entry, Subject subject)
        {
            Provider client = provider;

            if (entry.ContainsKey("client") && entry["client"] is string clientname)
            {
                if (!clients.ContainsKey(clientname))
                {
                    throw new OmniError("omni: unknown client: " + clientname, entry);
                }
                client = clients[clientname];
                subject = Runner.ResolveSubject(name, client) ?? subject;
            }

            if (fnon && entry.ContainsKey("fn") && entry["fn"] is string fn)
            {
                subject = Runner.ResolveSubject(fn, client) ??
                    throw new OmniError("omni: unknown fn: " + fn, entry);
            }

            return (client, subject);
        }

        private void RunEntry(Flags flags, int index, IDictionary<string, object> entry,
                              (Provider client, Subject subject) testpack)
        {
            object[] args;
            object res;
            try
            {
                args = ResolveArgs(entry, testpack.client);
                res = testpack.subject(args);
            }
            catch (OmniError)
            {
                throw;
            }
            catch (Exception err)
            {
                Runner.HandleError(flags, index, entry, err, provider);
                return;
            }

            res = Runner.FixJson(res, flags.Null);
            entry["res"] = res;

            Runner.CheckResult(flags, index, entry, args, res);
        }

        // Build the argument list: `ctx`, `args`, or `in`. Under `ctxargs` an
        // entry with both passes the context first, then each argument.
        private object[] ResolveArgs(IDictionary<string, object> entry, Provider client)
        {
            object[] args;

            bool hasctx = entry.ContainsKey("ctx");
            bool hasargs = entry.ContainsKey("args");

            if (ctxargs && hasctx && hasargs)
            {
                var both = new List<object> { entry["ctx"] };
                if (entry["args"] is IList<object> rest)
                {
                    both.AddRange(rest);
                }
                else
                {
                    both.Add(entry["args"]);
                }
                args = both.ToArray();
            }
            else if (hasctx)
            {
                args = new object[] { entry["ctx"] };
            }
            else if (hasargs)
            {
                args = entry["args"] is IList<object> list ? list.ToArray() : new object[] { entry["args"] };
            }
            else
            {
                // An entry carrying none of `in`/`args`/`ctx` is called with one
                // ABSENT argument, not with null. Canonical passes `undefined`
                // there and the corpus leans on the difference: `typify()` is
                // 1073741824 where `typify(null)` is 4194432.
                //
                // C# can say it - `Absent.Mark` is already this port's model for
                // "no value" - where python and ruby cannot and contain it in
                // their compat shims instead (register 4.12). Passing null here
                // collapsed the two states before any consumer could see them.
                //
                // No existing consumer changes: fib has 0 implicit entries of 68
                // and sekreto 0 of 110. struct's corpus has 17.
                args = new object[]
                {
                    entry.ContainsKey("in") ? Util.Clone(entry["in"]) : Absent.Mark,
                };
            }

            if ((hasctx || hasargs) && 0 < args.Length && Util.IsMap(args[0]))
            {
                object first = Util.Clone(args[0]);
                if (null != provider.Contextify)
                {
                    first = provider.Contextify(first);
                }
                if (first is IDictionary<string, object> firstmap)
                {
                    firstmap["client"] = client;
                }
                args[0] = first;
                entry["ctx"] = first;
            }

            return args;
        }
    }

    /// <summary>A loaded spec plus its provider.</summary>
    public class RunnerPack
    {
        private readonly object alltests;
        private readonly Provider provider;
        private readonly int specversion;
        private readonly string[] requires;

        internal RunnerPack(object alltests, Provider provider, int specversion)
        {
            this.alltests = alltests;
            this.provider = provider ?? new Provider();
            this.specversion = specversion;
            requires = Runner.ResolveRequires(alltests);
        }

        /// <summary>Resolve one named section of the spec.</summary>
        public RunPack Run(string name, object store = null)
        {
            object spec = Runner.ResolveSpec(name, alltests);
            var clients = Runner.ResolveClients(provider, spec, store);
            var subject = Runner.ResolveSubject(name, provider);
            return new RunPack(spec, subject, provider, clients, name, specversion, requires);
        }
    }

    public static class Runner
    {
        public const string NULLMARK = Util.NULLMARK;
        public const string UNDEFMARK = Util.UNDEFMARK;
        public const string EXISTSMARK = Util.EXISTSMARK;

        // The newest spec format version this runner understands. A spec
        // with no OMNI block is version 0: the original, lenient format,
        // frozen forever. Version 1 turns on strict entry validation (see
        // CheckEntry).
        public const int SPECVERSION = 1;

        // Capability strings this runner supports beyond the version
        // baseline. A spec's OMNI.requires list is checked against this: an
        // unknown capability refuses the spec loudly at load time, instead
        // of a lagging port silently mis-running it. A spec turns each on
        // only by requiring it.
        public static readonly string[] CAPABILITIES = { "ctxargs", "fn", "wait" };

        // The complete set of fields an entry may carry. Under version 1
        // anything else is an error: an unrecognised key is almost always a
        // typo'd assertion, and a typo'd assertion is a test that silently
        // stopped testing.
        private static readonly string[] ENTRYFIELDS =
            { "in", "args", "ctx", "out", "err", "match", "client", "id", "doc" };

        // Entry fields a capability adds, permitted only in a spec that requires it.
        private static readonly Dictionary<string, string> CAPFIELDS =
            new Dictionary<string, string> { ["fn"] = "fn", ["wait"] = "wait" };

        /// <summary>Make a runner for a spec file path and a provider.</summary>
        public static RunnerPack MakeRunner(string path, Provider provider = null)
        {
            object alltests = LoadSpec(path);
            int specversion = ResolveVersion(alltests);
            return new RunnerPack(alltests, provider, specversion);
        }

        /// <summary>Make a runner for an in-memory spec and a provider.</summary>
        public static RunnerPack MakeRunner(object spec, Provider provider = null)
        {
            int specversion = ResolveVersion(spec);
            return new RunnerPack(spec, provider, specversion);
        }

        /// <summary>Load a spec: a path to a JSON file.</summary>
        public static object LoadSpec(string path)
        {
            if (!File.Exists(path))
            {
                throw new OmniError("omni: cannot read spec: " + path);
            }
            return Util.Parse(File.ReadAllText(path));
        }

        // Read the spec's format version from its optional top-level OMNI
        // block, and refuse a spec this runner cannot faithfully run: a
        // version newer than SPECVERSION, or a required capability not in
        // CAPABILITIES.
        internal static int ResolveVersion(object alltests)
        {
            if (!(alltests is IDictionary<string, object> allmap) || !allmap.ContainsKey("OMNI"))
            {
                return 0;
            }

            object meta = allmap["OMNI"];

            if (!(meta is IDictionary<string, object> metamap) ||
                !metamap.ContainsKey("version") ||
                !Util.IsNum(metamap["version"]) ||
                0 != Util.ToNum(metamap["version"]) % 1)
            {
                throw new OmniError("omni: malformed OMNI version block");
            }

            double version = Util.ToNum(metamap["version"]);

            if (0 > version || SPECVERSION < version)
            {
                throw new OmniError("omni: unsupported spec version: " + Util.NumStr(version));
            }

            if (metamap.ContainsKey("requires"))
            {
                if (!(metamap["requires"] is IList<object> requires))
                {
                    throw new OmniError("omni: malformed OMNI requires list");
                }

                foreach (var cap in requires)
                {
                    if (!(cap is string capstr) || !CAPABILITIES.Contains(capstr))
                    {
                        throw new OmniError("omni: spec requires unsupported capability: " + Util.Stringify(cap));
                    }
                }
            }

            return (int)version;
        }

        // The capabilities a spec requires, which ResolveVersion has already
        // checked against CAPABILITIES.
        internal static string[] ResolveRequires(object alltests)
        {
            if (alltests is IDictionary<string, object> allmap && allmap.ContainsKey("OMNI") &&
                allmap["OMNI"] is IDictionary<string, object> meta &&
                meta.ContainsKey("requires") && meta["requires"] is IList<object> requires)
            {
                return requires.OfType<string>().ToArray();
            }
            return Array.Empty<string>();
        }

        // Strict entry validation, applied when the spec declares version 1
        // or later. The lenient format converts each of these mistakes into
        // a silent pass or a dead field; here they fail with the entry
        // named.
        internal static void CheckEntry(Flags flags, int index, object entry, string[] requires)
        {
            if (!(entry is IDictionary<string, object> map))
            {
                throw Fail(flags, index, entry, "entry is not a map");
            }

            foreach (var key in map.Keys)
            {
                if (!ENTRYFIELDS.Contains(key) &&
                    !(CAPFIELDS.ContainsKey(key) && requires.Contains(CAPFIELDS[key])))
                {
                    throw Fail(flags, index, entry, "unknown entry field: " + key);
                }
            }

            if (requires.Contains("ctxargs"))
            {
                if (map.ContainsKey("in") && (map.ContainsKey("args") || map.ContainsKey("ctx")))
                {
                    throw Fail(flags, index, entry, "entry has in beside args or ctx");
                }
            }
            else
            {
                int argsources = 0;
                foreach (var key in new[] { "in", "args", "ctx" })
                {
                    if (map.ContainsKey(key))
                    {
                        argsources++;
                    }
                }
                if (1 < argsources)
                {
                    throw Fail(flags, index, entry, "entry has more than one of in, args, ctx");
                }
            }

            if (map.ContainsKey("fn") && !(map["fn"] is string fn && 0 < fn.Length))
            {
                throw Fail(flags, index, entry, "entry fn is not a name");
            }

            if (map.ContainsKey("wait") && !IsWait(map["wait"]))
            {
                throw Fail(flags, index, entry, "entry wait has no cause");
            }

            bool haserr = map.ContainsKey("err") && null != map["err"];
            bool hasout = map.ContainsKey("out");
            if (haserr && hasout)
            {
                throw Fail(flags, index, entry, "entry has both err and out");
            }

            if (map.ContainsKey("id") && !(map["id"] is string))
            {
                throw Fail(flags, index, entry, "entry id is not a string");
            }
        }

        // Validate a version-1 group up front, against the AUTHORED entries
        // - null-normalisation would otherwise rewrite an authored null
        // (e.g. id: null) into a sentinel string and hide it from
        // validation. A malformed spec is a spec error, not a test result,
        // so it fails before any subject runs.
        internal static void CheckSet(Flags flags, object testspec, IList<object> normalset, string[] requires)
        {
            IList<object> origset = normalset;

            if (testspec is IDictionary<string, object> specmap &&
                specmap.ContainsKey("set") && specmap["set"] is IList<object> setlist)
            {
                origset = setlist;
            }

            bool markedempty = false;
            if (testspec is IDictionary<string, object> em &&
                em.ContainsKey("empty") && em["empty"] is bool flag)
            {
                markedempty = flag;
            }

            if (0 == origset.Count && !markedempty)
            {
                throw new OmniError("omni: empty test set: " + flags.Name);
            }

            for (int index = 0; index < origset.Count; index++)
            {
                CheckEntry(flags, index, origset[index], requires);
            }
        }

        internal static bool IsWait(object wait)
        {
            return wait is IDictionary<string, object> waitmap && waitmap.ContainsKey("cause") &&
                   waitmap["cause"] is string cause && 0 < cause.Length;
        }

        // The runner-side waits: entry id to its declaration. Each must name
        // an entry of the set, so a declaration cannot outlive the entry it
        // held.
        internal static IDictionary<string, object> ResolveWaits(Flags flags, IList<object> origset)
        {
            if (null == flags.Wait)
            {
                return new Dictionary<string, object>();
            }
            if (!(flags.Wait is IDictionary<string, object> waits))
            {
                throw new OmniError("omni: " + flags.Name + ": wait flag is not a map");
            }
            var ids = origset
                .Select(entry => entry is IDictionary<string, object> map && map.ContainsKey("id") ? map["id"] : null)
                .ToList();
            foreach (var wait in waits)
            {
                if (!ids.Any(id => id is string text && text == wait.Key))
                {
                    throw new OmniError("omni: " + flags.Name + ": wait names no entry: " + wait.Key);
                }
                if (!IsWait(wait.Value))
                {
                    throw new OmniError("omni: " + flags.Name + ": wait for " + wait.Key + " has no cause");
                }
            }
            return waits;
        }

        /// <summary>Find `primary.&lt;name&gt;`, then `&lt;name&gt;`, then the whole spec.</summary>
        public static object ResolveSpec(string name, object alltests)
        {
            if (string.IsNullOrEmpty(name))
            {
                return alltests;
            }

            if (alltests is IDictionary<string, object> allmap)
            {
                if (allmap.ContainsKey("primary") && allmap["primary"] is IDictionary<string, object> primary &&
                    primary.ContainsKey(name) && null != primary[name])
                {
                    return primary[name];
                }

                if (allmap.ContainsKey(name) && null != allmap[name])
                {
                    return allmap[name];
                }
            }

            return alltests;
        }

        internal static Dictionary<string, Provider> ResolveClients(Provider provider, object spec, object store)
        {
            var clients = new Dictionary<string, Provider>();

            if (!(spec is IDictionary<string, object> specmap) ||
                !specmap.ContainsKey("DEF") ||
                !(specmap["DEF"] is IDictionary<string, object> def) ||
                !def.ContainsKey("client") ||
                !(def["client"] is IDictionary<string, object> defclient))
            {
                return clients;
            }

            // A spec may define clients that a given test run never references.
            if (null == provider.Client)
            {
                return clients;
            }

            foreach (var entry in defclient)
            {
                object copts = new Dictionary<string, object>();

                if (entry.Value is IDictionary<string, object> cdef &&
                    cdef.ContainsKey("test") &&
                    cdef["test"] is IDictionary<string, object> ctest &&
                    ctest.ContainsKey("options"))
                {
                    copts = Util.Clone(ctest["options"]);
                }

                if (null != provider.Inject && Util.IsMap(store))
                {
                    copts = provider.Inject(copts, store);
                }

                clients[entry.Key] = provider.Client(copts);
            }

            return clients;
        }

        internal static Subject ResolveSubject(string name, Provider provider)
        {
            if (string.IsNullOrEmpty(name) || null == provider || null == provider.SubjectFor)
            {
                return null;
            }
            return provider.SubjectFor(name);
        }

        /// <summary>Nulls become NULLMARK, errors become {name,message}. Always a copy.</summary>
        public static object FixJson(object val, bool donull)
        {
            if (null == val || Util.IsAbsent(val))
            {
                return donull ? (object)Util.NULLMARK : val;
            }

            if (val is Exception err)
            {
                return Errify(err);
            }

            if (val is IList<object> list)
            {
                var outlist = new List<object>();
                foreach (var entry in list)
                {
                    outlist.Add(FixJson(entry, donull));
                }
                return outlist;
            }

            if (val is IDictionary<string, object> map)
            {
                var outmap = new Dictionary<string, object>();
                foreach (var entry in map)
                {
                    outmap[entry.Key] = FixJson(entry.Value, donull);
                }
                return outmap;
            }

            return val;
        }

        /// <summary>The JSON form of an error: always at least {name,message}.</summary>
        public static IDictionary<string, object> Errify(object err)
        {
            var out_ = new Dictionary<string, object>();

            if (err is Exception exception)
            {
                out_["name"] = exception.GetType().Name;
                out_["message"] = exception.Message;
            }
            else
            {
                out_["name"] = "Error";
                out_["message"] = Convert.ToString(err, CultureInfo.InvariantCulture);
            }

            return out_;
        }

        // The label of one entry, for failure messages.
        private static string EntryRef(Flags flags, int index, object entry)
        {
            string label = string.IsNullOrEmpty(flags.Name) ? "set" : flags.Name;
            string idpart = "";
            if (entry is IDictionary<string, object> map && map.ContainsKey("id") && null != map["id"])
            {
                idpart = " (" + Util.Stringify(map["id"]) + ")";
            }
            return label + "[" + index.ToString(CultureInfo.InvariantCulture) + "]" + idpart;
        }

        internal static OmniError Fail(Flags flags, int index, object entry,
                                       string reason, string expected = null, string actual = null)
        {
            var msg = new StringBuilder("omni: ").Append(EntryRef(flags, index, entry)).Append(": ").Append(reason);

            if (null != expected)
            {
                msg.Append("\n  expected: ").Append(expected);
            }
            if (null != actual)
            {
                msg.Append("\n  actual:   ").Append(actual);
            }
            msg.Append("\n  entry:    ").Append(Util.Stringify(EntrySummary(entry)));

            return new OmniError(msg.ToString(), entry);
        }

        // The spec-defined part of an entry (drop runner bookkeeping).
        private static object EntrySummary(object entry)
        {
            if (!(entry is IDictionary<string, object> map))
            {
                return entry;
            }
            var out_ = new Dictionary<string, object>();
            foreach (var field in map)
            {
                if ("res" != field.Key && "thrown" != field.Key && "ctx" != field.Key)
                {
                    out_[field.Key] = field.Value;
                }
            }
            return out_;
        }

        internal static void CheckResult(Flags flags, int index, IDictionary<string, object> entry,
                                         object[] args, object res)
        {
            bool matched = false;

            if (entry.ContainsKey("err") && null != entry["err"])
            {
                throw Fail(flags, index, entry, "expected error did not occur",
                           Util.Stringify(entry["err"]), Util.Stringify(res));
            }

            if (entry.ContainsKey("match") && null != entry["match"])
            {
                var base_ = new Dictionary<string, object>
                {
                    ["in"] = entry.ContainsKey("in") ? entry["in"] : null,
                    ["args"] = new List<object>(args),
                    ["out"] = entry.ContainsKey("res") ? entry["res"] : null,
                    ["ctx"] = entry.ContainsKey("ctx") ? entry["ctx"] : null,
                };
                Match(flags, index, entry, entry["match"], base_);
                matched = true;
            }

            // Same conflation as ResolveArgs: an entry with NO `out` expects an
            // absent result, and one with `out: null` expects a null. Answering
            // null for both compared a subject that correctly returned nothing
            // against null and marked it wrong. Canonical gets this for free -
            // `entry.out` on a missing key IS undefined, which is also how
            // TypeScript spells absent.
            //
            // This half was missing while FixJson stopped collapsing absent
            // into null (#23), and the two must agree: with only FixJson fixed,
            // a subject that returned absent produced `res` absent and `out`
            // null, so `minor/clone#13` failed.
            //
            // (Under `null: true` this never fires - ResolveEntry has already
            // put NULLMARK there.)
            object outval = entry.ContainsKey("out") ? entry["out"] : Absent.Mark;

            if (Util.DeepEqual(res, outval))
            {
                return;
            }

            // NOTE: a match with no explicit out is a complete check on its own.
            // `null == out` in canonical is true of undefined too, so absent counts.
            if (matched && (Util.NULLMARK.Equals(outval) || null == outval || Util.IsAbsent(outval)))
            {
                return;
            }

            throw Fail(flags, index, entry, "result mismatch", Util.Stringify(outval), Util.Stringify(res));
        }

        /// <summary>The error base a <c>match.err</c> sees: the provider's own, when it has one.</summary>
        internal static object ErrBase(object err, Provider provider)
        {
            return null != provider && null != provider.Errify ? provider.Errify(err) : Errify(err);
        }

        internal static void HandleError(Flags flags, int index, IDictionary<string, object> entry, Exception err, Provider provider = null)
        {
            object entryerr = entry.ContainsKey("err") ? entry["err"] : null;

            if (null != entryerr)
            {
                bool istrue = entryerr is bool flag && flag;

                if (istrue || MatchVal(entryerr, err.Message))
                {
                    if (entry.ContainsKey("match") && null != entry["match"])
                    {
                        var base_ = new Dictionary<string, object>
                        {
                            ["in"] = entry.ContainsKey("in") ? entry["in"] : null,
                            ["out"] = entry.ContainsKey("res") ? entry["res"] : null,
                            ["ctx"] = entry.ContainsKey("ctx") ? entry["ctx"] : null,
                            ["err"] = ErrBase(err, provider),
                        };
                        Match(flags, index, entry, entry["match"], base_);
                    }
                    return;
                }

                throw Fail(flags, index, entry, "error mismatch", Util.Stringify(entryerr), err.Message);
            }

            throw Fail(flags, index, entry, "unexpected error", null, err.Message);
        }

        /// <summary>Check that every leaf of `check` is present, and matches, in `base`.</summary>
        public static void Match(Flags flags, int index, IDictionary<string, object> entry,
                                 object check, object base_)
        {
            MatchWalk(flags, index, entry, check, base_, new List<string>());
        }

        private static void MatchWalk(Flags flags, int index, IDictionary<string, object> entry,
                                      object check, object base_, List<string> path)
        {
            string where = 0 == path.Count ? "<root>" : Util.PathIfy(path);

            if (check is IList<object> list)
            {
                for (int at = 0; at < list.Count; at++)
                {
                    var childpath = new List<string>(path) { at.ToString(CultureInfo.InvariantCulture) };
                    MatchWalk(flags, index, entry, list[at], base_, childpath);
                }
                return;
            }

            if (check is IDictionary<string, object> map)
            {
                foreach (var field in map)
                {
                    var childpath = new List<string>(path) { field.Key };
                    MatchWalk(flags, index, entry, field.Value, base_, childpath);
                }
                return;
            }

            object baseval = Util.GetPath(base_, path);

            // The sentinels are tested BEFORE the identity check below.
            // Otherwise a subject returning the literal string "__UNDEF__"
            // satisfies an assertion that the key is absent - two mutually
            // exclusive states passing one check. A sentinel that accepts
            // its own literal is not a sentinel. (NULLMARK still accepts
            // NULLMARK: under the default null flag a real null has already
            // been normalised to it, so the two are genuinely
            // indistinguishable here - that one needs a raw-value escape,
            // not an ordering change.)

            // Explicitly absent: satisfied only by a genuinely missing key,
            // never by a present null (the distinction the sentinels exist
            // to keep).
            if (Util.UNDEFMARK.Equals(check))
            {
                if (Util.IsAbsent(baseval))
                {
                    return;
                }
                throw Fail(flags, index, entry, "expected absent at " + where,
                           "absent", Util.Stringify(baseval));
            }

            // Explicitly null: satisfied only by a present null.
            if (Util.NULLMARK.Equals(check))
            {
                if (null == baseval || Util.NULLMARK.Equals(baseval))
                {
                    return;
                }
                throw Fail(flags, index, entry, "expected null at " + where,
                           "null", Util.Stringify(baseval));
            }

            // Explicitly present: any present value, including null.
            if (Util.EXISTSMARK.Equals(check))
            {
                if (!Util.IsAbsent(baseval))
                {
                    return;
                }
                throw Fail(flags, index, entry, "expected present at " + where,
                           "present", "absent");
            }

            // Identical values match. This sits below the sentinel branches
            // on purpose - see the note above.
            if (Util.DeepEqual(check, baseval))
            {
                return;
            }

            // A concrete expectation never matches a missing key - a match
            // leaf against an absent value must fail, not substring-match
            // "undefined".
            if (Util.IsAbsent(baseval))
            {
                throw Fail(flags, index, entry, "match failed at " + where,
                           Util.Stringify(check), "absent");
            }

            if (MatchVal(check, baseval))
            {
                return;
            }

            throw Fail(flags, index, entry, "match failed at " + where,
                       Util.Stringify(check), Util.Stringify(baseval));
        }

        /// <summary>Match one leaf: /regex/ or case-insensitive substring for strings.</summary>
        public static bool MatchVal(object check, object base_)
        {
            if (Util.DeepEqual(check, base_))
            {
                return true;
            }

            if (check is string text)
            {
                // An empty want would substring-match anything.
                if (0 == text.Length)
                {
                    return false;
                }

                string basestr = Util.Stringify(base_);

                if (2 < text.Length && text.StartsWith("/", StringComparison.Ordinal) &&
                    text.EndsWith("/", StringComparison.Ordinal))
                {
                    try
                    {
                        return Regex.IsMatch(basestr, text.Substring(1, text.Length - 2));
                    }
                    catch (ArgumentException)
                    {
                        return false;
                    }
                }

                return basestr.ToLowerInvariant().Contains(text.ToLowerInvariant());
            }

            return Util.DeepEqual(check, base_);
        }

        /// <summary>Convert NULLMARK sentinels back into real nulls.</summary>
        public static object NullModifier(object val, IList<string> path)
        {
            if (val is string text)
            {
                return Util.NULLMARK == text ? null : (object)text.Replace(Util.NULLMARK, "null");
            }
            return val;
        }
    }
}
