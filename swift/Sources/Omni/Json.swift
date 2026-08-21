// The omni JSON value model, with a small in-tree parser.
//
// The omni runner must be able to test *any* library, and must add no
// third-party dependencies, so it carries its own JSON support. A hand
// written model also keeps booleans and numbers distinct, which the
// Foundation JSON bridge does not guarantee on every platform.

import Foundation

/// A JSON value. `absent` is the marker for "no value at all", as
/// distinct from `null`.
public indirect enum Json {
  case absent
  case null
  case bool(Bool)
  case num(Double)
  case str(String)
  case list([Json])
  // An INSERTION-ORDERED association list, not a Swift Dictionary. JSON
  // objects are unordered by the letter of the spec, but a runner is a
  // measuring instrument: a consumer whose own maps are ordered (and every
  // struct port's are) reads back `keysof`, `items`, `stringify` and walk
  // order from the order the spec author wrote. A Dictionary silently
  // reshuffles them, and the failure looks like a library bug rather than a
  // runner one. omni-haskell and omni-ocaml carry the same association list;
  // omni-scala a ListMap; omni-clojure an array-map.
  case map([(String, Json)])
  // A live Provider reference, attached to a contextified map argument by
  // the runner (see RunPack.resolveargs) so a subject can reach the
  // client that owns it - the Swift analogue of canonical's
  // `first.client = testpack.client`. The JSON parser never produces this
  // case: it exists only for values the runner injects at call time, and
  // is never part of a spec file.
  case provider(Provider)

  public var ismap: Bool {
    if case .map = self { return true }
    return false
  }

  public var islist: Bool {
    if case .list = self { return true }
    return false
  }

  public var isnode: Bool { return ismap || islist }

  public var isabsent: Bool {
    if case .absent = self { return true }
    return false
  }

  public var isnull: Bool {
    if case .null = self { return true }
    return false
  }

  public var isnone: Bool { return isabsent || isnull }

  public var isnum: Bool {
    if case .num = self { return true }
    return false
  }

  public var isstr: Bool {
    if case .str = self { return true }
    return false
  }

  public var isbool: Bool {
    if case .bool = self { return true }
    return false
  }

  public var asnum: Double? {
    if case .num(let val) = self { return val }
    return nil
  }

  public var asstr: String? {
    if case .str(let val) = self { return val }
    return nil
  }

  public var asmap: [(String, Json)]? {
    if case .map(let val) = self { return val }
    return nil
  }

  /// The attached Provider, for a value set by `resolveargs`. `nil` for
  /// every value a spec can actually author.
  public var asprovider: Provider? {
    if case .provider(let val) = self { return val }
    return nil
  }

  public var aslist: [Json]? {
    if case .list(let val) = self { return val }
    return nil
  }

  /// Read a map entry. Returns `.absent` when missing.
  public func get(_ key: String) -> Json {
    if case .map(let val) = self {
      for (entrykey, entry) in val where entrykey == key {
        return entry
      }
    }
    return .absent
  }

  /// Is a map key present at all (even with a null value)?
  public func has(_ key: String) -> Bool {
    if case .map(let val) = self {
      return val.contains { $0.0 == key }
    }
    return false
  }

  /// Set a map entry (no-op for non-maps). Re-assigning an existing key
  /// keeps its POSITION, the way every port's ordered map behaves.
  public mutating func set(_ key: String, _ val: Json) {
    if case .map(var entries) = self {
      if let at = entries.firstIndex(where: { $0.0 == key }) {
        entries[at] = (key, val)
      } else {
        entries.append((key, val))
      }
      self = .map(entries)
    }
  }

  public static func mapOf(_ entries: [(String, Json)]) -> Json {
    var out: [(String, Json)] = []
    for (key, val) in entries {
      if let at = out.firstIndex(where: { $0.0 == key }) {
        out[at] = (key, val)
      } else {
        out.append((key, val))
      }
    }
    return .map(out)
  }

  // ---- parsing ----

  public static func parse(_ text: String) throws -> Json {
    var chars = Array(text)
    var pos = 0

    skipws(chars, &pos)
    let val = try parseval(&chars, &pos)
    skipws(chars, &pos)

    if pos < chars.count {
      throw OmniError("omni: trailing JSON content at \(pos)")
    }

    return val
  }

  public static func parsefile(_ path: String) throws -> Json {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      throw OmniError("omni: cannot read spec: \(path)")
    }
    return try parse(text)
  }

  private static func skipws(_ chars: [Character], _ pos: inout Int) {
    while pos < chars.count {
      let ch = chars[pos]
      if " " == ch || "\t" == ch || "\n" == ch || "\r" == ch {
        pos += 1
      } else {
        break
      }
    }
  }

  private static func parseval(_ chars: inout [Character], _ pos: inout Int) throws -> Json {
    guard pos < chars.count else {
      throw OmniError("omni: unexpected end of JSON")
    }

    switch chars[pos] {
    case "{": return try parsemap(&chars, &pos)
    case "[": return try parselist(&chars, &pos)
    case "\"": return .str(try parsestr(&chars, &pos))
    case "t":
      try parseword(chars, &pos, "true")
      return .bool(true)
    case "f":
      try parseword(chars, &pos, "false")
      return .bool(false)
    case "n":
      try parseword(chars, &pos, "null")
      return .null
    default: return try parsenum(chars, &pos)
    }
  }

  private static func parseword(_ chars: [Character], _ pos: inout Int, _ word: String) throws {
    for expect in word {
      guard pos < chars.count, chars[pos] == expect else {
        throw OmniError("omni: bad JSON literal at \(pos)")
      }
      pos += 1
    }
  }

  private static func parsemap(_ chars: inout [Character], _ pos: inout Int) throws -> Json {
    var out: [(String, Json)] = []
    pos += 1  // {

    skipws(chars, &pos)
    if pos < chars.count, "}" == chars[pos] {
      pos += 1
      return .map(out)
    }

    while true {
      skipws(chars, &pos)
      let key = try parsestr(&chars, &pos)
      skipws(chars, &pos)

      guard pos < chars.count, ":" == chars[pos] else {
        throw OmniError("omni: expected ':' at \(pos)")
      }
      pos += 1

      skipws(chars, &pos)
      let entry = try parseval(&chars, &pos)
      if let at = out.firstIndex(where: { $0.0 == key }) {
        out[at] = (key, entry)
      } else {
        out.append((key, entry))
      }
      skipws(chars, &pos)

      guard pos < chars.count else {
        throw OmniError("omni: unterminated JSON object")
      }
      if "," == chars[pos] {
        pos += 1
        continue
      }
      if "}" == chars[pos] {
        pos += 1
        return .map(out)
      }
      throw OmniError("omni: expected ',' or '}' at \(pos)")
    }
  }

  private static func parselist(_ chars: inout [Character], _ pos: inout Int) throws -> Json {
    var out: [Json] = []
    pos += 1  // [

    skipws(chars, &pos)
    if pos < chars.count, "]" == chars[pos] {
      pos += 1
      return .list(out)
    }

    while true {
      skipws(chars, &pos)
      out.append(try parseval(&chars, &pos))
      skipws(chars, &pos)

      guard pos < chars.count else {
        throw OmniError("omni: unterminated JSON array")
      }
      if "," == chars[pos] {
        pos += 1
        continue
      }
      if "]" == chars[pos] {
        pos += 1
        return .list(out)
      }
      throw OmniError("omni: expected ',' or ']' at \(pos)")
    }
  }

  private static func parsestr(_ chars: inout [Character], _ pos: inout Int) throws -> String {
    guard pos < chars.count, "\"" == chars[pos] else {
      throw OmniError("omni: expected string at \(pos)")
    }
    pos += 1

    var out = ""

    while pos < chars.count {
      let ch = chars[pos]
      pos += 1

      if "\"" == ch {
        return out
      }

      if "\\" != ch {
        out.append(ch)
        continue
      }

      guard pos < chars.count else { break }

      let escape = chars[pos]
      pos += 1

      switch escape {
      case "\"": out.append("\"")
      case "\\": out.append("\\")
      case "/": out.append("/")
      case "b": out.append("\u{8}")
      case "f": out.append("\u{c}")
      case "n": out.append("\n")
      case "r": out.append("\r")
      case "t": out.append("\t")
      case "u":
        guard pos + 4 <= chars.count else {
          throw OmniError("omni: bad JSON unicode escape")
        }
        let hex = String(chars[pos..<(pos + 4)])
        pos += 4
        guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
          throw OmniError("omni: bad JSON unicode escape")
        }
        out.append(Character(scalar))
      default:
        throw OmniError("omni: bad JSON escape at \(pos)")
      }
    }

    throw OmniError("omni: unterminated JSON string")
  }

  private static func parsenum(_ chars: [Character], _ pos: inout Int) throws -> Json {
    let start = pos

    if pos < chars.count, "-" == chars[pos] || "+" == chars[pos] {
      pos += 1
    }

    while pos < chars.count {
      let ch = chars[pos]
      if ch.isNumber || "." == ch || "e" == ch || "E" == ch || "-" == ch || "+" == ch {
        pos += 1
      } else {
        break
      }
    }

    let span = String(chars[start..<pos])
    guard let val = Double(span) else {
      throw OmniError("omni: bad JSON number [\(span)] at \(start)")
    }

    return .num(val)
  }
}
