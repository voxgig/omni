#!/usr/bin/env node
/* Copyright © 2026 Voxgig Ltd, MIT License. */

// build-spec.js — compile aontu test-spec sources into the spec JSON that
// every language port reads.
//
// The .aon sources are the SOURCE OF TRUTH. The .json beside them is a
// committed build artifact: ports load it directly (no port needs a Node
// toolchain to run its tests), but nobody edits it by hand. Change a spec,
// run this, commit both.
//
// Usage:
//   node build-spec.js                    # build every spec in ../spec
//   node build-spec.js ../spec/fib.aon  # build just these entry files
//   node build-spec.js --check            # rebuild to a temp dir and diff;
//                                         # non-zero if a .json is stale
//   node build-spec.js --spec-dir DIR     # build the specs in DIR instead
//
// --check is what CI runs: it proves the committed JSON still matches its
// aontu source, so a spec edit cannot be merged with a stale artifact.
//
// Each entry `<name>.aon` produces `<name>.json` beside it, via
// @voxgig/model, run with `--no-config` so that it does NOT scaffold a
// `<entry-dir>/.model-config/` directory. See buildOne.

'use strict'

const Fs = require('node:fs')
const Path = require('node:path')
const { execFileSync } = require('node:child_process')

const TOOLS = __dirname
const DEFAULT_SPEC_DIR = Path.resolve(TOOLS, '..', 'spec')

function usage(code) {
  process.stdout.write(
    require('node:fs')
      .readFileSync(__filename, 'utf8')
      .split('\n')
      .slice(4, 22)
      .map((l) => l.replace(/^\/\/ ?/, ''))
      .join('\n') + '\n'
  )
  process.exit(code)
}

function parseArgs(argv) {
  const out = { check: false, specDir: DEFAULT_SPEC_DIR, entries: [] }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if ('--check' === a) out.check = true
    else if ('--spec-dir' === a) out.specDir = Path.resolve(argv[++i])
    else if ('-h' === a || '--help' === a) usage(0)
    else if (a.startsWith('-')) {
      console.error('unknown option: ' + a)
      usage(2)
    } else out.entries.push(Path.resolve(a))
  }
  return out
}

// Every *.aon in the spec dir that is an ENTRY: a file whose name matches
// the .json it produces. Category files imported with @"..." are not
// entries; by convention they live in a sibling `def/` directory so the two
// kinds never get confused.
function findEntries(specDir) {
  if (!Fs.existsSync(specDir)) {
    console.error('no spec directory: ' + specDir)
    process.exit(1)
  }
  return Fs.readdirSync(specDir)
    .filter((n) => n.endsWith('.aon'))
    .sort()
    .map((n) => Path.join(specDir, n))
}

// Run @voxgig/model over one entry file. It writes `<entry>.json` beside
// the source, so it is run with cwd set to the spec directory.
//
// `--no-config` IS LOAD-BEARING. Without it voxgig-model looks for a
// `<entry-dir>/.model-config/` and SCAFFOLDS one from its own packaged
// defaults when it is absent — two files whose entire content is an
// import of those same defaults plus an empty `sys: model: action: {}`.
// This spec needs no config of its own, so that directory was a generated
// file sitting in the tree looking like a source: committed once, then
// silently rewritten on every build, and rewritten again the moment it was
// deleted. With the flag the output is byte-for-byte identical and nothing
// is written but the JSON.
function buildOne(entry) {
  const dir = Path.dirname(entry)
  const bin = Path.join(TOOLS, 'node_modules', '.bin', 'voxgig-model')
  if (!Fs.existsSync(bin)) {
    throw new Error('voxgig-model not found — run `npm install` in ' + TOOLS)
  }
  execFileSync(bin, ['--no-config', Path.basename(entry)], { cwd: dir, stdio: 'inherit' })
  const json = entry.replace(/\.aon$/, '.json')
  if (!Fs.existsSync(json)) {
    throw new Error('build produced no JSON for ' + entry)
  }
  return json
}

// The spec version marker. `OMNI.version` is what turns on strict entry
// validation in every runner, so a spec that loses it does not fail — it
// silently downgrades the checking in 23 ports at once.
//
// The spec-format shape (spec/def/omni-spec.aon) catches a misspelled
// key, a wrong type and a wrong value, because those are unification
// conflicts. It cannot catch ABSENCE: unifying `{}` with `{version: 1}`
// fills the key in rather than objecting. So absence is checked here,
// against the built artifact, which is the thing every port reads.
function requiremarker(json) {
  const data = JSON.parse(Fs.readFileSync(json, 'utf8'))
  const version = data && data.OMNI && data.OMNI.version
  if ('number' !== typeof version) {
    throw new Error(
      Path.relative(process.cwd(), json) +
      ' has no OMNI.version marker.\n' +
      'Without it every runner silently drops strict entry validation.'
    )
  }
}

// A generated JSON whose .aon source is gone. Nothing rebuilds it, so it
// would sit there forever looking authoritative while no longer having a
// source of truth - and a freshness check that only rebuilds live entries
// would never notice.
function findOrphans(specDir, entries) {
  const sources = new Set(entries.map((e) => Path.basename(e, '.aon')))
  return Fs.readdirSync(specDir)
    .filter((n) => n.endsWith('.json'))
    .filter((n) => !sources.has(Path.basename(n, '.json')))
    .sort()
    .map((n) => Path.join(specDir, n))
}

function main() {
  const args = parseArgs(process.argv.slice(2))
  const scanned = 0 === args.entries.length
  const entries = scanned ? findEntries(args.specDir) : args.entries

  // Before the empty check: removing the LAST source leaves an orphan too,
  // and "no entry files" would be a misleading way to report that.
  // Only when scanning - an explicit entry list says nothing about the files
  // it does not mention.
  if (scanned) {
    const orphans = findOrphans(args.specDir, entries)
    if (orphans.length) {
      console.error(
        'ORPHANED: generated JSON with no .aon source:\n  ' +
        orphans.map((o) => Path.relative(process.cwd(), o)).join('\n  ') +
        '\n\nDelete it, or restore the .aon it was built from.'
      )
      process.exit(1)
    }
  }

  if (0 === entries.length) {
    console.error('no .aon entry files found in ' + args.specDir)
    process.exit(1)
  }

  // --check must not leave a rebuilt artifact behind on failure, so the
  // existing JSON is stashed and restored around the rebuild.
  const stale = []
  for (const entry of entries) {
    const json = entry.replace(/\.aon$/, '.json')
    const before = args.check && Fs.existsSync(json)
      ? Fs.readFileSync(json, 'utf8') : null

    // Put back exactly what was there. When nothing was, the entry is
    // missing its committed JSON entirely - remove what this run
    // generated, so that --check leaves the worktree as it found it.
    const restore = () => {
      if (null != before) Fs.writeFileSync(json, before)
      else if (Fs.existsSync(json)) Fs.unlinkSync(json)
    }

    if (args.check) {
      // The generator can write or truncate the output and THEN fail, so
      // restoring only on a clean run leaves --check mutating the very
      // artifact it promises not to touch. Every exit path restores.
      let after
      try {
        buildOne(entry)
        requiremarker(json)
        after = Fs.readFileSync(json, 'utf8')
      } catch (err) {
        restore()
        throw err
      }

      if (before !== after) {
        stale.push(Path.relative(process.cwd(), json))
        restore()
      }
    } else {
      buildOne(entry)
      requiremarker(json)
      console.log('built ' + Path.relative(process.cwd(), json))
    }
  }

  if (args.check) {
    if (stale.length) {
      console.error(
        '\nSTALE: these are out of date with their .aon source:\n  ' +
        stale.join('\n  ') +
        '\n\nRun `npm run build-spec` in tools/ and commit the result.'
      )
      process.exit(1)
    }
    console.log('spec JSON is up to date with its aontu sources')
  }
}

try {
  main()
} catch (err) {
  console.error(err && err.message ? err.message : String(err))
  process.exit(1)
}
