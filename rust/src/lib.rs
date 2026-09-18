#![doc = include_str!("../COMMENT-NOTES.md")]

pub mod json;
pub mod regex;
pub mod runner;
pub mod util;

pub use json::{parse, Json};
pub use regex::Regex;
pub use runner::{
    errify, fixjson, loadspec, make_runner, matchcheck, matchval, nullmodifier, numtext,
    resolvespec, Flags, OmniError, Provider, RunPack, Runner, SpecRef, Subject, SubjectArgs,
    CAPABILITIES,
    SPECVERSION,
};
pub use util::{
    clone, deepequal, getpath, jsonstr, numstr, pathify, stringify, walk, EXISTSMARK, NULLMARK,
    UNDEFMARK,
};
