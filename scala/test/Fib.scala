// The system under test: a tiny Fibonacci library.
//
// Every omni port ships this same library, with the same behaviour and the
// same error messages, and tests it with the same spec file
// (spec/fib.json).

package voxgig.omni.test

import voxgig.omni.{Json, Util}

/** The Fibonacci library's own error type. A subject must never throw the
  * runner's OmniError - that type is reserved for test failures.
  */
class FibError(message: String) extends RuntimeException(message)

object Fib:

  /** Validate a Fibonacci index. The spec matches on these messages. */
  def fibindex(value: Json): Long =
    val num = value.asnum.getOrElse {
      throw FibError("fib: not a number: " + Util.stringify(value))
    }

    if num != num.toLong.toDouble then
      throw FibError("fib: non-integer index: " + Util.stringify(value))

    if 0 > num then throw FibError("fib: negative index: " + Util.stringify(value))

    num.toLong

  /** The nth Fibonacci number: fib(0)=0, fib(1)=1. */
  def fibnum(index: Long): Long =
    if 0L == index then return 0L

    var prev = 0L
    var cur = 1L

    for _ <- 1L until index do
      val next = prev + cur
      prev = cur
      cur = next

    cur

  def fib(value: Json): Json = Json.num(fibnum(fibindex(value)).toDouble)

  /** The first n Fibonacci numbers. */
  def fibseq(value: Json): Json =
    val count = fibindex(value)
    Json.JList((0L until count).map(index => Json.num(fibnum(index).toDouble)).toList)

  /** The Fibonacci numbers from index start to index end, inclusive. */
  def fibrange(start: Json, end: Json): Json =
    val from = fibindex(start)
    val to = fibindex(end)
    Json.JList((from to to).map(index => Json.num(fibnum(index).toDouble)).toList)

  /** A description of the nth Fibonacci number. `prev` is null at index 0,
    * which exercises the runner's null handling.
    */
  def fibinfo(value: Json): Json =
    val index = fibindex(value)
    val num = fibnum(index)

    Json.map(
      "n" -> Json.num(index.toDouble),
      "val" -> Json.num(num.toDouble),
      "even" -> Json.Bool(0L == num % 2),
      "prev" -> (if 0L == index then Json.Null else Json.num(fibnum(index - 1).toDouble)),
      "label" -> Json.str(
        "fib(" + Util.numstr(index.toDouble) + ")=" + Util.numstr(num.toDouble)
      ),
    )
