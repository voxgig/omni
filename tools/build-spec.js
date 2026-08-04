#!/usr/bin/env node
/* Copyright © 2026 Voxgig Ltd, MIT License. */

// build-spec.js — compile aontu test-spec sources into the spec JSON that
// every language port reads.
//
// The .aontu sources are the SOURCE OF TRUTH. The .json beside them is a
// committed build artifact: ports load it directly (no port needs a Node
// toolchain to run its tests), but nobody edits it by hand. Change a spec,
// run this, commit both.
//
// Usage:
//   node build-spec.js                    # build every spec in ../spec
//   node build-spec.js ../spec/fib.aontu  # build just these entry files
//   node build-spec.js --check            # rebuild to a temp dir and diff;
//                                         # non-zero if a .json is stale
//   node build-spec.js --spec-dir DIR     # build the specs in DIR instead
//
// --check is what CI runs: it proves the committed JSON still matches its
// aontu source, so a spec edit cannot be merged with a stale artifact.
//
// Each entry `<name>.aontu` produces `<name>.json` beside it, via
// @voxgig/model. A `.model-config/` directory must sit alongside the
// sources; see ../spec/.model-config/model-config.aontu.

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

// Every *.aontu in the spec dir that is an ENTRY: a file whose name matches
// the .json it produces. Category files imported with @"..." are not
// entries; by convention they live in a sibling `def/` directory so the two
// kinds never get confused.
function findEntries(specDir) {
  if (!Fs.existsSync(specDir)) {
    console.error('no spec directory: ' + specDir)
    process.exit(1)
  }
  return Fs.readdirSync(specDir)
    .filter((n) => n.endsWith('.aontu'))
    .sort()
    .map((n) => Path.join(specDir, n))
}

// Run @voxgig/model over one entry file. voxgig-model resolves its config
// from `<entry-dir>/.model-config/` and writes `<entry>.json` beside the
// source, so it is run with cwd set to the spec directory.
function buildOne(entry) {
  const dir = Path.dirname(entry)
  const bin = Path.join(TOOLS, 'node_modules', '.bin', 'voxgig-model')
  if (!Fs.existsSync(bin)) {
    console.error('voxgig-model not found — run `npm install` in ' + TOOLS)
    process.exit(1)
  }
  execFileSync(bin, [Path.basename(entry)], { cwd: dir, stdio: 'inherit' })
  const json = entry.replace(/\.aontu$/, '.json')
  if (!Fs.existsSync(json)) {
    console.error('build produced no JSON for ' + entry)
    process.exit(1)
  }
  return json
}

function main() {
  const args = parseArgs(process.argv.slice(2))
  const entries = args.entries.length ? args.entries : findEntries(args.specDir)

  if (0 === entries.length) {
    console.error('no .aontu entry files found in ' + args.specDir)
    process.exit(1)
  }

  // --check must not leave a rebuilt artifact behind on failure, so the
  // existing JSON is stashed and restored around the rebuild.
  const stale = []
  for (const entry of entries) {
    const json = entry.replace(/\.aontu$/, '.json')
    const before = args.check && Fs.existsSync(json)
      ? Fs.readFileSync(json, 'utf8') : null

    buildOne(entry)

    if (args.check) {
      const after = Fs.readFileSync(json, 'utf8')
      if (before !== after) {
        stale.push(Path.relative(process.cwd(), json))
        if (null != before) Fs.writeFileSync(json, before)
      }
    } else {
      console.log('built ' + Path.relative(process.cwd(), json))
    }
  }

  if (args.check) {
    if (stale.length) {
      console.error(
        '\nSTALE: these are out of date with their .aontu source:\n  ' +
        stale.join('\n  ') +
        '\n\nRun `npm run build-spec` in tools/ and commit the result.'
      )
      process.exit(1)
    }
    console.log('spec JSON is up to date with its aontu sources')
  }
}

main()
