//! Omni internal JSON utilities.
//!
//! Self-contained by design: the omni runner must be able to test *any*
//! library, including libraries that provide these same operations.

use crate::json::Json;

pub const NULLMARK: &str = "__NULL__"; // Value is JSON null.
pub const UNDEFMARK: &str = "__UNDEF__"; // Value is not present.
pub const EXISTSMARK: &str = "__EXISTS__"; // Value exists (not undefined).

/// Deep copy a JSON value.
pub fn clone(val: &Json) -> Json {
    val.clone()
}

/// Read a value by path. Returns `Json::Absent` when any step is missing.
pub fn getpath(val: &Json, path: &[String]) -> Json {
    let mut current = val.clone();

    for part in path {
        current = match &current {
            Json::List(list) => match part.parse::<usize>() {
                Ok(index) if index < list.len() => list[index].clone(),
                _ => return Json::Absent,
            },
            Json::Map(map) => match map.get(part) {
                Some(entry) => entry.clone(),
                None => return Json::Absent,
            },
            _ => return Json::Absent,
        };
    }

    current
}

/// Depth-first walk: children first, then the containing node. `apply` may
/// replace the value.
pub fn walk(val: &Json, apply: &dyn Fn(&Json, &[String]) -> Json) -> Json {
    walkdown(val, apply, &[])
}

fn walkdown(val: &Json, apply: &dyn Fn(&Json, &[String]) -> Json, path: &[String]) -> Json {
    let next = match val {
        Json::List(list) => {
            let mut out = Vec::with_capacity(list.len());
            for (index, entry) in list.iter().enumerate() {
                let mut childpath = path.to_vec();
                childpath.push(index.to_string());
                out.push(walkdown(entry, apply, &childpath));
            }
            Json::List(out)
        }
        Json::Map(map) => {
            let mut out = std::collections::BTreeMap::new();
            for (key, entry) in map.iter() {
                let mut childpath = path.to_vec();
                childpath.push(key.clone());
                out.insert(key.clone(), walkdown(entry, apply, &childpath));
            }
            Json::Map(out)
        }
        other => other.clone(),
    };

    apply(&next, path)
}

/// Deep structural equality: numbers by value, bools never numbers.
pub fn deepequal(a: &Json, b: &Json) -> bool {
    match (a, b) {
        (Json::Absent, Json::Absent) => true,
        (Json::Null, Json::Null) => true,
        (Json::Bool(x), Json::Bool(y)) => x == y,
        (Json::Num(x), Json::Num(y)) => x == y || (x.is_nan() && y.is_nan()),
        (Json::Str(x), Json::Str(y)) => x == y,
        (Json::List(x), Json::List(y)) => {
            x.len() == y.len() && x.iter().zip(y.iter()).all(|(xe, ye)| deepequal(xe, ye))
        }
        (Json::Map(x), Json::Map(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(key, val)| y.get(key).map(|other| deepequal(val, other)).unwrap_or(false))
        }
        _ => false,
    }
}

/// Render a number the same way in every port: 5.0 prints as 5.
pub fn numstr(val: f64) -> String {
    if val.is_nan() || val.is_infinite() {
        return "null".to_string();
    }
    if val == val.trunc() && val.abs() < 9007199254740992.0 {
        return format!("{}", val as i64);
    }
    format!("{}", val)
}

/// Render a string as a JSON string literal.
pub fn quote(val: &str) -> String {
    let mut out = String::from("\"");
    for char in val.chars() {
        match char {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            _ => {
                if (char as u32) < 0x20 {
                    out.push_str(&format!("\\u{:04x}", char as u32));
                } else {
                    out.push(char);
                }
            }
        }
    }
    out.push('"');
    out
}

/// Compact JSON text with map keys sorted, identical in every port.
pub fn jsonstr(val: &Json) -> String {
    match val {
        Json::Absent => "undefined".to_string(),
        Json::Null => "null".to_string(),
        Json::Bool(flag) => (if *flag { "true" } else { "false" }).to_string(),
        Json::Num(num) => numstr(*num),
        Json::Str(text) => quote(text),
        Json::List(list) => {
            let parts: Vec<String> = list.iter().map(jsonstr).collect();
            format!("[{}]", parts.join(","))
        }
        Json::Map(map) => {
            // BTreeMap iterates in key order, so this is already sorted.
            let parts: Vec<String> = map
                .iter()
                .map(|(key, entry)| format!("{}:{}", quote(key), jsonstr(entry)))
                .collect();
            format!("{{{}}}", parts.join(","))
        }
    }
}

/// Strings verbatim, everything else as compact JSON.
pub fn stringify(val: &Json) -> String {
    match val {
        Json::Str(text) => text.clone(),
        other => jsonstr(other),
    }
}

/// Render a path as a dotted string.
pub fn pathify(path: &[String]) -> String {
    path.join(".")
}
