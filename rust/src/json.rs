//! The omni JSON value model, with a small in-tree parser.
//!
//! The omni runner must be able to test *any* library, and must add no
//! third-party dependencies, so it carries its own JSON support rather
//! than borrowing serde or the system under test.

use std::collections::BTreeMap;
use std::fmt;

/// A JSON value. `Absent` is the marker for "no value at all", as distinct
/// from `Null`.
#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Absent,
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    List(Vec<Json>),
    Map(BTreeMap<String, Json>),
}

impl Json {
    /// A map (JSON object)?
    pub fn ismap(&self) -> bool {
        matches!(self, Json::Map(_))
    }

    /// A list (JSON array)?
    pub fn islist(&self) -> bool {
        matches!(self, Json::List(_))
    }

    /// A container (map or list)?
    pub fn isnode(&self) -> bool {
        self.ismap() || self.islist()
    }

    /// Absent (no value at all)?
    pub fn isabsent(&self) -> bool {
        matches!(self, Json::Absent)
    }

    /// Null (a JSON null)?
    pub fn isnull(&self) -> bool {
        matches!(self, Json::Null)
    }

    /// Absent or null?
    pub fn isnone(&self) -> bool {
        self.isabsent() || self.isnull()
    }

    /// A JSON number? Booleans are not numbers.
    pub fn isnum(&self) -> bool {
        matches!(self, Json::Num(_))
    }

    pub fn asnum(&self) -> Option<f64> {
        match self {
            Json::Num(num) => Some(*num),
            _ => None,
        }
    }

    pub fn asstr(&self) -> Option<&str> {
        match self {
            Json::Str(text) => Some(text),
            _ => None,
        }
    }

    pub fn asmap(&self) -> Option<&BTreeMap<String, Json>> {
        match self {
            Json::Map(map) => Some(map),
            _ => None,
        }
    }

    pub fn aslist(&self) -> Option<&Vec<Json>> {
        match self {
            Json::List(list) => Some(list),
            _ => None,
        }
    }

    /// Read a map entry. Returns `Absent` when missing.
    pub fn get(&self, key: &str) -> Json {
        match self {
            Json::Map(map) => map.get(key).cloned().unwrap_or(Json::Absent),
            _ => Json::Absent,
        }
    }

    /// Is a map key present at all (even with a null value)?
    pub fn has(&self, key: &str) -> bool {
        match self {
            Json::Map(map) => map.contains_key(key),
            _ => false,
        }
    }

    /// Build a map value.
    pub fn map(entries: Vec<(&str, Json)>) -> Json {
        let mut out = BTreeMap::new();
        for (key, val) in entries {
            out.insert(key.to_string(), val);
        }
        Json::Map(out)
    }

    /// Build a list value.
    pub fn list(entries: Vec<Json>) -> Json {
        Json::List(entries)
    }

    /// Build a string value.
    pub fn str(text: &str) -> Json {
        Json::Str(text.to_string())
    }
}

impl fmt::Display for Json {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(out, "{}", crate::util::jsonstr(self))
    }
}

impl From<f64> for Json {
    fn from(val: f64) -> Json {
        Json::Num(val)
    }
}

impl From<i64> for Json {
    fn from(val: i64) -> Json {
        Json::Num(val as f64)
    }
}

impl From<usize> for Json {
    fn from(val: usize) -> Json {
        Json::Num(val as f64)
    }
}

impl From<bool> for Json {
    fn from(val: bool) -> Json {
        Json::Bool(val)
    }
}

impl From<&str> for Json {
    fn from(val: &str) -> Json {
        Json::Str(val.to_string())
    }
}

impl From<String> for Json {
    fn from(val: String) -> Json {
        Json::Str(val)
    }
}

/// Maximum nesting depth the parser will follow. Omni specs are trusted
/// input, so this is crash-safety, not a security boundary: past this
/// depth the recursive parser would overflow the stack and abort the
/// process, so it returns an error instead. 1024 is far beyond any real
/// spec, and low enough that reaching the limit itself fits comfortably
/// in a default (2MiB) test-thread stack even in debug builds.
const MAX_DEPTH: usize = 1024;

/// Parse JSON text into a [`Json`] value.
pub fn parse(text: &str) -> Result<Json, String> {
    let chars: Vec<char> = text.chars().collect();
    let mut pos = 0usize;

    skipws(&chars, &mut pos);
    let val = parseval(&chars, &mut pos, 0)?;
    skipws(&chars, &mut pos);

    if pos < chars.len() {
        return Err(format!("omni: trailing JSON content at {}", pos));
    }

    Ok(val)
}

fn skipws(chars: &[char], pos: &mut usize) {
    while *pos < chars.len() {
        let char = chars[*pos];
        if char == ' ' || char == '\t' || char == '\n' || char == '\r' {
            *pos += 1;
        } else {
            break;
        }
    }
}

fn parseval(chars: &[char], pos: &mut usize, depth: usize) -> Result<Json, String> {
    if depth > MAX_DEPTH {
        return Err(format!("omni: JSON nested too deeply at {}", pos));
    }

    if *pos >= chars.len() {
        return Err("omni: unexpected end of JSON".to_string());
    }

    match chars[*pos] {
        '{' => parsemap(chars, pos, depth),
        '[' => parselist(chars, pos, depth),
        '"' => Ok(Json::Str(parsestr(chars, pos)?)),
        't' => parseword(chars, pos, "true", Json::Bool(true)),
        'f' => parseword(chars, pos, "false", Json::Bool(false)),
        'n' => parseword(chars, pos, "null", Json::Null),
        _ => parsenum(chars, pos),
    }
}

fn parseword(chars: &[char], pos: &mut usize, word: &str, val: Json) -> Result<Json, String> {
    for expect in word.chars() {
        if *pos >= chars.len() || chars[*pos] != expect {
            return Err(format!("omni: bad JSON literal at {}", pos));
        }
        *pos += 1;
    }
    Ok(val)
}

fn parsemap(chars: &[char], pos: &mut usize, depth: usize) -> Result<Json, String> {
    let mut out = BTreeMap::new();
    *pos += 1; // {

    skipws(chars, pos);
    if *pos < chars.len() && chars[*pos] == '}' {
        *pos += 1;
        return Ok(Json::Map(out));
    }

    loop {
        skipws(chars, pos);
        let key = parsestr(chars, pos)?;
        skipws(chars, pos);

        if *pos >= chars.len() || chars[*pos] != ':' {
            return Err(format!("omni: expected ':' at {}", pos));
        }
        *pos += 1;

        skipws(chars, pos);
        let val = parseval(chars, pos, depth + 1)?;
        out.insert(key, val);

        skipws(chars, pos);
        if *pos >= chars.len() {
            return Err("omni: unterminated JSON object".to_string());
        }
        if chars[*pos] == ',' {
            *pos += 1;
            continue;
        }
        if chars[*pos] == '}' {
            *pos += 1;
            return Ok(Json::Map(out));
        }
        return Err(format!("omni: expected ',' or '}}' at {}", pos));
    }
}

fn parselist(chars: &[char], pos: &mut usize, depth: usize) -> Result<Json, String> {
    let mut out = Vec::new();
    *pos += 1; // [

    skipws(chars, pos);
    if *pos < chars.len() && chars[*pos] == ']' {
        *pos += 1;
        return Ok(Json::List(out));
    }

    loop {
        skipws(chars, pos);
        out.push(parseval(chars, pos, depth + 1)?);

        skipws(chars, pos);
        if *pos >= chars.len() {
            return Err("omni: unterminated JSON array".to_string());
        }
        if chars[*pos] == ',' {
            *pos += 1;
            continue;
        }
        if chars[*pos] == ']' {
            *pos += 1;
            return Ok(Json::List(out));
        }
        return Err(format!("omni: expected ',' or ']' at {}", pos));
    }
}

fn parsestr(chars: &[char], pos: &mut usize) -> Result<String, String> {
    if *pos >= chars.len() || chars[*pos] != '"' {
        return Err(format!("omni: expected string at {}", pos));
    }
    *pos += 1;

    let mut out = String::new();

    while *pos < chars.len() {
        let char = chars[*pos];
        *pos += 1;

        if char == '"' {
            return Ok(out);
        }

        if char != '\\' {
            out.push(char);
            continue;
        }

        if *pos >= chars.len() {
            break;
        }

        let escape = chars[*pos];
        *pos += 1;

        match escape {
            '"' => out.push('"'),
            '\\' => out.push('\\'),
            '/' => out.push('/'),
            'b' => out.push('\u{8}'),
            'f' => out.push('\u{c}'),
            'n' => out.push('\n'),
            'r' => out.push('\r'),
            't' => out.push('\t'),
            'u' => {
                let mut code = 0u32;
                for _ in 0..4 {
                    if *pos >= chars.len() {
                        return Err("omni: bad JSON unicode escape".to_string());
                    }
                    let digit = chars[*pos]
                        .to_digit(16)
                        .ok_or_else(|| "omni: bad JSON unicode escape".to_string())?;
                    code = code * 16 + digit;
                    *pos += 1;
                }
                out.push(char::from_u32(code).unwrap_or('\u{fffd}'));
            }
            _ => return Err(format!("omni: bad JSON escape at {}", pos)),
        }
    }

    Err("omni: unterminated JSON string".to_string())
}

fn parsenum(chars: &[char], pos: &mut usize) -> Result<Json, String> {
    let start = *pos;

    if *pos < chars.len() && (chars[*pos] == '-' || chars[*pos] == '+') {
        *pos += 1;
    }

    while *pos < chars.len() {
        let char = chars[*pos];
        if char.is_ascii_digit()
            || char == '.'
            || char == 'e'
            || char == 'E'
            || char == '-'
            || char == '+'
        {
            *pos += 1;
        } else {
            break;
        }
    }

    let text: String = chars[start..*pos].iter().collect();
    text.parse::<f64>()
        .map(Json::Num)
        .map_err(|_| format!("omni: bad JSON number [{}] at {}", text, start))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Deeply nested input must produce a parse error, not overflow the
    // stack and abort the process.
    #[test]
    fn parse_rejects_deep_nesting() {
        let deep = "[".repeat(MAX_DEPTH * 4);
        let err = parse(&deep).expect_err("deep nesting must be rejected");
        assert!(err.contains("nested too deeply"), "unexpected error: {}", err);

        let deepmap = "{\"a\":".repeat(MAX_DEPTH * 4);
        let err = parse(&deepmap).expect_err("deep nesting must be rejected");
        assert!(err.contains("nested too deeply"), "unexpected error: {}", err);
    }

    // Reasonable nesting still parses.
    #[test]
    fn parse_allows_reasonable_nesting() {
        let text = format!("{}1{}", "[".repeat(64), "]".repeat(64));
        assert!(parse(&text).is_ok());
    }
}
