// Omni: the shared multi-language test runner (C++ port).
//
// A test spec is plain JSON. The same spec file drives the same tests in
// every language that ships an omni port.
//
// Port of the canonical TypeScript implementation
// (typescript/src/Runner.ts). Behaviour must match, case for case.
//
// Header-only, C++17, standard library only.

#ifndef VOXGIG_OMNI_HPP
#define VOXGIG_OMNI_HPP

#include <algorithm>
#include <cmath>
#include <functional>
#include <map>
#include <memory>
#include <regex>
#include <stdexcept>
#include <string>
#include <vector>

#include "json.hpp"
#include "util.hpp"

namespace omni {

// The function under test. Arguments arrive as JSON values; failure is
// reported by throwing.
using Subject = std::function<Json(const std::vector<Json>&)>;

// A test failure (or a malformed spec). Distinct from an exception thrown
// by the subject under test, which is a candidate for an `err` expectation.
class OmniError : public std::runtime_error {
 public:
  explicit OmniError(const std::string& message) : std::runtime_error(message) {}
};

// Run-time options for a set of test entries.
struct Flags {
  bool null = true;         // Convert JSON nulls to NULLMARK.
  std::string name;         // Label used in failure messages.

  static Flags nonull() {
    Flags flags;
    flags.null = false;
    return flags;
  }
};

// The host of the system under test. Every hook is optional.
struct Provider {
  // Resolve a test subject by name.
  std::function<Subject(const std::string&)> subject;
  // Build a sub-provider from a DEF.client entry's options.
  std::function<std::shared_ptr<Provider>(const Json&)> client;
  // Wrap a map argument as a call context.
  std::function<Json(const Json&)> contextify;
  // Resolve references in client options against the store.
  std::function<Json(const Json&, const Json&)> inject;
};

// The newest spec format version this runner understands. A spec with no
// OMNI block is version 0: the original, lenient format, frozen forever.
// Version 1 turns on strict entry validation (see checkentry).
inline const int SPECVERSION = 1;

// Capability strings this runner supports beyond the version baseline. A
// spec's OMNI.requires list is checked against this: an unknown capability
// refuses the spec loudly at load time, instead of a lagging port silently
// mis-running it. (Empty today; future format features mint a string here.)
inline const std::vector<std::string> CAPABILITIES = {};

// The complete set of fields an entry may carry. Under version 1 anything
// else is an error: an unrecognised key is almost always a typo'd
// assertion, and a typo'd assertion is a test that silently stopped
// testing.
inline const std::vector<std::string> ENTRYFIELDS = {
    "in", "args", "ctx", "out", "err", "match", "client", "id", "doc"};

// Read the spec's format version from its optional top-level OMNI block,
// and refuse a spec this runner cannot faithfully run: a version newer
// than SPECVERSION, or a required capability not in CAPABILITIES.
inline int resolveversion(const Json& alltests) {
  Json meta = alltests.ismap() ? alltests.get("OMNI") : Json::absent();

  if (meta.isabsent()) {
    return 0;
  }

  Json version = meta.get("version");
  if (!meta.ismap() || !version.isnum() || version.numval != std::floor(version.numval)) {
    throw OmniError("omni: malformed OMNI version block");
  }

  if (version.numval < 0 || SPECVERSION < version.numval) {
    throw OmniError("omni: unsupported spec version: " + numstr(version.numval));
  }

  Json reqlist = meta.get("requires");
  if (!reqlist.isabsent()) {
    if (!reqlist.islist()) {
      throw OmniError("omni: malformed OMNI requires list");
    }
    for (const auto& cap : reqlist.listval) {
      bool known = cap.isstr() &&
                  CAPABILITIES.end() != std::find(CAPABILITIES.begin(), CAPABILITIES.end(), cap.strval);
      if (!known) {
        throw OmniError("omni: spec requires unsupported capability: " + stringify(cap));
      }
    }
  }

  return static_cast<int>(version.numval);
}

// ---- internals -------------------------------------------------------

// Nulls (and absent values) become NULLMARK. Always a fresh copy.
inline Json fixjson(const Json& val, bool donull) {
  if (val.isnone()) {
    return donull ? Json::str(NULLMARK) : Json::null();
  }

  if (val.islist()) {
    Json out = Json::list();
    for (const auto& entry : val.listval) {
      out.push(fixjson(entry, donull));
    }
    return out;
  }

  if (val.ismap()) {
    Json out = Json::map();
    for (const auto& entry : val.mapval) {
      out.set(entry.first, fixjson(entry.second, donull));
    }
    return out;
  }

  return val;
}

// The JSON form of an error: always at least {name,message}.
inline Json errify(const std::string& message) {
  Json out = Json::map();
  out.set("name", Json::str("Error"));
  out.set("message", Json::str(message));
  return out;
}

// The spec-defined part of an entry (drop runner bookkeeping).
inline Json entrysummary(const Json& entry) {
  if (!entry.ismap()) {
    return entry;
  }

  Json out = Json::map();
  for (const auto& field : entry.mapval) {
    if ("res" != field.first && "thrown" != field.first && "ctx" != field.first) {
      out.set(field.first, field.second);
    }
  }
  return out;
}

// The label of one entry, for failure messages.
inline std::string entryref(const Flags& flags, size_t index, const Json& entry) {
  std::string label = flags.name.empty() ? "set" : flags.name;
  Json id = entry.get("id");
  std::string idpart = id.isabsent() ? "" : " (" + stringify(id) + ")";
  return label + "[" + std::to_string(index) + "]" + idpart;
}

inline OmniError fail(const Flags& flags, size_t index, const Json& entry,
                      const std::string& reason, const std::string* expected = nullptr,
                      const std::string* actual = nullptr) {
  std::string message = "omni: " + entryref(flags, index, entry) + ": " + reason;

  if (nullptr != expected) {
    message += "\n  expected: " + *expected;
  }
  if (nullptr != actual) {
    message += "\n  actual:   " + *actual;
  }
  message += "\n  entry:    " + stringify(entrysummary(entry));

  return OmniError(message);
}

// Strict entry validation, applied when the spec declares version 1 or
// later. The lenient format converts each of these mistakes into a silent
// pass or a dead field; here they fail with the entry named.
inline void checkentry(const Flags& flags, size_t index, const Json& entry) {
  if (!entry.ismap()) {
    throw fail(flags, index, entry, "entry is not a map");
  }

  for (const auto& field : entry.mapval) {
    if (ENTRYFIELDS.end() == std::find(ENTRYFIELDS.begin(), ENTRYFIELDS.end(), field.first)) {
      throw fail(flags, index, entry, "unknown entry field: " + field.first);
    }
  }

  int argsources = 0;
  for (const char* key : {"in", "args", "ctx"}) {
    if (entry.has(key)) {
      argsources++;
    }
  }
  if (1 < argsources) {
    throw fail(flags, index, entry, "entry has more than one of in, args, ctx");
  }

  if (!entry.get("err").isnone() && entry.has("out")) {
    throw fail(flags, index, entry, "entry has both err and out");
  }

  // Presence, not definedness: a present `id: null` is malformed, not a
  // sentinel to skip. Test against genuine absence, never `isnone()`.
  Json id = entry.get("id");
  if (!id.isabsent() && !id.isstr()) {
    throw fail(flags, index, entry, "entry id is not a string");
  }
}

// Validate a version-1 group up front, against the AUTHORED entries -
// null-normalisation would otherwise rewrite an authored null (e.g.
// id: null) into a sentinel string and hide it from validation. A
// malformed spec is a spec error, not a test result, so it fails before
// any subject runs. Absorbs the empty-set check too.
inline void checkset(const Flags& flags, const Json& testspec, const Json& normalset) {
  Json rawset = testspec.ismap() ? testspec.get("set") : Json::absent();
  Json origset = rawset.islist() ? rawset : normalset;

  Json emptyflag = testspec.ismap() ? testspec.get("empty") : Json::absent();
  bool marked = emptyflag.isbool() && emptyflag.boolval;

  if (origset.listval.empty() && !marked) {
    throw OmniError("omni: empty test set: " + flags.name);
  }

  for (size_t index = 0; index < origset.listval.size(); index++) {
    checkentry(flags, index, origset.listval[index]);
  }
}

// An entry with no `out` expects a null (or absent) result.
inline void resolveentry(Json& entry, const Flags& flags) {
  if (flags.null && entry.get("out").isnone()) {
    entry.set("out", Json::str(NULLMARK));
  }
}

// Match one leaf: /regex/ or case-insensitive substring for strings.
inline bool matchval(const Json& check, const Json& base) {
  if (deepequal(check, base)) {
    return true;
  }

  Json want = check;
  if (want.isstr() && (UNDEFMARK == want.strval || NULLMARK == want.strval)) {
    want = Json::null();
  }

  if (want.isnone()) {
    return base.isnone() || (base.isstr() && NULLMARK == base.strval);
  }

  if (want.isstr()) {
    std::string basestr = stringify(base);
    const std::string& text = want.strval;

    // An empty want is a substring of everything, so it would match any
    // value. Require the base to be the empty string too.
    if (text.empty()) {
      return base.isstr() && base.strval.empty();
    }

    if (2 < text.size() && '/' == text.front() && '/' == text.back()) {
      try {
        std::regex pattern(text.substr(1, text.size() - 2), std::regex::ECMAScript);
        return std::regex_search(basestr, pattern);
      } catch (const std::regex_error&) {
        return false;
      }
    }

    std::string lowbase = basestr;
    std::string lowwant = text;
    std::transform(lowbase.begin(), lowbase.end(), lowbase.begin(), ::tolower);
    std::transform(lowwant.begin(), lowwant.end(), lowwant.begin(), ::tolower);

    return std::string::npos != lowbase.find(lowwant);
  }

  return deepequal(want, base);
}

// Check that every leaf of `check` is present, and matches, in `base`.
inline void matchcheck(const Flags& flags, size_t index, const Json& entry, const Json& check,
                       const Json& base, std::vector<std::string> path = {}) {
  if (check.islist()) {
    for (size_t at = 0; at < check.listval.size(); at++) {
      std::vector<std::string> childpath = path;
      childpath.push_back(std::to_string(at));
      matchcheck(flags, index, entry, check.listval[at], base, childpath);
    }
    return;
  }

  if (check.ismap()) {
    for (const auto& field : check.mapval) {
      std::vector<std::string> childpath = path;
      childpath.push_back(field.first);
      matchcheck(flags, index, entry, field.second, base, childpath);
    }
    return;
  }

  Json baseval = getpath(base, path);
  std::string where = path.empty() ? "<root>" : pathify(path);

  // The sentinels are tested BEFORE the identity check below. Otherwise
  // a subject returning the literal string "__UNDEF__" satisfies an
  // assertion that the key is absent - two mutually exclusive states
  // passing one check. A sentinel that accepts its own literal is not a
  // sentinel. (NULLMARK still accepts NULLMARK: under the default null
  // flag a real null has already been normalised to it, so the two are
  // genuinely indistinguishable here - that one needs a raw-value
  // escape, not an ordering change.)

  // Explicitly absent: satisfied only by a genuinely missing key, never
  // by a present null (the distinction the sentinels exist to keep).
  if (check.isstr() && UNDEFMARK == check.strval) {
    if (baseval.isabsent()) {
      return;
    }
    std::string expected = "absent";
    std::string actual = stringify(baseval);
    throw fail(flags, index, entry, "expected absent at " + where, &expected, &actual);
  }

  // Explicitly null: satisfied only by a present null.
  if (check.isstr() && NULLMARK == check.strval) {
    if (baseval.isnull() || (baseval.isstr() && NULLMARK == baseval.strval)) {
      return;
    }
    std::string expected = "null";
    std::string actual = stringify(baseval);
    throw fail(flags, index, entry, "expected null at " + where, &expected, &actual);
  }

  // Explicitly present: any present value, including null.
  if (check.isstr() && EXISTSMARK == check.strval) {
    if (!baseval.isabsent()) {
      return;
    }
    std::string expected = "present";
    std::string actual = "absent";
    throw fail(flags, index, entry, "expected present at " + where, &expected, &actual);
  }

  // Identical values match. This sits below the sentinel branches on
  // purpose - see the note above.
  if (deepequal(check, baseval)) {
    return;
  }

  // A concrete expectation never matches a missing key - a match leaf
  // against an absent value must fail, not substring-match "undefined".
  if (baseval.isabsent()) {
    std::string expected = stringify(check);
    std::string actual = "absent";
    throw fail(flags, index, entry, "match failed at " + where, &expected, &actual);
  }

  if (matchval(check, baseval)) {
    return;
  }

  std::string expected = stringify(check);
  std::string actual = stringify(baseval);

  throw fail(flags, index, entry, "match failed at " + where, &expected, &actual);
}

// ---- runner ----------------------------------------------------------

class RunPack {
 public:
  Json spec;
  Subject subject;
  std::shared_ptr<Provider> client;

  RunPack(const Json& spec, const Subject& subject, const std::shared_ptr<Provider>& provider,
          const std::map<std::string, std::shared_ptr<Provider>>& clients,
          const std::string& name, int specversion)
      : spec(spec), subject(subject), client(provider), provider_(provider), clients_(clients),
        name_(name), specversion_(specversion) {}

  // A named group of the resolved spec.
  Json set(const std::string& name) const { return spec.get(name); }

  // Run one set of test entries.
  void runset(const Json& testspec, const Subject& testsubject = nullptr) const {
    runsetflags(testspec, Flags(), testsubject);
  }

  // Run one set of test entries with flags.
  void runsetflags(const Json& testspec, Flags flags,
                   const Subject& testsubject = nullptr) const {
    if (flags.name.empty()) {
      flags.name = name_.empty() ? "set" : name_;
    }

    Subject usesubject = testsubject ? testsubject : subject;
    if (!usesubject) {
      throw OmniError("omni: no test subject for: " + flags.name);
    }

    Json testspecmap = fixjson(testspec, flags.null);
    Json testset = testspecmap.get("set");

    if (!testset.islist()) {
      throw OmniError("omni: test spec has no set: " + flags.name);
    }

    // Validated against the AUTHORED (pre-fixjson) group - see checkset.
    if (1 <= specversion_) {
      checkset(flags, testspec, testset);
    }

    for (size_t index = 0; index < testset.listval.size(); index++) {
      Json entry = testset.listval[index];

      resolveentry(entry, flags);

      Subject entrysubject = usesubject;
      Json clientname = entry.get("client");

      if (clientname.isstr()) {
        auto found = clients_.find(clientname.strval);
        if (clients_.end() == found) {
          throw OmniError("omni: unknown client: " + clientname.strval);
        }
        if (found->second->subject) {
          Subject clientsubject = found->second->subject(name_);
          if (clientsubject) {
            entrysubject = clientsubject;
          }
        }
      }

      std::vector<Json> args = resolveargs(entry);

      Json res;
      try {
        res = entrysubject(args);
      } catch (const OmniError&) {
        throw;
      } catch (const std::exception& err) {
        handleerror(flags, index, entry, err.what());
        continue;
      }

      res = fixjson(res, flags.null);
      entry.set("res", res);

      checkresult(flags, index, entry, args, res);
    }
  }

 private:
  std::shared_ptr<Provider> provider_;
  std::map<std::string, std::shared_ptr<Provider>> clients_;
  std::string name_;
  int specversion_ = 0;

  // Build the argument list: `ctx`, `args`, or `in`.
  std::vector<Json> resolveargs(Json& entry) const {
    std::vector<Json> args;

    bool hasctx = entry.has("ctx");
    bool hasargs = entry.has("args");

    if (hasctx) {
      args.push_back(entry.get("ctx"));
    } else if (hasargs) {
      Json rawargs = entry.get("args");
      if (rawargs.islist()) {
        args = rawargs.listval;
      } else {
        args.push_back(rawargs);
      }
    } else {
      args.push_back(entry.get("in"));
    }

    if ((hasctx || hasargs) && !args.empty() && args[0].ismap()) {
      Json first = args[0];
      if (provider_ && provider_->contextify) {
        first = provider_->contextify(first);
      }
      if (first.ismap()) {
        // The resolved client is a live Provider (closures over the system
        // under test), and this port's Json carries no host-object variant
        // to hold one - so canonical's `first.client = testpack.client`
        // becomes presence, not identity: enough for a subject to prove the
        // runner attached a client at all.
        first.set("client", Json::boolean(true));
      }
      args[0] = first;
      entry.set("ctx", first);
    }

    return args;
  }

  void checkresult(const Flags& flags, size_t index, const Json& entry,
                   const std::vector<Json>& args, const Json& res) const {
    bool matched = false;

    Json entryerr = entry.get("err");
    if (!entryerr.isnone()) {
      std::string expected = stringify(entryerr);
      std::string actual = stringify(res);
      throw fail(flags, index, entry, "expected error did not occur", &expected, &actual);
    }

    Json check = entry.get("match");
    if (!check.isnone()) {
      Json base = Json::map();
      base.set("in", entry.get("in"));

      Json arglist = Json::list();
      for (const auto& arg : args) {
        arglist.push(arg);
      }
      base.set("args", arglist);
      base.set("out", entry.get("res"));
      base.set("ctx", entry.get("ctx"));

      matchcheck(flags, index, entry, check, base);
      matched = true;
    }

    Json out = entry.get("out");

    if (deepequal(res, out)) {
      return;
    }

    // NOTE: a match with no explicit out is a complete check on its own.
    if (matched && (out.isnone() || (out.isstr() && NULLMARK == out.strval))) {
      return;
    }

    std::string expected = stringify(out);
    std::string actual = stringify(res);
    throw fail(flags, index, entry, "result mismatch", &expected, &actual);
  }

  void handleerror(const Flags& flags, size_t index, const Json& entry,
                   const std::string& message) const {
    Json entryerr = entry.get("err");

    if (!entryerr.isnone()) {
      bool istrue = entryerr.isbool() && entryerr.boolval;

      if (istrue || matchval(entryerr, Json::str(message))) {
        Json check = entry.get("match");
        if (!check.isnone()) {
          Json base = Json::map();
          base.set("in", entry.get("in"));
          base.set("out", entry.get("res"));
          base.set("ctx", entry.get("ctx"));
          base.set("err", errify(message));
          matchcheck(flags, index, entry, check, base);
        }
        return;
      }

      std::string expected = stringify(entryerr);
      throw fail(flags, index, entry, "error mismatch", &expected, &message);
    }

    throw fail(flags, index, entry, "unexpected error", nullptr, &message);
  }
};

// Load a spec: a path to a JSON file.
inline Json loadspec(const std::string& path) { return Json::parsefile(path); }

// Convert NULLMARK sentinels back into real nulls. Use as a walk callback
// when a spec value must reach the subject as an actual null.
inline Json nullmodifier(const Json& val) {
  if (!val.isstr()) {
    return val;
  }

  if (NULLMARK == val.strval) {
    return Json::null();
  }

  std::string text = val.strval;
  std::string mark = NULLMARK;
  size_t at = text.find(mark);
  while (std::string::npos != at) {
    text = text.substr(0, at) + "null" + text.substr(at + mark.size());
    at = text.find(mark, at + 4);
  }

  return Json::str(text);
}

// Find `primary.<name>`, then `<name>`, then the whole spec.
inline Json resolvespec(const std::string& name, const Json& alltests) {
  if (name.empty()) {
    return alltests;
  }

  Json section = alltests.get("primary").get(name);
  if (!section.isabsent()) {
    return section;
  }

  section = alltests.get(name);
  if (!section.isabsent()) {
    return section;
  }

  return alltests;
}

// A loaded spec plus its provider.
class Runner {
 public:
  // Fail fast: resolveversion runs immediately after the spec is loaded, so
  // a version this runner cannot faithfully run is refused before any entry
  // in it gets a chance to run.
  Runner(const Json& alltests, const std::shared_ptr<Provider>& provider)
      : alltests_(alltests),
        specversion_(resolveversion(alltests)),
        provider_(provider ? provider : std::make_shared<Provider>()) {}

  // Resolve one named section of the spec.
  RunPack runner(const std::string& name, const Json& store = Json::absent()) const {
    Json spec = resolvespec(name, alltests_);

    std::map<std::string, std::shared_ptr<Provider>> clients;

    Json defclient = spec.get("DEF").get("client");

    // A spec may define clients that a given test run never references.
    if (defclient.ismap() && provider_->client) {
      for (const auto& entry : defclient.mapval) {
        Json copts = entry.second.get("test").get("options");
        if (copts.isabsent()) {
          copts = Json::map();
        }
        if (provider_->inject && store.ismap()) {
          copts = provider_->inject(copts, store);
        }
        clients[entry.first] = provider_->client(copts);
      }
    }

    Subject subject;
    if (provider_->subject && !name.empty()) {
      subject = provider_->subject(name);
    }

    return RunPack(spec, subject, provider_, clients, name, specversion_);
  }

 private:
  Json alltests_;
  int specversion_;
  std::shared_ptr<Provider> provider_;
};

// Make a runner for a spec file path and a provider.
inline Runner makeRunner(const std::string& path,
                         const std::shared_ptr<Provider>& provider = nullptr) {
  return Runner(Json::parsefile(path), provider);
}

// Make a runner for an in-memory spec and a provider.
inline Runner makeRunner(const Json& spec,
                         const std::shared_ptr<Provider>& provider = nullptr) {
  return Runner(spec, provider);
}

}  // namespace omni

#endif  // VOXGIG_OMNI_HPP
