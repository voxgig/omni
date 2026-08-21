// Drop-in replacement for the in-situ test runner in the voxgig/struct
// repository (`csharp/tests/Runner.cs`).
//
// struct's own runner and omni's runner implement the same spec format;
// this assembly exposes omni behind a struct-shaped API, so the C# port
// switches over by deleting its runner and referencing this project from
// `csharp/tests/Omni.cs`. The corpus, the library and the test bodies are
// unchanged. This is the C# peer of go/compat/struct, php/compat/Struct.php
// and lua/compat/struct.lua.
//
// It never references struct: a compat shim that linked the library under
// test would make omni depend on the thing it is meant to check. The SDK is
// reached by reflection instead, over the names struct's own SDK exposes.
//
// ---------------------------------------------------------------------------
// Three value-model gaps, all of them silent if left open
// ---------------------------------------------------------------------------
//
// 1. ABSENCE. omni marks an absent value with `Absent.Mark`; struct/csharp
//    uses its own `StructUtils.NONE`, a plain sentinel object. Neither
//    recognises the other, and omni's DeepEqual would compare NONE by
//    Object.Equals and simply answer false.
//
// 2. NUMBERS. omni parses every JSON number as `double` (Util.FromElement).
//    struct's own loader gave `long` for anything integral:
//
//        el.TryGetInt64(out long l) ? (object?)l : el.GetDouble()
//
//    and the library branches on that in a dozen places - `typify` answers
//    Integer or Decimal by it. Handing the port a double where it had always
//    seen a long changes answers, so integral doubles are converted on the
//    way IN. Nothing is needed on the way out: omni's DeepEqual already
//    compares long against double numerically.
//
// 3. LIST TYPE. omni's `IsList` is `val is IList<object>`, which a
//    `List<string>` does NOT satisfy - and struct's `KeysOf` returns exactly
//    that. Left alone, omni sees a scalar where the corpus wants a list and
//    reports a mismatch that names neither. struct's own runner papered over
//    it with a non-generic `IList` branch in its DeepEqual; here every list
//    is normalised to `List<object>` at the boundary instead.
//
// ---------------------------------------------------------------------------
// Register 4.12 (the seventeen no-argument entries)
// ---------------------------------------------------------------------------
//
// This is the first port that needs nothing for it. An entry carrying none
// of `in`/`args`/`ctx` is called with one absent argument; struct/csharp's
// subjects are fixed-arity-one and it has a real no-value whose `typify`
// answers noval, distinct from null. So `Absent.Mark` -> `NONE` is the whole
// of it - no `zeroargs` (python), `undefargs` (ruby), `NOVAL` (go, lua) or
// stdClass singleton (php).

using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Reflection;

namespace Voxgig.Omni.Compat
{
    /// <summary>omni, wearing struct's runner API.</summary>
    public static class Struct
    {
        /// <summary>Value is JSON null.</summary>
        public const string NULLMARK = Util.NULLMARK;

        /// <summary>Value is not present.</summary>
        public const string UNDEFMARK = Util.UNDEFMARK;

        /// <summary>Value exists.</summary>
        public const string EXISTSMARK = Util.EXISTSMARK;

        private const BindingFlags PUBLIC =
            BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static |
            BindingFlags.IgnoreCase | BindingFlags.FlattenHierarchy;

        // ------------------------------------------------------------------
        // Reaching struct without referencing it
        // ------------------------------------------------------------------

        /// <summary>Read a property, field or no-argument method by name.</summary>
        private static object Member(object target, string name)
        {
            if (null == target)
            {
                return null;
            }

            Type type = target as Type ?? target.GetType();
            object instance = target is Type ? null : target;

            PropertyInfo property = type.GetProperty(name, PUBLIC);
            if (null != property && property.CanRead)
            {
                return property.GetValue(instance);
            }

            FieldInfo field = type.GetField(name, PUBLIC);
            if (null != field)
            {
                return field.GetValue(instance);
            }

            MethodInfo method = type.GetMethod(name, PUBLIC, null, Type.EmptyTypes, null);
            if (null != method)
            {
                return method.Invoke(instance, null);
            }

            return null;
        }

        /// <summary>
        /// struct's own no-value, off the SDK. A client that does not carry one
        /// gets null back, and absence then travels as a plain null - which is
        /// what every port without a no-value already does.
        /// </summary>
        private static object StructNone(object client)
        {
            object utility = Member(client, "Utility");
            object structutils = Member(utility, "Struct");
            return Member(structutils ?? utility, "NONE");
        }

        // ------------------------------------------------------------------
        // The two value models
        // ------------------------------------------------------------------

        /// <summary>
        /// omni's model -> struct's. Absence becomes the port's own sentinel,
        /// and an integral double becomes a long, because that is what struct's
        /// own loader produced and what its library is written against.
        /// </summary>
        public static object ToStruct(object val, object none)
        {
            if (Util.IsAbsent(val))
            {
                return none;
            }

            if (val is double number)
            {
                // Integral and inside long's range: the port saw a long here.
                if (!double.IsNaN(number) && !double.IsInfinity(number) &&
                    Math.Floor(number) == number &&
                    number >= -9.2233720368547758E18 && number <= 9.2233720368547758E18)
                {
                    return (long)number;
                }
                return number;
            }

            if (val is IDictionary<string, object> map)
            {
                var outmap = new Dictionary<string, object>(map.Count);
                foreach (KeyValuePair<string, object> pair in map)
                {
                    outmap[pair.Key] = ToStruct(pair.Value, none);
                }
                return outmap;
            }

            if (val is IList<object> list)
            {
                var outlist = new List<object>(list.Count);
                for (int index = 0; index < list.Count; index++)
                {
                    outlist.Add(ToStruct(list[index], none));
                }
                return outlist;
            }

            return val;
        }

        /// <summary>
        /// struct's model -> omni's. The port's no-value becomes `Absent.Mark`,
        /// and ANY list becomes a `List&lt;object&gt;` - `KeysOf` returns a
        /// `List&lt;string&gt;`, which omni's `IsList` does not recognise.
        /// Numbers are left alone: omni compares long against double already.
        /// </summary>
        public static object ToOmni(object val, object none)
        {
            if (null != none && ReferenceEquals(val, none))
            {
                return Absent.Mark;
            }

            if (val is string || val is bool || Util.IsNum(val) || null == val)
            {
                return val;
            }

            if (val is IDictionary<string, object> map)
            {
                var outmap = new Dictionary<string, object>(map.Count);
                foreach (KeyValuePair<string, object> pair in map)
                {
                    outmap[pair.Key] = ToOmni(pair.Value, none);
                }
                return outmap;
            }

            // Every list shape, not just IList<object>. A non-generic IList
            // covers List<string>, List<List<object>> and the rest.
            if (val is IList list && !(val is string))
            {
                var outlist = new List<object>(list.Count);
                for (int index = 0; index < list.Count; index++)
                {
                    outlist.Add(ToOmni(list[index], none));
                }
                return outlist;
            }

            // A non-generic dictionary (rare, but IDictionary<string,object>
            // does not catch every shape a port might hand back).
            if (val is IDictionary raw)
            {
                var outmap = new Dictionary<string, object>();
                foreach (DictionaryEntry entry in raw)
                {
                    outmap[Convert.ToString(entry.Key, CultureInfo.InvariantCulture)] =
                        ToOmni(entry.Value, none);
                }
                return outmap;
            }

            return val;
        }

        // ------------------------------------------------------------------
        // struct's runner API
        // ------------------------------------------------------------------

        /// <summary>A struct-shaped subject: one argument in, one value out.</summary>
        public delegate object StructSubject(object input);

        /// <summary>
        /// A subject whose single argument is already a map. struct's ports bind
        /// most multi-argument groups this way - the entry's `in` is an object
        /// and the body reads named keys off it - and typing it here keeps those
        /// bodies unchanged across the swap. A separate NAME rather than an
        /// overload: C# cannot pick between two delegate types for an untyped
        /// lambda, so overloading would make every call site ambiguous.
        ///
        /// The concrete `Dictionary`, not `IDictionary`: the ports reach for
        /// `GetValueOrDefault`, which is an extension on `IReadOnlyDictionary`
        /// and so is not visible through the interface. Both conversions above
        /// build a concrete `Dictionary`, so the cast always lands.
        /// </summary>
        public delegate object MapSubject(Dictionary<string, object> input);

        /// <summary>What this shim returns for one named spec section.</summary>
        public sealed class StructRunPack
        {
            private readonly RunPack pack;
            private readonly object none;

            internal StructRunPack(RunPack pack, object client, object none)
            {
                this.pack = pack;
                this.none = none;
                Client = client;
            }

            /// <summary>The resolved spec section.</summary>
            public object Spec => pack.Spec;

            /// <summary>
            /// The SDK this runner was built with. omni's own RunPack carries the
            /// PROVIDER in that slot, which has none of struct's methods, so the
            /// client is handed back instead.
            /// </summary>
            public object Client { get; }

            /// <summary>A named group of the resolved spec.</summary>
            public object Set(string setname) => pack.Set(setname);

            /// <summary>
            /// Run one set of entries. The argument order is struct's, not
            /// omni's - subject then flags - so a port swapping over renames its
            /// calls rather than reordering them.
            /// </summary>
            public void RunSet(object testspec, StructSubject subject, Flags flags = null)
            {
                pack.RunSetFlags(testspec, flags ?? new Flags(), Wrap(subject, none));
            }

            /// <summary>Run one set of entries whose subject takes a map.</summary>
            public void RunSetMap(object testspec, MapSubject subject, Flags flags = null)
            {
                RunSet(testspec, input => subject(input as Dictionary<string, object>), flags);
            }

            /// <summary>
            /// Run one set of entries against the subject the spec itself names,
            /// via the provider. This is the client path: `DEF.subject`, and the
            /// `client` key on an entry.
            /// </summary>
            public void RunSetNamed(object testspec, Flags flags = null)
            {
                pack.RunSetFlags(testspec, flags ?? new Flags(), null);
            }
        }

        /// <summary>
        /// Wrap a struct-shaped subject as an omni one. Arity is preserved: an
        /// entry with no `in` arrives as a single absent argument, which becomes
        /// the port's no-value, so `Typify()` can answer noval where
        /// `Typify(null)` answers null.
        /// </summary>
        public static Subject Wrap(StructSubject subject, object none)
        {
            if (null == subject)
            {
                return null;
            }

            return args =>
            {
                object original = null == args || 0 == args.Length ? Absent.Mark : args[0];
                object input = ToStruct(original, none);

                object result = subject(input);

                // struct's functions MUTATE the node they are given - `setpath`
                // rewrites the store in place - and the corpus checks it through
                // `match.args`. But `ToStruct` built a copy, so the mutation
                // landed on the copy and omni compared the untouched original:
                // "match failed at args.0.store.x expected: 2 actual: 1".
                //
                // Writing it back keeps omni's own object identity, which is
                // what `match` holds a reference to.
                Splice(original, input, none);

                return ToOmni(result, none);
            };
        }

        /// <summary>
        /// Copy a mutated struct-side container back into the omni-side object
        /// it was converted from, in place, so `match.args` sees the mutation.
        /// </summary>
        private static void Splice(object into, object from, object none)
        {
            if (into is IDictionary<string, object> intomap &&
                from is IDictionary<string, object> frommap)
            {
                intomap.Clear();
                foreach (KeyValuePair<string, object> pair in frommap)
                {
                    intomap[pair.Key] = ToOmni(pair.Value, none);
                }
                return;
            }

            if (into is IList<object> intolist && from is IList fromlist)
            {
                intolist.Clear();
                for (int index = 0; index < fromlist.Count; index++)
                {
                    intolist.Add(ToOmni(fromlist[index], none));
                }
            }
        }

        /// <summary>
        /// struct's `makeRunner(testfile, client)`, backed by omni. The path is
        /// resolved relative to the process working directory, exactly as
        /// struct's own runner resolved it.
        /// </summary>
        public static Func<string, object, StructRunPack> MakeRunner(string testfile, object client)
        {
            object none = StructNone(client);
            RunnerPack runner = Runner.MakeRunner(testfile, StructProvider(client, none));

            return (name, store) => new StructRunPack(runner.Run(name, store), client, none);
        }

        /// <summary>
        /// Wrap a struct SDK client as an omni provider. Every hook is optional:
        /// a client that supplies none of them still drives every group whose
        /// entries carry their own subject.
        /// </summary>
        public static Provider StructProvider(object client, object none)
        {
            var provider = new Provider();

            // struct resolves a subject from the utility, or from utility.Struct.
            provider.SubjectFor = name =>
            {
                object utility = Member(client, "Utility");
                object found = Member(utility, name) ?? Member(Member(utility, "Struct"), name);

                if (found is Delegate hook)
                {
                    return args => ToOmni(
                        hook.DynamicInvoke(ToStruct(0 < args.Length ? args[0] : Absent.Mark, none)),
                        none);
                }

                return null;
            };

            // A DEF.client entry becomes another SDK instance. struct's C# SDK
            // spells this `Tester`, matching the other ports' `tester`.
            provider.Client = options =>
            {
                Type type = client?.GetType();
                MethodInfo tester = type?.GetMethod("Tester", PUBLIC);
                if (null == tester)
                {
                    throw new OmniError("structcompat: client has no Tester method");
                }

                object opts = ToStruct(options, none) ?? new Dictionary<string, object>();
                object made = tester.Invoke(client, tester.GetParameters().Length == 0
                    ? null
                    : new[] { opts });

                return StructProvider(made, none);
            };

            // struct's SDK supplies its own context wrapper, and its test files
            // reach `utility` off the context, which omni does not install.
            provider.Contextify = val =>
            {
                object utility = Member(client, "Utility");
                object ctx = val;

                object hook = Member(utility, "Contextify");
                if (hook is Delegate wrap)
                {
                    ctx = wrap.DynamicInvoke(val);
                }

                if (ctx is IDictionary<string, object> ctxmap && null != utility)
                {
                    ctxmap["utility"] = utility;
                }

                return ctx;
            };

            // Client options may reference the runner store.
            provider.Inject = (options, store) =>
            {
                object structutils = Member(Member(client, "Utility"), "Struct");
                object inject = Member(structutils, "Inject");

                if (inject is Delegate hook)
                {
                    return hook.DynamicInvoke(ToStruct(options, none), ToStruct(store, none));
                }

                return options;
            };

            return provider;
        }

        // ------------------------------------------------------------------
        // nullModifier
        // ------------------------------------------------------------------

        /// <summary>
        /// struct's null modifier, in struct's own shape.
        ///
        /// This is NOT a delegation. omni's `NullModifier(val, path)` RETURNS a
        /// replacement; struct's `Modify(val, key, parent, inj, store)` is an
        /// inject hook that MUTATES `parent[key]`. Delegating would quietly do
        /// nothing at all - which is the state struct/csharp is already in, its
        /// `inject/string` group having been bound with no modifier whatsoever.
        ///
        /// The behaviour: a value that IS the null mark becomes a real null, and
        /// a string that merely CONTAINS the mark has it rewritten in place to
        /// the four characters "null".
        /// </summary>
        public static object NullModifier(object val, object key, object parent,
                                          object inj, object store)
        {
            object replacement;

            if (NULLMARK.Equals(val as string))
            {
                replacement = null;
            }
            else if (val is string text && text.Contains(NULLMARK, StringComparison.Ordinal))
            {
                replacement = text.Replace(NULLMARK, "null", StringComparison.Ordinal);
            }
            else
            {
                return val;
            }

            SetChild(parent, key, replacement);
            return replacement;
        }

        /// <summary>Write into a parent node the way struct's `setprop` would.</summary>
        private static void SetChild(object parent, object key, object val)
        {
            if (parent is IDictionary<string, object> map && null != key)
            {
                map[Convert.ToString(key, CultureInfo.InvariantCulture)] = val;
                return;
            }

            if (parent is IList<object> list && null != key)
            {
                if (int.TryParse(Convert.ToString(key, CultureInfo.InvariantCulture),
                                 NumberStyles.Integer, CultureInfo.InvariantCulture, out int index) &&
                    0 <= index && index < list.Count)
                {
                    list[index] = val;
                }
            }
        }
    }
}
