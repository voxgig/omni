// Minimal JSON parser for omni.
//
// The omni runner must be able to test *any* library, and must add no
// third-party dependencies, so it carries its own JSON support rather than
// borrowing Gson, Jackson, or the system under test.
//
// Parses into plain Java values:
//   object  -> LinkedHashMap<String,Object> (insertion ordered)
//   array   -> ArrayList<Object>
//   string  -> String
//   number  -> Double
//   boolean -> Boolean
//   null    -> null

package com.voxgig.omni;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class Json {

  private Json() {}

  /** Absence, as distinct from a JSON null. Java has no `undefined`. */
  public static final class Absent {
    private static final Absent MARK = new Absent();

    private Absent() {}

    public static Absent mark() {
      return MARK;
    }

    @Override
    public String toString() {
      return "ABSENT";
    }
  }

  public static final Absent ABSENT = Absent.mark();

  public static class JsonError extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public JsonError(String message) {
      super(message);
    }
  }

  public static Object parse(String text) {
    Parser parser = new Parser(text);
    parser.skipws();
    Object val = parser.value();
    parser.skipws();
    if (!parser.done()) {
      throw new JsonError("omni: trailing JSON content at " + parser.pos);
    }
    return val;
  }

  private static final class Parser {
    private final String text;
    private int pos;

    Parser(String text) {
      this.text = text;
      this.pos = 0;
    }

    boolean done() {
      return pos >= text.length();
    }

    void skipws() {
      while (pos < text.length()) {
        char c = text.charAt(pos);
        if (' ' == c || '\t' == c || '\n' == c || '\r' == c) {
          pos++;
        } else {
          break;
        }
      }
    }

    Object value() {
      if (done()) {
        throw new JsonError("omni: unexpected end of JSON");
      }

      char c = text.charAt(pos);

      if ('{' == c) {
        return map();
      }
      if ('[' == c) {
        return list();
      }
      if ('"' == c) {
        return str();
      }
      if ('t' == c) {
        word("true");
        return Boolean.TRUE;
      }
      if ('f' == c) {
        word("false");
        return Boolean.FALSE;
      }
      if ('n' == c) {
        word("null");
        return null;
      }

      return num();
    }

    void word(String want) {
      if (!text.startsWith(want, pos)) {
        throw new JsonError("omni: bad JSON literal at " + pos);
      }
      pos += want.length();
    }

    Map<String, Object> map() {
      Map<String, Object> out = new LinkedHashMap<>();
      pos++; // {

      skipws();
      if (!done() && '}' == text.charAt(pos)) {
        pos++;
        return out;
      }

      while (true) {
        skipws();
        String key = str();
        skipws();

        if (done() || ':' != text.charAt(pos)) {
          throw new JsonError("omni: expected ':' at " + pos);
        }
        pos++;

        skipws();
        out.put(key, value());
        skipws();

        if (done()) {
          throw new JsonError("omni: unterminated JSON object");
        }
        if (',' == text.charAt(pos)) {
          pos++;
          continue;
        }
        if ('}' == text.charAt(pos)) {
          pos++;
          return out;
        }
        throw new JsonError("omni: expected ',' or '}' at " + pos);
      }
    }

    List<Object> list() {
      List<Object> out = new ArrayList<>();
      pos++; // [

      skipws();
      if (!done() && ']' == text.charAt(pos)) {
        pos++;
        return out;
      }

      while (true) {
        skipws();
        out.add(value());
        skipws();

        if (done()) {
          throw new JsonError("omni: unterminated JSON array");
        }
        if (',' == text.charAt(pos)) {
          pos++;
          continue;
        }
        if (']' == text.charAt(pos)) {
          pos++;
          return out;
        }
        throw new JsonError("omni: expected ',' or ']' at " + pos);
      }
    }

    String str() {
      if (done() || '"' != text.charAt(pos)) {
        throw new JsonError("omni: expected string at " + pos);
      }
      pos++;

      StringBuilder out = new StringBuilder();

      while (pos < text.length()) {
        char c = text.charAt(pos++);

        if ('"' == c) {
          return out.toString();
        }

        if ('\\' != c) {
          out.append(c);
          continue;
        }

        if (done()) {
          break;
        }

        char escape = text.charAt(pos++);
        switch (escape) {
          case '"':
            out.append('"');
            break;
          case '\\':
            out.append('\\');
            break;
          case '/':
            out.append('/');
            break;
          case 'b':
            out.append('\b');
            break;
          case 'f':
            out.append('\f');
            break;
          case 'n':
            out.append('\n');
            break;
          case 'r':
            out.append('\r');
            break;
          case 't':
            out.append('\t');
            break;
          case 'u':
            if (pos + 4 > text.length()) {
              throw new JsonError("omni: bad JSON unicode escape");
            }
            out.append((char) Integer.parseInt(text.substring(pos, pos + 4), 16));
            pos += 4;
            break;
          default:
            throw new JsonError("omni: bad JSON escape at " + pos);
        }
      }

      throw new JsonError("omni: unterminated JSON string");
    }

    Double num() {
      int start = pos;

      if (pos < text.length() && ('-' == text.charAt(pos) || '+' == text.charAt(pos))) {
        pos++;
      }

      while (pos < text.length()) {
        char c = text.charAt(pos);
        if (Character.isDigit(c) || '.' == c || 'e' == c || 'E' == c || '-' == c || '+' == c) {
          pos++;
        } else {
          break;
        }
      }

      String span = text.substring(start, pos);
      try {
        return Double.valueOf(span);
      } catch (NumberFormatException err) {
        throw new JsonError("omni: bad JSON number [" + span + "] at " + start);
      }
    }
  }
}
