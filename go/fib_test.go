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
	// The context-group subject: reports what the runner delivered - the
	// contextify mark and the attached client - as plain data, so the spec
	// can pin both with an ordinary `out` comparison in every port.
	// A subject that returns the sentinel text "__UNDEF__" as ordinary data.
	// A match of `{"__UNDEF__"}` asserts the key is ABSENT, so it must not be
	// satisfied by a present key that happens to hold that literal string.
	FIBUNDEFLIT = omni.Subject(func(args ...any) (any, error) {
		return map[string]any{"a": "__UNDEF__"}, nil
	})
	FIBCTX = omni.Subject(func(args ...any) (any, error) {
		ctx, _ := args[0].(map[string]any)
		val, err := fib.Fib(ctx["n"])
		if nil != err {
			return nil, err
		}
		return map[string]any{
			"n":         ctx["n"],
			"val":       val,
			"mark":      ctx["mark"],
			"hasclient": nil != ctx["client"],
		}, nil
	})
)

// The provider hosts the system under test. `shift` offsets the Fibonacci
// index, so that a client-specific subject is observably different.
// `contextify` marks the map, so the context group can prove the hook ran.
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
		Contextify: func(val any) any {
			base, is := val.(map[string]any)
			if !is {
				return val
			}
			out := make(map[string]any, len(base)+1)
			for key, entry := range base {
				out[key] = entry
			}
			out["mark"] = "CTX"
			return out
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
		{"context", FIBCTX, nil},
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
			// A concrete match leaf against a missing key must fail, not
			// substring-match the text "undefined".
			"matchabsent": map[string]any{"set": []any{
				map[string]any{"in": 6.0, "match": map[string]any{
					"out": map[string]any{"nope": "fine"},
				}},
			}},
			// __UNDEF__ (absent) must not be satisfied by a present null.
			"undefonnull": map[string]any{"set": []any{
				map[string]any{"in": 0.0, "match": map[string]any{
					"out": map[string]any{"prev": "__UNDEF__"},
				}},
			}},
			// __NULL__ (present null) must not be satisfied by an absent key.
			"nullonabsent": map[string]any{"set": []any{
				map[string]any{"in": 6.0, "match": map[string]any{
					"out": map[string]any{"nope": "__NULL__"},
				}},
			}},
			// __UNDEF__ (absent) must not be satisfied by a present key
			// holding the literal string "__UNDEF__" as data.
			"wrongundef": map[string]any{"set": []any{
				map[string]any{"in": 1.0, "match": map[string]any{
					"out": map[string]any{"a": "__UNDEF__"},
				}},
			}},
			// An empty-string want is not a wildcard substring match.
			"emptystr": map[string]any{"set": []any{
				map[string]any{"in": 6.0, "match": map[string]any{
					"out": map[string]any{"label": ""},
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

	t.Run("a concrete match leaf does not match a missing key",
		func(t *testing.T) { expectfail(t, "matchabsent", FIBINFO) })
	t.Run("__UNDEF__ does not match a present null",
		func(t *testing.T) { expectfail(t, "undefonnull", FIBINFO) })
	t.Run("__NULL__ does not match an absent key",
		func(t *testing.T) { expectfail(t, "nullonabsent", FIBINFO) })
	t.Run("an empty-string match leaf is not a wildcard",
		func(t *testing.T) { expectfail(t, "emptystr", FIBINFO) })
	t.Run("__UNDEF__ does not match its own literal string",
		func(t *testing.T) { expectfail(t, "wrongundef", FIBUNDEFLIT) })

	t.Run("rejects an unsupported spec version", func(t *testing.T) {
		_, err := omni.MakeRunner(map[string]any{
			"OMNI": map[string]any{"version": 99.0},
			"fib":  map[string]any{"g": map[string]any{"set": []any{}}},
		}, nil)
		if nil == err || !omni.IsOmniError(err) {
			t.Fatalf("omni: expected OmniError, got: %v", err)
		}
		if !strings.Contains(err.Error(), "unsupported spec version") {
			t.Fatalf("omni: unexpected message: %s", err.Error())
		}
	})

	t.Run("rejects an unknown required capability", func(t *testing.T) {
		_, err := omni.MakeRunner(map[string]any{
			"OMNI": map[string]any{"version": 1.0, "requires": []any{"nosuchfeature"}},
			"fib":  map[string]any{"g": map[string]any{"set": []any{}}},
		}, nil)
		if nil == err || !omni.IsOmniError(err) {
			t.Fatalf("omni: expected OmniError, got: %v", err)
		}
		if !strings.Contains(err.Error(), "unsupported capability") {
			t.Fatalf("omni: unexpected message: %s", err.Error())
		}
	})

	t.Run("rejects a malformed version block", func(t *testing.T) {
		_, err := omni.MakeRunner(map[string]any{
			"OMNI": map[string]any{"version": "one"},
			"fib":  map[string]any{"g": map[string]any{"set": []any{}}},
		}, nil)
		if nil == err || !omni.IsOmniError(err) {
			t.Fatalf("omni: expected OmniError, got: %v", err)
		}
		if !strings.Contains(err.Error(), "malformed OMNI") {
			t.Fatalf("omni: unexpected message: %s", err.Error())
		}
	})

	t.Run("strict: an unknown entry field fails instead of passing vacuously", func(t *testing.T) {
		runner, err := omni.MakeRunner(map[string]any{
			"OMNI": map[string]any{"version": 1.0},
			"fib": map[string]any{"g": map[string]any{"set": []any{
				map[string]any{"in": 6.0, "matches": map[string]any{"out": 999.0}},
			}}},
		}, nil)
		if nil != err {
			t.Fatalf("omni: cannot make runner: %v", err)
		}
		R, err := runner("fib", nil)
		if nil != err {
			t.Fatalf("omni: cannot resolve spec: %v", err)
		}
		err = R.RunSet(R.Set("g"), FIBINFO)
		if nil == err || !strings.Contains(err.Error(), "unknown entry field: matches") {
			t.Fatalf("omni: unexpected error: %v", err)
		}
	})

	t.Run("strict: more than one of in, args, ctx fails", func(t *testing.T) {
		runner, err := omni.MakeRunner(map[string]any{
			"OMNI": map[string]any{"version": 1.0},
			"fib": map[string]any{"g": map[string]any{"set": []any{
				map[string]any{"in": 5.0, "args": []any{5.0}, "out": 5.0},
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
		if nil == err || !strings.Contains(err.Error(), "more than one of in, args, ctx") {
			t.Fatalf("omni: unexpected error: %v", err)
		}
	})

	t.Run("strict: err together with out fails", func(t *testing.T) {
		runner, err := omni.MakeRunner(map[string]any{
			"OMNI": map[string]any{"version": 1.0},
			"fib": map[string]any{"g": map[string]any{"set": []any{
				map[string]any{"in": -1.0, "err": true, "out": 5.0},
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
		if nil == err || !strings.Contains(err.Error(), "both err and out") {
			t.Fatalf("omni: unexpected error: %v", err)
		}
	})

	t.Run("strict: a null id fails even under null-normalisation", func(t *testing.T) {
		runner, err := omni.MakeRunner(map[string]any{
			"OMNI": map[string]any{"version": 1.0},
			"fib": map[string]any{"g": map[string]any{"set": []any{
				map[string]any{"in": 1.0, "out": 1.0, "id": nil},
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
		if nil == err || !strings.Contains(err.Error(), "entry id is not a string") {
			t.Fatalf("omni: unexpected error: %v", err)
		}
	})

	t.Run("strict: an empty set fails unless marked empty", func(t *testing.T) {
		runner, err := omni.MakeRunner(map[string]any{
			"OMNI": map[string]any{"version": 1.0},
			"fib": map[string]any{
				"g": map[string]any{"set": []any{}},
				"h": map[string]any{"set": []any{}, "empty": true},
			},
		}, nil)
		if nil != err {
			t.Fatalf("omni: cannot make runner: %v", err)
		}
		R, err := runner("fib", nil)
		if nil != err {
			t.Fatalf("omni: cannot resolve spec: %v", err)
		}
		err = R.RunSet(R.Set("g"), FIB)
		if nil == err || !strings.Contains(err.Error(), "empty test set") {
			t.Fatalf("omni: unexpected error: %v", err)
		}
		if err := R.RunSet(R.Set("h"), FIB); nil != err {
			t.Fatalf("omni: unexpected error: %v", err)
		}
	})

	t.Run("a legacy spec (no OMNI block) stays lenient", func(t *testing.T) {
		runner, err := omni.MakeRunner(map[string]any{
			"fib": map[string]any{"g": map[string]any{"set": []any{
				map[string]any{"in": 6.0, "matches": map[string]any{"out": 999.0}, "out": 8.0},
			}}},
		}, nil)
		if nil != err {
			t.Fatalf("omni: cannot make runner: %v", err)
		}
		R, err := runner("fib", nil)
		if nil != err {
			t.Fatalf("omni: cannot resolve spec: %v", err)
		}
		if err := R.RunSet(R.Set("g"), FIB); nil != err {
			t.Fatalf("omni: unexpected error: %v", err)
		}
	})

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
