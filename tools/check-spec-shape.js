#!/usr/bin/env node
/* Copyright © 2026 Voxgig Ltd, MIT License. */

// check-spec-shape.js — check each spec source against the spec-format
// shape (spec/def/omni-spec.aontu), using aontu itself.
//
// The corpus is written in aontu, so the shape is written in aontu too: a
// violation is an ordinary unification conflict, reported with an error
// code, the exact spec path, and the source file — not a second, separate
// description of the format that can drift from the first.
//
// The check compiles a small generated file that imports the shape and the
// spec together and spreads the group template across every section, then
// THROWS THE OUTPUT AWAY. Only the exit status matters. Building a separate
// artifact is what keeps `make spec` byte-exact: under aontu 0.48.2 an
// optional key holding an empty container (`out: []`) is dropped as
// unresolved, which would rewrite entries like fib/seq#empty if the shape
// were unified into the build itself.
//
// The runner remains the authority on spec semantics; this catches the
// subset a unifier can catch, at author time. See spec/def/omni-spec.aontu
// for exactly what is and is not covered.
//
// Usage: node check-spec-shape.js [spec.aontu ...]
//   With no arguments, checks every entry *.aontu in ../spec.
//   --self-test additionally proves the shape can go red.

'use strict'

const Fs = require('node:fs')
const Os = require('node:os')
const Path = require('node:path')
const { spawnSync } = require('node:child_process')

const TOOLS = __dirname
const SPEC_DIR = Path.resolve(TOOLS, '..', 'spec')
const SHAPE = Path.join(SPEC_DIR, 'def', 'omni-spec.aontu')
const AONTU = Path.join(TOOLS, 'node_modules', '.bin', 'aontu')

// Entry specs are the *.aontu files directly in spec/; the def/ directory
// holds imported definitions, which are not compiled on their own.
function entryspecs(args) {
  if (0 < args.length) {
    return args.map((a) => Path.resolve(a))
  }
  return Fs.readdirSync(SPEC_DIR)
    .filter((n) => n.endsWith('.aontu'))
    .sort()
    .map((n) => Path.join(SPEC_DIR, n))
}

// Unify one spec source with the shape. Returns aontu's stderr on failure,
// null on success.
function checkspec(specfile) {
  const work = Fs.mkdtempSync(Path.join(Os.tmpdir(), 'omni-shape-'))
  const check = Path.join(work, 'check.aontu')

  try {
    Fs.writeFileSync(
      check,
      '@"' + SHAPE + '"\n' +
      '@"' + specfile + '"\n' +
      // Every section under `primary`, and every group within it.
      'primary: &: { &: $.Group }\n'
    )

    const res = spawnSync(AONTU, [check], { encoding: 'utf8' })
    if (0 === res.status) {
      return null
    }
    return (res.stderr || res.stdout || 'aontu exited ' + res.status).trim()
  } finally {
    Fs.rmSync(work, { recursive: true, force: true })
  }
}

// A check that cannot fail proves nothing. Compile a spec that breaks each
// enforced rule and require the shape to reject it.
const REDCASES = [
  ['unknown entry field', 'primary: s: g: set: [ { in: 1, matches: { out: 2 } } ]'],
  ['non-string id', 'primary: s: g: set: [ { in: 1, out: 1, id: null } ]'],
  ['non-boolean doc', 'primary: s: g: set: [ { in: 1, out: 1, doc: yes } ]'],
  ['map-valued err', 'primary: s: g: set: [ { in: 1, err: { code: 1 } } ]'],
]

function selftest() {
  const work = Fs.mkdtempSync(Path.join(Os.tmpdir(), 'omni-shape-red-'))
  let bad = 0

  try {
    for (const [name, src] of REDCASES) {
      const spec = Path.join(work, 'red.aontu')
      Fs.writeFileSync(spec, src + '\n')

      if (null === checkspec(spec)) {
        bad++
        console.error('NOT RED  ' + name + ' — the shape accepted it')
      } else {
        console.log('red      ' + name)
      }
    }
  } finally {
    Fs.rmSync(work, { recursive: true, force: true })
  }

  return bad
}

function main() {
  const args = process.argv.slice(2)
  const selftestonly = args.includes('--self-test')
  const specs = entryspecs(args.filter((a) => !a.startsWith('-')))

  let bad = 0

  for (const spec of specs) {
    const rel = Path.relative(process.cwd(), spec)
    const err = checkspec(spec)

    if (null === err) {
      console.log('ok       ' + rel)
    } else {
      bad++
      console.error('BAD      ' + rel)
      console.error(err)
    }
  }

  if (selftestonly) {
    bad += selftest()
  }

  if (bad) {
    console.error('\n' + bad + ' spec shape failure(s)')
    process.exit(1)
  }
}

main()
