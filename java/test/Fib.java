// The system under test: a tiny Fibonacci library.
//
// Every omni port ships this same library, with the same behaviour and the
// same error messages, and tests it with the same spec file
// (spec/fib.json).

import com.voxgig.omni.Util;
import java.util.LinkedHashMap;
import java.util.Map;

public final class Fib {

  private Fib() {}

  /** Validate a Fibonacci index. The spec matches on these messages. */
  public static long fibindex(Object val) {
    if (!Util.isnum(val)) {
      throw new IllegalArgumentException("fib: not a number: " + Util.stringify(val));
    }

    double num = ((Number) val).doubleValue();

    if (num != Math.rint(num)) {
      throw new IllegalArgumentException("fib: non-integer index: " + Util.stringify(val));
    }

    if (num < 0) {
      throw new IllegalArgumentException("fib: negative index: " + Util.stringify(val));
    }

    return (long) num;
  }

  /** The nth Fibonacci number: fib(0)=0, fib(1)=1. */
  public static long fib(Object n) {
    return fibnum(fibindex(n));
  }

  public static long fibnum(long index) {
    if (0 == index) {
      return 0;
    }

    long prev = 0;
    long cur = 1;

    for (long step = 1; step < index; step++) {
      long next = prev + cur;
      prev = cur;
      cur = next;
    }

    return cur;
  }

  /** The first n Fibonacci numbers. */
  public static Object fibseq(Object n) {
    long count = fibindex(n);
    java.util.List<Object> out = new java.util.ArrayList<>();
    for (long index = 0; index < count; index++) {
      out.add(fibnum(index));
    }
    return out;
  }

  /** The Fibonacci numbers from index start to index end, inclusive. */
  public static Object fibrange(Object start, Object end) {
    long from = fibindex(start);
    long to = fibindex(end);
    java.util.List<Object> out = new java.util.ArrayList<>();
    for (long index = from; index <= to; index++) {
      out.add(fibnum(index));
    }
    return out;
  }

  /**
   * A description of the nth Fibonacci number. `prev` is null at index 0,
   * which exercises the runner's null handling.
   */
  public static Object fibinfo(Object n) {
    long index = fibindex(n);
    long val = fibnum(index);

    Map<String, Object> out = new LinkedHashMap<>();
    out.put("n", index);
    out.put("val", val);
    out.put("even", 0 == val % 2);
    out.put("prev", 0 == index ? null : fibnum(index - 1));
    out.put("label", "fib(" + Util.numstr(index) + ")=" + Util.numstr(val));

    return out;
  }
}
