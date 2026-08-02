# The system under test: a tiny Fibonacci library.
#
# Every omni port ships this same library, with the same behaviour and the
# same error messages, and tests it with the same spec file
# (spec/fib.json).

require_relative '../lib/voxgig_omni'

module Fib
  U = VoxgigOmni::Util

  module_function

  # Validate a Fibonacci index. The spec matches on these messages.
  def fibindex(val)
    raise 'fib: not a number: ' + U.stringify(val) unless U.isnum(val)
    raise 'fib: non-integer index: ' + U.stringify(val) if val % 1 != 0
    raise 'fib: negative index: ' + U.stringify(val) if val.negative?

    val.to_i
  end

  # The nth Fibonacci number: fib(0)=0, fib(1)=1.
  def fib(n)
    index = fibindex(n)
    return 0 if index.zero?

    prev = 0
    cur = 1

    (1...index).each do
      prev, cur = cur, prev + cur
    end

    cur
  end

  # The first n Fibonacci numbers.
  def fibseq(n)
    count = fibindex(n)
    (0...count).map { |i| fib(i) }
  end

  # The Fibonacci numbers from index start to index end, inclusive.
  def fibrange(start, last)
    from = fibindex(start)
    to = fibindex(last)
    (from..to).map { |i| fib(i) }
  end

  # A description of the nth Fibonacci number. `prev` is nil at index 0,
  # which exercises the runner's null handling.
  def fibinfo(n)
    index = fibindex(n)
    val = fib(index)

    {
      'n' => index,
      'val' => val,
      'even' => (val % 2).zero?,
      'prev' => index.zero? ? nil : fib(index - 1),
      'label' => 'fib(' + U.stringify(index) + ')=' + U.stringify(val)
    }
  end
end
