"""The system under test: a tiny Fibonacci library.

Every omni port ships this same library, with the same behaviour and the
same error messages, and tests it with the same spec file (spec/fib.json).
"""

from voxgig_omni.util import isnum, stringify


def fibindex(val):
    """Validate a Fibonacci index. The spec matches on these messages."""
    if not isnum(val):
        raise ValueError('fib: not a number: ' + stringify(val))

    if val % 1 != 0:
        raise ValueError('fib: non-integer index: ' + stringify(val))

    if val < 0:
        raise ValueError('fib: negative index: ' + stringify(val))

    return int(val)


def fib(n):
    """The nth Fibonacci number: fib(0)=0, fib(1)=1."""
    index = fibindex(n)

    if index == 0:
        return 0

    prev, cur = 0, 1

    for _i in range(1, index):
        prev, cur = cur, prev + cur

    return cur


def fibseq(n):
    """The first n Fibonacci numbers."""
    count = fibindex(n)
    return [fib(i) for i in range(count)]


def fibrange(start, end):
    """The Fibonacci numbers from index start to index end, inclusive."""
    from_index = fibindex(start)
    to_index = fibindex(end)
    return [fib(i) for i in range(from_index, to_index + 1)]


def fibinfo(n):
    """A description of the nth Fibonacci number.

    `prev` is None at index 0, which exercises the runner's null handling.
    """
    index = fibindex(n)
    val = fib(index)

    return {
        'n': index,
        'val': val,
        'even': val % 2 == 0,
        'prev': None if index == 0 else fib(index - 1),
        'label': 'fib(' + stringify(index) + ')=' + stringify(val),
    }
