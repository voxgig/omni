// Omni: the shared multi-language test runner (Swift port).
//
// Port of the canonical TypeScript implementation
// (typescript/src/Runner.ts). Behaviour must match, case for case.

import Foundation

/// The function under test. Arguments arrive as JSON values; failure is
/// reported by throwing.
public typealias Subject = ([Json]) throws -> Json

/// A subject that may REPLACE its arguments, which `match.args` can then
/// assert on. `minor/setpath` is the case in point: eight of its nine entries
/// assert that the store was rewritten in place, and `merge/integrity` all
/// six.
///
/// `Json` is an enum with value semantics, so a consumer holding a converted
/// copy has no way to write through the argument list even when its own nodes
/// are mutable (struct/swift's `VMap` / `VList` are classes). Returning the
/// arguments alongside the result is the only channel there is.
///
/// Separate from `Subject` rather than replacing it: a signature change would
/// break every consumer for a capability most subjects do not need. omni-rust,
/// -cpp, -ocaml, -elixir, -haskell, -clojure and -scala carry the same pair.
public typealias SubjectArgs = ([Json]) throws -> ([Json], Json)

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

/// The newest spec format version this runner understands. A spec with no
/// OMNI block is version 0: the original, lenient format, frozen forever.
/// Version 1 turns on strict entry validation (see checkentry).
public let SPECVERSION = 1

/// Capability strings this runner supports beyond the version baseline. A
/// spec's OMNI.requires list is checked against this: an unknown
/// capability refuses the spec loudly at load time, instead of a lagging
/// port silently mis-running it. A spec turns each on only by requiring it.
public let CAPABILITIES: [String] = ["ctxargs", "fn", "wait"]

/// The complete set of fields an entry may carry. Under version 1 anything
/// else is an error: an unrecognised key is almost always a typo'd
/// assertion, and a typo'd assertion is a test that silently stopped
/// testing.
private let ENTRYFIELDS = ["in", "args", "ctx", "out", "err", "match", "client", "id", "doc"]

/// Entry fields a capability adds, permitted only in a spec that requires it.
private let CAPFIELDS = ["fn": "fn", "wait": "wait"]

/// Run-time options for a set of test entries.
public struct Flags {
  public var null: Bool
  public var name: String?
  /// Run every entry, then fail once listing each failure.
  public var all: Bool
  /// Entry id to `{cause}`, holding those entries.
  public var wait: Json

  public init(null: Bool = true, name: String? = nil, all: Bool = false, wait: Json = .absent) {
    self.null = null
    self.name = name
    self.all = all
    self.wait = wait
  }

  public static func nonull() -> Flags { return Flags(null: false) }
}

/// The host of the system under test. Every hook is optional.
public final class Provider {
  public var subject: ((String) -> Subject?)?
  public var client: ((Json) -> Provider)?
  public var contextify: ((Json) -> Json)?
  public var inject: ((Json, Json) -> Json)?
  /// Build the `match.err` base from the raised error, REPLACING `errify`.
  /// A library whose errors carry a code can then assert on it with
  /// `match: {err: {code: "x"}}` instead of pattern-matching prose.
  public var errify: ((Error) -> Json)?

  public init(
    subject: ((String) -> Subject?)? = nil,
    client: ((Json) -> Provider)? = nil,
    contextify: ((Json) -> Json)? = nil,
    inject: ((Json, Json) -> Json)? = nil,
    errify: ((Error) -> Json)? = nil
  ) {
    self.subject = subject
    self.client = client
    self.contextify = contextify
    self.inject = inject
    self.errify = errify
  }
}

/// Load a spec: a path to a JSON file.
public func loadspec(_ path: String) throws -> Json {
  return try Json.parsefile(path)
}

/// Read the spec's format version from its optional top-level OMNI block,
/// and refuse a spec this runner cannot faithfully run: a version newer
/// than SPECVERSION, or a required capability not in CAPABILITIES. A
/// present-but-null OMNI (or OMNI.requires) is malformed - only a
/// genuinely absent key is legacy.
public func resolveversion(_ alltests: Json) throws -> Int {
  guard alltests.has("OMNI") else {
    return 0
  }

  let meta = alltests.get("OMNI")

  guard meta.ismap, let version = meta.get("version").asnum,
    version == version.rounded(.towardZero)
  else {
    throw OmniError("omni: malformed OMNI version block")
  }

  if 0 > version || Double(SPECVERSION) < version {
    throw OmniError("omni: unsupported spec version: " + numstr(version))
  }

  if meta.has("requires") {
    guard let requireslist = meta.get("requires").aslist else {
      throw OmniError("omni: malformed OMNI requires list")
    }
    for cap in requireslist {
      guard let capstr = cap.asstr, CAPABILITIES.contains(capstr) else {
        throw OmniError("omni: spec requires unsupported capability: " + stringify(cap))
      }
    }
  }

  return Int(version)
}

// The capabilities a spec requires, which resolveversion has already
// checked against CAPABILITIES.
private func resolverequires(_ alltests: Json) -> [String] {
  return (alltests.get("OMNI").get("requires").aslist ?? []).compactMap { $0.asstr }
}

private func iswait(_ wait: Json) -> Bool {
  return !(wait.get("cause").asstr ?? "").isEmpty
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
    // Canonical returns the value UNCHANGED when donull is false
    // (typescript/src/Runner.ts): absent stays absent and null stays null.
    // Answering .null for both collapsed two states the corpus distinguishes,
    // so a subject that correctly returned nothing was compared against null
    // and marked wrong. Same defect the other ports carried (#17, #23, #25,
    // #26, #27, #28).
    return donull ? .str(NULLMARK) : val
  }

  if case .list(let entries) = val {
    return .list(entries.map { fixjson($0, donull) })
  }

  if case .map(let entries) = val {
    var out: [(String, Json)] = []
    for (key, entry) in entries {
      out.append((key, fixjson(entry, donull)))
    }
    return .map(out)
  }

  return val
}

/// The JSON form of an error: always at least {name,message}. The name is
/// the thrown error's type name (the canonical runner uses `err.name`), so
/// a `match:{err:{name:...}}` expectation can see the real error type.
public func errify(_ err: Error) -> Json {
  return Json.mapOf([("name", .str(errname(err))), ("message", .str(errmessage(err)))])
}

/// The name of an error: its Swift type name (e.g. "FibError").
public func errname(_ err: Error) -> String {
  return String(describing: type(of: err))
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
    // An empty want is not a wildcard: it matches only an empty string.
    if text.isEmpty {
      return "" == base.asstr
    }

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

// The provider and subject one entry runs against. `argsubject` is the
// caller's args-taking subject, kept only while no `fn` chose another.
private struct TestPack {
  var client: Provider
  var subject: Subject?
  var argsubject: SubjectArgs?
}

/// What a runner returns for one named spec section.
public final class RunPack {
  public let spec: Json
  public let subject: Subject?
  public let client: Provider

  private let provider: Provider
  private let clients: [String: Provider]
  private let name: String
  private let specversion: Int
  private let requires: [String]
  private let ctxargs: Bool
  private let fnon: Bool
  private let waiton: Bool

  init(
    spec: Json, subject: Subject?, provider: Provider, clients: [String: Provider], name: String,
    specversion: Int, requires: [String]
  ) {
    self.spec = spec
    self.subject = subject
    self.client = provider
    self.provider = provider
    self.clients = clients
    self.name = name
    self.specversion = specversion
    self.requires = requires
    self.ctxargs = requires.contains("ctxargs")
    self.fnon = requires.contains("fn")
    self.waiton = requires.contains("wait")
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
    try drive(testspec, flags, testsubject, nil)
  }

  /// Everything `runsetflags` does, for a subject that may replace its
  /// arguments. See `SubjectArgs`.
  public func runsetflagsargs(_ testspec: Json, _ flags: Flags, _ argsubject: @escaping SubjectArgs)
    throws
  {
    try drive(testspec, flags, nil, argsubject)
  }

  private func drive(
    _ testspec: Json, _ flags: Flags, _ testsubject: Subject?, _ argsubject: SubjectArgs?
  ) throws {
    var useflags = flags
    if nil == useflags.name {
      useflags.name = name.isEmpty ? "set" : name
    }
    let label = useflags.name ?? "set"

    let usesubject = nil == argsubject ? testsubject ?? subject : nil
    if nil == argsubject && nil == usesubject && !fnon {
      throw OmniError("omni: no test subject for: \(label)")
    }

    let testspecmap = fixjson(testspec, useflags.null)
    guard let testset = testspecmap.get("set").aslist else {
      throw OmniError("omni: test spec has no set: \(label)")
    }

    // Validate the AUTHORED group (testspec, not testspecmap) - null
    // normalisation above would otherwise rewrite an authored null (e.g.
    // id: null) into a sentinel string and hide it from checkentry.
    if 1 <= specversion {
      try checkset(useflags, testspec, testset, requires)
    }

    let origset = testspec.get("set").aslist ?? testset
    let waits = try resolvewaits(useflags, origset)
    var failures: [String] = []

    for (index, rawentry) in testset.enumerated() {
      do {
        var entry = rawentry

        guard entry.ismap else {
          throw OmniError("omni: \(label)[\(index)]: entry is not a map")
        }

        // An entry with no `out` expects a null (or absent) result.
        if useflags.null && entry.get("out").isnone {
          entry.set("out", .str(NULLMARK))
        }

        let testpack = try resolvetestpack(entry, usesubject, argsubject)
        if nil == testpack.subject && nil == testpack.argsubject {
          throw OmniError("omni: no test subject for: \(label)")
        }

        var wait = Json.absent
        if waiton && !entry.get("wait").isabsent {
          wait = entry.get("wait")
        } else if let id = entry.get("id").asstr {
          wait = waits.get(id)
        }

        if wait.isabsent {
          try runentry(useflags, index, &entry, testpack)
        } else {
          var held = false
          do {
            try runentry(useflags, index, &entry, testpack)
          } catch is OmniError {
            held = true
          }
          if !held {
            throw fail(useflags, index, entry, "stale wait: " + stringify(wait.get("cause")))
          }
        }
      } catch let omnierr as OmniError where useflags.all {
        failures.append(omnierr.message)
      }
    }

    if !failures.isEmpty {
      throw OmniError(
        "omni: \(label): \(failures.count) of \(testset.count) entries failed\n"
          + failures.joined(separator: "\n"))
    }
  }

  private func resolvetestpack(_ entry: Json, _ subject: Subject?, _ argsubject: SubjectArgs?)
    throws -> TestPack
  {
    var testpack = TestPack(client: provider, subject: subject, argsubject: argsubject)

    if let clientname = entry.get("client").asstr {
      guard let found = clients[clientname] else {
        throw OmniError("omni: unknown client: \(clientname)", entry)
      }
      testpack.client = found
      if nil == testpack.argsubject, let clientsubject = found.subject?(name) {
        testpack.subject = clientsubject
      }
    }

    if fnon, let fn = entry.get("fn").asstr {
      guard let fnsubject = testpack.client.subject?(fn) else {
        throw OmniError("omni: unknown fn: \(fn)", entry)
      }
      testpack.subject = fnsubject
      testpack.argsubject = nil
    }

    return testpack
  }

  private func runentry(_ flags: Flags, _ index: Int, _ entry: inout Json, _ testpack: TestPack)
    throws
  {
    // An args-subject returns its arguments alongside the result, so
    // `match.args` sees what the subject actually did with them.
    var callargs: [Json] = []
    var res: Json
    do {
      let args = resolveargs(&entry, testpack.client)
      callargs = args
      if let call = testpack.argsubject {
        (callargs, res) = try call(args)
      } else if let call = testpack.subject {
        res = try call(args)
      } else {
        throw OmniError("omni: no test subject for: \(flags.name ?? "set")")
      }
    } catch let omnierr as OmniError {
      throw omnierr
    } catch {
      try handleerror(flags, index, entry, error)
      return
    }

    res = fixjson(res, flags.null)
    entry.set("res", res)

    try checkresult(flags, index, entry, callargs, res)
  }

  // The runner-side waits: entry id to its declaration. Each must name an
  // entry of the set, so a declaration cannot outlive the entry it held.
  private func resolvewaits(_ flags: Flags, _ origset: [Json]) throws -> Json {
    let label = flags.name ?? "set"

    if flags.wait.isnone {
      return .map([])
    }
    guard let waits = flags.wait.asmap else {
      throw OmniError("omni: \(label): wait flag is not a map")
    }

    let ids = origset.compactMap { $0.get("id").asstr }
    for (id, wait) in waits {
      if !ids.contains(id) {
        throw OmniError("omni: \(label): wait names no entry: \(id)")
      }
      if !iswait(wait) {
        throw OmniError("omni: \(label): wait for \(id) has no cause")
      }
    }

    return flags.wait
  }

  // Build the argument list: `ctx`, `args`, or `in`. Under `ctxargs` an
  // entry with both passes the context first, then each argument.
  private func resolveargs(_ entry: inout Json, _ client: Provider) -> [Json] {
    var args: [Json]

    let hasctx = entry.has("ctx")
    let hasargs = entry.has("args")
    let listargs = entry.get("args").aslist ?? [entry.get("args")]

    if ctxargs && hasctx && hasargs {
      args = [entry.get("ctx")] + listargs
    } else if hasctx {
      args = [entry.get("ctx")]
    } else if hasargs {
      args = listargs
    } else {
      args = [entry.get("in")]
    }

    if (hasctx || hasargs) && !args.isEmpty && args[0].ismap {
      var first = args[0]
      if let contextify = provider.contextify {
        first = contextify(first)
      }
      // Attach the entry's resolved client (canonical:
      // `first.client = testpack.client`), before first is copied into
      // args[0]/entry.ctx - Json has value semantics, unlike the JS
      // object canonical mutates in place, so the attach must happen
      // before both copies are taken, not after.
      if first.ismap {
        first.set("client", .provider(client))
      }
      args[0] = first
      entry.set("ctx", first)
    }

    return args
  }

  // Validate a version-1 group up front, against the AUTHORED entries
  // (testspec, not the null-normalised testset) - see the call site in
  // runsetflags. Absorbs the empty-set check: a group with no entries
  // must say so explicitly (`empty: true`), or it is a mistake, not a
  // deliberate no-op.
  private func checkset(
    _ flags: Flags, _ testspec: Json, _ normalset: [Json], _ requires: [String]
  ) throws {
    let origset: [Json]
    if testspec.ismap, let set = testspec.get("set").aslist {
      origset = set
    } else {
      origset = normalset
    }

    var markedempty = false
    if case .bool(true) = testspec.get("empty") {
      markedempty = true
    }

    if origset.isEmpty && !markedempty {
      throw OmniError("omni: empty test set: \(flags.name ?? "set")")
    }

    for (index, entry) in origset.enumerated() {
      try checkentry(flags, index, entry, requires)
    }
  }

  // Strict entry validation, applied when the spec declares version 1 or
  // later. The lenient format converts each of these mistakes into a
  // silent pass or a dead field; here they fail with the entry named.
  private func checkentry(_ flags: Flags, _ index: Int, _ entry: Json, _ requires: [String])
    throws
  {
    guard case .map(let fields) = entry else {
      throw fail(flags, index, entry, "entry is not a map")
    }

    for key in fields.map({ $0.0 }).sorted() {
      let capfield = CAPFIELDS[key].map { requires.contains($0) } ?? false
      if !ENTRYFIELDS.contains(key) && !capfield {
        throw fail(flags, index, entry, "unknown entry field: " + key)
      }
    }

    if requires.contains("ctxargs") {
      if entry.has("in") && (entry.has("args") || entry.has("ctx")) {
        throw fail(flags, index, entry, "entry has in beside args or ctx")
      }
    } else {
      var argsources = 0
      for key in ["in", "args", "ctx"] where entry.has(key) {
        argsources += 1
      }
      if 1 < argsources {
        throw fail(flags, index, entry, "entry has more than one of in, args, ctx")
      }
    }

    if entry.has("fn") && (entry.get("fn").asstr ?? "").isEmpty {
      throw fail(flags, index, entry, "entry fn is not a name")
    }

    if entry.has("wait") && !iswait(entry.get("wait")) {
      throw fail(flags, index, entry, "entry wait has no cause")
    }

    if !entry.get("err").isnone && entry.has("out") {
      throw fail(flags, index, entry, "entry has both err and out")
    }

    // Presence, not definedness: `id: null` must fail here too, so a
    // strict spec cannot smuggle a non-string id past this check under
    // null-normalisation (checkset validates before fixjson runs).
    if entry.has("id") && !entry.get("id").isstr {
      throw fail(flags, index, entry, "entry id is not a string")
    }
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

  /// The error base a `match.err` sees: the provider's own, when it has one.
  private func errbase(_ err: Error) -> Json {
    if let hook = provider.errify {
      return hook(err)
    }
    return Omni.errify(err)
  }

  private func handleerror(_ flags: Flags, _ index: Int, _ entry: Json, _ err: Error) throws {
    let message = errmessage(err)
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
            ("err", errbase(err)),
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

    // The sentinels are tested BEFORE the identity check below. Otherwise
    // a subject returning the literal string "__UNDEF__" satisfies an
    // assertion that the key is absent - two mutually exclusive states
    // passing one check. A sentinel that accepts its own literal is not a
    // sentinel. (NULLMARK still accepts NULLMARK: under the default null
    // flag a real null has already been normalised to it, so the two are
    // genuinely indistinguishable here - that one needs a raw-value
    // escape, not an ordering change.)

    // Explicitly absent: satisfied only by a genuinely missing key, never
    // by a present null (the distinction the sentinels exist to keep).
    if UNDEFMARK == check.asstr {
      if baseval.isabsent {
        return
      }
      throw fail(
        flags, index, entry, "expected absent at \(matchat(path))",
        "absent", stringify(baseval))
    }

    // Explicitly null: satisfied only by a present null.
    if NULLMARK == check.asstr {
      if baseval.isnull || NULLMARK == baseval.asstr {
        return
      }
      throw fail(
        flags, index, entry, "expected null at \(matchat(path))",
        "null", stringify(baseval))
    }

    // Explicitly present: any present value, including null.
    if EXISTSMARK == check.asstr {
      if !baseval.isabsent {
        return
      }
      throw fail(
        flags, index, entry, "expected present at \(matchat(path))",
        "present", "absent")
    }

    // Identical values match. This sits below the sentinel branches on
    // purpose - see the note above.
    if deepequal(check, baseval) {
      return
    }

    // A concrete expectation never matches a missing key - a match leaf
    // against an absent value must fail, not substring-match "undefined".
    if baseval.isabsent {
      throw fail(
        flags, index, entry, "match failed at \(matchat(path))",
        stringify(check), "absent")
    }

    if matchval(check, baseval) {
      return
    }

    throw fail(
      flags, index, entry, "match failed at \(matchat(path))",
      stringify(check), stringify(baseval))
  }

  // The location of one match leaf, for failure messages.
  private func matchat(_ path: [String]) -> String {
    return path.isEmpty ? "<root>" : pathify(path)
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

    var summary: [(String, Json)] = []
    if case .map(let entries) = entry {
      for (key, val) in entries where "res" != key && "thrown" != key && "ctx" != key {
        summary.append((key, val))
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
  private let specversion: Int
  private let requires: [String]

  /// Resolves the spec's format version immediately - fail fast, before
  /// any group runs, on a version this runner cannot faithfully run.
  public init(_ alltests: Json, _ provider: Provider) throws {
    self.alltests = alltests
    self.provider = provider
    self.specversion = try resolveversion(alltests)
    self.requires = resolverequires(alltests)
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
          copts = .map([])
        }
        if let inject = provider.inject, store.ismap {
          copts = inject(copts, store)
        }
        clients[clientname] = clientmaker(copts)
      }
    }

    let subject = name.isEmpty ? nil : provider.subject?(name)

    return RunPack(
      spec: spec, subject: subject, provider: provider, clients: clients, name: name,
      specversion: specversion, requires: requires)
  }
}

/// Make a runner for a spec file path and a provider.
public func makeRunner(_ path: String, _ provider: Provider = Provider()) throws -> Runner {
  return try Runner(try loadspec(path), provider)
}

/// Make a runner for an in-memory spec and a provider.
public func makeRunner(_ spec: Json, _ provider: Provider = Provider()) throws -> Runner {
  return try Runner(spec, provider)
}
