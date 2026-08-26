// RUN: npm test
//
// The Fibonacci conformance suite: every omni port runs this same set of
// groups, from the same spec/fib.json, against the same fib library.

const { existsSync } = require('node:fs')
const { dirname, join } = require('node:path')
const { before, describe, test } = require('node:test')
const assert = require('node:assert')

const { OmniError, deepequal, makeRunner } = require('../src')
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
// `contextify` marks the map, so the context group can prove the hook ran.
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
    contextify: (val) => ({ ...val, mark: 'CTX' }),
  }
}

// The context-group subject: reports what the runner delivered - the
// contextify mark and the attached client - as plain data, so the spec can
// pin both with an ordinary `out` comparison in every port.
function fibctx(ctx) {
  return {
    n: ctx.n,
    val: fib(ctx.n),
    mark: ctx.mark,
    hasclient: null != ctx.client,
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

  test('context', async () => {
    await R.runset(R.spec.context, fibctx)
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
      // A concrete match leaf against a missing key must fail, not
      // substring-match the text "undefined".
      matchabsent: { set: [{ in: 6, match: { out: { nope: 'fine' } } }] },
      // __UNDEF__ (absent) must not be satisfied by a present null.
      undefonnull: { set: [{ in: 0, match: { out: { prev: '__UNDEF__' } } }] },
      // __NULL__ (present null) must not be satisfied by an absent key.
      nullonabsent: { set: [{ in: 6, match: { out: { nope: '__NULL__' } } }] },
      // An empty-string match leaf is not a wildcard.
      emptystr: { set: [{ in: 6, match: { out: { label: '' } } }] },
      // __UNDEF__ (absent) must not be satisfied by a subject returning the
      // literal string "__UNDEF__" as ordinary data.
      wrongundef: { set: [{ in: 6, match: { out: { a: '__UNDEF__' } } }] },
    },
  }

  // A subject whose ordinary data happens to be the literal sentinel text.
  const fibundefliteral = (n) => ({ n, a: '__UNDEF__' })

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

  test('a concrete match leaf does not match a missing key', async () => {
    await expectfail('matchabsent', fibinfo)
  })

  test('__UNDEF__ does not match a present null', async () => {
    await expectfail('undefonnull', fibinfo)
  })

  test('__NULL__ does not match an absent key', async () => {
    await expectfail('nullonabsent', fibinfo)
  })

  test('an empty-string match leaf is not a wildcard', async () => {
    await expectfail('emptystr', fibinfo)
  })

  test('__UNDEF__ does not match a literal "__UNDEF__" in the data', async () => {
    await expectfail('wrongundef', fibundefliteral)
  })

  test('rejects an unsupported spec version', async () => {
    await assert.rejects(
      async () => makeRunner({ OMNI: { version: 99 }, fib: { g: { set: [] } } }),
      (err) => err instanceof OmniError && /unsupported spec version/.test(err.message),
    )
  })

  test('rejects an unknown required capability', async () => {
    await assert.rejects(
      async () => makeRunner({ OMNI: { version: 1, requires: ['nosuchfeature'] }, fib: { g: { set: [] } } }),
      (err) => err instanceof OmniError && /unsupported capability/.test(err.message),
    )
  })

  test('rejects a malformed version block', async () => {
    await assert.rejects(
      async () => makeRunner({ OMNI: { version: 'one' }, fib: { g: { set: [] } } }),
      (err) => err instanceof OmniError && /malformed OMNI/.test(err.message),
    )
  })

  test('strict: an unknown entry field fails instead of passing vacuously', async () => {
    const runner = await makeRunner({
      OMNI: { version: 1 },
      fib: { g: { set: [{ in: 6, matches: { out: 999 } }] } },
    })
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runset(R.spec.g, fibinfo),
      (err) => err instanceof OmniError && /unknown entry field: matches/.test(err.message),
    )
  })

  test('strict: more than one of in, args, ctx fails', async () => {
    const runner = await makeRunner({
      OMNI: { version: 1 },
      fib: { g: { set: [{ in: 5, args: [5], out: 5 }] } },
    })
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runset(R.spec.g, fib),
      (err) => err instanceof OmniError && /more than one of in, args, ctx/.test(err.message),
    )
  })

  test('strict: err together with out fails', async () => {
    const runner = await makeRunner({
      OMNI: { version: 1 },
      fib: { g: { set: [{ in: -1, err: true, out: 5 }] } },
    })
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runset(R.spec.g, fib),
      (err) => err instanceof OmniError && /both err and out/.test(err.message),
    )
  })

  test('strict: a null id fails even under null-normalisation', async () => {
    const runner = await makeRunner({
      OMNI: { version: 1 },
      fib: { g: { set: [{ in: 1, out: 1, id: null }] } },
    })
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runset(R.spec.g, fib),
      (err) => err instanceof OmniError && /entry id is not a string/.test(err.message),
    )
  })

  test('strict: an empty set fails unless marked empty', async () => {
    const runner = await makeRunner({
      OMNI: { version: 1 },
      fib: { g: { set: [] }, h: { set: [], empty: true } },
    })
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runset(R.spec.g, fib),
      (err) => err instanceof OmniError && /empty test set/.test(err.message),
    )
    await R.runset(R.spec.h, fib)
  })

  test('a legacy spec (no OMNI block) stays lenient', async () => {
    const runner = await makeRunner({
      fib: { g: { set: [{ in: 6, matches: { out: 999 }, out: 8 }] } },
    })
    const R = await runner('fib')
    await R.runset(R.spec.g, fib)
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

// deepequal is structural, not IEEE: NaN equals NaN, everywhere, including
// inside containers. The spec suite cannot reach this - spec/fib.json is
// JSON, and JSON has no NaN literal - so it is pinned here directly.
//
// The two NaNs come from two DIFFERENT expressions, deliberately. A test
// written with one NaN constant used twice can be satisfied by an identity
// fast-path alone (`a === b` at the top of deepequal) and would prove
// nothing about the NaN branch.
describe('deepequal', () => {
  const n1 = 0 / 0
  const n2 = Number.POSITIVE_INFINITY - Number.POSITIVE_INFINITY

  test('NaN equals NaN, structurally', () => {
    assert.ok(isNaN(n1) && isNaN(n2))
    // Neither the `a === b` fast path nor Object.is can be doing the work:
    // no NaN is === to any NaN, and these two are not the same expression.
    assert.equal(n1 === n2, false)

    assert.equal(deepequal(n1, n2), true)
    assert.equal(deepequal([n1], [n2]), true)
    assert.equal(deepequal({ x: n1 }, { x: n2 }), true)
  })

  test('NaN equality does not loosen the ordinary comparisons', () => {
    assert.equal(deepequal(1, 1.0), true)
    assert.equal(deepequal(n1, 1.0), false)
    assert.equal(deepequal(true, 1), false)
    assert.equal(deepequal(1, 2), false)
  })
})
