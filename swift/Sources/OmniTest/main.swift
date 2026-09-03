// RUN: make test
// RUN-SOME: ./.build/debug/omnitest basic
//
// The Fibonacci conformance suite: every omni port runs this same set of
// groups, from the same spec/fib.json, against the same fib library.
//
// No third-party test framework: a failing omni check throws OmniError, so
// XCTest reports it as a failure. This harness keeps `make test`
// dependency-free.

import Foundation
import Omni

var ONLY: String? = nil
var passcount = 0
var failcount = 0

// Find the shared spec directory by walking up from the working directory.
func specfile(_ name: String) throws -> String {
  var dir = FileManager.default.currentDirectoryPath

  for _ in 0..<8 {
    let cand = dir + "/spec/" + name
    if FileManager.default.fileExists(atPath: cand) {
      return cand
    }
    let parent = (dir as NSString).deletingLastPathComponent
    if parent == dir || parent.isEmpty {
      break
    }
    dir = parent
  }

  throw OmniError("omni: spec not found: " + name)
}

let FIB: Subject = { args in try Fib.fib(args[0]) }
let FIBSEQ: Subject = { args in try Fib.fibseq(args[0]) }
let FIBRANGE: Subject = { args in try Fib.fibrange(args[0], args[1]) }
let FIBINFO: Subject = { args in try Fib.fibinfo(args[0]) }

// The context-group subject: reports what the runner delivered - the
// contextify mark and the attached client - as plain data, so the spec
// can pin both with an ordinary `out` comparison.
let FIBCTX: Subject = { args in
  let ctx = args[0]
  return Json.mapOf([
    ("n", ctx.get("n")),
    ("val", try Fib.fib(ctx.get("n"))),
    ("mark", ctx.get("mark")),
    ("hasclient", .bool(!ctx.get("client").isnone)),
  ])
}

// A subject that returns the sentinel string as ordinary data. The absent
// sentinel must not be satisfied by a literal "__UNDEF__" in the result.
let FIBUNDEF: Subject = { _ in
  return Json.mapOf([("a", .str(UNDEFMARK))])
}

// The provider hosts the system under test. `shift` offsets the Fibonacci
// index, so that a client-specific subject is observably different.
// `contextify` marks the map, so the context group can prove the hook ran.
func fibprovider(_ shift: Double) -> Provider {
  return Provider(
    subject: { name in
      switch name {
      case "fib":
        return { args in
          if let num = args[0].asnum {
            return try Fib.fib(.num(num + shift))
          }
          return try Fib.fib(args[0])
        }
      case "fibseq": return FIBSEQ
      case "fibrange": return FIBRANGE
      case "fibinfo": return FIBINFO
      default: return nil
      }
    },
    client: { options in
      return fibprovider(options.get("shift").asnum ?? 0)
    },
    contextify: { val in
      var out = val
      out.set("mark", .str("CTX"))
      return out
    }
  )
}

func testcase(_ name: String, _ body: () throws -> Void) {
  if let only = ONLY, name != only {
    return
  }

  do {
    try body()
    passcount += 1
    print("ok   - \(name)")
  } catch {
    failcount += 1
    print("FAIL - \(name)")
    print(errmessage(error))
  }
}

// The runner must fail when the subject is wrong - otherwise a green suite
// means nothing.
func badspec() -> Json {
  return Json.mapOf([
    (
      "fib",
      Json.mapOf([
        (
          "wrongout",
          Json.mapOf([
            (
              "set",
              .list([
                Json.mapOf([("in", .num(5)), ("out", .num(5))]),
                Json.mapOf([("in", .num(6)), ("out", .num(999))]),
              ])
            )
          ])
        ),
        (
          "wrongerr",
          Json.mapOf([
            (
              "set",
              .list([Json.mapOf([("in", .num(1)), ("err", .str("never happens"))])])
            )
          ])
        ),
        (
          "wrongmatch",
          Json.mapOf([
            (
              "set",
              .list([
                Json.mapOf([
                  ("in", .num(6)), ("match", Json.mapOf([("out", .num(999))])),
                ])
              ])
            )
          ])
        ),
        (
          "missing",
          Json.mapOf([
            (
              "set",
              .list([
                Json.mapOf([
                  ("in", .num(6)),
                  (
                    "match",
                    Json.mapOf([("out", Json.mapOf([("nope", .str("__EXISTS__"))]))])
                  ),
                ])
              ])
            )
          ])
        ),
        // A concrete match leaf against a missing key must fail, not
        // substring-match the text "undefined".
        (
          "matchabsent",
          Json.mapOf([
            (
              "set",
              .list([
                Json.mapOf([
                  ("in", .num(6)),
                  (
                    "match",
                    Json.mapOf([("out", Json.mapOf([("nope", .str("fine"))]))])
                  ),
                ])
              ])
            )
          ])
        ),
        // __UNDEF__ (absent) must not be satisfied by a present null.
        (
          "undefonnull",
          Json.mapOf([
            (
              "set",
              .list([
                Json.mapOf([
                  ("in", .num(0)),
                  (
                    "match",
                    Json.mapOf([("out", Json.mapOf([("prev", .str("__UNDEF__"))]))])
                  ),
                ])
              ])
            )
          ])
        ),
        // __NULL__ (present null) must not be satisfied by an absent key.
        (
          "nullonabsent",
          Json.mapOf([
            (
              "set",
              .list([
                Json.mapOf([
                  ("in", .num(6)),
                  (
                    "match",
                    Json.mapOf([("out", Json.mapOf([("nope", .str("__NULL__"))]))])
                  ),
                ])
              ])
            )
          ])
        ),
        // The literal string "__UNDEF__" as ordinary data is not an absent
        // key - the sentinel must not accept its own literal.
        (
          "wrongundef",
          Json.mapOf([
            (
              "set",
              .list([
                Json.mapOf([
                  ("in", .num(6)),
                  (
                    "match",
                    Json.mapOf([("out", Json.mapOf([("a", .str("__UNDEF__"))]))])
                  ),
                ])
              ])
            )
          ])
        ),
        // An empty-string leaf matches only an empty string, not "anything".
        (
          "emptystr",
          Json.mapOf([
            (
              "set",
              .list([
                Json.mapOf([
                  ("in", .num(6)),
                  (
                    "match",
                    Json.mapOf([("out", Json.mapOf([("label", .str(""))]))])
                  ),
                ])
              ])
            )
          ])
        ),
      ])
    )
  ])
}

func expectfail(_ setname: String, _ subject: @escaping Subject) throws {
  let pack = try makeRunner(badspec()).runner("fib")

  do {
    try pack.runset(pack.set(setname), subject)
  } catch is OmniError {
    return
  }

  throw OmniError("omni: expected OmniError for set: " + setname)
}

// makeRunner itself must refuse a spec version-1 flags loudly, at load
// time - before any group runs.
func expectmakefail(_ spec: Json, _ want: String) throws {
  do {
    _ = try makeRunner(spec)
  } catch let err as OmniError {
    if !err.message.contains(want) {
      throw OmniError("omni: message missing [\(want)]: \(err.message)")
    }
    return
  }
  throw OmniError("omni: expected OmniError containing [\(want)]")
}

// Strict (version-1) entry validation must name the reason in the message.
func expectrunfail(_ spec: Json, _ setname: String, _ subject: @escaping Subject, _ want: String)
  throws
{
  let pack = try makeRunner(spec).runner("fib")

  do {
    try pack.runset(pack.set(setname), subject)
  } catch let err as OmniError {
    if !err.message.contains(want) {
      throw OmniError("omni: message missing [\(want)]: \(err.message)")
    }
    return
  }

  throw OmniError("omni: expected OmniError containing [\(want)] for set: " + setname)
}

// A version-1 spec with one group's `set` list, and OMNI.version already
// filled in - the shared shape behind every strict negative test below.
func strictspec(_ setname: String, _ entries: [Json], _ empty: Bool = false) -> Json {
  var group: [(String, Json)] = [("set", .list(entries))]
  if empty {
    group.append(("empty", .bool(true)))
  }
  return Json.mapOf([
    ("OMNI", Json.mapOf([("version", .num(1))])),
    ("fib", Json.mapOf([(setname, Json.mapOf(group))])),
  ])
}

func checkmessage() throws {
  let spec = Json.mapOf([
    (
      "fib",
      Json.mapOf([
        (
          "g",
          Json.mapOf([
            (
              "set",
              .list([
                Json.mapOf([("in", .num(1)), ("out", .num(1))]),
                Json.mapOf([("id", .str("x#2")), ("in", .num(2)), ("out", .num(42))]),
              ])
            )
          ])
        )
      ])
    )
  ])

  let pack = try makeRunner(spec).runner("fib")

  do {
    try pack.runset(pack.set("g"), FIB)
  } catch let err as OmniError {
    for want in ["fib[1] (x#2)", "expected: 42", "actual:   1"] {
      if !err.message.contains(want) {
        throw OmniError("omni: message missing [\(want)]: \(err.message)")
      }
    }
    return
  }

  throw OmniError("omni: expected OmniError")
}

func checkequal(_ want: Bool, _ a: Json, _ b: Json, _ what: String) throws {
  if want != deepequal(a, b) {
    throw OmniError("omni: deepequal(\(what)) should be \(want)")
  }
}

// deepequal is structural, not IEEE: NaN equals NaN, at the top level and
// inside nodes, so a subject that returns NaN can still be pinned by a
// spec. spec/fib.json is the only suite, it is JSON, and JSON has no NaN
// literal - so this is the only place the rule is checked.
//
// The two NaNs come from two *different* expressions. Using one NaN
// constant twice would let an identity fast-path pass the test while
// proving nothing. Json is a Swift enum - a value type with no object
// identity - so there is no such fast-path here to assert against.
func checknan() throws {
  let n1 = Json.num(Double.infinity - Double.infinity)
  let n2 = Json.num(Double("nan") ?? 0.0)

  guard let d1 = n1.asnum, let d2 = n2.asnum, d1.isNaN, d2.isNaN else {
    throw OmniError("omni: both values must be NaN")
  }

  try checkequal(true, n1, n2, "NaN, NaN")
  try checkequal(true, .list([n1]), .list([n2]), "[NaN], [NaN]")
  try checkequal(true, Json.mapOf([("x", n1)]), Json.mapOf([("x", n2)]), "{x:NaN}, {x:NaN}")

  // Regressions: the NaN rule must not loosen anything else.
  try checkequal(true, .num(1), .num(1.0), "1, 1.0")
  try checkequal(false, n1, .num(1.0), "NaN, 1.0")
  try checkequal(false, .bool(true), .num(1), "true, 1")
  try checkequal(false, .num(1), .num(2), "1, 2")
}

let args = CommandLine.arguments
if 1 < args.count {
  ONLY = args[1]
}

// Derive fib's error code from its message.
func fiberrcode(_ message: String) -> String {
  if message.contains("negative index") { return "fib_negative" }
  if message.contains("non-integer") { return "fib_noninteger" }
  if message.contains("not a number") { return "fib_notanumber" }
  return "fib_unknown"
}

// The same provider, plus the `errify` hook: fib's errors gain a CODE.
//
// A SECOND runner rather than a hook on `fibprovider`, so that the
// `error` group keeps exercising the DEFAULT errify.
func fibcodedprovider() -> Provider {
  let provider = fibprovider(0)
  provider.errify = { err in
    let message = errmessage(err)
    return .map([
      ("name", .str("Error")),
      ("message", .str(message)),
      ("code", .str(fiberrcode(message))),
    ])
  }
  return provider
}

let R = try makeRunner(try specfile("fib.json"), fibprovider(0)).runner("fib")
let RC = try makeRunner(try specfile("fib.json"), fibcodedprovider()).runner("fib")

testcase("basic") { try R.runset(R.set("basic"), FIB) }
testcase("seq") { try R.runset(R.set("seq"), FIBSEQ) }
testcase("range") { try R.runset(R.set("range"), FIBRANGE) }
testcase("info") { try R.runset(R.set("info"), FIBINFO) }
testcase("nulls") { try R.runsetflags(R.set("nulls"), Flags.nonull(), FIBINFO) }
testcase("error") { try R.runset(R.set("error"), FIB) }
testcase("errcode") { try RC.runset(RC.set("errcode"), FIB) }
testcase("match") { try R.runset(R.set("match"), FIB) }
testcase("matchinfo") { try R.runset(R.set("matchinfo"), FIBINFO) }
testcase("client") { try R.runset(R.set("client"), FIB) }
testcase("context") { try R.runset(R.set("context"), FIBCTX) }

testcase("detects wrong result") { try expectfail("wrongout", FIB) }
testcase("detects missing error") { try expectfail("wrongerr", FIB) }
testcase("detects failed match") { try expectfail("wrongmatch", FIB) }
testcase("detects absent key") { try expectfail("missing", FIBINFO) }
testcase("a concrete match leaf does not match a missing key") {
  try expectfail("matchabsent", FIBINFO)
}
testcase("__UNDEF__ does not match a present null") { try expectfail("undefonnull", FIBINFO) }
testcase("__NULL__ does not match an absent key") { try expectfail("nullonabsent", FIBINFO) }
testcase("an empty-string match leaf is not a wildcard") { try expectfail("emptystr", FIBINFO) }
testcase("__UNDEF__ does not match a literal \"__UNDEF__\" result") {
  try expectfail("wrongundef", FIBUNDEF)
}

testcase("rejects an unsupported spec version") {
  try expectmakefail(
    Json.mapOf([
      ("OMNI", Json.mapOf([("version", .num(99))])),
      ("fib", Json.mapOf([("g", Json.mapOf([("set", .list([]))]))])),
    ]),
    "unsupported spec version")
}

testcase("rejects an unknown required capability") {
  try expectmakefail(
    Json.mapOf([
      (
        "OMNI",
        Json.mapOf([("version", .num(1)), ("requires", .list([.str("nosuchfeature")]))])
      ),
      ("fib", Json.mapOf([("g", Json.mapOf([("set", .list([]))]))])),
    ]),
    "unsupported capability")
}

testcase("rejects a malformed version block") {
  try expectmakefail(
    Json.mapOf([
      ("OMNI", Json.mapOf([("version", .str("one"))])),
      ("fib", Json.mapOf([("g", Json.mapOf([("set", .list([]))]))])),
    ]),
    "malformed OMNI")
}

// A present-but-null block is malformed; only a genuinely absent OMNI key
// is legacy. Testing definedness rather than presence would silently
// skip strict mode here, so both cases are pinned.
testcase("rejects a null OMNI block, but accepts an absent one") {
  // No OMNI key at all - the baseline this test mutates a copy of, so the
  // third assertion below (an absent OMNI) is exactly this, untouched.
  let fibgroup = Json.mapOf([
    (
      "fib",
      Json.mapOf([
        ("g", Json.mapOf([("set", .list([Json.mapOf([("in", .num(1)), ("out", .num(1))])]))]))
      ])
    )
  ])

  var withnullomni = fibgroup
  withnullomni.set("OMNI", .null)
  try expectmakefail(withnullomni, "malformed OMNI")

  var withnullrequires = fibgroup
  withnullrequires.set("OMNI", Json.mapOf([("version", .num(1)), ("requires", .null)]))
  try expectmakefail(withnullrequires, "malformed OMNI requires list")

  _ = try makeRunner(fibgroup)
}

testcase("strict: an unknown entry field fails instead of passing vacuously") {
  try expectrunfail(
    strictspec("g", [Json.mapOf([("in", .num(6)), ("matches", Json.mapOf([("out", .num(999))]))])]),
    "g", FIBINFO, "unknown entry field: matches")
}

testcase("strict: more than one of in, args, ctx fails") {
  try expectrunfail(
    strictspec("g", [Json.mapOf([("in", .num(5)), ("args", .list([.num(5)])), ("out", .num(5))])]),
    "g", FIB, "more than one of in, args, ctx")
}

testcase("strict: err together with out fails") {
  try expectrunfail(
    strictspec("g", [Json.mapOf([("in", .num(-1)), ("err", .bool(true)), ("out", .num(5))])]),
    "g", FIB, "both err and out")
}

testcase("strict: a null id fails even under null-normalisation") {
  try expectrunfail(
    strictspec("g", [Json.mapOf([("in", .num(1)), ("out", .num(1)), ("id", .null)])]),
    "g", FIB, "entry id is not a string")
}

testcase("strict: an empty set fails unless marked empty") {
  try expectrunfail(strictspec("g", []), "g", FIB, "empty test set")

  let pack = try makeRunner(strictspec("h", [], true)).runner("fib")
  try pack.runset(pack.set("h"), FIB)
}

testcase("a legacy spec (no OMNI block) stays lenient") {
  let spec = Json.mapOf([
    (
      "fib",
      Json.mapOf([
        (
          "g",
          Json.mapOf([
            (
              "set",
              .list([
                Json.mapOf([
                  ("in", .num(6)), ("matches", Json.mapOf([("out", .num(999))])), ("out", .num(8)),
                ])
              ])
            )
          ])
        )
      ])
    )
  ])
  let pack = try makeRunner(spec).runner("fib")
  try pack.runset(pack.set("g"), FIB)
}

testcase("reports entry index and id") { try checkmessage() }
testcase("deepequal matches NaN with NaN, structurally") { try checknan() }

print("\n\(passcount) passed, \(failcount) failed")

exit(0 == failcount ? 0 : 1)
