package omni

// Regression pins for the runner fixes ported from the typescript
// reference (the "omni#54" set): a cyclic match base must not blow the
// stack, JsonStr must render a cycle as [Circular] while a DAG still
// renders in full. Each of these went red on the unfixed code.

import (
	"strings"
	"testing"
)

func TestMatchCyclicBase(t *testing.T) {
	base := map[string]any{"name": "ctx"}
	base["self"] = base // a live client context reaches itself

	entry := map[string]any{"id": "cyc"}
	flags := Flags{}

	if err := Match(flags, 0, entry, map[string]any{"name": "ctx"}, base); nil != err {
		t.Fatalf("a cyclic base must still match on its plain leaves: %v", err)
	}

	err := Match(flags, 0, entry, map[string]any{"name": "wrong"}, base)
	if nil == err {
		t.Fatal("a mismatch on a cyclic base must still FAIL")
	}
}

func TestJsonStrCycle(t *testing.T) {
	cyc := map[string]any{"a": 1}
	cyc["me"] = cyc

	out := JsonStr(cyc)
	if !strings.Contains(out, "[Circular]") {
		t.Fatalf("a cycle must render as [Circular], got %s", out)
	}

	// A DAG - the same object as two siblings - is NOT a cycle and must
	// render in full both times.
	leaf := map[string]any{"x": 1}
	dag := map[string]any{"a": leaf, "b": leaf}
	out = JsonStr(dag)
	if strings.Contains(out, "[Circular]") {
		t.Fatalf("a DAG must render in full, got %s", out)
	}
	if 2 != strings.Count(out, `"x":1`) {
		t.Fatalf("both DAG siblings must render, got %s", out)
	}
}
