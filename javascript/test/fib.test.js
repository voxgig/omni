// RUN: npm test
//
// The Fibonacci conformance suite: every omni port runs this same set of
// groups, from the same spec/fib.json, against the same fib library.

const { existsSync } = require('node:fs')
const { dirname, join } = require('node:path')
const { before, describe, test } = require('node:test')
const assert = require('node:assert')

const { OmniError, makeRunner } = require('../src')
const { fib, fibinfo, fibrange, fibseq } = require('./fib')

// Find the shared spec directory by walking up from this file.
function specfile(name) {
  let dir = __dirname
  for (let i = 0; i < 8; i++) {
    const cand = join(dir, 'spec', name)
    if (existsSync(cand)) {
      return cand
    }
    dir = dirname(dir)
  }
  throw new Error('omni: spec not found: ' + name)
}

// The provider hosts the system under test. `shift` offsets the Fibonacci
// index, so that a client-specific subject is observably different.
function fibprovider(shift) {
  const subjects = {
    fib: (n) => fib('number' === typeof n ? n + shift : n),
    fibseq,
    fibrange,
    fibinfo,
  }

  return {
    subject: (name) => subjects[name],
    client: (options) => fibprovider(options && options.shift ? options.shift : 0),
  }
}

describe('fib', () => {
  let R

  before(async () => {
    const runner = await makeRunner(specfile('fib.json'), fibprovider(0))
    R = await runner('fib')
  })

  test('basic', async () => {
    await R.runset(R.spec.basic, fib)
  })

  test('seq', async () => {
    await R.runset(R.spec.seq, fibseq)
  })

  test('range', async () => {
    await R.runset(R.spec.range, fibrange)
  })

  test('info', async () => {
    await R.runset(R.spec.info, fibinfo)
  })

  test('nulls', async () => {
    await R.runsetflags(R.spec.nulls, { null: false }, fibinfo)
  })

  test('error', async () => {
    await R.runset(R.spec.error, fib)
  })

  test('match', async () => {
    await R.runset(R.spec.match, fib)
  })

  test('matchinfo', async () => {
    await R.runset(R.spec.matchinfo, fibinfo)
  })

  test('client', async () => {
    await R.runset(R.spec.client, fib)
  })
})

// The runner must fail when the subject is wrong - otherwise a green suite
// means nothing.
describe('runner', () => {
  const badspec = {
    fib: {
      wrongout: { set: [{ in: 5, out: 5 }, { in: 6, out: 999 }] },
      wrongerr: { set: [{ in: 1, err: 'never happens' }] },
      wrongmatch: { set: [{ in: 6, match: { out: 999 } }] },
      missing: { set: [{ in: 6, match: { out: { nope: '__EXISTS__' } } }] },
    },
  }

  async function expectfail(setname, subject, flags) {
    const runner = await makeRunner(badspec)
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runsetflags(R.spec[setname], flags || {}, subject),
      (err) => err instanceof OmniError,
    )
  }

  test('detects wrong result', async () => {
    await expectfail('wrongout', fib)
  })

  test('detects missing error', async () => {
    await expectfail('wrongerr', fib)
  })

  test('detects failed match', async () => {
    await expectfail('wrongmatch', fib)
  })

  test('detects absent key', async () => {
    await expectfail('missing', fibinfo)
  })

  test('reports entry index and id', async () => {
    const runner = await makeRunner({
      fib: { g: { set: [{ in: 1, out: 1 }, { id: 'x#2', in: 2, out: 42 }] } },
    })
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runset(R.spec.g, fib),
      (err) => {
        assert.match(err.message, /fib\[1\] \(x#2\)/)
        assert.match(err.message, /expected: 42/)
        assert.match(err.message, /actual:   1/)
        return true
      },
    )
  })
})
