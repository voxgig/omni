// The omni JSON value model, with a small in-tree parser.
//
// The omni runner must be able to test *any* library, and must add no
// third-party dependencies, so it carries its own JSON support rather than
// borrowing nlohmann/json or the system under test.

#ifndef VOXGIG_OMNI_JSON_HPP
#define VOXGIG_OMNI_JSON_HPP

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <initializer_list>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace omni {

// A JSON value. `Absent` is the marker for "no value at all", as distinct
// from `Null`.
class Json {
 public:
  enum class Type { Absent, Null, Bool, Num, Str, List, Map };

  Type type = Type::Absent;
  bool boolval = false;
  double numval = 0.0;
  std::string strval;
  std::vector<Json> listval;
  std::vector<std::pair<std::string, Json>> mapval;

  Json() = default;

  static Json absent() { return Json(); }

  static Json null() {
    Json out;
    out.type = Type::Null;
    return out;
  }

  static Json boolean(bool val) {
    Json out;
    out.type = Type::Bool;
    out.boolval = val;
    return out;
  }

  static Json num(double val) {
    Json out;
    out.type = Type::Num;
    out.numval = val;
    return out;
  }

  static Json str(const std::string& val) {
    Json out;
    out.type = Type::Str;
    out.strval = val;
    return out;
  }

  static Json list(std::initializer_list<Json> entries = {}) {
    Json out;
    out.type = Type::List;
    out.listval.assign(entries.begin(), entries.end());
    return out;
  }

  static Json map(std::initializer_list<std::pair<std::string, Json>> entries = {}) {
    Json out;
    out.type = Type::Map;
    for (const auto& entry : entries) {
      out.set(entry.first, entry.second);
    }
    return out;
  }

  bool ismap() const { return Type::Map == type; }
  bool islist() const { return Type::List == type; }
  bool isnode() const { return ismap() || islist(); }
  bool isabsent() const { return Type::Absent == type; }
  bool isnull() const { return Type::Null == type; }
  bool isnone() const { return isabsent() || isnull(); }
  bool isnum() const { return Type::Num == type; }
  bool isstr() const { return Type::Str == type; }
  bool isbool() const { return Type::Bool == type; }

  // Read a map entry. Returns an absent value when missing.
  Json get(const std::string& key) const {
    if (ismap()) {
      for (const auto& entry : mapval) {
        if (entry.first == key) {
          return entry.second;
        }
      }
    }
    return Json::absent();
  }

  bool has(const std::string& key) const {
    if (!ismap()) {
      return false;
    }
    for (const auto& entry : mapval) {
      if (entry.first == key) {
        return true;
      }
    }
    return false;
  }

  void set(const std::string& key, const Json& val) {
    if (Type::Map != type) {
      type = Type::Map;
    }
    for (auto& entry : mapval) {
      if (entry.first == key) {
        entry.second = val;
        return;
      }
    }
    mapval.emplace_back(key, val);
  }

  void push(const Json& val) {
    if (Type::List != type) {
      type = Type::List;
    }
    listval.push_back(val);
  }

  Json at(size_t index) const {
    if (islist() && index < listval.size()) {
      return listval[index];
    }
    return Json::absent();
  }

  size_t size() const {
    if (islist()) {
      return listval.size();
    }
    if (ismap()) {
      return mapval.size();
    }
    return 0;
  }

  // ---- parsing ----

  static Json parse(const std::string& text) {
    size_t pos = 0;
    skipws(text, pos);
    Json val = parseval(text, pos);
    skipws(text, pos);
    if (pos < text.size()) {
      throw std::runtime_error("omni: trailing JSON content at " + std::to_string(pos));
    }
    return val;
  }

  static Json parsefile(const std::string& path) {
    std::ifstream handle(path);
    if (!handle) {
      throw std::runtime_error("omni: cannot read spec: " + path);
    }
    std::stringstream buffer;
    buffer << handle.rdbuf();
    return parse(buffer.str());
  }

 private:
  static void skipws(const std::string& text, size_t& pos) {
    while (pos < text.size()) {
      char ch = text[pos];
      if (' ' == ch || '\t' == ch || '\n' == ch || '\r' == ch) {
        pos++;
      } else {
        break;
      }
    }
  }

  static Json parseval(const std::string& text, size_t& pos) {
    if (pos >= text.size()) {
      throw std::runtime_error("omni: unexpected end of JSON");
    }

    char ch = text[pos];

    if ('{' == ch) {
      return parsemap(text, pos);
    }
    if ('[' == ch) {
      return parselist(text, pos);
    }
    if ('"' == ch) {
      return Json::str(parsestr(text, pos));
    }
    if ('t' == ch) {
      parseword(text, pos, "true");
      return Json::boolean(true);
    }
    if ('f' == ch) {
      parseword(text, pos, "false");
      return Json::boolean(false);
    }
    if ('n' == ch) {
      parseword(text, pos, "null");
      return Json::null();
    }

    return parsenum(text, pos);
  }

  static void parseword(const std::string& text, size_t& pos, const std::string& word) {
    if (0 != text.compare(pos, word.size(), word)) {
      throw std::runtime_error("omni: bad JSON literal at " + std::to_string(pos));
    }
    pos += word.size();
  }

  static Json parsemap(const std::string& text, size_t& pos) {
    Json out = Json::map();
    pos++;  // {

    skipws(text, pos);
    if (pos < text.size() && '}' == text[pos]) {
      pos++;
      return out;
    }

    for (;;) {
      skipws(text, pos);
      std::string key = parsestr(text, pos);
      skipws(text, pos);

      if (pos >= text.size() || ':' != text[pos]) {
        throw std::runtime_error("omni: expected ':' at " + std::to_string(pos));
      }
      pos++;

      skipws(text, pos);
      out.set(key, parseval(text, pos));
      skipws(text, pos);

      if (pos >= text.size()) {
        throw std::runtime_error("omni: unterminated JSON object");
      }
      if (',' == text[pos]) {
        pos++;
        continue;
      }
      if ('}' == text[pos]) {
        pos++;
        return out;
      }
      throw std::runtime_error("omni: expected ',' or '}' at " + std::to_string(pos));
    }
  }

  static Json parselist(const std::string& text, size_t& pos) {
    Json out = Json::list();
    pos++;  // [

    skipws(text, pos);
    if (pos < text.size() && ']' == text[pos]) {
      pos++;
      return out;
    }

    for (;;) {
      skipws(text, pos);
      out.push(parseval(text, pos));
      skipws(text, pos);

      if (pos >= text.size()) {
        throw std::runtime_error("omni: unterminated JSON array");
      }
      if (',' == text[pos]) {
        pos++;
        continue;
      }
      if (']' == text[pos]) {
        pos++;
        return out;
      }
      throw std::runtime_error("omni: expected ',' or ']' at " + std::to_string(pos));
    }
  }

  static std::string parsestr(const std::string& text, size_t& pos) {
    if (pos >= text.size() || '"' != text[pos]) {
      throw std::runtime_error("omni: expected string at " + std::to_string(pos));
    }
    pos++;

    std::string out;

    while (pos < text.size()) {
      char ch = text[pos++];

      if ('"' == ch) {
        return out;
      }

      if ('\\' != ch) {
        out.push_back(ch);
        continue;
      }

      if (pos >= text.size()) {
        break;
      }

      char escape = text[pos++];
      switch (escape) {
        case '"':
          out.push_back('"');
          break;
        case '\\':
          out.push_back('\\');
          break;
        case '/':
          out.push_back('/');
          break;
        case 'b':
          out.push_back('\b');
          break;
        case 'f':
          out.push_back('\f');
          break;
        case 'n':
          out.push_back('\n');
          break;
        case 'r':
          out.push_back('\r');
          break;
        case 't':
          out.push_back('\t');
          break;
        case 'u': {
          if (pos + 4 > text.size()) {
            throw std::runtime_error("omni: bad JSON unicode escape");
          }
          unsigned int code =
              static_cast<unsigned int>(std::stoul(text.substr(pos, 4), nullptr, 16));
          pos += 4;
          if (0x80 > code) {
            out.push_back(static_cast<char>(code));
          } else if (0x800 > code) {
            out.push_back(static_cast<char>(0xC0 | (code >> 6)));
            out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
          } else {
            out.push_back(static_cast<char>(0xE0 | (code >> 12)));
            out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
          }
          break;
        }
        default:
          throw std::runtime_error("omni: bad JSON escape at " + std::to_string(pos));
      }
    }

    throw std::runtime_error("omni: unterminated JSON string");
  }

  static Json parsenum(const std::string& text, size_t& pos) {
    size_t start = pos;

    if (pos < text.size() && ('-' == text[pos] || '+' == text[pos])) {
      pos++;
    }

    while (pos < text.size()) {
      char ch = text[pos];
      if (std::isdigit(static_cast<unsigned char>(ch)) || '.' == ch || 'e' == ch || 'E' == ch ||
          '-' == ch || '+' == ch) {
        pos++;
      } else {
        break;
      }
    }

    std::string span = text.substr(start, pos - start);
    try {
      return Json::num(std::stod(span));
    } catch (const std::exception&) {
      throw std::runtime_error("omni: bad JSON number [" + span + "] at " +
                               std::to_string(start));
    }
  }
};

}  // namespace omni

#endif  // VOXGIG_OMNI_JSON_HPP
