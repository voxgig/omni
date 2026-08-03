// The system under test: a tiny Fibonacci library.
//
// Every omni port ships this same library, with the same behaviour and the
// same error messages, and tests it with the same spec file
// (spec/fib.json).

package fib

import (
	"errors"
	"math"

	omni "github.com/voxgig/omni/go"
)

// FibIndex validates a Fibonacci index. Errors are part of the contract:
// the spec matches on these messages.
func FibIndex(val any) (int, error) {
	num, isnum := omni.ToNum(val)
	if _, isbool := val.(bool); isbool || !isnum {
		return 0, errors.New("fib: not a number: " + omni.Stringify(val))
	}

	if num != math.Trunc(num) {
		return 0, errors.New("fib: non-integer index: " + omni.Stringify(val))
	}

	if num < 0 {
		return 0, errors.New("fib: negative index: " + omni.Stringify(val))
	}

	return int(num), nil
}

// Fib is the nth Fibonacci number: fib(0)=0, fib(1)=1.
func Fib(n any) (int, error) {
	index, err := FibIndex(n)
	if nil != err {
		return 0, err
	}

	if 0 == index {
		return 0, nil
	}

	prev := 0
	cur := 1

	for i := 1; i < index; i++ {
		prev, cur = cur, prev+cur
	}

	return cur, nil
}

// FibSeq is the first n Fibonacci numbers.
func FibSeq(n any) ([]any, error) {
	count, err := FibIndex(n)
	if nil != err {
		return nil, err
	}

	out := []any{}
	for i := 0; i < count; i++ {
		val, err := Fib(i)
		if nil != err {
			return nil, err
		}
		out = append(out, val)
	}

	return out, nil
}

// FibRange is the Fibonacci numbers from index start to index end,
// inclusive.
func FibRange(start any, end any) ([]any, error) {
	from, err := FibIndex(start)
	if nil != err {
		return nil, err
	}

	to, err := FibIndex(end)
	if nil != err {
		return nil, err
	}

	out := []any{}
	for i := from; i <= to; i++ {
		val, err := Fib(i)
		if nil != err {
			return nil, err
		}
		out = append(out, val)
	}

	return out, nil
}

// FibInfo describes the nth Fibonacci number. `prev` is nil at index 0,
// which exercises the runner's null handling.
func FibInfo(n any) (map[string]any, error) {
	index, err := FibIndex(n)
	if nil != err {
		return nil, err
	}

	val, err := Fib(index)
	if nil != err {
		return nil, err
	}

	var prev any
	if 0 != index {
		prevval, err := Fib(index - 1)
		if nil != err {
			return nil, err
		}
		prev = prevval
	}

	return map[string]any{
		"n":     index,
		"val":   val,
		"even":  0 == val%2,
		"prev":  prev,
		"label": "fib(" + omni.Stringify(index) + ")=" + omni.Stringify(val),
	}, nil
}
