// Drop-in replacement for the in-situ test runner in the voxgig/struct
// repository (`go/testutil/runner.go`).
//
// struct's own runner and omni's runner implement the same spec format;
// this package exposes omni behind struct's exact runner API, so the Go
// port switches over by deleting its runner and re-exporting this package
// from `go/testutil/omni.go`. Everything else - the corpus, the SDK, the
// test files - is unchanged. This is the Go peer of
// javascript/compat/struct.js and python/voxgig_omni/compat/struct.py.
//
// The package never imports struct: a compat shim that linked the library
// under test would make omni depend on the thing it is meant to check. The
// SDK is reached by reflection instead, over the four names struct's SDK
// already exposes: Utility(), Utility().Struct(), Utility().Contextify()
// and Tester().
//
// Two shapes cannot cross the language boundary and so stay in struct's
// own test tree: `NullModifier`, whose signature names struct's
// `*voxgigstruct.Injection`, and the `Fdt`/`ToJSONString` debug helpers,
// which are not runner API at all.

package structcompat

import (
	"fmt"
	"reflect"
	"strings"

	omni "github.com/voxgig/omni/go"
)

// The sentinels, under struct's names.
var (
	NULLMARK   = omni.NULLMARK   // Value is JSON null.
	UNDEFMARK  = omni.UNDEFMARK  // Value is not present (thus, undefined).
	EXISTSMARK = omni.EXISTSMARK // Value exists (not undefined).
)

// Subject is the function under test, in struct's (and omni's) form.
type Subject = omni.Subject

// TestingT is the part of *testing.T that struct's runner API uses.
// Naming it structurally keeps `testing` out of omni's import graph.
type TestingT interface {
	Helper()
	Error(args ...any)
}

// RunSet runs one set of test entries, reporting failures to the test.
type RunSet func(t TestingT, testspec any, testsubject any)

// RunSetFlags runs one set of test entries with flags.
type RunSetFlags func(t TestingT, testspec any, flags map[string]bool, testsubject any)

// RunPack is what struct's runner returns for one named spec section.
type RunPack struct {
	Spec        map[string]any
	RunSet      RunSet
	RunSetFlags RunSetFlags
	Subject     Subject
	Client      any
}

// MakeRunner is struct's makeRunner(testfile, client) signature, backed by
// omni. struct's test files run with the package directory as the working
// directory, and pass the corpus path relative to it, so the path needs no
// further resolution.
func MakeRunner(testfile string, client any) func(name string, store any) (*RunPack, error) {
	provider := StructProvider(client)
	sentinel := structnoval(client)
	runner, mkerr := omni.MakeRunner(testfile, provider)

	return func(name string, store any) (*RunPack, error) {
		if nil != mkerr {
			return nil, mkerr
		}

		pack, err := runner(name, store)
		if nil != err {
			return nil, err
		}

		spec, _ := pack.Spec.(map[string]any)

		runsetflags := func(t TestingT, testspec any, flags map[string]bool, testsubject any) {
			t.Helper()

			subject := pack.Subject
			if nil != testsubject {
				subject = Subjectify(testsubject)
			}
			subject = novalsubject(subject, sentinel)

			spec := novalargs(fixnums(testspec), sentinel)
			if err := pack.RunSetFlags(spec, omniflags(flags), subject); nil != err {
				t.Error(err.Error())
			}
		}

		runset := func(t TestingT, testspec any, testsubject any) {
			t.Helper()
			runsetflags(t, testspec, nil, testsubject)
		}

		return &RunPack{
			Spec:        spec,
			RunSet:      runset,
			RunSetFlags: runsetflags,
			Subject:     pack.Subject,
			Client:      client,
		}, nil
	}
}

// struct's flags are booleans; omni's carry any value.
func omniflags(flags map[string]bool) omni.Flags {
	out := omni.Flags{}
	for name, flag := range flags {
		out[name] = flag
	}
	return out
}

// StructProvider wraps a struct SDK client as an omni provider. The
// original client travels on the RunPack, so test code that reaches
// through it keeps working unchanged.
func StructProvider(client any) *omni.Provider {
	return &omni.Provider{
		// struct resolves a subject from the utility, or from utility.struct.
		Subject: func(name string) omni.Subject {
			utility := utilityof(client)

			if method := findmethod(utility, name); method.IsValid() {
				return Subjectify(method.Interface())
			}

			field := findfield(structutilof(utility), name)
			if field.IsValid() && reflect.Func == field.Kind() && !field.IsNil() {
				return Subjectify(field.Interface())
			}

			return nil
		},

		// A DEF.client entry becomes another SDK instance.
		Client: func(options any) (*omni.Provider, error) {
			tester := findmethod(reflect.ValueOf(client), "tester")
			if !tester.IsValid() {
				return nil, fmt.Errorf("structcompat: client has no Tester method")
			}

			opts, is := options.(map[string]any)
			if !is {
				opts = map[string]any{}
			}

			results := tester.Call([]reflect.Value{reflect.ValueOf(opts)})
			if 2 != len(results) {
				return nil, fmt.Errorf("structcompat: Tester must return (client, error)")
			}
			if err, is := results[1].Interface().(error); is && nil != err {
				return nil, err
			}

			return StructProvider(results[0].Interface()), nil
		},

		// struct's SDK supplies its own context wrapper.
		Contextify: func(val any) any {
			utility := utilityof(client)

			ctx := val
			if hook := findmethod(utility, "contextify"); hook.IsValid() {
				if ctxmap, is := val.(map[string]any); is {
					results := hook.Call([]reflect.Value{reflect.ValueOf(ctxmap)})
					if 1 == len(results) {
						ctx = results[0].Interface()
					}
				}
			}

			if ctxmap, is := ctx.(map[string]any); is && utility.IsValid() {
				ctxmap["utility"] = utility.Interface()
			}

			return ctx
		},

		// Client options may reference the runner store.
		Inject: func(options any, store any) any {
			inject := findfield(structutilof(utilityof(client)), "inject")
			if !inject.IsValid() || reflect.Func != inject.Kind() || inject.IsNil() {
				return options
			}

			results := inject.Call([]reflect.Value{
				anyvalue(options),
				anyvalue(store),
			})
			if 0 == len(results) {
				return options
			}

			return results[0].Interface()
		},
	}
}

// A reflect.Value of static type `any`, so that a nil argument still has a
// type to be assigned to an `any` parameter.
func anyvalue(val any) reflect.Value {
	holder := reflect.New(reflect.TypeOf((*any)(nil)).Elem()).Elem()
	if nil != val {
		holder.Set(reflect.ValueOf(val))
	}
	return holder
}

func utilityof(client any) reflect.Value {
	method := findmethod(reflect.ValueOf(client), "utility")
	if !method.IsValid() {
		return reflect.Value{}
	}

	results := method.Call(nil)
	if 1 != len(results) {
		return reflect.Value{}
	}

	return reflect.ValueOf(results[0].Interface())
}

func structutilof(utility reflect.Value) reflect.Value {
	method := findmethod(utility, "struct")
	if !method.IsValid() {
		return reflect.Value{}
	}

	results := method.Call(nil)
	if 1 != len(results) {
		return reflect.Value{}
	}

	return reflect.ValueOf(results[0].Interface())
}

// Spec names are lower case; Go names are exported, and some are
// multi-word (`getpath` is `GetPath`), so match without case.
func findmethod(val reflect.Value, name string) reflect.Value {
	if !val.IsValid() || "" == name {
		return reflect.Value{}
	}

	valtype := val.Type()
	for index := 0; index < valtype.NumMethod(); index++ {
		if strings.EqualFold(valtype.Method(index).Name, name) {
			return val.Method(index)
		}
	}

	return reflect.Value{}
}

func findfield(val reflect.Value, name string) reflect.Value {
	if !val.IsValid() || "" == name {
		return reflect.Value{}
	}

	if reflect.Pointer == val.Kind() {
		if val.IsNil() {
			return reflect.Value{}
		}
		val = val.Elem()
	}

	if reflect.Struct != val.Kind() {
		return reflect.Value{}
	}

	valtype := val.Type()
	for index := 0; index < valtype.NumField(); index++ {
		if strings.EqualFold(valtype.Field(index).Name, name) {
			return val.Field(index)
		}
	}

	return reflect.Value{}
}

// structnoval reads the port's own no-value sentinel off the SDK, the same
// way StructProvider reaches everything else: by reflection, so the shim
// never imports the library it checks. Nil when the port has no such
// sentinel, in which case the generic rule applies unchanged.
func structnoval(client any) any {
	defer func() { _ = recover() }()

	utility := callnamed(client, "Utility")
	if nil == utility {
		return nil
	}

	structutils := callnamed(utility, "Struct")
	if nil == structutils {
		return nil
	}

	val := reflect.ValueOf(structutils)
	for reflect.Ptr == val.Kind() && !val.IsNil() {
		val = val.Elem()
	}
	if reflect.Struct != val.Kind() {
		return nil
	}

	field := val.FieldByName("NOVAL")
	if !field.IsValid() || !field.CanInterface() {
		return nil
	}

	return field.Interface()
}

// callnamed invokes a zero-argument method by name, returning its first
// result. Nil when there is no such method.
func callnamed(target any, name string) any {
	val := reflect.ValueOf(target)
	method := val.MethodByName(name)
	if !method.IsValid() || 0 != method.Type().NumIn() || 1 > method.Type().NumOut() {
		return nil
	}

	out := method.Call(nil)
	if 0 == len(out) {
		return nil
	}

	return out[0].Interface()
}

// novalargs is the go peer of the python shim's `zeroargs` and the ruby
// shim's `undefargs`: struct's corpus carries seventeen entries with no
// `in`, `args` or `ctx`, meaning "call the subject with no arguments", and
// each port's runner spelled that its own way.
//
// go's runner spelled it by not running them - it skipped this class
// outright, on a hardcoded T_noval comparison, so the port's suite never
// asserted them. There is no prior behaviour to reproduce, so the shim
// gives them the port's own no-value instead, which is what canonical
// means by them: `typify()` is T_noval where `typify(null)` is
// T_scalar|T_null.
//
// The rewrite is in memory and for this port only; the corpus on disk is
// untouched. When the port exposes no sentinel the spec is returned
// unchanged.
//
// What goes into the spec is a MARKER, not the sentinel: omni's runner
// runs `fixjson` over the whole group, arguments included (register 4.2's
// third channel defect), and a Go sentinel is a struct pointer, so it
// would arrive at the subject as the string "{NOVAL}" and typify as a map.
// The marker is a string, so it survives untouched, and `novalsubject`
// swaps it for the real sentinel at the call boundary. The marker is
// private to this shim, so nothing in a corpus can collide with it.
func novalargs(testspec any, sentinel any) any {
	if nil == sentinel {
		return testspec
	}

	spec, is := testspec.(map[string]any)
	if !is {
		return testspec
	}

	set, is := spec["set"].([]any)
	if !is {
		return testspec
	}

	found := false
	for _, entry := range set {
		if noargs(entry) {
			found = true
			break
		}
	}
	if !found {
		return testspec
	}

	patched := make([]any, len(set))
	for index, entry := range set {
		if noargs(entry) {
			copied := map[string]any{}
			for key, val := range entry.(map[string]any) {
				copied[key] = val
			}
			copied["args"] = []any{NOVALMARK}
			entry = copied
		}
		patched[index] = entry
	}

	out := map[string]any{}
	for key, val := range spec {
		out[key] = val
	}
	out["set"] = patched

	return out
}

// NOVALMARK stands in for the port's no-value between novalargs and
// novalsubject. Deliberately not one of omni's own sentinels: those are
// meaningful to the runner, and this one must pass through it inert.
const NOVALMARK = "__STRUCTCOMPAT_NOVAL__"

// novalsubject swaps the marker back for the port's real sentinel, at the
// point of call - after the runner has finished normalising the spec.
func novalsubject(subject Subject, sentinel any) Subject {
	if nil == sentinel || nil == subject {
		return subject
	}

	return func(args ...any) (any, error) {
		for index, arg := range args {
			if mark, is := arg.(string); is && NOVALMARK == mark {
				args[index] = sentinel
			}
		}
		return subject(args...)
	}
}

func noargs(entry any) bool {
	fields, is := entry.(map[string]any)
	if !is {
		return false
	}

	for _, key := range []string{"in", "args", "ctx"} {
		if _, has := fields[key]; has {
			return false
		}
	}

	return true
}

// fixnums reproduces the Float64 branch of struct's own `fixJSON`
// (`go/testutil/runner.go`, before the swap): an integral JSON number
// becomes a Go `int`.
//
// Go is the only port where this matters, and it is not cosmetic. struct's
// Go API is written in `int` - `Typename(t int)`, `Flatten(list, depths
// ...int)`, `Stringify(val, maxlen ...int)`, `Merge(val, maxdepths ...int)`
// - and struct's test file destructures entries itself, doing
// `m["depth"].(int)` on the way in. omni's Go runner keeps JSON numbers as
// `float64`, which is right for its own value model but hands struct a type
// its API and its tests both reject: a direct subject fails `callarg` with
// "not assignable to parameter type int", and a destructuring closure
// panics outright with "interface conversion: interface {} is float64, not
// int".
//
// So the shim normalises where struct's runner did, and on both sides for
// the same reason struct's did: `fixJSON` ran over the whole group, results
// included. Normalising only the spec would leave an `int` expectation
// compared against a `float64` result, which omni's deepequal correctly
// refuses to conflate.
//
// Non-integral numbers are left alone, and so are numbers that are already
// an integer type. Nothing outside the Float64 branch is touched.
func fixnums(val any) any {
	switch value := val.(type) {
	case float64:
		if value == float64(int(value)) {
			return int(value)
		}
		return val

	case float32:
		if float64(value) == float64(int(value)) {
			return int(value)
		}
		return val

	case map[string]any:
		out := make(map[string]any, len(value))
		for key, entry := range value {
			out[key] = fixnums(entry)
		}
		return out

	case []any:
		out := make([]any, len(value))
		for index, entry := range value {
			out[index] = fixnums(entry)
		}
		return out

	default:
		return val
	}
}

// Subjectify adapts any Go function to omni's calling convention, so that
// a struct test can keep passing the library function itself as the
// subject. Missing arguments become the parameter's zero value, and a
// (value, error) pair becomes omni's result.
func Subjectify(fn any) Subject {
	if subject, is := fn.(Subject); is {
		return subject
	}

	fnval := reflect.ValueOf(fn)
	if !fnval.IsValid() || reflect.Func != fnval.Kind() {
		panic("structcompat: subject is not a function")
	}

	fntype := fnval.Type()

	return func(args ...any) (any, error) {
		fixed := fntype.NumIn()
		if fntype.IsVariadic() {
			fixed--
		}

		if len(args) < fixed {
			extended := make([]any, fixed)
			copy(extended, args)
			args = extended
		}

		in := make([]reflect.Value, 0, len(args))

		for index := 0; index < fixed; index++ {
			val, err := callarg(args[index], fntype.In(index), index)
			if nil != err {
				return nil, err
			}
			in = append(in, val)
		}

		if fntype.IsVariadic() {
			elemtype := fntype.In(fntype.NumIn() - 1).Elem()
			for index := fixed; index < len(args); index++ {
				val, err := callarg(args[index], elemtype, index)
				if nil != err {
					return nil, err
				}
				in = append(in, val)
			}
		}

		out := fnval.Call(in)

		switch len(out) {
		case 0:
			return nil, nil
		case 1:
			return fixnums(out[0].Interface()), nil
		case 2:
			err, _ := out[1].Interface().(error)
			return fixnums(out[0].Interface()), err
		default:
			return nil, fmt.Errorf("structcompat: subject returns too many values (%d)", len(out))
		}
	}
}

func callarg(arg any, paramtype reflect.Type, index int) (reflect.Value, error) {
	if nil == arg {
		return reflect.Zero(paramtype), nil
	}

	val := reflect.ValueOf(arg)
	if !val.Type().AssignableTo(paramtype) {
		return reflect.Value{}, fmt.Errorf(
			"structcompat: argument %d type %T not assignable to parameter type %s",
			index, arg, paramtype)
	}

	return val, nil
}
