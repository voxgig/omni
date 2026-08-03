// The system under test: a tiny Fibonacci library.
//
// Every omni port ships this same library, with the same behaviour and the
// same error messages, and tests it with the same spec file
// (spec/fib.json).

package voxgig.omni.test

import voxgig.omni.Json
import voxgig.omni.numstr
import voxgig.omni.stringify
import kotlin.math.truncate

/**
 * The Fibonacci library's own error type. A subject must never throw the
 * runner's OmniError - that type is reserved for test failures.
 */
class FibError(message: String) : RuntimeException(message)

object Fib {
    /** Validate a Fibonacci index. The spec matches on these messages. */
    fun fibindex(value: Json): Long {
        val num = value.asnum ?: throw FibError("fib: not a number: " + stringify(value))

        if (num != truncate(num)) {
            throw FibError("fib: non-integer index: " + stringify(value))
        }

        if (0 > num) {
            throw FibError("fib: negative index: " + stringify(value))
        }

        return num.toLong()
    }

    /** The nth Fibonacci number: fib(0)=0, fib(1)=1. */
    fun fibnum(index: Long): Long {
        if (0L == index) {
            return 0L
        }

        var prev = 0L
        var cur = 1L

        for (step in 1 until index) {
            val next = prev + cur
            prev = cur
            cur = next
        }

        return cur
    }

    fun fib(value: Json): Json = Json.num(fibnum(fibindex(value)))

    /** The first n Fibonacci numbers. */
    fun fibseq(value: Json): Json {
        val count = fibindex(value)
        val out = mutableListOf<Json>()
        for (index in 0 until count) {
            out.add(Json.num(fibnum(index)))
        }
        return Json.JList(out)
    }

    /** The Fibonacci numbers from index start to index end, inclusive. */
    fun fibrange(start: Json, end: Json): Json {
        val from = fibindex(start)
        val to = fibindex(end)
        val out = mutableListOf<Json>()
        for (index in from..to) {
            out.add(Json.num(fibnum(index)))
        }
        return Json.JList(out)
    }

    /**
     * A description of the nth Fibonacci number. `prev` is null at index 0,
     * which exercises the runner's null handling.
     */
    fun fibinfo(value: Json): Json {
        val index = fibindex(value)
        val num = fibnum(index)

        return Json.map(
            "n" to Json.num(index),
            "val" to Json.num(num),
            "even" to Json.Bool(0L == num % 2),
            "prev" to if (0L == index) Json.Null else Json.num(fibnum(index - 1)),
            "label" to Json.str("fib(" + numstr(index.toDouble()) + ")=" + numstr(num.toDouble())),
        )
    }
}
