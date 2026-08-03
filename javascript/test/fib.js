// The system under test: a tiny Fibonacci library.
//
// Every omni port ships this same library, with the same behaviour and the
// same error messages, and tests it with the same spec file
// (spec/fib.json).

const { stringify } = require('../src/util')

// Validate a Fibonacci index. Errors are part of the contract: the spec
// matches on these messages.
function fibindex(val) {
  if ('number' !== typeof val || !isFinite(val)) {
    throw new Error('fib: not a number: ' + stringify(val))
  }

  if (0 !== val % 1) {
    throw new Error('fib: non-integer index: ' + stringify(val))
  }

  if (val < 0) {
    throw new Error('fib: negative index: ' + stringify(val))
  }

  return val
}

// The nth Fibonacci number: fib(0)=0, fib(1)=1, fib(n)=fib(n-1)+fib(n-2).
function fib(n) {
  const index = fibindex(n)

  let prev = 0
  let cur = 1

  if (0 === index) {
    return 0
  }

  for (let i = 1; i < index; i++) {
    const next = prev + cur
    prev = cur
    cur = next
  }

  return cur
}

// The first n Fibonacci numbers.
function fibseq(n) {
  const count = fibindex(n)
  const out = []

  for (let i = 0; i < count; i++) {
    out.push(fib(i))
  }

  return out
}

// The Fibonacci numbers from index start to index end, inclusive.
function fibrange(start, end) {
  const from = fibindex(start)
  const to = fibindex(end)
  const out = []

  for (let i = from; i <= to; i++) {
    out.push(fib(i))
  }

  return out
}

// A description of the nth Fibonacci number. `prev` is null at index 0,
// which exercises the runner's null handling.
function fibinfo(n) {
  const index = fibindex(n)
  const val = fib(index)

  return {
    n: index,
    val,
    even: 0 === val % 2,
    prev: 0 === index ? null : fib(index - 1),
    label: 'fib(' + stringify(index) + ')=' + stringify(val),
  }
}

module.exports = { fib, fibindex, fibinfo, fibrange, fibseq }
