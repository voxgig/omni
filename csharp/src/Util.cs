// Omni internal JSON utilities.
//
// Self-contained by design: the omni runner must be able to test *any*
// library, including libraries that provide these same operations.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace Voxgig.Omni
{
    /// <summary>Absence, as distinct from a JSON null.</summary>
    public sealed class Absent
    {
        public static readonly Absent Mark = new Absent();

        private Absent() { }

        public override string ToString() => "ABSENT";
    }

    public static class Util
    {
        public const string NULLMARK = "__NULL__";     // Value is JSON null.
        public const string UNDEFMARK = "__UNDEF__";   // Value is not present.
        public const string EXISTSMARK = "__EXISTS__"; // Value exists.

        /// <summary>A map (JSON object)?</summary>
        public static bool IsMap(object val) => val is IDictionary<string, object>;

        /// <summary>A list (JSON array)?</summary>
        public static bool IsList(object val) => val is IList<object>;

        /// <summary>A container (map or list)?</summary>
        public static bool IsNode(object val) => IsMap(val) || IsList(val);

        /// <summary>Absent (no value at all)?</summary>
        public static bool IsAbsent(object val) => val is Absent;

        /// <summary>A JSON number? Booleans are not numbers.</summary>
        public static bool IsNum(object val) =>
            val is double || val is float || val is int || val is long || val is short ||
            val is byte || val is decimal || val is uint || val is ulong;

        public static double ToNum(object val) => Convert.ToDouble(val, CultureInfo.InvariantCulture);

        /// <summary>Deep copy a JSON value.</summary>
        public static object Clone(object val)
        {
            if (val is IList<object> list)
            {
                var outlist = new List<object>();
                foreach (var entry in list)
                {
                    outlist.Add(Clone(entry));
                }
                return outlist;
            }

            if (val is IDictionary<string, object> map)
            {
                var outmap = new Dictionary<string, object>();
                foreach (var entry in map)
                {
                    outmap[entry.Key] = Clone(entry.Value);
                }
                return outmap;
            }

            return val;
        }

        /// <summary>Read a value by path. Returns Absent when a step is missing.</summary>
        public static object GetPath(object val, IList<string> path)
        {
            object current = val;

            foreach (var part in path)
            {
                if (current is IList<object> list)
                {
                    if (!int.TryParse(part, NumberStyles.Integer, CultureInfo.InvariantCulture, out int index) ||
                        0 > index || index >= list.Count)
                    {
                        return Absent.Mark;
                    }
                    current = list[index];
                    continue;
                }

                if (current is IDictionary<string, object> map)
                {
                    if (!map.ContainsKey(part))
                    {
                        return Absent.Mark;
                    }
                    current = map[part];
                    continue;
                }

                return Absent.Mark;
            }

            return current;
        }

        /// <summary>Depth-first walk: children first, then the containing node.</summary>
        public static object Walk(object val, Func<object, IList<string>, object> apply)
        {
            return WalkDown(val, apply, new List<string>());
        }

        private static object WalkDown(object val, Func<object, IList<string>, object> apply, List<string> path)
        {
            if (val is IList<object> list)
            {
                for (int index = 0; index < list.Count; index++)
                {
                    var childpath = new List<string>(path) { index.ToString(CultureInfo.InvariantCulture) };
                    list[index] = WalkDown(list[index], apply, childpath);
                }
            }
            else if (val is IDictionary<string, object> map)
            {
                foreach (var key in map.Keys.ToList())
                {
                    var childpath = new List<string>(path) { key };
                    map[key] = WalkDown(map[key], apply, childpath);
                }
            }

            return apply(val, path);
        }

        /// <summary>Deep structural equality: numbers by value, bools never numbers.</summary>
        public static bool DeepEqual(object a, object b)
        {
            if (ReferenceEquals(a, b))
            {
                return true;
            }

            if (a is bool || b is bool)
            {
                return a is bool aflag && b is bool bflag && aflag == bflag;
            }

            if (IsNum(a) || IsNum(b))
            {
                if (!IsNum(a) || !IsNum(b))
                {
                    return false;
                }
                double anum = ToNum(a);
                double bnum = ToNum(b);
                return anum == bnum || (double.IsNaN(anum) && double.IsNaN(bnum));
            }

            if (IsAbsent(a) || IsAbsent(b))
            {
                return IsAbsent(a) && IsAbsent(b);
            }

            if (null == a || null == b)
            {
                return null == a && null == b;
            }

            if (a is IList<object> || b is IList<object>)
            {
                if (!(a is IList<object> alist) || !(b is IList<object> blist) || alist.Count != blist.Count)
                {
                    return false;
                }
                for (int index = 0; index < alist.Count; index++)
                {
                    if (!DeepEqual(alist[index], blist[index]))
                    {
                        return false;
                    }
                }
                return true;
            }

            if (a is IDictionary<string, object> || b is IDictionary<string, object>)
            {
                if (!(a is IDictionary<string, object> amap) ||
                    !(b is IDictionary<string, object> bmap) ||
                    amap.Count != bmap.Count)
                {
                    return false;
                }
                foreach (var entry in amap)
                {
                    if (!bmap.ContainsKey(entry.Key) || !DeepEqual(entry.Value, bmap[entry.Key]))
                    {
                        return false;
                    }
                }
                return true;
            }

            return a.Equals(b);
        }

        /// <summary>Render a number the same way in every port: 5.0 prints as 5.</summary>
        public static string NumStr(double val)
        {
            if (double.IsNaN(val) || double.IsInfinity(val))
            {
                return "null";
            }
            if (val == Math.Truncate(val) && Math.Abs(val) < 9007199254740992.0)
            {
                return ((long)val).ToString(CultureInfo.InvariantCulture);
            }
            return val.ToString("R", CultureInfo.InvariantCulture);
        }

        /// <summary>Render a string as a JSON string literal.</summary>
        public static string Quote(string val)
        {
            var out_ = new StringBuilder("\"");

            foreach (char ch in val)
            {
                switch (ch)
                {
                    case '"': out_.Append("\\\""); break;
                    case '\\': out_.Append("\\\\"); break;
                    case '\n': out_.Append("\\n"); break;
                    case '\r': out_.Append("\\r"); break;
                    case '\t': out_.Append("\\t"); break;
                    default:
                        if (0x20 > ch)
                        {
                            out_.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            out_.Append(ch);
                        }
                        break;
                }
            }

            return out_.Append('"').ToString();
        }

        /// <summary>Compact JSON text with map keys sorted, identical in every port.</summary>
        public static string JsonStr(object val)
        {
            if (IsAbsent(val))
            {
                return "undefined";
            }

            if (null == val)
            {
                return "null";
            }

            if (val is bool flag)
            {
                return flag ? "true" : "false";
            }

            if (val is string text)
            {
                return Quote(text);
            }

            if (IsNum(val))
            {
                return NumStr(ToNum(val));
            }

            if (val is IList<object> list)
            {
                return "[" + string.Join(",", list.Select(JsonStr)) + "]";
            }

            if (val is IDictionary<string, object> map)
            {
                var keys = map.Keys.ToList();
                keys.Sort(StringComparer.Ordinal);
                return "{" + string.Join(",", keys.Select(key => Quote(key) + ":" + JsonStr(map[key]))) + "}";
            }

            return Quote(val.ToString());
        }

        /// <summary>Strings verbatim, everything else as compact JSON.</summary>
        public static string Stringify(object val) => val is string text ? text : JsonStr(val);

        /// <summary>Render a path as a dotted string.</summary>
        public static string PathIfy(IList<string> path) => string.Join(".", path ?? new List<string>());

        /// <summary>Parse JSON text into the omni value model.</summary>
        public static object Parse(string text)
        {
            using var doc = JsonDocument.Parse(text);
            return FromElement(doc.RootElement);
        }

        private static object FromElement(JsonElement element)
        {
            switch (element.ValueKind)
            {
                case JsonValueKind.Object:
                    {
                        var map = new Dictionary<string, object>();
                        foreach (var field in element.EnumerateObject())
                        {
                            map[field.Name] = FromElement(field.Value);
                        }
                        return map;
                    }
                case JsonValueKind.Array:
                    {
                        var list = new List<object>();
                        foreach (var entry in element.EnumerateArray())
                        {
                            list.Add(FromElement(entry));
                        }
                        return list;
                    }
                case JsonValueKind.String:
                    return element.GetString();
                case JsonValueKind.Number:
                    return element.GetDouble();
                case JsonValueKind.True:
                    return true;
                case JsonValueKind.False:
                    return false;
                default:
                    return null;
            }
        }
    }
}
