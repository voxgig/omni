// RUN: make test
// RUN-SOME: ./build/omnitest basic
//
// The Fibonacci conformance suite: every omni port runs this same set of
// groups, from the same spec/fib.json, against the same fib library.
//
// No third-party test framework: a failing omni check throws OmniError, so
// any host framework (Catch2, GoogleTest) reports it as a failure. This
// harness keeps `make test` dependency-free.

#include <cmath>
#include <filesystem>
#include <functional>
#include <iostream>
#include <limits>
#include <memory>
#include <string>
#include <vector>

#include "../src/omni.hpp"
#include "fib.hpp"

namespace {

std::string ONLY;
int PASSCOUNT = 0;
int FAILCOUNT = 0;

// Find the shared spec directory by walking up from the working directory.
std::string specfile(const std::string& name) {
  std::filesystem::path dir = std::filesystem::current_path();

  for (int step = 0; step < 8; step++) {
    std::filesystem::path cand = dir / "spec" / name;
    if (std::filesystem::exists(cand)) {
      return cand.string();
    }
    if (!dir.has_parent_path() || dir == dir.parent_path()) {
      break;
    }
    dir = dir.parent_path();
  }

  throw omni::OmniError("omni: spec not found: " + name);
}

const omni::Subject FIB = [](const std::vector<omni::Json>& args) { return fib::fib(args[0]); };
const omni::Subject FIBSEQ = [](const std::vector<omni::Json>& args) {
  return fib::fibseq(args[0]);
};
const omni::Subject FIBRANGE = [](const std::vector<omni::Json>& args) {
  return fib::fibrange(args[0], args[1]);
};
const omni::Subject FIBINFO = [](const std::vector<omni::Json>& args) {
  return fib::fibinfo(args[0]);
};

// A subject that returns the literal string "__UNDEF__" as ordinary data.
// The sentinel must not accept its own literal: `match:{out:{a:"__UNDEF__"}}`
// asserts the key is ABSENT, so this present value has to fail.
const omni::Subject UNDEFDATA = [](const std::vector<omni::Json>&) {
  omni::Json out = omni::Json::map();
  out.set("a", omni::Json::str("__UNDEF__"));
  return out;
};

// The context-group subject: reports what the runner delivered - the
// contextify mark and the attached client - as plain data, so the spec can
// pin both with an ordinary `out` comparison.
const omni::Subject FIBCTX = [](const std::vector<omni::Json>& args) {
  const omni::Json& ctx = args[0];
  omni::Json out = omni::Json::map();
  out.set("n", ctx.get("n"));
  out.set("val", fib::fib(ctx.get("n")));
  out.set("mark", ctx.get("mark"));
  out.set("hasclient", omni::Json::boolean(!ctx.get("client").isnone()));
  return out;
};

// The provider hosts the system under test. `shift` offsets the Fibonacci
// index, so that a client-specific subject is observably different.
// `contextify` marks the map, so the context group can prove the hook ran.
std::shared_ptr<omni::Provider> fibprovider(double shift) {
  auto provider = std::make_shared<omni::Provider>();

  provider->subject = [shift](const std::string& name) -> omni::Subject {
    if ("fib" == name) {
      return [shift](const std::vector<omni::Json>& args) {
        if (args[0].isnum()) {
          return fib::fib(omni::Json::num(args[0].numval + shift));
        }
        return fib::fib(args[0]);
      };
    }
    if ("fibseq" == name) {
      return FIBSEQ;
    }
    if ("fibrange" == name) {
      return FIBRANGE;
    }
    if ("fibinfo" == name) {
      return FIBINFO;
    }
    return nullptr;
  };

  provider->client = [](const omni::Json& options) {
    omni::Json shiftval = options.get("shift");
    return fibprovider(shiftval.isnum() ? shiftval.numval : 0);
  };

  provider->contextify = [](const omni::Json& val) {
    omni::Json out = val;
    out.set("mark", omni::Json::str("CTX"));
    return out;
  };

  return provider;
}

void testcase(const std::string& name, const std::function<void()>& body) {
  if (!ONLY.empty() && name != ONLY) {
    return;
  }

  try {
    body();
    PASSCOUNT++;
    std::cout << "ok   - " << name << "\n";
  } catch (const std::exception& err) {
    FAILCOUNT++;
    std::cout << "FAIL - " << name << "\n" << err.what() << "\n";
  }
}

// The runner must fail when the subject is wrong - otherwise a green suite
// means nothing.
omni::Json badspec() {
  using omni::Json;

  return Json::map({
      {"fib",
       Json::map({
           {"wrongout", Json::map({{"set", Json::list({
                                               Json::map({{"in", Json::num(5)},
                                                          {"out", Json::num(5)}}),
                                               Json::map({{"in", Json::num(6)},
                                                          {"out", Json::num(999)}}),
                                           })}})},
           {"wrongerr", Json::map({{"set", Json::list({Json::map(
                                               {{"in", Json::num(1)},
                                                {"err", Json::str("never happens")}})})}})},
           {"wrongmatch",
            Json::map({{"set", Json::list({Json::map(
                                   {{"in", Json::num(6)},
                                    {"match", Json::map({{"out", Json::num(999)}})}})})}})},
           {"missing",
            Json::map({{"set",
                        Json::list({Json::map(
                            {{"in", Json::num(6)},
                             {"match", Json::map({{"out", Json::map({{"nope",
                                                                      Json::str("__EXISTS__")}})}})}})})}})},
           // A concrete match leaf against a missing key must fail, not
           // substring-match the text "undefined".
           {"matchabsent",
            Json::map({{"set",
                        Json::list({Json::map(
                            {{"in", Json::num(6)},
                             {"match", Json::map({{"out", Json::map({{"nope",
                                                                      Json::str("fine")}})}})}})})}})},
           // __UNDEF__ (absent) must not be satisfied by a present null.
           {"undefonnull",
            Json::map({{"set",
                        Json::list({Json::map(
                            {{"in", Json::num(0)},
                             {"match", Json::map({{"out", Json::map({{"prev",
                                                                      Json::str("__UNDEF__")}})}})}})})}})},
           // __NULL__ (present null) must not be satisfied by an absent key.
           {"nullonabsent",
            Json::map({{"set",
                        Json::list({Json::map(
                            {{"in", Json::num(6)},
                             {"match", Json::map({{"out", Json::map({{"nope",
                                                                      Json::str("__NULL__")}})}})}})})}})},
           // __UNDEF__ (absent) must not be satisfied by a subject returning
           // the literal string "__UNDEF__" as data.
           {"wrongundef",
            Json::map({{"set",
                        Json::list({Json::map(
                            {{"in", Json::num(6)},
                             {"match", Json::map({{"out", Json::map({{"a",
                                                                      Json::str("__UNDEF__")}})}})}})})}})},
           // An empty-string want is a substring of everything, not a wildcard.
           {"emptystr",
            Json::map({{"set",
                        Json::list({Json::map(
                            {{"in", Json::num(6)},
                             {"match", Json::map({{"out", Json::map({{"label",
                                                                      Json::str("")}})}})}})})}})},
       })},
  });
}

void expectfail(const std::string& setname, const omni::Subject& subject) {
  omni::RunPack pack = omni::makeRunner(badspec()).runner("fib");

  try {
    pack.runset(pack.set(setname), subject);
  } catch (const omni::OmniError&) {
    return;
  }

  throw std::runtime_error("omni: expected OmniError for set: " + setname);
}

void checkmessage() {
  using omni::Json;

  Json spec = Json::map({
      {"fib", Json::map({{"g", Json::map({{"set", Json::list({
                                              Json::map({{"in", Json::num(1)},
                                                         {"out", Json::num(1)}}),
                                              Json::map({{"id", Json::str("x#2")},
                                                         {"in", Json::num(2)},
                                                         {"out", Json::num(42)}}),
                                          })}})}})},
  });

  omni::RunPack pack = omni::makeRunner(spec).runner("fib");

  try {
    pack.runset(pack.set("g"), FIB);
  } catch (const omni::OmniError& err) {
    std::string msg = err.what();
    for (const std::string want : {"fib[1] (x#2)", "expected: 42", "actual:   1"}) {
      if (std::string::npos == msg.find(want)) {
        throw std::runtime_error("omni: message missing [" + want + "]: " + msg);
      }
    }
    return;
  }

  throw std::runtime_error("omni: expected OmniError");
}

// Run `body`, and require it to throw an OmniError whose message contains
// `want`.
void expectmessage(const std::function<void()>& body, const std::string& want) {
  try {
    body();
  } catch (const omni::OmniError& err) {
    std::string msg = err.what();
    if (std::string::npos == msg.find(want)) {
      throw std::runtime_error("omni: message missing [" + want + "]: " + msg);
    }
    return;
  }

  throw std::runtime_error("omni: expected OmniError containing [" + want + "]");
}

void rejectsunsupportedversion() {
  using omni::Json;

  Json spec = Json::map({
      {"OMNI", Json::map({{"version", Json::num(99)}})},
      {"fib", Json::map({{"g", Json::map({{"set", Json::list({})}})}})},
  });

  expectmessage([&] { omni::makeRunner(spec); }, "unsupported spec version");
}

void rejectsunknowncapability() {
  using omni::Json;

  Json spec = Json::map({
      {"OMNI", Json::map({{"version", Json::num(1)},
                          {"requires", Json::list({Json::str("nosuchfeature")})}})},
      {"fib", Json::map({{"g", Json::map({{"set", Json::list({})}})}})},
  });

  expectmessage([&] { omni::makeRunner(spec); }, "unsupported capability");
}

void rejectsmalformedversion() {
  using omni::Json;

  Json spec = Json::map({
      {"OMNI", Json::map({{"version", Json::str("one")}})},
      {"fib", Json::map({{"g", Json::map({{"set", Json::list({})}})}})},
  });

  expectmessage([&] { omni::makeRunner(spec); }, "malformed OMNI");
}

// A present-but-null block is malformed; only a genuinely absent OMNI key
// is legacy. Ports that test definedness rather than presence silently
// skip strict mode here, so both cases are pinned.
void rejectsnullomni() {
  using omni::Json;

  Json specnull = Json::map({
      {"OMNI", Json::null()},
      {"fib", Json::map({{"g", Json::map({{"set", Json::list({
                                  Json::map({{"in", Json::num(1)}, {"out", Json::num(1)}}),
                              })}})}})},
  });
  expectmessage([&] { omni::makeRunner(specnull); }, "malformed OMNI");

  Json specnullreq = Json::map({
      {"OMNI", Json::map({{"version", Json::num(1)}, {"requires", Json::null()}})},
      {"fib", Json::map({{"g", Json::map({{"set", Json::list({
                                  Json::map({{"in", Json::num(1)}, {"out", Json::num(1)}}),
                              })}})}})},
  });
  expectmessage([&] { omni::makeRunner(specnullreq); }, "malformed OMNI requires list");

  Json specabsent = Json::map({
      {"fib", Json::map({{"g", Json::map({{"set", Json::list({
                                  Json::map({{"in", Json::num(1)}, {"out", Json::num(1)}}),
                              })}})}})},
  });
  omni::makeRunner(specabsent);
}

void strictunknownfield() {
  using omni::Json;

  Json spec = Json::map({
      {"OMNI", Json::map({{"version", Json::num(1)}})},
      {"fib", Json::map({{"g", Json::map({{"set", Json::list({
                                  Json::map({{"in", Json::num(6)},
                                             {"matches", Json::map({{"out", Json::num(999)}})}}),
                              })}})}})},
  });

  omni::RunPack pack = omni::makeRunner(spec).runner("fib");
  expectmessage([&] { pack.runset(pack.set("g"), FIBINFO); }, "unknown entry field: matches");
}

void strictmultiplesources() {
  using omni::Json;

  Json spec = Json::map({
      {"OMNI", Json::map({{"version", Json::num(1)}})},
      {"fib", Json::map({{"g", Json::map({{"set", Json::list({
                                  Json::map({{"in", Json::num(5)},
                                             {"args", Json::list({Json::num(5)})},
                                             {"out", Json::num(5)}}),
                              })}})}})},
  });

  omni::RunPack pack = omni::makeRunner(spec).runner("fib");
  expectmessage([&] { pack.runset(pack.set("g"), FIB); }, "more than one of in, args, ctx");
}

void stricterrandout() {
  using omni::Json;

  Json spec = Json::map({
      {"OMNI", Json::map({{"version", Json::num(1)}})},
      {"fib", Json::map({{"g", Json::map({{"set", Json::list({
                                  Json::map({{"in", Json::num(-1)},
                                             {"err", Json::boolean(true)},
                                             {"out", Json::num(5)}}),
                              })}})}})},
  });

  omni::RunPack pack = omni::makeRunner(spec).runner("fib");
  expectmessage([&] { pack.runset(pack.set("g"), FIB); }, "both err and out");
}

// This catches Fix 1 (checkset must validate the AUTHORED entries) and the
// id half of Fix 2 (presence, not null-normalisation) together: under
// default flags an authored `id: null` becomes "__NULL__", so a check that
// runs after normalisation, or on typed-null-only, never fires.
void strictnullid() {
  using omni::Json;

  Json spec = Json::map({
      {"OMNI", Json::map({{"version", Json::num(1)}})},
      {"fib", Json::map({{"g", Json::map({{"set", Json::list({
                                  Json::map({{"in", Json::num(1)},
                                             {"out", Json::num(1)},
                                             {"id", Json::null()}}),
                              })}})}})},
  });

  omni::RunPack pack = omni::makeRunner(spec).runner("fib");
  expectmessage([&] { pack.runset(pack.set("g"), FIB); }, "entry id is not a string");
}

void strictemptyset() {
  using omni::Json;

  Json spec = Json::map({
      {"OMNI", Json::map({{"version", Json::num(1)}})},
      {"fib", Json::map({
                  {"g", Json::map({{"set", Json::list({})}})},
                  {"h", Json::map({{"set", Json::list({})}, {"empty", Json::boolean(true)}})},
              })},
  });

  omni::RunPack pack = omni::makeRunner(spec).runner("fib");
  expectmessage([&] { pack.runset(pack.set("g"), FIB); }, "empty test set");
  pack.runset(pack.set("h"), FIB);
}

void legacystayslenient() {
  using omni::Json;

  Json spec = Json::map({
      {"fib", Json::map({{"g", Json::map({{"set", Json::list({
                                  Json::map({{"in", Json::num(6)},
                                             {"matches", Json::map({{"out", Json::num(999)}})},
                                             {"out", Json::num(8)}}),
                              })}})}})},
  });

  omni::RunPack pack = omni::makeRunner(spec).runner("fib");
  pack.runset(pack.set("g"), FIB);
}

// deepequal is structural, not IEEE: NaN equals NaN, at the top level and
// nested inside containers. spec/fib.json cannot pin this - JSON has no NaN
// literal - so it is pinned here instead.
//
// The two NaNs come from two DIFFERENT expressions, and the guard below
// requires them to be genuine NaNs that are not IEEE-equal to each other.
// Json is a value type, so there is no object identity to defeat, but a
// single shared NaN constant used twice would still prove nothing: the
// point is that deepequal answers true for values that `==` calls unequal.
// The `volatile` reads keep the compiler from folding the two expressions
// into one constant.
void nanequality() {
  auto check = [](bool got, bool want, const std::string& what) {
    if (got != want) {
      throw std::runtime_error("omni: expected " + what + " to be " +
                               (want ? "true" : "false"));
    }
  };

  volatile double zero = 0.0;
  volatile double huge = std::numeric_limits<double>::infinity();
  const double nan1 = zero / zero;  // 0.0 / 0.0
  const double nan2 = huge - huge;  // INFINITY - INFINITY

  check(std::isnan(nan1) && std::isnan(nan2), true, "two NaN values");
  check(nan1 == nan2, false, "the two NaNs IEEE-equal");

  const omni::Json n1 = omni::Json::num(nan1);
  const omni::Json n2 = omni::Json::num(nan2);

  check(omni::deepequal(n1, n2), true, "deepequal(NaN, NaN)");
  check(omni::deepequal(omni::Json::list({n1}), omni::Json::list({n2})), true,
        "deepequal([NaN], [NaN])");
  check(omni::deepequal(omni::Json::map({{"x", n1}}), omni::Json::map({{"x", n2}})), true,
        "deepequal({x:NaN}, {x:NaN})");

  check(omni::deepequal(omni::Json::num(1), omni::Json::num(1.0)), true, "deepequal(1, 1.0)");
  check(omni::deepequal(n1, omni::Json::num(1.0)), false, "deepequal(NaN, 1.0)");
  check(omni::deepequal(omni::Json::boolean(true), omni::Json::num(1)), false,
        "deepequal(true, 1)");
  check(omni::deepequal(omni::Json::num(1), omni::Json::num(2)), false, "deepequal(1, 2)");
}

}  // namespace

int main(int argc, char** argv) {
  if (1 < argc) {
    ONLY = argv[1];
  }

  omni::RunPack R = omni::makeRunner(specfile("fib.json"), fibprovider(0)).runner("fib");

  testcase("basic", [&R] { R.runset(R.set("basic"), FIB); });
  testcase("seq", [&R] { R.runset(R.set("seq"), FIBSEQ); });
  testcase("range", [&R] { R.runset(R.set("range"), FIBRANGE); });
  testcase("info", [&R] { R.runset(R.set("info"), FIBINFO); });
  testcase("nulls",
           [&R] { R.runsetflags(R.set("nulls"), omni::Flags::nonull(), FIBINFO); });
  testcase("error", [&R] { R.runset(R.set("error"), FIB); });
  testcase("match", [&R] { R.runset(R.set("match"), FIB); });
  testcase("matchinfo", [&R] { R.runset(R.set("matchinfo"), FIBINFO); });
  testcase("client", [&R] { R.runset(R.set("client"), FIB); });
  testcase("context", [&R] { R.runset(R.set("context"), FIBCTX); });

  testcase("detects wrong result", [] { expectfail("wrongout", FIB); });
  testcase("detects missing error", [] { expectfail("wrongerr", FIB); });
  testcase("detects failed match", [] { expectfail("wrongmatch", FIB); });
  testcase("detects absent key", [] { expectfail("missing", FIBINFO); });
  testcase("a concrete match leaf does not match a missing key",
           [] { expectfail("matchabsent", FIBINFO); });
  testcase("__UNDEF__ does not match a present null",
           [] { expectfail("undefonnull", FIBINFO); });
  testcase("__NULL__ does not match an absent key",
           [] { expectfail("nullonabsent", FIBINFO); });
  testcase("__UNDEF__ does not match the literal string \"__UNDEF__\"",
           [] { expectfail("wrongundef", UNDEFDATA); });
  testcase("an empty-string match leaf is not a wildcard",
           [] { expectfail("emptystr", FIBINFO); });

  testcase("rejects an unsupported spec version", rejectsunsupportedversion);
  testcase("rejects an unknown required capability", rejectsunknowncapability);
  testcase("rejects a malformed version block", rejectsmalformedversion);
  testcase("rejects a null OMNI block, but accepts an absent one", rejectsnullomni);
  testcase("strict: an unknown entry field fails instead of passing vacuously",
           strictunknownfield);
  testcase("strict: more than one of in, args, ctx fails", strictmultiplesources);
  testcase("strict: err together with out fails", stricterrandout);
  testcase("strict: a null id fails even under null-normalisation", strictnullid);
  testcase("strict: an empty set fails unless marked empty", strictemptyset);
  testcase("a legacy spec (no OMNI block) stays lenient", legacystayslenient);

  testcase("reports entry index and id", checkmessage);

  testcase("deepequal: two distinct NaNs are structurally equal", nanequality);

  std::cout << "\n" << PASSCOUNT << " passed, " << FAILCOUNT << " failed\n";

  return 0 == FAILCOUNT ? 0 : 1;
}
