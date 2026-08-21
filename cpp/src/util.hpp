// Omni internal JSON utilities.
//
// Self-contained by design: the omni runner must be able to test *any*
// library, including libraries that provide these same operations.

#ifndef VOXGIG_OMNI_UTIL_HPP
#define VOXGIG_OMNI_UTIL_HPP

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "json.hpp"

namespace omni {

inline const char* const NULLMARK = "__NULL__";      // Value is JSON null.
inline const char* const UNDEFMARK = "__UNDEF__";    // Value is not present.
inline const char* const EXISTSMARK = "__EXISTS__";  // Value exists.

// Deep copy a JSON value (values already have copy semantics).
inline Json clone(const Json& val) { return val; }

// Read a value by path. Returns an absent value when a step is missing.
inline Json getpath(const Json& val, const std::vector<std::string>& path) {
  Json current = val;

  for (const auto& part : path) {
    if (current.islist()) {
      size_t index = 0;
      try {
        index = static_cast<size_t>(std::stoul(part));
      } catch (const std::exception&) {
        return Json::absent();
      }
      if (index >= current.listval.size()) {
        return Json::absent();
      }
      // NOT `current = current.listval[index]`. That is a self-assignment
      // through a member of the object being assigned: copy-assignment
      // overwrites `listval` while the right-hand side still lives inside it,
      // and the following members are copied out of freed storage. The value
      // came back with its map keys mangled. Copy out first, then assign.
      Json next = current.listval[index];
      current = next;
      continue;
    }

    if (current.ismap()) {
      if (!current.has(part)) {
        return Json::absent();
      }
      current = current.get(part);
      continue;
    }

    return Json::absent();
  }

  return current;
}

// Depth-first walk: children first, then the containing node.
inline Json walk(const Json& val,
                 const std::function<Json(const Json&, const std::vector<std::string>&)>& apply,
                 std::vector<std::string> path = {}) {
  Json next = val;

  if (val.islist()) {
    next.listval.clear();
    for (size_t index = 0; index < val.listval.size(); index++) {
      std::vector<std::string> childpath = path;
      childpath.push_back(std::to_string(index));
      next.listval.push_back(walk(val.listval[index], apply, childpath));
    }
  } else if (val.ismap()) {
    next.mapval.clear();
    for (const auto& entry : val.mapval) {
      std::vector<std::string> childpath = path;
      childpath.push_back(entry.first);
      next.mapval.emplace_back(entry.first, walk(entry.second, apply, childpath));
    }
  }

  return apply(next, path);
}

// Deep structural equality: numbers by value, bools never numbers.
inline bool deepequal(const Json& a, const Json& b) {
  if (a.type != b.type) {
    return false;
  }

  switch (a.type) {
    case Json::Type::Absent:
    case Json::Type::Null:
      return true;
    case Json::Type::Bool:
      return a.boolval == b.boolval;
    case Json::Type::Num:
      return a.numval == b.numval || (std::isnan(a.numval) && std::isnan(b.numval));
    case Json::Type::Str:
      return a.strval == b.strval;
    case Json::Type::List: {
      if (a.listval.size() != b.listval.size()) {
        return false;
      }
      for (size_t index = 0; index < a.listval.size(); index++) {
        if (!deepequal(a.listval[index], b.listval[index])) {
          return false;
        }
      }
      return true;
    }
    case Json::Type::Map: {
      if (a.mapval.size() != b.mapval.size()) {
        return false;
      }
      for (const auto& entry : a.mapval) {
        if (!b.has(entry.first)) {
          return false;
        }
        if (!deepequal(entry.second, b.get(entry.first))) {
          return false;
        }
      }
      return true;
    }
  }

  return false;
}

// Render a number the same way in every port: 5.0 prints as 5.
inline std::string numstr(double val) {
  if (std::isnan(val) || std::isinf(val)) {
    return "null";
  }

  char text[64];

  if (val == std::floor(val) && std::fabs(val) < 9007199254740992.0) {
    std::snprintf(text, sizeof(text), "%.0f", val);
    if (0 == std::string(text).compare("-0")) {
      return "0";
    }
    return text;
  }

  std::snprintf(text, sizeof(text), "%.17g", val);
  return text;
}

// Render a string as a JSON string literal.
inline std::string quote(const std::string& val) {
  std::string out = "\"";

  for (char ch : val) {
    switch (ch) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (0x20 > static_cast<unsigned char>(ch)) {
          char escape[8];
          std::snprintf(escape, sizeof(escape), "\\u%04x", static_cast<unsigned char>(ch));
          out += escape;
        } else {
          out.push_back(ch);
        }
    }
  }

  return out + "\"";
}

// Compact JSON text with map keys sorted, identical in every port.
inline std::string jsonstr(const Json& val) {
  switch (val.type) {
    case Json::Type::Absent:
      return "undefined";
    case Json::Type::Null:
      return "null";
    case Json::Type::Bool:
      return val.boolval ? "true" : "false";
    case Json::Type::Num:
      return numstr(val.numval);
    case Json::Type::Str:
      return quote(val.strval);
    case Json::Type::List: {
      std::string out = "[";
      for (size_t index = 0; index < val.listval.size(); index++) {
        if (0 < index) {
          out += ",";
        }
        out += jsonstr(val.listval[index]);
      }
      return out + "]";
    }
    case Json::Type::Map: {
      std::vector<std::pair<std::string, Json>> sorted = val.mapval;
      std::sort(sorted.begin(), sorted.end(),
                [](const std::pair<std::string, Json>& a,
                   const std::pair<std::string, Json>& b) { return a.first < b.first; });

      std::string out = "{";
      for (size_t index = 0; index < sorted.size(); index++) {
        if (0 < index) {
          out += ",";
        }
        out += quote(sorted[index].first) + ":" + jsonstr(sorted[index].second);
      }
      return out + "}";
    }
  }

  return "undefined";
}

// Strings verbatim, everything else as compact JSON.
inline std::string stringify(const Json& val) {
  return val.isstr() ? val.strval : jsonstr(val);
}

// Render a path as a dotted string.
inline std::string pathify(const std::vector<std::string>& path) {
  std::string out;
  for (size_t index = 0; index < path.size(); index++) {
    if (0 < index) {
      out += ".";
    }
    out += path[index];
  }
  return out;
}

}  // namespace omni

#endif  // VOXGIG_OMNI_UTIL_HPP
