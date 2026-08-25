// @voxgig/omni-js - shared multi-language test runner.
//
// The names are destructured into local bindings and re-exported in
// shorthand, rather than spread. Node's cjs-module-lexer can only detect
// names it can read STATICALLY: `module.exports = {...runner, ...util}` is
// opaque to it, so `import { makeRunner } from '@voxgig/omni-js'` failed
// with "Named export 'makeRunner' not found", while the same import from
// @voxgig/omni worked because tsc emits an explicit
// `Object.defineProperty(exports, ...)` per name. Publishing is what made
// that asymmetry reachable.
//
// Shorthand specifically: `{ makeRunner: runner.makeRunner }` is a member
// expression and the lexer cannot follow it either - that form was tried
// and `make pack-check` rejected it.
//
// This also mirrors canonical: typescript/src/index.ts lists exactly these
// names, and the parity tool reads that list.

const {
  CAPABILITIES,
  EXISTSMARK,
  NULLMARK,
  OmniError,
  SPECVERSION,
  UNDEFMARK,
  errify,
  fixjson,
  loadspec,
  makeRunner,
  match,
  matchval,
  nullmodifier,
  resolvespec,
} = require('./runner')

const {
  clone,
  deepequal,
  getpath,
  islist,
  ismap,
  isnode,
  jsonstr,
  pathify,
  stringify,
  walk,
} = require('./util')

module.exports = {
  CAPABILITIES,
  EXISTSMARK,
  NULLMARK,
  OmniError,
  SPECVERSION,
  UNDEFMARK,
  errify,
  fixjson,
  loadspec,
  makeRunner,
  match,
  matchval,
  nullmodifier,
  resolvespec,
  clone,
  deepequal,
  getpath,
  islist,
  ismap,
  isnode,
  jsonstr,
  pathify,
  stringify,
  walk,
}
