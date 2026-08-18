// Omni internal JSON utilities.
//
// Self-contained by design: the omni runner must be able to test *any*
// library, including libraries that provide these same operations.

import Foundation

public let NULLMARK = "__NULL__"  // Value is JSON null.
public let UNDEFMARK = "__UNDEF__"  // Value is not present.
public let EXISTSMARK = "__EXISTS__"  // Value exists (not undefined).

/// Deep copy a JSON value (the value model already has value semantics).
public func clone(_ val: Json) -> Json {
  return val
}

/// Read a value by path. Returns `.absent` when any step is missing.
public func getpath(_ val: Json, _ path: [String]) -> Json {
  var current = val

  for part in path {
    switch current {
    case .list(let entries):
      guard let index = Int(part), 0 <= index, index < entries.count else {
        return .absent
      }
      current = entries[index]
    case .map(let entries):
      guard let entry = entries[part] else {
        return .absent
      }
      current = entry
    default:
      return .absent
    }
  }

  return current
}

/// Depth-first walk: children first, then the containing node.
public func walk(_ val: Json, _ apply: (Json, [String]) -> Json, _ path: [String] = []) -> Json {
  var next = val

  switch val {
  case .list(let entries):
    var out: [Json] = []
    for (index, entry) in entries.enumerated() {
      out.append(walk(entry, apply, path + [String(index)]))
    }
    next = .list(out)
  case .map(let entries):
    var out: [String: Json] = [:]
    for (key, entry) in entries {
      out[key] = walk(entry, apply, path + [key])
    }
    next = .map(out)
  default:
    break
  }

  return apply(next, path)
}

/// Deep structural equality: numbers by value, bools never numbers.
public func deepequal(_ a: Json, _ b: Json) -> Bool {
  switch (a, b) {
  case (.absent, .absent): return true
  case (.null, .null): return true
  case (.bool(let x), .bool(let y)): return x == y
  case (.num(let x), .num(let y)): return x == y || (x.isNaN && y.isNaN)
  case (.str(let x), .str(let y)): return x == y
  case (.list(let x), .list(let y)):
    if x.count != y.count { return false }
    for index in 0..<x.count where !deepequal(x[index], y[index]) {
      return false
    }
    return true
  case (.map(let x), .map(let y)):
    if x.count != y.count { return false }
    for (key, val) in x {
      guard let other = y[key], deepequal(val, other) else { return false }
    }
    return true
  default:
    return false
  }
}

/// Render a number the same way in every port: 5.0 prints as 5.
public func numstr(_ val: Double) -> String {
  if val.isNaN || val.isInfinite {
    return "null"
  }
  if val == val.rounded(.towardZero) && abs(val) < 9_007_199_254_740_992.0 {
    return String(Int64(val))
  }
  return String(val)
}

/// Render a string as a JSON string literal.
public func quote(_ val: String) -> String {
  var out = "\""

  for ch in val.unicodeScalars {
    switch ch {
    case "\"": out += "\\\""
    case "\\": out += "\\\\"
    case "\n": out += "\\n"
    case "\r": out += "\\r"
    case "\t": out += "\\t"
    default:
      if 0x20 > ch.value {
        out += String(format: "\\u%04x", ch.value)
      } else {
        out.unicodeScalars.append(ch)
      }
    }
  }

  return out + "\""
}

/// Compact JSON text with map keys sorted, identical in every port.
public func jsonstr(_ val: Json) -> String {
  switch val {
  case .absent: return "undefined"
  case .null: return "null"
  case .bool(let flag): return flag ? "true" : "false"
  case .num(let entry): return numstr(entry)
  case .str(let text): return quote(text)
  case .list(let entries): return "[" + entries.map(jsonstr).joined(separator: ",") + "]"
  case .map(let entries):
    let keys = entries.keys.sorted()
    return "{" + keys.map { quote($0) + ":" + jsonstr(entries[$0]!) }.joined(separator: ",") + "}"
  // Never authored in a spec (see Json.provider) - rendered only if a
  // failure message happens to reach into it.
  case .provider: return quote("<provider>")
  }
}

/// Strings verbatim, everything else as compact JSON.
public func stringify(_ val: Json) -> String {
  if case .str(let text) = val {
    return text
  }
  return jsonstr(val)
}

/// Render a path as a dotted string.
public func pathify(_ path: [String]) -> String {
  return path.joined(separator: ".")
}
