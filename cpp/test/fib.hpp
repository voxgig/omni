// The system under test: a tiny Fibonacci library.
//
// Every omni port ships this same library, with the same behaviour and the
// same error messages, and tests it with the same spec file
// (spec/fib.json).

#ifndef VOXGIG_OMNI_FIB_HPP
#define VOXGIG_OMNI_FIB_HPP

#include <cmath>
#include <stdexcept>
#include <string>

#include "../src/omni.hpp"

namespace fib {

// Validate a Fibonacci index. Errors are part of the contract: the spec
// matches on these messages.
inline long fibindex(const omni::Json& val) {
  if (!val.isnum()) {
    throw std::runtime_error("fib: not a number: " + omni::stringify(val));
  }

  double num = val.numval;

  if (num != std::floor(num)) {
    throw std::runtime_error("fib: non-integer index: " + omni::stringify(val));
  }

  if (0 > num) {
    throw std::runtime_error("fib: negative index: " + omni::stringify(val));
  }

  return static_cast<long>(num);
}

// The nth Fibonacci number: fib(0)=0, fib(1)=1.
inline long fibnum(long index) {
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

inline omni::Json fib(const omni::Json& val) {
  return omni::Json::num(static_cast<double>(fibnum(fibindex(val))));
}

// The first n Fibonacci numbers.
inline omni::Json fibseq(const omni::Json& val) {
  long count = fibindex(val);
  omni::Json out = omni::Json::list();

  for (long index = 0; index < count; index++) {
    out.push(omni::Json::num(static_cast<double>(fibnum(index))));
  }

  return out;
}

// The Fibonacci numbers from index start to index end, inclusive.
inline omni::Json fibrange(const omni::Json& start, const omni::Json& end) {
  long from = fibindex(start);
  long to = fibindex(end);
  omni::Json out = omni::Json::list();

  for (long index = from; index <= to; index++) {
    out.push(omni::Json::num(static_cast<double>(fibnum(index))));
  }

  return out;
}

// A description of the nth Fibonacci number. `prev` is null at index 0,
// which exercises the runner's null handling.
inline omni::Json fibinfo(const omni::Json& val) {
  long index = fibindex(val);
  long num = fibnum(index);

  omni::Json out = omni::Json::map();
  out.set("n", omni::Json::num(static_cast<double>(index)));
  out.set("val", omni::Json::num(static_cast<double>(num)));
  out.set("even", omni::Json::boolean(0 == num % 2));
  out.set("prev", 0 == index ? omni::Json::null()
                             : omni::Json::num(static_cast<double>(fibnum(index - 1))));
  out.set("label", omni::Json::str("fib(" + omni::numstr(static_cast<double>(index)) + ")=" +
                                   omni::numstr(static_cast<double>(num))));

  return out;
}

}  // namespace fib

#endif  // VOXGIG_OMNI_FIB_HPP
