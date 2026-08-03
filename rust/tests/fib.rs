// RUN: cargo test
// RUN-SOME: cargo test basic
//
// The Fibonacci conformance suite: every omni port runs this same set of
// groups, from the same spec/fib.json, against the same fib library.

mod common;

use std::path::PathBuf;
use std::rc::Rc;

use common::{fib, fibinfo, fibnum, fibrange, fibseq};
use voxgig_omni::{make_runner, Flags, Json, Provider, RunPack, Subject};

// Find the shared spec directory by walking up from this file.
fn specfile(name: &str) -> String {
    let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));

    for _step in 0..8 {
        let cand = dir.join("spec").join(name);
        if cand.exists() {
            return cand.to_string_lossy().to_string();
        }
        dir = match dir.parent() {
            Some(parent) => parent.to_path_buf(),
            None => break,
        };
    }

    panic!("omni: spec not found: {}", name);
}

fn subjects() -> (Subject, Subject, Subject, Subject) {
    (
        Rc::new(|args: &[Json]| fib(&args[0])),
        Rc::new(|args: &[Json]| fibseq(&args[0])),
        Rc::new(|args: &[Json]| fibrange(&args[0], &args[1])),
        Rc::new(|args: &[Json]| fibinfo(&args[0])),
    )
}

// The provider hosts the system under test. `shift` offsets the Fibonacci
// index, so that a client-specific subject is observably different.
fn fibprovider(shift: f64) -> Provider {
    Provider {
        subject: Some(Rc::new(move |name: &str| -> Option<Subject> {
            let (fibsub, seqsub, rangesub, infosub) = subjects();
            match name {
                "fib" => {
                    let shift = shift;
                    Some(Rc::new(move |args: &[Json]| match args[0].asnum() {
                        Some(num) => fib(&Json::Num(num + shift)),
                        None => fib(&args[0]),
                    }))
                }
                "fibseq" => Some(seqsub),
                "fibrange" => Some(rangesub),
                "fibinfo" => Some(infosub),
                _ => {
                    let _ = fibsub;
                    None
                }
            }
        })),
        client: Some(Rc::new(|options: &Json| {
            fibprovider(options.get("shift").asnum().unwrap_or(0.0))
        })),
        ..Provider::default()
    }
}

fn runpack() -> RunPack {
    let runner = make_runner(specfile("fib.json"), fibprovider(0.0)).expect("runner");
    runner.runner("fib", None).expect("spec")
}

#[test]
fn fib_conformance() {
    let pack = runpack();
    let (fibsub, seqsub, rangesub, infosub) = subjects();

    let groups: Vec<(&str, &Subject, Flags)> = vec![
        ("basic", &fibsub, Flags::default()),
        ("seq", &seqsub, Flags::default()),
        ("range", &rangesub, Flags::default()),
        ("info", &infosub, Flags::default()),
        ("nulls", &infosub, Flags::nonull()),
        ("error", &fibsub, Flags::default()),
        ("match", &fibsub, Flags::default()),
        ("matchinfo", &infosub, Flags::default()),
        ("client", &fibsub, Flags::default()),
    ];

    for (name, subject, flags) in groups {
        if let Err(err) = pack.runsetflags(&pack.set(name), &flags, Some(subject)) {
            panic!("group {}: {}", name, err);
        }
    }
}

#[test]
fn fib_numbers() {
    assert_eq!(0, fibnum(0));
    assert_eq!(1, fibnum(1));
    assert_eq!(55, fibnum(10));
    assert_eq!(832040, fibnum(30));
}

// The runner must fail when the subject is wrong - otherwise a green suite
// means nothing.
fn badspec() -> Json {
    Json::map(vec![(
        "fib",
        Json::map(vec![
            (
                "wrongout",
                Json::map(vec![(
                    "set",
                    Json::list(vec![
                        Json::map(vec![("in", Json::Num(5.0)), ("out", Json::Num(5.0))]),
                        Json::map(vec![("in", Json::Num(6.0)), ("out", Json::Num(999.0))]),
                    ]),
                )]),
            ),
            (
                "wrongerr",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(1.0)),
                        ("err", Json::str("never happens")),
                    ])]),
                )]),
            ),
            (
                "wrongmatch",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(6.0)),
                        ("match", Json::map(vec![("out", Json::Num(999.0))])),
                    ])]),
                )]),
            ),
            (
                "missing",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(6.0)),
                        (
                            "match",
                            Json::map(vec![(
                                "out",
                                Json::map(vec![("nope", Json::str("__EXISTS__"))]),
                            )]),
                        ),
                    ])]),
                )]),
            ),
            // A concrete match leaf against a missing key must fail, not
            // substring-match the text "undefined".
            (
                "matchabsent",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(6.0)),
                        (
                            "match",
                            Json::map(vec![(
                                "out",
                                Json::map(vec![("nope", Json::str("fine"))]),
                            )]),
                        ),
                    ])]),
                )]),
            ),
            // __UNDEF__ (absent) must not be satisfied by a present null.
            (
                "undefonnull",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(0.0)),
                        (
                            "match",
                            Json::map(vec![(
                                "out",
                                Json::map(vec![("prev", Json::str("__UNDEF__"))]),
                            )]),
                        ),
                    ])]),
                )]),
            ),
            // __NULL__ (present null) must not be satisfied by an absent key.
            (
                "nullonabsent",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(6.0)),
                        (
                            "match",
                            Json::map(vec![(
                                "out",
                                Json::map(vec![("nope", Json::str("__NULL__"))]),
                            )]),
                        ),
                    ])]),
                )]),
            ),
            // An empty container asserts an empty container, not "anything".
            (
                "emptymatch",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(6.0)),
                        ("match", Json::map(vec![("out", Json::map(vec![]))])),
                    ])]),
                )]),
            ),
            // An empty-string want is not a wildcard substring match.
            (
                "emptystr",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(6.0)),
                        (
                            "match",
                            Json::map(vec![(
                                "out",
                                Json::map(vec![("label", Json::str(""))]),
                            )]),
                        ),
                    ])]),
                )]),
            ),
        ]),
    )])
}

fn expectfail(setname: &str, subject: &Subject) {
    let runner = make_runner(badspec(), Provider::default()).expect("runner");
    let pack = runner.runner("fib", None).expect("spec");

    match pack.runset(&pack.set(setname), Some(subject)) {
        Ok(()) => panic!("omni: expected failure for set: {}", setname),
        Err(err) => assert!(err.message.starts_with("omni:")),
    }
}

#[test]
fn runner_detects_failures() {
    let (fibsub, _seqsub, _rangesub, infosub) = subjects();

    expectfail("wrongout", &fibsub);
    expectfail("wrongerr", &fibsub);
    expectfail("wrongmatch", &fibsub);
    expectfail("missing", &infosub);

    // A concrete match leaf does not match a missing key.
    expectfail("matchabsent", &infosub);
    // __UNDEF__ does not match a present null.
    expectfail("undefonnull", &infosub);
    // __NULL__ does not match an absent key.
    expectfail("nullonabsent", &infosub);
    // An empty match container is not vacuous.
    expectfail("emptymatch", &infosub);
    // An empty-string match leaf is not a wildcard.
    expectfail("emptystr", &infosub);
}

#[test]
fn runner_reports_entry_index_and_id() {
    let spec = Json::map(vec![(
        "fib",
        Json::map(vec![(
            "g",
            Json::map(vec![(
                "set",
                Json::list(vec![
                    Json::map(vec![("in", Json::Num(1.0)), ("out", Json::Num(1.0))]),
                    Json::map(vec![
                        ("id", Json::str("x#2")),
                        ("in", Json::Num(2.0)),
                        ("out", Json::Num(42.0)),
                    ]),
                ]),
            )]),
        )]),
    )]);

    let runner = make_runner(spec, Provider::default()).expect("runner");
    let pack = runner.runner("fib", None).expect("spec");
    let (fibsub, _, _, _) = subjects();

    match pack.runset(&pack.set("g"), Some(&fibsub)) {
        Ok(()) => panic!("omni: expected failure"),
        Err(err) => {
            for want in ["fib[1] (x#2)", "expected: 42", "actual:   1"] {
                assert!(
                    err.message.contains(want),
                    "omni: message missing [{}]: {}",
                    want,
                    err.message
                );
            }
        }
    }
}

#[test]
fn regex_matching() {
    use voxgig_omni::Regex;

    assert!(Regex::new("^fib\\(6\\)=8$").unwrap().is_match("fib(6)=8"));
    assert!(!Regex::new("^fib\\(6\\)=8$").unwrap().is_match("fib(6)=13"));
    assert!(Regex::new("negative index: -3$")
        .unwrap()
        .is_match("fib: negative index: -3"));
    assert!(Regex::new("a+b?c*").unwrap().is_match("xxaaabcccz"));
    assert!(Regex::new("[0-9]{2,3}z").unwrap().is_match("q123z"));
    assert!(Regex::new("^(cat|dog)s?$").unwrap().is_match("dogs"));
    assert!(!Regex::new("^(cat|dog)s?$").unwrap().is_match("dogsx"));
    assert!(Regex::new("\\d+\\.\\d+").unwrap().is_match("pi is 3.14"));
    assert!(!Regex::new("\\d+\\.\\d+").unwrap().is_match("pi is 314"));
}
