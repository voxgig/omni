// RUN: make test
// RUN-SOME: ./.build/debug/omnitest "ext ctxargs"
//
// The capability suite: spec/ext.json requires ctxargs, fn and wait, and
// every port that carries them runs it, beside the runner flag `all`.

import Foundation
import Omni

func extprovider() -> Provider {
  let subjects: [String: Subject] = [
    "fib": FIB, "fibseq": FIBSEQ, "fibrange": FIBRANGE, "fibinfo": FIBINFO,
  ]
  return Provider(
    subject: { name in subjects[name] },
    contextify: { val in
      var out = val
      out.set("mark", .str("CTX"))
      return out
    }
  )
}

// The ctxargs subject: the context comes first, and must arrive
// contextified with its client attached.
let FIBSHIFTED: Subject = { args in
  let arg = { (at: Int) -> Json in at < args.count ? args[at] : .absent }
  let ctx = arg(0)
  guard "CTX" == ctx.get("mark").asstr, !ctx.get("client").isnone else {
    throw FibError("fib: context not delivered")
  }
  let shift = ctx.get("shift").asnum ?? 0
  let shifted = { (val: Json) -> Json in val.asnum.map { .num($0 + shift) } ?? val }
  return try Fib.fibrange(shifted(arg(1)), shifted(arg(2)))
}

func extrunner(_ spec: Json) throws -> RunPack {
  return try makeRunner(spec, extprovider()).runner("fib")
}

func v1(_ requires: String, _ set: String) throws -> Json {
  return try Json.parse(
    #"{"OMNI":{"version":1,"requires":"# + requires + #"},"fib":{"g":{"set":"# + set + "}}}")
}

func refuses(_ pattern: String, _ run: () throws -> Void) throws {
  do {
    try run()
  } catch let err as OmniError {
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(err.message.startIndex..., in: err.message)
    if nil == regex.firstMatch(in: err.message, range: range) {
      throw OmniError("omni: expected a failure matching: \(pattern)\ngot: \(err.message)")
    }
    return
  }
  throw OmniError("omni: expected a failure matching: \(pattern)")
}

func extsuite() {
  let extpack = { try makeRunner(try specfile("ext.json"), extprovider()).runner("fib") }

  testcase("ext capabilities") {
    for cap in ["ctxargs", "fn", "wait"] where !CAPABILITIES.contains(cap) {
      throw OmniError("omni: missing capability: " + cap)
    }
  }

  testcase("ext ctxargs") {
    let R = try extpack()
    try R.runset(R.set("ctxargs"), FIBSHIFTED)
  }

  testcase("ext fn") {
    let R = try extpack()
    try R.runset(R.set("fn"), FIB)
  }

  testcase("ext wait") {
    let R = try extpack()
    try R.runset(R.set("wait"), FIB)
  }

  testcase("a waiting entry that passes fails the set") {
    let R = try extrunner(try v1(#"["wait"]"#, #"[{"in":5,"out":5,"wait":{"cause":"gone#1"}}]"#))
    try refuses(#"\[0\]: stale wait: gone#1"#) { try R.runset(R.set("g"), FIB) }
  }

  testcase("the wait flag holds an entry by id") {
    let R = try extrunner(try v1("[]", #"[{"id":"a","in":6,"out":9},{"in":7,"out":13}]"#))
    let flags = Flags(wait: try Json.parse(#"{"a":{"cause":"flag#1"}}"#))
    try R.runsetflags(R.set("g"), flags, FIB)
  }

  testcase("the wait flag fails when its entry passes") {
    let R = try extrunner(try v1("[]", #"[{"id":"a","in":6,"out":8}]"#))
    let flags = Flags(wait: try Json.parse(#"{"a":{"cause":"flag#1"}}"#))
    try refuses("stale wait: flag#1") { try R.runsetflags(R.set("g"), flags, FIB) }
  }

  testcase("the wait flag must name an entry") {
    let R = try extrunner(try v1("[]", #"[{"id":"a","in":6,"out":8}]"#))
    let flags = Flags(wait: try Json.parse(#"{"zz":{"cause":"c"}}"#))
    try refuses("wait names no entry: zz") { try R.runsetflags(R.set("g"), flags, FIB) }
  }

  testcase("a wait needs a cause") {
    let R = try extrunner(try v1(#"["wait"]"#, #"[{"in":6,"out":9,"wait":{}}]"#))
    try refuses("entry wait has no cause") { try R.runset(R.set("g"), FIB) }
  }

  testcase("wait and fn are unknown fields unless required") {
    let W = try extrunner(try v1("[]", #"[{"in":6,"out":9,"wait":{"cause":"c"}}]"#))
    try refuses("unknown entry field: wait") { try W.runset(W.set("g"), FIB) }
    let F = try extrunner(try v1("[]", #"[{"fn":"fib","in":6,"out":8}]"#))
    try refuses("unknown entry field: fn") { try F.runset(F.set("g"), FIB) }
  }

  testcase("an unknown fn is a spec error") {
    let R = try extrunner(try v1(#"["fn"]"#, #"[{"fn":"nope","in":6,"out":8}]"#))
    try refuses("unknown fn: nope") { try R.runset(R.set("g"), FIB) }
  }

  testcase("ctx with args needs ctxargs, and never takes in") {
    let N = try extrunner(try v1("[]", #"[{"ctx":{"shift":0},"args":[0,1],"out":[0,1]}]"#))
    try refuses("more than one of in, args, ctx") { try N.runset(N.set("g"), FIBSHIFTED) }
    let I = try extrunner(try v1(#"["ctxargs"]"#, #"[{"in":1,"ctx":{"shift":0},"out":[0]}]"#))
    try refuses("entry has in beside args or ctx") { try I.runset(I.set("g"), FIBSHIFTED) }
  }

  testcase("a legacy spec ignores fn and wait") {
    let R = try extrunner(
      try Json.parse(
        #"{"fib":{"g":{"set":[{"in":6,"out":8,"fn":"nope","wait":{"cause":"c"}}]}}}"#))
    try R.runset(R.set("g"), FIB)
  }

  testcase("all reports every failure at once") {
    let R = try extrunner(
      try v1("[]", #"[{"in":5,"out":6},{"in":6,"out":8},{"in":7,"out":14}]"#))
    try refuses(
      #"(?s)^omni: fib: 2 of 3 entries failed\n.*fib\[0\]: result mismatch.*fib\[2\]: result mismatch"#
    ) { try R.runsetflags(R.set("g"), Flags(all: true), FIB) }
    try refuses(#"^omni: fib\[0\]: result mismatch"#) { try R.runset(R.set("g"), FIB) }
  }
}
