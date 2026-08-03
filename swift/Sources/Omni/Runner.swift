// Omni: the shared multi-language test runner (Swift port).
//
// Port of the canonical TypeScript implementation
// (typescript/src/Runner.ts). Behaviour must match, case for case.

import Foundation

/// The function under test. Arguments arrive as JSON values; failure is
/// reported by throwing.
public typealias Subject = ([Json]) throws -> Json

/// A test failure (or a malformed spec). Distinct from an error thrown by
/// the subject under test, which is a candidate for an `err` expectation.
public struct OmniError: Error, CustomStringConvertible {
  public let message: String
  public let entry: Json

  public init(_ message: String, _ entry: Json = .absent) {
    self.message = message
    self.entry = entry
  }

  public var description: String { return message }
}

/// Run-time options for a set of test entries.
public struct Flags {
  public var null: Bool
  public var name: String?

  public init(null: Bool = true, name: String? = nil) {
    self.null = null
    self.name = name
  }

  public static func nonull() -> Flags { return Flags(null: false) }
}

/// The host of the system under test. Every hook is optional.
public final class Provider {
  public var subject: ((String) -> Subject?)?
  public var client: ((Json) -> Provider)?
  public var contextify: ((Json) -> Json)?
  public var inject: ((Json, Json) -> Json)?

  public init(
    subject: ((String) -> Subject?)? = nil,
    client: ((Json) -> Provider)? = nil,
    contextify: ((Json) -> Json)? = nil,
    inject: ((Json, Json) -> Json)? = nil
  ) {
    self.subject = subject
    self.client = client
    self.contextify = contextify
    self.inject = inject
  }
}

/// Load a spec: a path to a JSON file.
public func loadspec(_ path: String) throws -> Json {
  return try Json.parsefile(path)
}

/// Find `primary.<name>`, then `<name>`, then the whole spec.
public func resolvespec(_ name: String, _ alltests: Json) -> Json {
  if name.isEmpty {
    return alltests
  }

  let primary = alltests.get("primary").get(name)
  if !primary.isabsent {
    return primary
  }

  let section = alltests.get(name)
  if !section.isabsent {
    return section
  }

  return alltests
}

/// Nulls (and absent values) become NULLMARK. Always a fresh copy.
public func fixjson(_ val: Json, _ donull: Bool) -> Json {
  if val.isnone {
    return donull ? .str(NULLMARK) : .null
  }

  if case .list(let entries) = val {
    return .list(entries.map { fixjson($0, donull) })
  }

  if case .map(let entries) = val {
    var out: [String: Json] = [:]
    for (key, entry) in entries {
      out[key] = fixjson(entry, donull)
    }
    return .map(out)
  }

  return val
}

/// The JSON form of an error: always at least {name,message}.
public func errify(_ message: String) -> Json {
  return Json.mapOf([("name", .str("Error")), ("message", .str(message))])
}

/// The message an `err` expectation matches.
public func errmessage(_ err: Error) -> String {
  if let omnierr = err as? OmniError {
    return omnierr.message
  }
  return "\(err)"
}

/// Match one leaf: /regex/ or case-insensitive substring for strings.
public func matchval(_ check: Json, _ base: Json) -> Bool {
  if deepequal(check, base) {
    return true
  }

  var want = check
  if let text = want.asstr, UNDEFMARK == text || NULLMARK == text {
    want = .null
  }

  if want.isnone {
    return base.isnone || NULLMARK == base.asstr
  }

  if let text = want.asstr {
    let basestr = stringify(base)

    if 2 < text.count, text.hasPrefix("/"), text.hasSuffix("/") {
      let pattern = String(text.dropFirst().dropLast())
      guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return false
      }
      let range = NSRange(basestr.startIndex..., in: basestr)
      return nil != regex.firstMatch(in: basestr, range: range)
    }

    return basestr.lowercased().contains(text.lowercased())
  }

  return deepequal(want, base)
}

/// Convert NULLMARK sentinels back into real nulls.
public func nullmodifier(_ val: Json) -> Json {
  guard let text = val.asstr else {
    return val
  }
  if NULLMARK == text {
    return .null
  }
  return .str(text.replacingOccurrences(of: NULLMARK, with: "null"))
}

/// What a runner returns for one named spec section.
public final class RunPack {
  public let spec: Json
  public let subject: Subject?
  public let client: Provider

  private let provider: Provider
  private let clients: [String: Provider]
  private let name: String

  init(spec: Json, subject: Subject?, provider: Provider, clients: [String: Provider], name: String) {
    self.spec = spec
    self.subject = subject
    self.client = provider
    self.provider = provider
    self.clients = clients
    self.name = name
  }

  /// A named group of the resolved spec.
  public func set(_ setname: String) -> Json {
    return spec.get(setname)
  }

  /// Run one set of test entries.
  public func runset(_ testspec: Json, _ testsubject: Subject? = nil) throws {
    try runsetflags(testspec, Flags(), testsubject)
  }

  /// Run one set of test entries with flags.
  public func runsetflags(_ testspec: Json, _ flags: Flags, _ testsubject: Subject? = nil) throws {
    var useflags = flags
    if nil == useflags.name {
      useflags.name = name.isEmpty ? "set" : name
    }
    let label = useflags.name ?? "set"

    guard let usesubject = testsubject ?? subject else {
      throw OmniError("omni: no test subject for: \(label)")
    }

    let testspecmap = fixjson(testspec, useflags.null)
    guard let testset = testspecmap.get("set").aslist else {
      throw OmniError("omni: test spec has no set: \(label)")
    }

    for (index, rawentry) in testset.enumerated() {
      var entry = rawentry

      guard entry.ismap else {
        throw OmniError("omni: \(label)[\(index)]: entry is not a map")
      }

      // An entry with no `out` expects a null (or absent) result.
      if useflags.null && entry.get("out").isnone {
        entry.set("out", .str(NULLMARK))
      }

      var entrysubject = usesubject
      var entryclient = provider

      if let clientname = entry.get("client").asstr {
        guard let found = clients[clientname] else {
          throw OmniError("omni: unknown client: \(clientname)", entry)
        }
        entryclient = found
        if let clientsubject = found.subject?(name) {
          entrysubject = clientsubject
        }
      }

      let args = resolveargs(&entry, entryclient)

      var res: Json
      do {
        res = try entrysubject(args)
      } catch let omnierr as OmniError {
        throw omnierr
      } catch {
        try handleerror(useflags, index, entry, errmessage(error))
        continue
      }

      res = fixjson(res, useflags.null)
      entry.set("res", res)

      try checkresult(useflags, index, entry, args, res)
    }
  }

  // Build the argument list: `ctx`, `args`, or `in`.
  private func resolveargs(_ entry: inout Json, _ client: Provider) -> [Json] {
    var args: [Json]

    let hasctx = entry.has("ctx")
    let hasargs = entry.has("args")

    if hasctx {
      args = [entry.get("ctx")]
    } else if hasargs {
      args = entry.get("args").aslist ?? [entry.get("args")]
    } else {
      args = [entry.get("in")]
    }

    if (hasctx || hasargs) && !args.isEmpty && args[0].ismap {
      var first = args[0]
      if let contextify = provider.contextify {
        first = contextify(first)
      }
      args[0] = first
      entry.set("ctx", first)
    }

    return args
  }

  private func checkresult(_ flags: Flags, _ index: Int, _ entry: Json, _ args: [Json], _ res: Json)
    throws
  {
    var matched = false

    let entryerr = entry.get("err")
    if !entryerr.isnone {
      throw fail(
        flags, index, entry, "expected error did not occur", stringify(entryerr), stringify(res))
    }

    let check = entry.get("match")
    if !check.isnone {
      let base = Json.mapOf([
        ("in", entry.get("in")),
        ("args", .list(args)),
        ("out", entry.get("res")),
        ("ctx", entry.get("ctx")),
      ])
      try matchcheck(flags, index, entry, check, base)
      matched = true
    }

    let out = entry.get("out")

    if deepequal(res, out) {
      return
    }

    // NOTE: a match with no explicit out is a complete check on its own.
    if matched && (out.isnone || NULLMARK == out.asstr) {
      return
    }

    throw fail(flags, index, entry, "result mismatch", stringify(out), stringify(res))
  }

  private func handleerror(_ flags: Flags, _ index: Int, _ entry: Json, _ message: String) throws {
    let entryerr = entry.get("err")

    if !entryerr.isnone {
      var istrue = false
      if case .bool(true) = entryerr {
        istrue = true
      }

      if istrue || matchval(entryerr, .str(message)) {
        let check = entry.get("match")
        if !check.isnone {
          let base = Json.mapOf([
            ("in", entry.get("in")),
            ("out", entry.get("res")),
            ("ctx", entry.get("ctx")),
            ("err", errify(message)),
          ])
          try matchcheck(flags, index, entry, check, base)
        }
        return
      }

      throw fail(flags, index, entry, "error mismatch", stringify(entryerr), message)
    }

    throw fail(flags, index, entry, "unexpected error", nil, message)
  }

  // Check that every leaf of `check` is present, and matches, in `base`.
  private func matchcheck(
    _ flags: Flags, _ index: Int, _ entry: Json, _ check: Json, _ base: Json,
    _ path: [String] = []
  ) throws {
    if case .list(let entries) = check {
      for (at, subcheck) in entries.enumerated() {
        try matchcheck(flags, index, entry, subcheck, base, path + [String(at)])
      }
      return
    }

    if case .map(let entries) = check {
      for (key, subcheck) in entries {
        try matchcheck(flags, index, entry, subcheck, base, path + [key])
      }
      return
    }

    let baseval = getpath(base, path)

    if deepequal(check, baseval) {
      return
    }

    // Explicitly absent.
    if UNDEFMARK == check.asstr && baseval.isabsent {
      return
    }

    // Explicitly present.
    if EXISTSMARK == check.asstr && !baseval.isnone {
      return
    }

    if matchval(check, baseval) {
      return
    }

    let where_ = path.isEmpty ? "<root>" : pathify(path)

    throw fail(
      flags, index, entry, "match failed at \(where_)", stringify(check), stringify(baseval))
  }

  // The label of one entry, for failure messages.
  private func entryref(_ flags: Flags, _ index: Int, _ entry: Json) -> String {
    let label = flags.name ?? "set"
    let id = entry.get("id")
    let idpart = id.isabsent ? "" : " (\(stringify(id)))"
    return "\(label)[\(index)]\(idpart)"
  }

  private func fail(
    _ flags: Flags, _ index: Int, _ entry: Json, _ reason: String,
    _ expected: String? = nil, _ actual: String? = nil
  ) -> OmniError {
    var message = "omni: \(entryref(flags, index, entry)): \(reason)"

    if let expected = expected {
      message += "\n  expected: \(expected)"
    }
    if let actual = actual {
      message += "\n  actual:   \(actual)"
    }

    var summary: [String: Json] = [:]
    if case .map(let entries) = entry {
      for (key, val) in entries where "res" != key && "thrown" != key && "ctx" != key {
        summary[key] = val
      }
    }
    message += "\n  entry:    \(stringify(.map(summary)))"

    return OmniError(message, entry)
  }
}

/// A loaded spec plus its provider.
public final class Runner {
  private let alltests: Json
  private let provider: Provider

  public init(_ alltests: Json, _ provider: Provider) {
    self.alltests = alltests
    self.provider = provider
  }

  /// Resolve one named section of the spec.
  public func runner(_ name: String, _ store: Json = .absent) -> RunPack {
    let spec = resolvespec(name, alltests)
    var clients: [String: Provider] = [:]

    let defclient = spec.get("DEF").get("client")

    // A spec may define clients that a given test run never references.
    if let entries = defclient.asmap, let clientmaker = provider.client {
      for (clientname, cdef) in entries {
        var copts = cdef.get("test").get("options")
        if copts.isabsent {
          copts = .map([:])
        }
        if let inject = provider.inject, store.ismap {
          copts = inject(copts, store)
        }
        clients[clientname] = clientmaker(copts)
      }
    }

    let subject = name.isEmpty ? nil : provider.subject?(name)

    return RunPack(spec: spec, subject: subject, provider: provider, clients: clients, name: name)
  }
}

/// Make a runner for a spec file path and a provider.
public func makeRunner(_ path: String, _ provider: Provider = Provider()) throws -> Runner {
  return Runner(try loadspec(path), provider)
}

/// Make a runner for an in-memory spec and a provider.
public func makeRunner(_ spec: Json, _ provider: Provider = Provider()) -> Runner {
  return Runner(spec, provider)
}
