// Omni internal JSON utilities.
//
// Self-contained by design: the omni runner must be able to test *any*
// library, including libraries that provide these same operations.

const String NULLMARK = '__NULL__'; // Value is JSON null.
const String UNDEFMARK = '__UNDEF__'; // Value is not present.
const String EXISTSMARK = '__EXISTS__'; // Value exists (not undefined).

/// Absence, as distinct from a JSON null. Dart has only `null`.
class Absent {
  const Absent._();

  static const Absent mark = Absent._();

  @override
  String toString() => 'ABSENT';
}

const Absent ABSENT = Absent.mark;

/// A map (JSON object)?
bool ismap(dynamic val) => val is Map;

/// A list (JSON array)?
bool islist(dynamic val) => val is List;

/// A container (map or list)?
bool isnode(dynamic val) => ismap(val) || islist(val);

/// Absent (no value at all)?
bool isabsent(dynamic val) => val is Absent;

/// A JSON number? Booleans are not numbers.
bool isnum(dynamic val) => val is num && val is! bool;

/// Deep copy a JSON value.
dynamic clone(dynamic val) {
  if (val is List) {
    return val.map<dynamic>(clone).toList();
  }

  if (val is Map) {
    final out = <String, dynamic>{};
    val.forEach((key, subval) => out['$key'] = clone(subval));
    return out;
  }

  return val;
}

/// Read a value by path. Returns ABSENT when any step is missing.
dynamic getpath(dynamic val, List<String> path) {
  dynamic current = val;

  for (final part in path) {
    if (current is List) {
      final index = int.tryParse(part);
      if (null == index || 0 > index || index >= current.length) {
        return ABSENT;
      }
      current = current[index];
      continue;
    }

    if (current is Map) {
      if (!current.containsKey(part)) {
        return ABSENT;
      }
      current = current[part];
      continue;
    }

    return ABSENT;
  }

  return current;
}

/// Depth-first walk: children first, then the containing node.
dynamic walk(dynamic val, dynamic Function(dynamic, List<String>) apply,
    [List<String> path = const []]) {
  if (val is List) {
    for (var index = 0; index < val.length; index++) {
      val[index] = walk(val[index], apply, [...path, '$index']);
    }
  } else if (val is Map) {
    for (final key in val.keys.toList()) {
      val[key] = walk(val[key], apply, [...path, '$key']);
    }
  }

  return apply(val, path);
}

/// Deep structural equality: numbers by value, bools never numbers.
bool deepequal(dynamic a, dynamic b) {
  if (identical(a, b)) {
    return true;
  }

  if (a is bool || b is bool) {
    return a is bool && b is bool && a == b;
  }

  if (isnum(a) || isnum(b)) {
    if (!isnum(a) || !isnum(b)) {
      return false;
    }
    final anum = (a as num).toDouble();
    final bnum = (b as num).toDouble();
    return anum == bnum || (anum.isNaN && bnum.isNaN);
  }

  if (isabsent(a) || isabsent(b)) {
    return isabsent(a) && isabsent(b);
  }

  if (null == a || null == b) {
    return null == a && null == b;
  }

  if (a is List || b is List) {
    if (a is! List || b is! List || a.length != b.length) {
      return false;
    }
    for (var index = 0; index < a.length; index++) {
      if (!deepequal(a[index], b[index])) {
        return false;
      }
    }
    return true;
  }

  if (a is Map || b is Map) {
    if (a is! Map || b is! Map || a.length != b.length) {
      return false;
    }
    for (final key in a.keys) {
      if (!b.containsKey(key) || !deepequal(a[key], b[key])) {
        return false;
      }
    }
    return true;
  }

  return a == b;
}

/// Render a number the same way in every port: 5.0 prints as 5.
String numstr(num val) {
  final asdouble = val.toDouble();

  if (asdouble.isNaN || asdouble.isInfinite) {
    return 'null';
  }

  if (asdouble == asdouble.truncateToDouble() && asdouble.abs() < 9007199254740992.0) {
    return asdouble.toInt().toString();
  }

  return asdouble.toString();
}

/// Render a string as a JSON string literal.
String quote(String val) {
  final out = StringBuffer('"');

  for (final ch in val.runes) {
    if (0x22 == ch) {
      out.write('\\"');
    } else if (0x5C == ch) {
      out.write('\\\\');
    } else if (0x0A == ch) {
      out.write('\\n');
    } else if (0x0D == ch) {
      out.write('\\r');
    } else if (0x09 == ch) {
      out.write('\\t');
    } else if (0x20 > ch) {
      out.write('\\u${ch.toRadixString(16).padLeft(4, '0')}');
    } else {
      out.writeCharCode(ch);
    }
  }

  out.write('"');
  return out.toString();
}

/// Compact JSON text with map keys sorted, identical in every port.
String jsonstr(dynamic val) {
  if (isabsent(val)) {
    return 'undefined';
  }

  if (null == val) {
    return 'null';
  }

  if (val is bool) {
    return val ? 'true' : 'false';
  }

  if (val is String) {
    return quote(val);
  }

  if (isnum(val)) {
    return numstr(val as num);
  }

  if (val is List) {
    return '[${val.map<String>(jsonstr).join(',')}]';
  }

  if (val is Map) {
    final keys = val.keys.map((key) => '$key').toList()..sort();
    return '{${keys.map((key) => '${quote(key)}:${jsonstr(val[key])}').join(',')}}';
  }

  return quote('$val');
}

/// Strings verbatim, everything else as compact JSON.
String stringify(dynamic val) => val is String ? val : jsonstr(val);

/// Render a path as a dotted string.
String pathify(List<String> path) => path.join('.');
