// RUN: cargo test --test ext
//
// The capability suite: spec/ext.json requires ctxargs, fn and wait, and
// every port that carries them runs it, beside the runner flag `all`.

mod common;

use std::path::PathBuf;
use std::rc::Rc;

use common::{fib, fibinfo, fibrange, fibseq};
use voxgig_omni::{
    make_runner, parse, Flags, Json, OmniError, Provider, Regex, RunPack, SpecRef, Subject,
    CAPABILITIES,
};

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

fn fibprovider() -> Provider {
    Provider {
        subject: Some(Rc::new(|name: &str| -> Option<Subject> {
            match name {
                "fib" => Some(Rc::new(|args: &[Json]| fib(&args[0]))),
                "fibseq" => Some(Rc::new(|args: &[Json]| fibseq(&args[0]))),
                "fibrange" => Some(Rc::new(|args: &[Json]| fibrange(&args[0], &args[1]))),
                "fibinfo" => Some(Rc::new(|args: &[Json]| fibinfo(&args[0]))),
                _ => None,
            }
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

fn fibsubject() -> Subject {
    Rc::new(|args: &[Json]| fib(&args[0]))
}

// The ctxargs subject: the context comes first, and must arrive
// contextified with its client attached.
fn fibshifted() -> Subject {
    Rc::new(|args: &[Json]| {
        let arg = |at: usize| args.get(at).cloned().unwrap_or(Json::Absent);
        let ctx = arg(0);
        if Some("CTX") != ctx.get("mark").asstr() || ctx.get("client").isnone() {
            return Err("fib: context not delivered".to_string());
        }
        let shift = ctx.get("shift").asnum().unwrap_or(0.0);
        let shifted = |val: Json| match val.asnum() {
            Some(num) => Json::Num(num + shift),
            None => val,
        };
        fibrange(&shifted(arg(1)), &shifted(arg(2)))
    })
}

fn runner<S: Into<SpecRef>>(spec: S) -> RunPack {
    let runner = make_runner(spec, fibprovider()).expect("runner");
    runner.runner("fib", None).expect("spec")
}

fn jsonof(text: &str) -> Json {
    parse(text).expect("json")
}

fn v1(requires: &[&str], set: &str) -> Json {
    let caps = requires.iter().map(|cap| Json::str(cap)).collect();
    Json::map(vec![
        (
            "OMNI",
            Json::map(vec![
                ("version", Json::Num(1.0)),
                ("requires", Json::list(caps)),
            ]),
        ),
        (
            "fib",
            Json::map(vec![("g", Json::map(vec![("set", jsonof(set))]))]),
        ),
    ])
}

fn waitflag(text: &str) -> Flags {
    Flags {
        wait: Some(jsonof(text)),
        ..Flags::default()
    }
}

fn refuses(result: Result<(), OmniError>, pattern: &str) {
    match result {
        Ok(()) => panic!("omni: expected a failure matching: {}", pattern),
        Err(err) => assert!(
            Regex::new(pattern).expect("regex").is_match(&err.message),
            "omni: expected a failure matching: {}\ngot: {}",
            pattern,
            err.message
        ),
    }
}

#[test]
fn ext_capabilities() {
    for cap in ["ctxargs", "fn", "wait"] {
        assert!(CAPABILITIES.contains(&cap), "{}", cap);
    }
}

#[test]
fn ext_ctxargs() {
    let pack = runner(specfile("ext.json"));
    pack.runset(&pack.set("ctxargs"), Some(&fibshifted()))
        .expect("ctxargs");
}

#[test]
fn ext_fn() {
    let pack = runner(specfile("ext.json"));
    pack.runset(&pack.set("fn"), Some(&fibsubject())).expect("fn");
}

#[test]
fn ext_wait() {
    let pack = runner(specfile("ext.json"));
    pack.runset(&pack.set("wait"), Some(&fibsubject()))
        .expect("wait");
}

#[test]
fn ext_runner_a_waiting_entry_that_passes_fails_the_set() {
    let pack = runner(v1(
        &["wait"],
        r#"[{"in":5,"out":5,"wait":{"cause":"gone#1"}}]"#,
    ));
    refuses(
        pack.runset(&pack.set("g"), Some(&fibsubject())),
        r"\[0\]: stale wait: gone#1",
    );
}

#[test]
fn ext_runner_the_wait_flag_holds_an_entry_by_id() {
    let pack = runner(v1(&[], r#"[{"id":"a","in":6,"out":9},{"in":7,"out":13}]"#));
    let flags = waitflag(r#"{"a":{"cause":"flag#1"}}"#);
    pack.runsetflags(&pack.set("g"), &flags, Some(&fibsubject()))
        .expect("held");
}

#[test]
fn ext_runner_the_wait_flag_fails_when_its_entry_passes() {
    let pack = runner(v1(&[], r#"[{"id":"a","in":6,"out":8}]"#));
    let flags = waitflag(r#"{"a":{"cause":"flag#1"}}"#);
    refuses(
        pack.runsetflags(&pack.set("g"), &flags, Some(&fibsubject())),
        "stale wait: flag#1",
    );
}

#[test]
fn ext_runner_the_wait_flag_must_name_an_entry() {
    let pack = runner(v1(&[], r#"[{"id":"a","in":6,"out":8}]"#));
    let flags = waitflag(r#"{"zz":{"cause":"c"}}"#);
    refuses(
        pack.runsetflags(&pack.set("g"), &flags, Some(&fibsubject())),
        "wait names no entry: zz",
    );
}

#[test]
fn ext_runner_a_wait_needs_a_cause() {
    let pack = runner(v1(&["wait"], r#"[{"in":6,"out":9,"wait":{}}]"#));
    refuses(
        pack.runset(&pack.set("g"), Some(&fibsubject())),
        "entry wait has no cause",
    );
}

#[test]
fn ext_runner_wait_and_fn_are_unknown_fields_unless_required() {
    let waits = runner(v1(&[], r#"[{"in":6,"out":9,"wait":{"cause":"c"}}]"#));
    refuses(
        waits.runset(&waits.set("g"), Some(&fibsubject())),
        "unknown entry field: wait",
    );
    let fns = runner(v1(&[], r#"[{"fn":"fib","in":6,"out":8}]"#));
    refuses(
        fns.runset(&fns.set("g"), Some(&fibsubject())),
        "unknown entry field: fn",
    );
}

#[test]
fn ext_runner_an_unknown_fn_is_a_spec_error() {
    let pack = runner(v1(&["fn"], r#"[{"fn":"nope","in":6,"out":8}]"#));
    refuses(
        pack.runset(&pack.set("g"), Some(&fibsubject())),
        "unknown fn: nope",
    );
}

#[test]
fn ext_runner_ctx_with_args_needs_ctxargs_and_never_takes_in() {
    let noctxargs = runner(v1(
        &[],
        r#"[{"ctx":{"shift":0},"args":[0,1],"out":[0,1]}]"#,
    ));
    refuses(
        noctxargs.runset(&noctxargs.set("g"), Some(&fibshifted())),
        "more than one of in, args, ctx",
    );
    let within = runner(v1(&["ctxargs"], r#"[{"in":1,"ctx":{"shift":0},"out":[0]}]"#));
    refuses(
        within.runset(&within.set("g"), Some(&fibshifted())),
        "entry has in beside args or ctx",
    );
}

#[test]
fn ext_runner_a_legacy_spec_ignores_fn_and_wait() {
    let pack = runner(jsonof(
        r#"{"fib":{"g":{"set":[{"in":6,"out":8,"fn":"nope","wait":{"cause":"c"}}]}}}"#,
    ));
    pack.runset(&pack.set("g"), Some(&fibsubject()))
        .expect("legacy");
}

#[test]
fn ext_runner_fn_needs_no_default_subject_but_an_entry_without_fn_does() {
    let fibxonly = || Provider {
        subject: Some(Rc::new(|name: &str| -> Option<Subject> {
            if "fibx" == name {
                Some(fibsubject())
            } else {
                None
            }
        })),
        ..Provider::default()
    };
    let run = |spec: Json| {
        let runner = make_runner(spec, fibxonly()).expect("runner");
        runner.runner("fib", None).expect("spec")
    };

    let named = run(v1(&["fn"], r#"[{"fn":"fibx","in":6,"out":8}]"#));
    named.runset(&named.set("g"), None).expect("fn");

    let unnamed = run(v1(
        &["fn"],
        r#"[{"fn":"fibx","in":6,"out":8},{"in":6,"out":8}]"#,
    ));
    refuses(
        unnamed.runset(&unnamed.set("g"), None),
        r"^omni: no test subject for: fib$",
    );

    let legacy = run(v1(&[], r#"[{"in":6,"out":8}]"#));
    refuses(
        legacy.runset(&legacy.set("g"), None),
        r"^omni: no test subject for: fib$",
    );
}

#[test]
fn ext_runner_a_wait_is_found_by_an_id_the_entry_owns_never_an_inherited_one() {
    let pack = runner(v1(
        &[],
        r#"[{"id":"constructor","in":6,"out":8},{"id":"toString","in":7,"out":13}]"#,
    ));
    pack.runset(&pack.set("g"), Some(&fibsubject()))
        .expect("plain");
    pack.runsetflags(&pack.set("g"), &waitflag("{}"), Some(&fibsubject()))
        .expect("empty wait flag");
}

#[test]
fn ext_runner_all_reports_every_failure_at_once() {
    let pack = runner(v1(
        &[],
        r#"[{"in":5,"out":6},{"in":6,"out":8},{"in":7,"out":14}]"#,
    ));
    let flags = Flags {
        all: true,
        ..Flags::default()
    };
    refuses(
        pack.runsetflags(&pack.set("g"), &flags, Some(&fibsubject())),
        r"^omni: fib: 2 of 3 entries failed\n[\s\S]*fib\[0\]: result mismatch[\s\S]*fib\[2\]: result mismatch",
    );
    refuses(
        pack.runset(&pack.set("g"), Some(&fibsubject())),
        r"^omni: fib\[0\]: result mismatch",
    );
}
