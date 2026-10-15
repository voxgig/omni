// RUN: go test -run 'TestExt' ./...
//
// The capability suite: spec/ext.json requires ctxargs, fn and wait, and
// every port that carries them runs it, beside the runner flag `all`.

package omni_test

import (
	"regexp"
	"slices"
	"testing"

	omni "github.com/voxgig/omni/go"
	"github.com/voxgig/omni/go/fib"
)

func extprovider() *omni.Provider {
	subjects := map[string]omni.Subject{
		"fib": FIB, "fibseq": FIBSEQ, "fibrange": FIBRANGE, "fibinfo": FIBINFO,
	}
	return &omni.Provider{
		Subject: func(name string) omni.Subject { return subjects[name] },
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

// The ctxargs subject: the context comes first, and must arrive
// contextified with its client attached.
var FIBSHIFTED = omni.Subject(func(args ...any) (any, error) {
	ctx, _ := args[0].(map[string]any)
	if "CTX" != ctx["mark"] || nil == ctx["client"] {
		return nil, &fibfault{"fib: context not delivered"}
	}
	shift, _ := omni.ToNum(ctx["shift"])
	start, _ := omni.ToNum(args[1])
	end, _ := omni.ToNum(args[2])
	return fib.FibRange(start+shift, end+shift)
})

type fibfault struct{ msg string }

func (fault *fibfault) Error() string { return fault.msg }

func extrunner(t *testing.T, spec any) *omni.RunPack {
	t.Helper()
	runner, err := omni.MakeRunner(spec, extprovider())
	if nil != err {
		t.Fatalf("omni: %v", err)
	}
	pack, err := runner("fib", nil)
	if nil != err {
		t.Fatalf("omni: %v", err)
	}
	return pack
}

func refuses(t *testing.T, err error, pattern string) {
	t.Helper()
	if nil == err || !omni.IsOmniError(err) || !regexp.MustCompile(pattern).MatchString(err.Error()) {
		t.Fatalf("expected an OmniError matching %q, got: %v", pattern, err)
	}
}

func v1(requires []any, set []any) any {
	return map[string]any{
		"OMNI": map[string]any{"version": 1.0, "requires": requires},
		"fib":  map[string]any{"g": map[string]any{"set": set}},
	}
}

func entry(fields ...any) map[string]any {
	out := map[string]any{}
	for i := 0; i < len(fields); i += 2 {
		out[fields[i].(string)] = fields[i+1]
	}
	return out
}

func TestExt(t *testing.T) {
	R := extrunner(t, specfile(t, "ext.json"))

	t.Run("capabilities", func(t *testing.T) {
		for _, cap := range []string{"ctxargs", "fn", "wait"} {
			if !slices.Contains(omni.CAPABILITIES, cap) {
				t.Fatalf("missing capability: %s", cap)
			}
		}
	})

	for _, group := range []struct {
		name    string
		subject omni.Subject
	}{{"ctxargs", FIBSHIFTED}, {"fn", FIB}, {"wait", FIB}} {
		t.Run(group.name, func(t *testing.T) {
			if err := R.RunSet(R.Set(group.name), group.subject); nil != err {
				t.Fatal(err)
			}
		})
	}
}

func TestExtRunner(t *testing.T) {
	g := func(R *omni.RunPack) any { return R.Set("g") }

	t.Run("a waiting entry that passes fails the set", func(t *testing.T) {
		R := extrunner(t, v1([]any{"wait"}, []any{
			entry("in", 5.0, "out", 5.0, "wait", map[string]any{"cause": "gone#1"})}))
		refuses(t, R.RunSet(g(R), FIB), `\[0\]: stale wait: gone#1`)
	})

	t.Run("the wait flag holds an entry by id", func(t *testing.T) {
		R := extrunner(t, v1([]any{}, []any{
			entry("id", "a", "in", 6.0, "out", 9.0), entry("in", 7.0, "out", 13.0)}))
		flags := omni.Flags{"wait": map[string]any{"a": map[string]any{"cause": "flag#1"}}}
		if err := R.RunSetFlags(g(R), flags, FIB); nil != err {
			t.Fatal(err)
		}
	})

	t.Run("the wait flag fails when its entry passes", func(t *testing.T) {
		R := extrunner(t, v1([]any{}, []any{entry("id", "a", "in", 6.0, "out", 8.0)}))
		flags := omni.Flags{"wait": map[string]any{"a": map[string]any{"cause": "flag#1"}}}
		refuses(t, R.RunSetFlags(g(R), flags, FIB), `stale wait: flag#1`)
	})

	t.Run("the wait flag must name an entry", func(t *testing.T) {
		R := extrunner(t, v1([]any{}, []any{entry("id", "a", "in", 6.0, "out", 8.0)}))
		flags := omni.Flags{"wait": map[string]any{"zz": map[string]any{"cause": "c"}}}
		refuses(t, R.RunSetFlags(g(R), flags, FIB), `wait names no entry: zz`)
	})

	t.Run("a wait needs a cause", func(t *testing.T) {
		R := extrunner(t, v1([]any{"wait"}, []any{
			entry("in", 6.0, "out", 9.0, "wait", map[string]any{})}))
		refuses(t, R.RunSet(g(R), FIB), `entry wait has no cause`)
	})

	t.Run("wait and fn are unknown fields unless required", func(t *testing.T) {
		W := extrunner(t, v1([]any{}, []any{
			entry("in", 6.0, "out", 9.0, "wait", map[string]any{"cause": "c"})}))
		refuses(t, W.RunSet(g(W), FIB), `unknown entry field: wait`)
		F := extrunner(t, v1([]any{}, []any{entry("fn", "fib", "in", 6.0, "out", 8.0)}))
		refuses(t, F.RunSet(g(F), FIB), `unknown entry field: fn`)
	})

	t.Run("an unknown fn is a spec error", func(t *testing.T) {
		R := extrunner(t, v1([]any{"fn"}, []any{entry("fn", "nope", "in", 6.0, "out", 8.0)}))
		refuses(t, R.RunSet(g(R), FIB), `unknown fn: nope`)
	})

	t.Run("ctx with args needs ctxargs, and never takes in", func(t *testing.T) {
		N := extrunner(t, v1([]any{}, []any{
			entry("ctx", map[string]any{"shift": 0.0}, "args", []any{0.0, 1.0}, "out", []any{0.0, 1.0})}))
		refuses(t, N.RunSet(g(N), FIBSHIFTED), `more than one of in, args, ctx`)
		I := extrunner(t, v1([]any{"ctxargs"}, []any{
			entry("in", 1.0, "ctx", map[string]any{"shift": 0.0}, "out", []any{0.0})}))
		refuses(t, I.RunSet(g(I), FIBSHIFTED), `entry has in beside args or ctx`)
	})

	t.Run("all reports every failure at once", func(t *testing.T) {
		R := extrunner(t, v1([]any{}, []any{
			entry("in", 5.0, "out", 6.0), entry("in", 6.0, "out", 8.0), entry("in", 7.0, "out", 14.0)}))
		refuses(t, R.RunSetFlags(g(R), omni.Flags{"all": true}, FIB),
			`(?s)^omni: fib: 2 of 3 entries failed\n.*fib\[0\]: result mismatch.*fib\[2\]: result mismatch`)
		refuses(t, R.RunSet(g(R), FIB), `^omni: fib\[0\]: result mismatch`)
	})
}
