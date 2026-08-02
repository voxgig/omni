// RUN: make test
// RUN-SOME: ./build/omnitest basic
//
// The Fibonacci conformance suite: every omni port runs this same set of
// groups, from the same spec/fib.json, against the same fib library.
//
// No third-party test framework: a failing omni check throws OmniError, so
// any host framework (Catch2, GoogleTest) reports it as a failure. This
// harness keeps `make test` dependency-free.

#include <filesystem>
#include <functional>
#include <iostream>
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

// The provider hosts the system under test. `shift` offsets the Fibonacci
// index, so that a client-specific subject is observably different.
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

  testcase("detects wrong result", [] { expectfail("wrongout", FIB); });
  testcase("detects missing error", [] { expectfail("wrongerr", FIB); });
  testcase("detects failed match", [] { expectfail("wrongmatch", FIB); });
  testcase("detects absent key", [] { expectfail("missing", FIBINFO); });
  testcase("reports entry index and id", checkmessage);

  std::cout << "\n" << PASSCOUNT << " passed, " << FAILCOUNT << " failed\n";

  return 0 == FAILCOUNT ? 0 : 1;
}
