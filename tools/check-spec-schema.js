#!/usr/bin/env node
/* Copyright © 2026 Voxgig Ltd, MIT License. */

// check-spec-schema.js — validate the committed spec JSON against the
// spec-format schema (spec/omni-spec.schema.json).
//
// The runner is the authority on spec semantics; this check exists so that
// a malformed committed artifact fails in CI with a named path, instead of
// failing later inside whichever port happens to read the bad entry first.
// Only version-1 (or later) specs are validated: the schema encodes the
// strict rules, which legacy version-0 specs are exempt from by design.
//
// Usage: node check-spec-schema.js [spec.json ...]
//   With no arguments, validates every non-schema *.json in ../spec.

'use strict'

const Fs = require('node:fs')
const Path = require('node:path')

const Ajv = require('ajv')

const TOOLS = __dirname
const SPEC_DIR = Path.resolve(TOOLS, '..', 'spec')
const SCHEMA = Path.join(SPEC_DIR, 'omni-spec.schema.json')

function specfiles(args) {
  if (0 < args.length) {
    return args.map((a) => Path.resolve(a))
  }
  return Fs.readdirSync(SPEC_DIR)
    .filter((n) => n.endsWith('.json') && !n.endsWith('.schema.json'))
    .sort()
    .map((n) => Path.join(SPEC_DIR, n))
}

function main() {
  const schema = JSON.parse(Fs.readFileSync(SCHEMA, 'utf8'))
  const ajv = new Ajv({ allErrors: true, allowUnionTypes: true })
  const validate = ajv.compile(schema)

  let bad = 0

  for (const file of specfiles(process.argv.slice(2))) {
    const rel = Path.relative(process.cwd(), file)
    const spec = JSON.parse(Fs.readFileSync(file, 'utf8'))

    const version =
      spec && 'object' === typeof spec.OMNI ? spec.OMNI.version : 0
    if (!(1 <= version)) {
      console.log('skip  ' + rel + ' (legacy spec, version 0)')
      continue
    }

    if (validate(spec)) {
      console.log('ok    ' + rel)
    } else {
      bad++
      console.error('BAD   ' + rel)
      for (const err of validate.errors) {
        console.error('  ' + (err.instancePath || '<root>') + ' ' + err.message)
      }
    }
  }

  if (bad) {
    console.error('\n' + bad + ' spec file(s) fail the schema')
    process.exit(1)
  }
}

main()
