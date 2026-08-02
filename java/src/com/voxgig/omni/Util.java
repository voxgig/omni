// Omni internal JSON utilities.
//
// Self-contained by design: the omni runner must be able to test *any*
// library, including libraries that provide these same operations.

package com.voxgig.omni;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

public final class Util {

  public static final String NULLMARK = "__NULL__"; // Value is JSON null.
  public static final String UNDEFMARK = "__UNDEF__"; // Value is not present.
  public static final String EXISTSMARK = "__EXISTS__"; // Value exists.

  private Util() {}

  /** A map (JSON object)? */
  public static boolean ismap(Object val) {
    return val instanceof Map;
  }

  /** A list (JSON array)? */
  public static boolean islist(Object val) {
    return val instanceof List;
  }

  /** A container (map or list)? */
  public static boolean isnode(Object val) {
    return ismap(val) || islist(val);
  }

  /** A JSON number? Booleans are not numbers. */
  public static boolean isnum(Object val) {
    return val instanceof Number;
  }

  /** Absent (no value at all)? */
  public static boolean isabsent(Object val) {
    return val instanceof Json.Absent;
  }

  /** Deep copy a JSON value. Other values pass through by reference. */
  @SuppressWarnings("unchecked")
  public static Object clone(Object val) {
    if (islist(val)) {
      List<Object> out = new ArrayList<>();
      for (Object entry : (List<Object>) val) {
        out.add(clone(entry));
      }
      return out;
    }

    if (ismap(val)) {
      Map<String, Object> out = new LinkedHashMap<>();
      for (Map.Entry<String, Object> entry : ((Map<String, Object>) val).entrySet()) {
        out.put(entry.getKey(), clone(entry.getValue()));
      }
      return out;
    }

    return val;
  }

  /** Read a value by path. Returns ABSENT when any step is missing. */
  @SuppressWarnings("unchecked")
  public static Object getpath(Object val, List<Object> path) {
    Object current = val;

    for (Object part : path) {
      if (islist(current)) {
        List<Object> list = (List<Object>) current;
        int index;
        try {
          index = isnum(part) ? ((Number) part).intValue() : Integer.parseInt(String.valueOf(part));
        } catch (NumberFormatException err) {
          return Json.ABSENT;
        }
        if (index < 0 || index >= list.size()) {
          return Json.ABSENT;
        }
        current = list.get(index);
        continue;
      }

      if (ismap(current)) {
        Map<String, Object> map = (Map<String, Object>) current;
        String key = strkey(part);
        if (!map.containsKey(key)) {
          return Json.ABSENT;
        }
        current = map.get(key);
        continue;
      }

      return Json.ABSENT;
    }

    return current;
  }

  /** Render a path part as a map key. */
  public static String strkey(Object part) {
    if (part instanceof String) {
      return (String) part;
    }
    if (isnum(part)) {
      return numstr(((Number) part).doubleValue());
    }
    return String.valueOf(part);
  }

  /** The callback of a walk. */
  public interface Apply {
    Object apply(Object key, Object val, Object parent, List<Object> path);
  }

  /** Depth-first walk: children first, then the containing node. */
  public static Object walk(Object val, Apply apply) {
    return walkdown(val, apply, null, null, new ArrayList<>());
  }

  @SuppressWarnings("unchecked")
  private static Object walkdown(
      Object val, Apply apply, Object key, Object parent, List<Object> path) {

    if (islist(val)) {
      List<Object> list = (List<Object>) val;
      for (int index = 0; index < list.size(); index++) {
        List<Object> childpath = new ArrayList<>(path);
        childpath.add(index);
        list.set(index, walkdown(list.get(index), apply, index, list, childpath));
      }
    } else if (ismap(val)) {
      Map<String, Object> map = (Map<String, Object>) val;
      for (String childkey : new ArrayList<>(map.keySet())) {
        List<Object> childpath = new ArrayList<>(path);
        childpath.add(childkey);
        map.put(childkey, walkdown(map.get(childkey), apply, childkey, map, childpath));
      }
    }

    return apply.apply(key, val, parent, path);
  }

  /** Deep structural equality: numbers by value, bools never numbers. */
  @SuppressWarnings("unchecked")
  public static boolean deepequal(Object a, Object b) {
    if (a == b) {
      return true;
    }

    if (a instanceof Boolean || b instanceof Boolean) {
      return a instanceof Boolean && b instanceof Boolean && a.equals(b);
    }

    if (isnum(a) || isnum(b)) {
      if (!isnum(a) || !isnum(b)) {
        return false;
      }
      double anum = ((Number) a).doubleValue();
      double bnum = ((Number) b).doubleValue();
      return anum == bnum || (Double.isNaN(anum) && Double.isNaN(bnum));
    }

    if (isabsent(a) || isabsent(b)) {
      return isabsent(a) && isabsent(b);
    }

    if (null == a || null == b) {
      return null == a && null == b;
    }

    if (islist(a) || islist(b)) {
      if (!islist(a) || !islist(b)) {
        return false;
      }
      List<Object> alist = (List<Object>) a;
      List<Object> blist = (List<Object>) b;
      if (alist.size() != blist.size()) {
        return false;
      }
      for (int index = 0; index < alist.size(); index++) {
        if (!deepequal(alist.get(index), blist.get(index))) {
          return false;
        }
      }
      return true;
    }

    if (ismap(a) || ismap(b)) {
      if (!ismap(a) || !ismap(b)) {
        return false;
      }
      Map<String, Object> amap = (Map<String, Object>) a;
      Map<String, Object> bmap = (Map<String, Object>) b;
      if (amap.size() != bmap.size()) {
        return false;
      }
      for (Map.Entry<String, Object> entry : amap.entrySet()) {
        if (!bmap.containsKey(entry.getKey())) {
          return false;
        }
        if (!deepequal(entry.getValue(), bmap.get(entry.getKey()))) {
          return false;
        }
      }
      return true;
    }

    return a.equals(b);
  }

  /** Render a number the same way in every port: 5.0 prints as 5. */
  public static String numstr(double val) {
    if (Double.isNaN(val) || Double.isInfinite(val)) {
      return "null";
    }
    if (val == Math.rint(val) && Math.abs(val) < 9007199254740992.0) {
      return Long.toString((long) val);
    }
    String out = Double.toString(val);
    return out;
  }

  /** Render a string as a JSON string literal. */
  public static String quote(String val) {
    StringBuilder out = new StringBuilder("\"");
    for (int index = 0; index < val.length(); index++) {
      char c = val.charAt(index);
      switch (c) {
        case '"':
          out.append("\\\"");
          break;
        case '\\':
          out.append("\\\\");
          break;
        case '\n':
          out.append("\\n");
          break;
        case '\r':
          out.append("\\r");
          break;
        case '\t':
          out.append("\\t");
          break;
        default:
          if (c < 0x20) {
            out.append(String.format("\\u%04x", (int) c));
          } else {
            out.append(c);
          }
      }
    }
    return out.append('"').toString();
  }

  /** Compact JSON text with map keys sorted, identical in every port. */
  @SuppressWarnings("unchecked")
  public static String jsonstr(Object val) {
    if (isabsent(val)) {
      return "undefined";
    }

    if (null == val) {
      return "null";
    }

    if (val instanceof Boolean) {
      return ((Boolean) val) ? "true" : "false";
    }

    if (val instanceof String) {
      return quote((String) val);
    }

    if (isnum(val)) {
      return numstr(((Number) val).doubleValue());
    }

    if (islist(val)) {
      List<String> parts = new ArrayList<>();
      for (Object entry : (List<Object>) val) {
        parts.add(jsonstr(entry));
      }
      return "[" + String.join(",", parts) + "]";
    }

    if (ismap(val)) {
      Map<String, Object> sorted = new TreeMap<>((Map<String, Object>) val);
      List<String> parts = new ArrayList<>();
      for (Map.Entry<String, Object> entry : sorted.entrySet()) {
        parts.add(quote(entry.getKey()) + ":" + jsonstr(entry.getValue()));
      }
      return "{" + String.join(",", parts) + "}";
    }

    return quote(String.valueOf(val));
  }

  /** Strings verbatim, everything else as compact JSON. */
  public static String stringify(Object val) {
    return val instanceof String ? (String) val : jsonstr(val);
  }

  /** Render a path as a dotted string. */
  public static String pathify(List<Object> path) {
    List<String> parts = new ArrayList<>();
    for (Object entry : (null == path ? Arrays.asList() : path)) {
      parts.add(strkey(entry));
    }
    return String.join(".", parts);
  }
}
