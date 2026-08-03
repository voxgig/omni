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

// The provider hosts the system under test. `shift` offsets the Fibonacci
// index, so that a client-specific subject is observably different.
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
        // An empty container asserts an empty container, not "anything".
        (
          "emptymatch",
          Json.mapOf([
            (
              "set",
              .list([
                Json.mapOf([
                  ("in", .num(6)),
                  ("match", Json.mapOf([("out", .map([:]))])),
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
  let pack = makeRunner(badspec()).runner("fib")

  do {
    try pack.runset(pack.set(setname), subject)
  } catch is OmniError {
    return
  }

  throw OmniError("omni: expected OmniError for set: " + setname)
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

  let pack = makeRunner(spec).runner("fib")

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

let args = CommandLine.arguments
if 1 < args.count {
  ONLY = args[1]
}

let R = try makeRunner(try specfile("fib.json"), fibprovider(0)).runner("fib")

testcase("basic") { try R.runset(R.set("basic"), FIB) }
testcase("seq") { try R.runset(R.set("seq"), FIBSEQ) }
testcase("range") { try R.runset(R.set("range"), FIBRANGE) }
testcase("info") { try R.runset(R.set("info"), FIBINFO) }
testcase("nulls") { try R.runsetflags(R.set("nulls"), Flags.nonull(), FIBINFO) }
testcase("error") { try R.runset(R.set("error"), FIB) }
testcase("match") { try R.runset(R.set("match"), FIB) }
testcase("matchinfo") { try R.runset(R.set("matchinfo"), FIBINFO) }
testcase("client") { try R.runset(R.set("client"), FIB) }

testcase("detects wrong result") { try expectfail("wrongout", FIB) }
testcase("detects missing error") { try expectfail("wrongerr", FIB) }
testcase("detects failed match") { try expectfail("wrongmatch", FIB) }
testcase("detects absent key") { try expectfail("missing", FIBINFO) }
testcase("a concrete match leaf does not match a missing key") {
  try expectfail("matchabsent", FIBINFO)
}
testcase("__UNDEF__ does not match a present null") { try expectfail("undefonnull", FIBINFO) }
testcase("__NULL__ does not match an absent key") { try expectfail("nullonabsent", FIBINFO) }
testcase("an empty match container is not vacuous") { try expectfail("emptymatch", FIBINFO) }
testcase("an empty-string match leaf is not a wildcard") { try expectfail("emptystr", FIBINFO) }
testcase("reports entry index and id") { try checkmessage() }

print("\n\(passcount) passed, \(failcount) failed")

exit(0 == failcount ? 0 : 1)
