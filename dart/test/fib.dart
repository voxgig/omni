// The system under test: a tiny Fibonacci library.
//
// Every omni port ships this same library, with the same behaviour and the
// same error messages, and tests it with the same spec file
// (spec/fib.json).

import '../lib/util.dart';

/// Validate a Fibonacci index. The spec matches on these messages.
int fibindex(dynamic val) {
  if (!isnum(val)) {
    throw Exception('fib: not a number: ${stringify(val)}');
  }

  final numval = (val as num).toDouble();

  if (numval != numval.truncateToDouble()) {
    throw Exception('fib: non-integer index: ${stringify(val)}');
  }

  if (0 > numval) {
    throw Exception('fib: negative index: ${stringify(val)}');
  }

  return numval.toInt();
}

/// The nth Fibonacci number: fib(0)=0, fib(1)=1.
int fibnum(int index) {
  if (0 == index) {
    return 0;
  }

  var prev = 0;
  var cur = 1;

  for (var step = 1; step < index; step++) {
    final next = prev + cur;
    prev = cur;
    cur = next;
  }

  return cur;
}

int fib(dynamic n) => fibnum(fibindex(n));

/// The first n Fibonacci numbers.
List<dynamic> fibseq(dynamic n) {
  final count = fibindex(n);
  return [for (var index = 0; index < count; index++) fibnum(index)];
}

/// The Fibonacci numbers from index start to index end, inclusive.
List<dynamic> fibrange(dynamic start, dynamic end) {
  final from = fibindex(start);
  final to = fibindex(end);
  return [for (var index = from; index <= to; index++) fibnum(index)];
}

/// A description of the nth Fibonacci number. `prev` is null at index 0,
/// which exercises the runner's null handling.
Map<String, dynamic> fibinfo(dynamic n) {
  final index = fibindex(n);
  final val = fibnum(index);

  return {
    'n': index,
    'val': val,
    'even': 0 == val % 2,
    'prev': 0 == index ? null : fibnum(index - 1),
    'label': 'fib(${numstr(index)})=${numstr(val)}',
  };
}
