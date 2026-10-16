// RUN: cargo test --test unicode

use voxgig_omni::{deepequal, loadspec, parse, Json, SpecRef};

fn strval(val: &Json) -> String {
    match val {
        Json::Str(text) => text.clone(),
        other => panic!("omni: expected a string, got {:?}", other),
    }
}

#[test]
fn escaped_surrogate_pair_is_the_literal_character() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/unicode.json");
    let spec = loadspec(SpecRef::Path(path.to_string())).expect("omni: fixture must load");
    let literal = spec.get("literal");

    assert_eq!("\u{1f600}", strval(&literal));
    assert!(deepequal(&spec.get("escaped"), &literal));
    assert!(deepequal(&spec.get("upper"), &literal));

    assert_eq!(
        "A\u{e9}\u{20ac}",
        strval(&parse("\"\\u0041\\u00e9\\u20ac\"").unwrap())
    );
    assert_eq!("a\u{0}b", strval(&parse("\"a\\u0000b\"").unwrap()));
}

#[test]
fn lone_surrogate_escape_is_refused() {
    for text in [
        "\"\\ud800\"",
        "\"\\ude00\"",
        "\"\\ude00\\ud83d\"",
        "\"\\ud83dx\"",
        "\"\\ud83d\\u0041\"",
        "\"\\ud83d\\ud83d\"",
    ] {
        let err = parse(text).expect_err(text);
        assert!(err.contains("lone surrogate"), "{}: {}", text, err);
    }
}
