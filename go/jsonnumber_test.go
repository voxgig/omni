// A spec decoded with json.Decoder.UseNumber holds json.Number values, and
// those are numbers to every util and to the runner.

package omni_test

import (
	"encoding/json"
	"math"
	"strings"
	"testing"

	omni "github.com/voxgig/omni/go"
)

func TestJsonNumberDeepEqual(t *testing.T) {
	equal := [][2]any{
		{json.Number("1"), json.Number("1.0")},
		{json.Number("1"), 1.0},
		{1, json.Number("1e0")},
		{[]any{json.Number("2")}, []any{2}},
		{map[string]any{"a": json.Number("0.5")}, map[string]any{"a": 0.5}},
		{json.Number("1e400"), math.Inf(1)},
	}
	for _, pair := range equal {
		if !omni.DeepEqual(pair[0], pair[1]) {
			t.Errorf("DeepEqual(%#v, %#v) must be true", pair[0], pair[1])
		}
	}

	unequal := [][2]any{
		{json.Number("1"), "1"},
		{json.Number("1"), json.Number("2")},
		{json.Number("1"), true},
		{json.Number("0"), nil},
	}
	for _, pair := range unequal {
		if omni.DeepEqual(pair[0], pair[1]) {
			t.Errorf("DeepEqual(%#v, %#v) must be false", pair[0], pair[1])
		}
	}
}

func TestJsonNumberJsonStr(t *testing.T) {
	cases := []struct {
		val  any
		want string
	}{
		{json.Number("4"), "4"},
		{json.Number("4.0"), "4"},
		{json.Number("-2.5"), "-2.5"},
		{json.Number("1e400"), "null"},
		{map[string]any{"offset": json.Number("4")}, `{"offset":4}`},
	}
	for _, c := range cases {
		if got := omni.JsonStr(c.val); c.want != got {
			t.Errorf("JsonStr(%#v) = %s, want %s", c.val, got, c.want)
		}
	}

	if got := omni.Stringify(json.Number("4.0")); "4" != got {
		t.Errorf("Stringify(json.Number(\"4.0\")) = %s, want 4", got)
	}
	if got := omni.PathIfy([]any{"a", json.Number("1")}); "a.1" != got {
		t.Errorf("PathIfy with a json.Number = %s, want a.1", got)
	}
	if got := omni.GetPath([]any{"x", "y"}, []any{json.Number("1")}); "y" != got {
		t.Errorf("GetPath with a json.Number index = %#v, want y", got)
	}
	for _, index := range []any{json.Number("1.5"), 1.5} {
		if got := omni.GetPath([]any{"x", "y"}, []any{index}); !omni.IsAbsent(got) {
			t.Errorf("GetPath with the fractional index %#v = %#v, want absent", index, got)
		}
	}
}

func usenumberspec(t *testing.T, text string) any {
	t.Helper()
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	var spec any
	if err := decoder.Decode(&spec); nil != err {
		t.Fatalf("decode: %v", err)
	}
	return spec
}

func TestJsonNumberRunner(t *testing.T) {
	offset := omni.Subject(func(args ...any) (any, error) {
		num, _ := omni.ToNum(args[0])
		return map[string]any{"offset": num + 1}, nil
	})

	R := providerrunner(t, usenumberspec(t,
		`{"fib":{"g":{"set":[{"in":3,"out":{"offset":4.0}}]}}}`), nil)
	if err := R.RunSet(R.Set("g"), offset); nil != err {
		t.Fatalf("a json.Number out must equal the float result: %v", err)
	}

	R = providerrunner(t, usenumberspec(t,
		`{"fib":{"g":{"set":[{"in":3,"out":{"offset":5}}]}}}`), nil)
	err := R.RunSet(R.Set("g"), offset)
	if nil == err {
		t.Fatal("a wrong json.Number out must still FAIL")
	}
	if !strings.Contains(err.Error(), `{"offset":5}`) || strings.Contains(err.Error(), `"5"`) {
		t.Fatalf("the expected number must print unquoted: %v", err)
	}
}
