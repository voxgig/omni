// The system under test: a tiny Fibonacci library.
//
// Every omni port ships this same library, with the same behaviour and the
// same error messages, and tests it with the same spec file
// (spec/fib.json).

use voxgig_omni::{stringify, Json};

/// Validate a Fibonacci index. Errors are part of the contract: the spec
/// matches on these messages.
pub fn fibindex(val: &Json) -> Result<i64, String> {
    let num = match val {
        Json::Num(num) => *num,
        other => return Err(format!("fib: not a number: {}", stringify(other))),
    };

    if num != num.trunc() {
        return Err(format!("fib: non-integer index: {}", stringify(val)));
    }

    if num < 0.0 {
        return Err(format!("fib: negative index: {}", stringify(val)));
    }

    Ok(num as i64)
}

/// The nth Fibonacci number: fib(0)=0, fib(1)=1.
pub fn fibnum(index: i64) -> i64 {
    if 0 == index {
        return 0;
    }

    let mut prev = 0i64;
    let mut cur = 1i64;

    for _step in 1..index {
        let next = prev + cur;
        prev = cur;
        cur = next;
    }

    cur
}

pub fn fib(val: &Json) -> Result<Json, String> {
    let index = fibindex(val)?;
    Ok(Json::Num(fibnum(index) as f64))
}

/// The first n Fibonacci numbers.
pub fn fibseq(val: &Json) -> Result<Json, String> {
    let count = fibindex(val)?;
    let mut out = Vec::new();
    for index in 0..count {
        out.push(Json::Num(fibnum(index) as f64));
    }
    Ok(Json::List(out))
}

/// The Fibonacci numbers from index start to index end, inclusive.
pub fn fibrange(start: &Json, end: &Json) -> Result<Json, String> {
    let from = fibindex(start)?;
    let to = fibindex(end)?;

    let mut out = Vec::new();
    let mut index = from;
    while index <= to {
        out.push(Json::Num(fibnum(index) as f64));
        index += 1;
    }

    Ok(Json::List(out))
}

/// A description of the nth Fibonacci number. `prev` is null at index 0,
/// which exercises the runner's null handling.
pub fn fibinfo(val: &Json) -> Result<Json, String> {
    let index = fibindex(val)?;
    let num = fibnum(index);

    let prev = if 0 == index {
        Json::Null
    } else {
        Json::Num(fibnum(index - 1) as f64)
    };

    Ok(Json::map(vec![
        ("n", Json::Num(index as f64)),
        ("val", Json::Num(num as f64)),
        ("even", Json::Bool(0 == num % 2)),
        ("prev", prev),
        (
            "label",
            Json::Str(format!(
                "fib({})={}",
                stringify(&Json::Num(index as f64)),
                stringify(&Json::Num(num as f64))
            )),
        ),
    ]))
}
