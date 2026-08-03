//! Omni: the shared multi-language test runner.
//!
//! Port of the canonical TypeScript implementation
//! (typescript/src/Runner.ts). Behaviour must match, case for case.
//!
//! Rust has no exceptions, so a failing check is returned as an
//! [`OmniError`] rather than thrown, and a subject reports failure as
//! `Err(String)`.

use std::collections::BTreeMap;
use std::fmt;
use std::rc::Rc;

use crate::json::{self, Json};
use crate::regex::Regex;
use crate::util::{
    deepequal, getpath, jsonstr, numstr, pathify, stringify, EXISTSMARK, NULLMARK, UNDEFMARK,
};

/// The function under test. A spec entry's arguments arrive as a slice of
/// JSON values; an error is reported as its message.
pub type Subject = Rc<dyn Fn(&[Json]) -> Result<Json, String>>;

/// Run-time options for a set of test entries.
#[derive(Clone, Debug)]
pub struct Flags {
    /// Convert JSON nulls to the NULLMARK sentinel (default: true).
    pub null: bool,
    /// Label used in failure messages (default: the runner name).
    pub name: Option<String>,
}

impl Default for Flags {
    fn default() -> Flags {
        Flags {
            null: true,
            name: None,
        }
    }
}

impl Flags {
    /// Flags with null conversion disabled.
    pub fn nonull() -> Flags {
        Flags {
            null: false,
            name: None,
        }
    }
}

/// The host of the system under test. Every hook is optional.
#[derive(Clone, Default)]
pub struct Provider {
    /// Resolve a test subject by name.
    pub subject: Option<Rc<dyn Fn(&str) -> Option<Subject>>>,
    /// Build a sub-provider from a DEF.client entry's options.
    pub client: Option<Rc<dyn Fn(&Json) -> Provider>>,
    /// Wrap a map argument as a call context.
    pub contextify: Option<Rc<dyn Fn(Json) -> Json>>,
    /// Resolve references in client options against the store.
    pub inject: Option<Rc<dyn Fn(&Json, &Json) -> Json>>,
}

/// A test failure (or a malformed spec). Distinct from an error returned
/// by the subject under test, which is a candidate for an `err`
/// expectation.
#[derive(Clone, Debug)]
pub struct OmniError {
    pub message: String,
    pub entry: Option<Json>,
}

impl OmniError {
    pub fn new(message: String) -> OmniError {
        OmniError {
            message,
            entry: None,
        }
    }
}

impl fmt::Display for OmniError {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(out, "{}", self.message)
    }
}

impl std::error::Error for OmniError {}

/// Where a spec comes from: a file path, or an in-memory value.
pub enum SpecRef {
    Path(String),
    Value(Json),
}

impl From<&str> for SpecRef {
    fn from(path: &str) -> SpecRef {
        SpecRef::Path(path.to_string())
    }
}

impl From<String> for SpecRef {
    fn from(path: String) -> SpecRef {
        SpecRef::Path(path)
    }
}

impl From<Json> for SpecRef {
    fn from(val: Json) -> SpecRef {
        SpecRef::Value(val)
    }
}

/// Load a spec: a path to a JSON file, or an already-parsed value.
pub fn loadspec(specref: SpecRef) -> Result<Json, OmniError> {
    match specref {
        SpecRef::Value(val) => Ok(val),
        SpecRef::Path(path) => {
            let text = std::fs::read_to_string(&path)
                .map_err(|_| OmniError::new(format!("omni: cannot read spec: {}", path)))?;
            json::parse(&text)
                .map_err(|err| OmniError::new(format!("omni: cannot parse spec: {}: {}", path, err)))
        }
    }
}

/// Find `primary.<name>`, then `<name>`, then the whole spec.
pub fn resolvespec(name: &str, alltests: &Json) -> Json {
    if name.is_empty() {
        return alltests.clone();
    }

    let primary = alltests.get("primary");
    let section = primary.get(name);
    if !section.isabsent() {
        return section;
    }

    let section = alltests.get(name);
    if !section.isabsent() {
        return section;
    }

    alltests.clone()
}

/// What a runner returns for one named spec section.
pub struct RunPack {
    pub spec: Json,
    pub subject: Option<Subject>,
    pub client: Provider,
    name: String,
    provider: Provider,
    clients: BTreeMap<String, Provider>,
}

impl RunPack {
    /// A named group of the resolved spec.
    pub fn set(&self, name: &str) -> Json {
        self.spec.get(name)
    }

    /// Run one set of test entries.
    pub fn runset(&self, testspec: &Json, subject: Option<&Subject>) -> Result<(), OmniError> {
        self.runsetflags(testspec, &Flags::default(), subject)
    }

    /// Run one set of test entries with flags.
    pub fn runsetflags(
        &self,
        testspec: &Json,
        flags: &Flags,
        subject: Option<&Subject>,
    ) -> Result<(), OmniError> {
        let mut useflags = flags.clone();
        if useflags.name.is_none() {
            useflags.name = Some(if self.name.is_empty() {
                "set".to_string()
            } else {
                self.name.clone()
            });
        }

        let label = useflags.name.clone().unwrap_or_else(|| "set".to_string());

        let usesubject = match subject.cloned().or_else(|| self.subject.clone()) {
            Some(found) => found,
            None => {
                return Err(OmniError::new(format!(
                    "omni: no test subject for: {}",
                    label
                )))
            }
        };

        let testspecmap = fixjson(testspec, &useflags);
        let testset = match testspecmap.get("set") {
            Json::List(list) => list,
            _ => {
                return Err(OmniError::new(format!(
                    "omni: test spec has no set: {}",
                    label
                )))
            }
        };

        for (index, rawentry) in testset.iter().enumerate() {
            let mut entry = resolveentry(rawentry.clone(), &useflags);

            let (client, entrysubject) = self.resolvetestpack(&entry, &usesubject)?;
            let args = self.resolveargs(&mut entry, &client);

            match entrysubject(&args) {
                Err(message) => {
                    handleerror(&useflags, index, &entry, &message)?;
                }
                Ok(rawres) => {
                    let res = fixjson(&rawres, &useflags);
                    jset(&mut entry, "res", res.clone());
                    checkresult(&useflags, index, &entry, &args, &res)?;
                }
            }
        }

        Ok(())
    }

    fn resolvetestpack(
        &self,
        entry: &Json,
        subject: &Subject,
    ) -> Result<(Provider, Subject), OmniError> {
        let clientname = entry.get("client");

        let name = match clientname.asstr() {
            Some(text) => text,
            None => return Ok((self.provider.clone(), subject.clone())),
        };

        let client = self.clients.get(name).ok_or_else(|| OmniError {
            message: format!("omni: unknown client: {}", name),
            entry: Some(entry.clone()),
        })?;

        let clientsubject = resolvesubject(&self.name, client).unwrap_or_else(|| subject.clone());

        Ok((client.clone(), clientsubject))
    }

    /// Build the argument list: `ctx`, `args`, or `in`.
    fn resolveargs(&self, entry: &mut Json, _client: &Provider) -> Vec<Json> {
        let hasctx = entry.has("ctx");
        let hasargs = entry.has("args");

        let mut args: Vec<Json> = if hasctx {
            vec![entry.get("ctx")]
        } else if hasargs {
            match entry.get("args") {
                Json::List(list) => list,
                other => vec![other],
            }
        } else {
            vec![entry.get("in")]
        };

        if (hasctx || hasargs) && !args.is_empty() && args[0].ismap() {
            let mut first = args[0].clone();
            if let Some(contextify) = &self.provider.contextify {
                first = contextify(first);
            }
            args[0] = first.clone();
            jset(entry, "ctx", first);
        }

        args
    }
}

fn resolvesubject(name: &str, provider: &Provider) -> Option<Subject> {
    if name.is_empty() {
        return None;
    }
    provider.subject.as_ref().and_then(|resolve| resolve(name))
}

/// An entry with no `out` expects a null (or absent) result.
fn resolveentry(entry: Json, flags: &Flags) -> Json {
    let mut out = entry;
    if out.get("out").isnone() && flags.null {
        jset(&mut out, "out", Json::str(NULLMARK));
    }
    out
}

/// Set a map entry (no-op for non-maps).
fn jset(val: &mut Json, key: &str, entry: Json) {
    if let Json::Map(map) = val {
        map.insert(key.to_string(), entry);
    }
}

/// Nulls (and absent values) become NULLMARK. Always a fresh copy.
pub fn fixjson(val: &Json, flags: &Flags) -> Json {
    fixjsonval(val, flags.null)
}

fn fixjsonval(val: &Json, donull: bool) -> Json {
    match val {
        Json::Absent | Json::Null => {
            if donull {
                Json::str(NULLMARK)
            } else {
                Json::Null
            }
        }
        Json::List(list) => Json::List(list.iter().map(|e| fixjsonval(e, donull)).collect()),
        Json::Map(map) => {
            let mut out = BTreeMap::new();
            for (key, entry) in map.iter() {
                out.insert(key.clone(), fixjsonval(entry, donull));
            }
            Json::Map(out)
        }
        other => other.clone(),
    }
}

/// The JSON form of an error: always at least {name,message}.
pub fn errify(message: &str) -> Json {
    Json::map(vec![
        ("name", Json::str("Error")),
        ("message", Json::str(message)),
    ])
}

/// The label of one entry, for failure messages.
fn entryref(flags: &Flags, index: usize, entry: &Json) -> String {
    let label = flags.name.clone().unwrap_or_else(|| "set".to_string());
    let id = entry.get("id");
    let idpart = if id.isabsent() {
        String::new()
    } else {
        format!(" ({})", stringify(&id))
    };
    format!("{}[{}]{}", label, index, idpart)
}

fn fail(
    flags: &Flags,
    index: usize,
    entry: &Json,
    reason: &str,
    expected: Option<String>,
    actual: Option<String>,
) -> OmniError {
    let mut message = format!("omni: {}: {}", entryref(flags, index, entry), reason);
    if let Some(text) = expected {
        message.push_str(&format!("\n  expected: {}", text));
    }
    if let Some(text) = actual {
        message.push_str(&format!("\n  actual:   {}", text));
    }
    message.push_str(&format!("\n  entry:    {}", jsonstr(&entrysummary(entry))));

    OmniError {
        message,
        entry: Some(entry.clone()),
    }
}

/// The spec-defined part of an entry (drop runner bookkeeping).
fn entrysummary(entry: &Json) -> Json {
    match entry {
        Json::Map(map) => {
            let mut out = BTreeMap::new();
            for (key, val) in map.iter() {
                if "res" != key && "thrown" != key && "ctx" != key {
                    out.insert(key.clone(), val.clone());
                }
            }
            Json::Map(out)
        }
        other => other.clone(),
    }
}

fn checkresult(
    flags: &Flags,
    index: usize,
    entry: &Json,
    args: &[Json],
    res: &Json,
) -> Result<(), OmniError> {
    let mut matched = false;

    let entryerr = entry.get("err");
    if !entryerr.isnone() {
        return Err(fail(
            flags,
            index,
            entry,
            "expected error did not occur",
            Some(stringify(&entryerr)),
            Some(stringify(res)),
        ));
    }

    let check = entry.get("match");
    if !check.isnone() {
        let base = Json::map(vec![
            ("in", entry.get("in")),
            ("args", Json::List(args.to_vec())),
            ("out", entry.get("res")),
            ("ctx", entry.get("ctx")),
        ]);
        matchcheck(flags, index, entry, &check, &base)?;
        matched = true;
    }

    let out = entry.get("out");

    if deepequal(res, &out) {
        return Ok(());
    }

    // NOTE: a match with no explicit out is a complete check on its own.
    if matched && (out.isnone() || Some(NULLMARK) == out.asstr()) {
        return Ok(());
    }

    Err(fail(
        flags,
        index,
        entry,
        "result mismatch",
        Some(stringify(&out)),
        Some(stringify(res)),
    ))
}

fn handleerror(flags: &Flags, index: usize, entry: &Json, message: &str) -> Result<(), OmniError> {
    let entryerr = entry.get("err");

    if !entryerr.isnone() {
        let istrue = matches!(entryerr, Json::Bool(true));

        if istrue || matchval(&entryerr, &Json::str(message)) {
            let check = entry.get("match");
            if !check.isnone() {
                let base = Json::map(vec![
                    ("in", entry.get("in")),
                    ("out", entry.get("res")),
                    ("ctx", entry.get("ctx")),
                    ("err", errify(message)),
                ]);
                matchcheck(flags, index, entry, &check, &base)?;
            }
            return Ok(());
        }

        return Err(fail(
            flags,
            index,
            entry,
            "error mismatch",
            Some(stringify(&entryerr)),
            Some(message.to_string()),
        ));
    }

    Err(fail(
        flags,
        index,
        entry,
        "unexpected error",
        None,
        Some(message.to_string()),
    ))
}

/// Check that every leaf of `check` is present, and matches, in `base`.
pub fn matchcheck(
    flags: &Flags,
    index: usize,
    entry: &Json,
    check: &Json,
    base: &Json,
) -> Result<(), OmniError> {
    matchwalk(flags, index, entry, check, base, &mut Vec::new())
}

fn matchwalk(
    flags: &Flags,
    index: usize,
    entry: &Json,
    check: &Json,
    base: &Json,
    path: &mut Vec<String>,
) -> Result<(), OmniError> {
    match check {
        Json::List(list) => {
            for (subindex, subcheck) in list.iter().enumerate() {
                path.push(subindex.to_string());
                matchwalk(flags, index, entry, subcheck, base, path)?;
                path.pop();
            }
            Ok(())
        }
        Json::Map(map) => {
            for (key, subcheck) in map.iter() {
                path.push(key.clone());
                matchwalk(flags, index, entry, subcheck, base, path)?;
                path.pop();
            }
            Ok(())
        }
        leaf => {
            let baseval = getpath(base, path);

            if deepequal(leaf, &baseval) {
                return Ok(());
            }

            // Explicitly absent.
            if Some(UNDEFMARK) == leaf.asstr() && baseval.isabsent() {
                return Ok(());
            }

            // Explicitly present.
            if Some(EXISTSMARK) == leaf.asstr() && !baseval.isnone() {
                return Ok(());
            }

            if matchval(leaf, &baseval) {
                return Ok(());
            }

            let where_ = if path.is_empty() {
                "<root>".to_string()
            } else {
                pathify(path)
            };

            Err(fail(
                flags,
                index,
                entry,
                &format!("match failed at {}", where_),
                Some(stringify(leaf)),
                Some(stringify(&baseval)),
            ))
        }
    }
}

/// Match one leaf: /regex/ or case-insensitive substring for strings.
pub fn matchval(check: &Json, base: &Json) -> bool {
    if deepequal(check, base) {
        return true;
    }

    let mut want = check.clone();
    if Some(UNDEFMARK) == want.asstr() || Some(NULLMARK) == want.asstr() {
        want = Json::Null;
    }

    if want.isnone() {
        return base.isnone() || Some(NULLMARK) == base.asstr();
    }

    if let Some(text) = want.asstr() {
        let basestr = stringify(base);

        if 2 < text.len() && text.starts_with('/') && text.ends_with('/') {
            let pattern = &text[1..text.len() - 1];
            return match Regex::new(pattern) {
                Ok(regex) => regex.is_match(&basestr),
                Err(_) => false,
            };
        }

        return basestr.to_lowercase().contains(&text.to_lowercase());
    }

    deepequal(&want, base)
}

/// Convert NULLMARK sentinels back into real nulls.
pub fn nullmodifier(val: &Json) -> Json {
    match val {
        Json::Str(text) if NULLMARK == text => Json::Null,
        Json::Str(text) => Json::Str(text.replace(NULLMARK, "null")),
        other => other.clone(),
    }
}

/// A loaded spec plus its provider.
pub struct Runner {
    alltests: Json,
    provider: Provider,
}

impl Runner {
    /// Resolve one named section of the spec.
    pub fn runner(&self, name: &str, store: Option<&Json>) -> Result<RunPack, OmniError> {
        let spec = resolvespec(name, &self.alltests);
        let clients = self.resolveclients(&spec, store)?;
        let subject = resolvesubject(name, &self.provider);

        Ok(RunPack {
            spec,
            subject,
            client: self.provider.clone(),
            name: name.to_string(),
            provider: self.provider.clone(),
            clients,
        })
    }

    fn resolveclients(
        &self,
        spec: &Json,
        store: Option<&Json>,
    ) -> Result<BTreeMap<String, Provider>, OmniError> {
        let mut clients = BTreeMap::new();

        let defclient = spec.get("DEF").get("client");
        let defmap = match defclient.asmap() {
            Some(map) => map.clone(),
            None => return Ok(clients),
        };

        // A spec may define clients that a given test run never references.
        let clientmaker = match &self.provider.client {
            Some(maker) => maker.clone(),
            None => return Ok(clients),
        };

        for (clientname, cdef) in defmap.iter() {
            let mut copts = cdef.get("test").get("options");
            if copts.isabsent() {
                copts = Json::map(vec![]);
            }

            if let (Some(inject), Some(store)) = (&self.provider.inject, store) {
                copts = inject(&copts, store);
            }

            clients.insert(clientname.clone(), clientmaker(&copts));
        }

        Ok(clients)
    }
}

/// Make a runner for a spec file (or spec value) and a provider.
pub fn make_runner<S: Into<SpecRef>>(specref: S, provider: Provider) -> Result<Runner, OmniError> {
    let alltests = loadspec(specref.into())?;
    Ok(Runner { alltests, provider })
}

/// Render a number the same way in every port (re-exported for subjects).
pub fn numtext(val: f64) -> String {
    numstr(val)
}
