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
// `contextify` marks the map, so the context group can prove the hook ran.
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
        contextify: Some(Rc::new(|val: Json| match val {
            Json::Map(mut map) => {
                map.insert("mark".to_string(), Json::str("CTX"));
                Json::Map(map)
            }
            other => other,
        })),
        ..Provider::default()
    }
}

// The context-group subject: reports what the runner delivered - the
// contextify mark and the attached client - as plain data, so the spec can
// pin both with an ordinary `out` comparison.
fn fibctx(ctx: &Json) -> Result<Json, String> {
    Ok(Json::map(vec![
        ("n", ctx.get("n")),
        ("val", fib(&ctx.get("n"))?),
        ("mark", ctx.get("mark")),
        ("hasclient", Json::Bool(!ctx.get("client").isnone())),
    ]))
}

fn runpack() -> RunPack {
    let runner = make_runner(specfile("fib.json"), fibprovider(0.0)).expect("runner");
    runner.runner("fib", None).expect("spec")
}

/// Derive fib's error code from its message.
fn fiberrcode(message: &str) -> &'static str {
    if message.contains("negative index") {
        "fib_negative"
    } else if message.contains("non-integer") {
        "fib_noninteger"
    } else if message.contains("not a number") {
        "fib_notanumber"
    } else {
        "fib_unknown"
    }
}

/// The same provider, plus the `errify` hook: fib's errors gain a CODE.
///
/// A SECOND runner rather than a hook on `fibprovider`, so that the
/// `error` group keeps exercising the DEFAULT errify.
fn fibcodedprovider() -> Provider {
    Provider {
        errify: Some(Rc::new(|message: &str| {
            Json::map(vec![
                ("name", Json::str("Error")),
                ("message", Json::str(message)),
                ("code", Json::str(fiberrcode(message))),
            ])
        })),
        ..fibprovider(0.0)
    }
}

#[test]
fn fib_errcode() {
    let runner = make_runner(specfile("fib.json"), fibcodedprovider()).expect("runner");
    let pack = runner.runner("fib", None).expect("spec");
    let (fibsub, _, _, _) = subjects();
    pack.runset(&pack.set("errcode"), Some(&fibsub)).expect("errcode");
}

#[test]
fn fib_conformance() {
    let pack = runpack();
    let (fibsub, seqsub, rangesub, infosub) = subjects();
    let ctxsub: Subject = Rc::new(|args: &[Json]| fibctx(&args[0]));

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
        ("context", &ctxsub, Flags::default()),
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
            // A subject returning the literal string "__UNDEF__" as
            // ordinary data must not satisfy an __UNDEF__ (absent)
            // assertion - the sentinel never accepts its own literal.
            (
                "wrongundef",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(6.0)),
                        (
                            "match",
                            Json::map(vec![(
                                "out",
                                Json::map(vec![("a", Json::str("__UNDEF__"))]),
                            )]),
                        ),
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
    // An empty-string match leaf is not a wildcard.
    expectfail("emptystr", &infosub);

    // The literal string "__UNDEF__" returned as data does not satisfy an
    // __UNDEF__ (absent) assertion.
    let undefsub: Subject =
        Rc::new(|_args: &[Json]| Ok(Json::map(vec![("a", Json::str("__UNDEF__"))])));
    expectfail("wrongundef", &undefsub);
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
fn rejects_an_unsupported_spec_version() {
    let spec = Json::map(vec![
        ("OMNI", Json::map(vec![("version", Json::Num(99.0))])),
        (
            "fib",
            Json::map(vec![("g", Json::map(vec![("set", Json::list(vec![]))]))]),
        ),
    ]);

    match make_runner(spec, Provider::default()) {
        Ok(_) => panic!("omni: expected refusal"),
        Err(err) => assert!(
            err.message.contains("unsupported spec version"),
            "omni: unexpected message: {}",
            err.message
        ),
    }
}

#[test]
fn rejects_an_unknown_required_capability() {
    let spec = Json::map(vec![
        (
            "OMNI",
            Json::map(vec![
                ("version", Json::Num(1.0)),
                ("requires", Json::list(vec![Json::str("nosuchfeature")])),
            ]),
        ),
        (
            "fib",
            Json::map(vec![("g", Json::map(vec![("set", Json::list(vec![]))]))]),
        ),
    ]);

    match make_runner(spec, Provider::default()) {
        Ok(_) => panic!("omni: expected refusal"),
        Err(err) => assert!(
            err.message.contains("unsupported capability"),
            "omni: unexpected message: {}",
            err.message
        ),
    }
}

#[test]
fn rejects_a_malformed_version_block() {
    let spec = Json::map(vec![
        ("OMNI", Json::map(vec![("version", Json::str("one"))])),
        (
            "fib",
            Json::map(vec![("g", Json::map(vec![("set", Json::list(vec![]))]))]),
        ),
    ]);

    match make_runner(spec, Provider::default()) {
        Ok(_) => panic!("omni: expected refusal"),
        Err(err) => assert!(
            err.message.contains("malformed OMNI"),
            "omni: unexpected message: {}",
            err.message
        ),
    }
}

#[test]
fn strict_unknown_entry_field_fails_instead_of_passing_vacuously() {
    let spec = Json::map(vec![
        ("OMNI", Json::map(vec![("version", Json::Num(1.0))])),
        (
            "fib",
            Json::map(vec![(
                "g",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(6.0)),
                        ("matches", Json::map(vec![("out", Json::Num(999.0))])),
                    ])]),
                )]),
            )]),
        ),
    ]);

    let runner = make_runner(spec, Provider::default()).expect("runner");
    let pack = runner.runner("fib", None).expect("spec");
    let (_fibsub, _seqsub, _rangesub, infosub) = subjects();

    match pack.runset(&pack.set("g"), Some(&infosub)) {
        Ok(()) => panic!("omni: expected failure"),
        Err(err) => assert!(
            err.message.contains("unknown entry field: matches"),
            "omni: unexpected message: {}",
            err.message
        ),
    }
}

#[test]
fn strict_more_than_one_of_in_args_ctx_fails() {
    let spec = Json::map(vec![
        ("OMNI", Json::map(vec![("version", Json::Num(1.0))])),
        (
            "fib",
            Json::map(vec![(
                "g",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(5.0)),
                        ("args", Json::list(vec![Json::Num(5.0)])),
                        ("out", Json::Num(5.0)),
                    ])]),
                )]),
            )]),
        ),
    ]);

    let runner = make_runner(spec, Provider::default()).expect("runner");
    let pack = runner.runner("fib", None).expect("spec");
    let (fibsub, _, _, _) = subjects();

    match pack.runset(&pack.set("g"), Some(&fibsub)) {
        Ok(()) => panic!("omni: expected failure"),
        Err(err) => assert!(
            err.message.contains("more than one of in, args, ctx"),
            "omni: unexpected message: {}",
            err.message
        ),
    }
}

#[test]
fn strict_err_together_with_out_fails() {
    let spec = Json::map(vec![
        ("OMNI", Json::map(vec![("version", Json::Num(1.0))])),
        (
            "fib",
            Json::map(vec![(
                "g",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(-1.0)),
                        ("err", Json::Bool(true)),
                        ("out", Json::Num(5.0)),
                    ])]),
                )]),
            )]),
        ),
    ]);

    let runner = make_runner(spec, Provider::default()).expect("runner");
    let pack = runner.runner("fib", None).expect("spec");
    let (fibsub, _, _, _) = subjects();

    match pack.runset(&pack.set("g"), Some(&fibsub)) {
        Ok(()) => panic!("omni: expected failure"),
        Err(err) => assert!(
            err.message.contains("both err and out"),
            "omni: unexpected message: {}",
            err.message
        ),
    }
}

#[test]
fn strict_a_null_id_fails_even_under_null_normalisation() {
    let spec = Json::map(vec![
        ("OMNI", Json::map(vec![("version", Json::Num(1.0))])),
        (
            "fib",
            Json::map(vec![(
                "g",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(1.0)),
                        ("out", Json::Num(1.0)),
                        ("id", Json::Null),
                    ])]),
                )]),
            )]),
        ),
    ]);

    let runner = make_runner(spec, Provider::default()).expect("runner");
    let pack = runner.runner("fib", None).expect("spec");
    let (fibsub, _, _, _) = subjects();

    match pack.runset(&pack.set("g"), Some(&fibsub)) {
        Ok(()) => panic!("omni: expected failure"),
        Err(err) => assert!(
            err.message.contains("entry id is not a string"),
            "omni: unexpected message: {}",
            err.message
        ),
    }
}

// A present-but-null OMNI block is malformed; only a genuinely absent
// OMNI key is legacy. A port that tests definedness rather than presence
// silently skips strict mode here, so both cases are pinned.
#[test]
fn rejects_a_null_omni_block_but_accepts_an_absent_one() {
    let nullblock = Json::map(vec![
        ("OMNI", Json::Null),
        (
            "fib",
            Json::map(vec![(
                "g",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(1.0)),
                        ("out", Json::Num(1.0)),
                    ])]),
                )]),
            )]),
        ),
    ]);
    match make_runner(nullblock, Provider::default()) {
        Ok(_) => panic!("omni: expected refusal"),
        Err(err) => assert!(
            err.message.contains("malformed OMNI"),
            "omni: unexpected message: {}",
            err.message
        ),
    }

    let nullrequires = Json::map(vec![
        (
            "OMNI",
            Json::map(vec![("version", Json::Num(1.0)), ("requires", Json::Null)]),
        ),
        (
            "fib",
            Json::map(vec![(
                "g",
                Json::map(vec![(
                    "set",
                    Json::list(vec![Json::map(vec![
                        ("in", Json::Num(1.0)),
                        ("out", Json::Num(1.0)),
                    ])]),
                )]),
            )]),
        ),
    ]);
    match make_runner(nullrequires, Provider::default()) {
        Ok(_) => panic!("omni: expected refusal"),
        Err(err) => assert!(
            err.message.contains("malformed OMNI requires list"),
            "omni: unexpected message: {}",
            err.message
        ),
    }

    let noomni = Json::map(vec![(
        "fib",
        Json::map(vec![(
            "g",
            Json::map(vec![(
                "set",
                Json::list(vec![Json::map(vec![
                    ("in", Json::Num(1.0)),
                    ("out", Json::Num(1.0)),
                ])]),
            )]),
        )]),
    )]);
    make_runner(noomni, Provider::default()).expect("legacy spec without OMNI must load fine");
}

#[test]
fn strict_empty_set_fails_unless_marked_empty() {
    let spec = Json::map(vec![
        ("OMNI", Json::map(vec![("version", Json::Num(1.0))])),
        (
            "fib",
            Json::map(vec![
                ("g", Json::map(vec![("set", Json::list(vec![]))])),
                (
                    "h",
                    Json::map(vec![
                        ("set", Json::list(vec![])),
                        ("empty", Json::Bool(true)),
                    ]),
                ),
            ]),
        ),
    ]);

    let runner = make_runner(spec, Provider::default()).expect("runner");
    let pack = runner.runner("fib", None).expect("spec");
    let (fibsub, _, _, _) = subjects();

    match pack.runset(&pack.set("g"), Some(&fibsub)) {
        Ok(()) => panic!("omni: expected failure"),
        Err(err) => assert!(
            err.message.contains("empty test set"),
            "omni: unexpected message: {}",
            err.message
        ),
    }

    pack.runset(&pack.set("h"), Some(&fibsub))
        .expect("empty: true must pass");
}

#[test]
fn legacy_spec_without_omni_block_stays_lenient() {
    let spec = Json::map(vec![(
        "fib",
        Json::map(vec![(
            "g",
            Json::map(vec![(
                "set",
                Json::list(vec![Json::map(vec![
                    ("in", Json::Num(6.0)),
                    ("matches", Json::map(vec![("out", Json::Num(999.0))])),
                    ("out", Json::Num(8.0)),
                ])]),
            )]),
        )]),
    )]);

    let runner = make_runner(spec, Provider::default()).expect("runner");
    let pack = runner.runner("fib", None).expect("spec");
    let (fibsub, _, _, _) = subjects();

    pack.runset(&pack.set("g"), Some(&fibsub))
        .expect("legacy spec must stay lenient");
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

// deepequal is structural, not IEEE: two NaNs are equal, however they were
// made. spec/fib.json cannot pin this - JSON has no NaN literal - so it is
// pinned here.
#[test]
fn deepequal_nan() {
    use voxgig_omni::deepequal;

    // Two NaNs from two DIFFERENT expressions. A test written with one
    // shared NaN constant used twice can pass on an identity fast-path
    // while proving nothing.
    let zero = 0.0f64;
    let n1 = zero / zero;
    let n2 = f64::INFINITY - f64::INFINITY;

    assert!(n1.is_nan() && n2.is_nan(), "omni: expected two NaNs");

    // Rust f64 values have no object identity, so IEEE inequality is the
    // check that keeps the two honestly distinct: if this ever holds,
    // someone has replaced a NaN with an ordinary number.
    assert!(n1 != n2, "omni: NaN must not be IEEE-equal to NaN");

    let nan1 = Json::Num(n1);
    let nan2 = Json::Num(n2);

    assert!(deepequal(&nan1, &nan2), "omni: NaN must equal NaN");
    assert!(
        deepequal(
            &Json::list(vec![nan1.clone()]),
            &Json::list(vec![nan2.clone()])
        ),
        "omni: NaN must equal NaN inside a list"
    );
    assert!(
        deepequal(
            &Json::map(vec![("x", nan1.clone())]),
            &Json::map(vec![("x", nan2.clone())])
        ),
        "omni: NaN must equal NaN inside a map"
    );

    // Regressions: the NaN rule must not loosen anything else. Json::Num
    // is always f64, so an integer and a float of the same value are the
    // same value once inside the model - this port has no separate int.
    assert!(
        deepequal(&Json::Num(1i64 as f64), &Json::Num(1.0)),
        "omni: 1 must equal 1.0"
    );
    assert!(
        !deepequal(&nan1, &Json::Num(1.0)),
        "omni: NaN must not equal a real number"
    );
    assert!(
        !deepequal(&Json::Bool(true), &Json::Num(1.0)),
        "omni: a bool is never a number"
    );
    assert!(
        !deepequal(&Json::Num(1.0), &Json::Num(2.0)),
        "omni: 1 must not equal 2"
    );
}
