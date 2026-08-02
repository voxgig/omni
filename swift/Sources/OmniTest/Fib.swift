// The system under test: a tiny Fibonacci library.
//
// Every omni port ships this same library, with the same behaviour and the
// same error messages, and tests it with the same spec file
// (spec/fib.json).

import Foundation
import Omni

/// The Fibonacci library's own error type. A subject must never throw the
/// runner's OmniError - that type is reserved for test failures.
struct FibError: Error, CustomStringConvertible {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var description: String { return message }
}

enum Fib {
  /// Validate a Fibonacci index. The spec matches on these messages.
  static func fibindex(_ val: Json) throws -> Int {
    guard let num = val.asnum else {
      throw FibError("fib: not a number: " + stringify(val))
    }

    if num != num.rounded(.towardZero) {
      throw FibError("fib: non-integer index: " + stringify(val))
    }

    if 0 > num {
      throw FibError("fib: negative index: " + stringify(val))
    }

    return Int(num)
  }

  /// The nth Fibonacci number: fib(0)=0, fib(1)=1.
  static func fibnum(_ index: Int) -> Int {
    if 0 == index {
      return 0
    }

    var prev = 0
    var cur = 1

    for _ in 1..<max(index, 1) {
      let next = prev + cur
      prev = cur
      cur = next
    }

    return cur
  }

  static func fib(_ val: Json) throws -> Json {
    return .num(Double(fibnum(try fibindex(val))))
  }

  /// The first n Fibonacci numbers.
  static func fibseq(_ val: Json) throws -> Json {
    let count = try fibindex(val)
    var out: [Json] = []
    for index in 0..<max(count, 0) {
      out.append(.num(Double(fibnum(index))))
    }
    return .list(out)
  }

  /// The Fibonacci numbers from index start to index end, inclusive.
  static func fibrange(_ start: Json, _ end: Json) throws -> Json {
    let from = try fibindex(start)
    let to = try fibindex(end)
    var out: [Json] = []
    var index = from
    while index <= to {
      out.append(.num(Double(fibnum(index))))
      index += 1
    }
    return .list(out)
  }

  /// A description of the nth Fibonacci number. `prev` is null at index 0,
  /// which exercises the runner's null handling.
  static func fibinfo(_ val: Json) throws -> Json {
    let index = try fibindex(val)
    let num = fibnum(index)

    return Json.mapOf([
      ("n", .num(Double(index))),
      ("val", .num(Double(num))),
      ("even", .bool(0 == num % 2)),
      ("prev", 0 == index ? .null : .num(Double(fibnum(index - 1)))),
      ("label", .str("fib(" + numstr(Double(index)) + ")=" + numstr(Double(num)))),
    ])
  }
}
