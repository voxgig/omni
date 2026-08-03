// RUN: go test ./...
// RUN-SOME: go test -run 'TestFib/basic'
//
// The Fibonacci conformance suite: every omni port runs this same set of
// groups, from the same spec/fib.json, against the same fib library.

package omni_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	omni "github.com/voxgig/omni/go"
	"github.com/voxgig/omni/go/fib"
)

// Find the shared spec directory by walking up from the working directory.
func specfile(t *testing.T, name string) string {
	t.Helper()

	dir, err := os.Getwd()
	if nil != err {
		t.Fatalf("omni: no working directory: %v", err)
	}

	for i := 0; i < 8; i++ {
		cand := filepath.Join(dir, "spec", name)
		if _, err := os.Stat(cand); nil == err {
			return cand
		}
		dir = filepath.Dir(dir)
	}

	t.Fatalf("omni: spec not found: %s", name)
	return ""
}

// The subjects, adapted to the omni calling convention.
var (
	FIB = omni.Subject(func(args ...any) (any, error) {
		return fib.Fib(args[0])
	})
	FIBSEQ = omni.Subject(func(args ...any) (any, error) {
		return fib.FibSeq(args[0])
	})
	FIBRANGE = omni.Subject(func(args ...any) (any, error) {
		return fib.FibRange(args[0], args[1])
	})
	FIBINFO = omni.Subject(func(args ...any) (any, error) {
		return fib.FibInfo(args[0])
	})
)

// The provider hosts the system under test. `shift` offsets the Fibonacci
// index, so that a client-specific subject is observably different.
func fibprovider(shift float64) *omni.Provider {
	subjects := map[string]omni.Subject{
		"fib": func(args ...any) (any, error) {
			if num, is := omni.ToNum(args[0]); is {
				return fib.Fib(num + shift)
			}
			return fib.Fib(args[0])
		},
		"fibseq":   FIBSEQ,
		"fibrange": FIBRANGE,
		"fibinfo":  FIBINFO,
	}

	return &omni.Provider{
		Subject: func(name string) omni.Subject {
			return subjects[name]
		},
		Client: func(options any) (*omni.Provider, error) {
			shift := 0.0
			if optmap, is := options.(map[string]any); is {
				if num, is := omni.ToNum(optmap["shift"]); is {
					shift = num
				}
			}
			return fibprovider(shift), nil
		},
	}
}

func TestFib(t *testing.T) {
	runner, err := omni.MakeRunner(specfile(t, "fib.json"), fibprovider(0))
	if nil != err {
		t.Fatalf("omni: cannot make runner: %v", err)
	}

	R, err := runner("fib", nil)
	if nil != err {
		t.Fatalf("omni: cannot resolve spec: %v", err)
	}

	groups := []struct {
		name    string
		subject omni.Subject
		flags   omni.Flags
	}{
		{"basic", FIB, nil},
		{"seq", FIBSEQ, nil},
		{"range", FIBRANGE, nil},
		{"info", FIBINFO, nil},
		{"nulls", FIBINFO, omni.Flags{"null": false}},
		{"error", FIB, nil},
		{"match", FIB, nil},
		{"matchinfo", FIBINFO, nil},
		{"client", FIB, nil},
	}

	for _, group := range groups {
		t.Run(group.name, func(t *testing.T) {
			flags := group.flags
			if nil == flags {
				flags = omni.Flags{}
			}
			if err := R.RunSetFlags(R.Set(group.name), flags, group.subject); nil != err {
				t.Fatal(err)
			}
		})
	}
}

// The runner must fail when the subject is wrong - otherwise a green suite
// means nothing.
func TestRunner(t *testing.T) {
	badspec := map[string]any{
		"fib": map[string]any{
			"wrongout": map[string]any{"set": []any{
				map[string]any{"in": 5.0, "out": 5.0},
				map[string]any{"in": 6.0, "out": 999.0},
			}},
			"wrongerr": map[string]any{"set": []any{
				map[string]any{"in": 1.0, "err": "never happens"},
			}},
			"wrongmatch": map[string]any{"set": []any{
				map[string]any{"in": 6.0, "match": map[string]any{"out": 999.0}},
			}},
			"missing": map[string]any{"set": []any{
				map[string]any{"in": 6.0, "match": map[string]any{
					"out": map[string]any{"nope": "__EXISTS__"},
				}},
			}},
		},
	}

	expectfail := func(t *testing.T, setname string, subject omni.Subject) {
		t.Helper()

		runner, err := omni.MakeRunner(badspec, nil)
		if nil != err {
			t.Fatalf("omni: cannot make runner: %v", err)
		}
		R, err := runner("fib", nil)
		if nil != err {
			t.Fatalf("omni: cannot resolve spec: %v", err)
		}

		err = R.RunSet(R.Set(setname), subject)
		if nil == err {
			t.Fatalf("omni: expected failure for set: %s", setname)
		}
		if !omni.IsOmniError(err) {
			t.Fatalf("omni: expected OmniError, got: %v", err)
		}
	}

	t.Run("detects wrong result", func(t *testing.T) { expectfail(t, "wrongout", FIB) })
	t.Run("detects missing error", func(t *testing.T) { expectfail(t, "wrongerr", FIB) })
	t.Run("detects failed match", func(t *testing.T) { expectfail(t, "wrongmatch", FIB) })
	t.Run("detects absent key", func(t *testing.T) { expectfail(t, "missing", FIBINFO) })

	t.Run("reports entry index and id", func(t *testing.T) {
		runner, err := omni.MakeRunner(map[string]any{
			"fib": map[string]any{"g": map[string]any{"set": []any{
				map[string]any{"in": 1.0, "out": 1.0},
				map[string]any{"id": "x#2", "in": 2.0, "out": 42.0},
			}}},
		}, nil)
		if nil != err {
			t.Fatalf("omni: cannot make runner: %v", err)
		}

		R, err := runner("fib", nil)
		if nil != err {
			t.Fatalf("omni: cannot resolve spec: %v", err)
		}

		err = R.RunSet(R.Set("g"), FIB)
		if nil == err {
			t.Fatal("omni: expected failure")
		}

		for _, want := range []string{"fib[1] (x#2)", "expected: 42", "actual:   1"} {
			if !strings.Contains(err.Error(), want) {
				t.Fatalf("omni: message missing [%s]: %s", want, err.Error())
			}
		}
	})
}
