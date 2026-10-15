// RUN: npm test
//
// The capability suite: spec/ext.json requires ctxargs, fn and wait, and
// every port that carries them runs it, beside the runner flag `all`.

const { existsSync } = require('node:fs')
const { dirname, join } = require('node:path')
const { before, describe, test } = require('node:test')
const assert = require('node:assert')

const { CAPABILITIES, OmniError, makeRunner } = require('../src')
const { fib, fibinfo, fibrange, fibseq } = require('./fib')

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

function fibprovider() {
  const subjects = { fib, fibseq, fibrange, fibinfo }
  return {
    subject: (name) => subjects[name],
    contextify: (val) => ({ ...val, mark: 'CTX' }),
  }
}

// The ctxargs subject: the context comes first, and must arrive
// contextified with its client attached.
function fibshifted(ctx, start, end) {
  if ('CTX' !== ctx.mark || null == ctx.client) {
    throw new Error('fib: context not delivered')
  }
  return fibrange(start + ctx.shift, end + ctx.shift)
}

async function runner(spec, name = 'fib') {
  return (await makeRunner(spec, fibprovider()))(name)
}

async function refuses(run, pattern) {
  await assert.rejects(run, (err) => err instanceof OmniError && pattern.test(err.message))
}

describe('ext', () => {
  let R

  before(async () => {
    R = await runner(specfile('ext.json'))
  })

  test('capabilities', () => {
    for (const cap of ['ctxargs', 'fn', 'wait']) {
      assert.ok(CAPABILITIES.includes(cap), cap)
    }
  })

  test('ctxargs', async () => {
    await R.runset(R.spec.ctxargs, fibshifted)
  })

  test('fn', async () => {
    await R.runset(R.spec.fn, fib)
  })

  test('wait', async () => {
    await R.runset(R.spec.wait, fib)
  })
})

describe('ext runner', () => {
  const v1 = (requires, set) =>
    ({ OMNI: { version: 1, requires }, fib: { g: { set } } })

  test('a waiting entry that passes fails the set', async () => {
    const R = await runner(v1(['wait'], [{ in: 5, out: 5, wait: { cause: 'gone#1' } }]))
    await refuses(() => R.runset(R.spec.g, fib), /\[0\]: stale wait: gone#1/)
  })

  test('the wait flag holds an entry by id', async () => {
    const R = await runner(v1([], [{ id: 'a', in: 6, out: 9 }, { in: 7, out: 13 }]))
    await R.runsetflags(R.spec.g, { wait: { a: { cause: 'flag#1' } } }, fib)
  })

  test('the wait flag fails when its entry passes', async () => {
    const R = await runner(v1([], [{ id: 'a', in: 6, out: 8 }]))
    await refuses(() => R.runsetflags(R.spec.g, { wait: { a: { cause: 'flag#1' } } }, fib),
      /stale wait: flag#1/)
  })

  test('the wait flag must name an entry', async () => {
    const R = await runner(v1([], [{ id: 'a', in: 6, out: 8 }]))
    await refuses(() => R.runsetflags(R.spec.g, { wait: { zz: { cause: 'c' } } }, fib),
      /wait names no entry: zz/)
  })

  test('a wait needs a cause', async () => {
    const R = await runner(v1(['wait'], [{ in: 6, out: 9, wait: {} }]))
    await refuses(() => R.runset(R.spec.g, fib), /entry wait has no cause/)
  })

  test('wait and fn are unknown fields unless required', async () => {
    const W = await runner(v1([], [{ in: 6, out: 9, wait: { cause: 'c' } }]))
    await refuses(() => W.runset(W.spec.g, fib), /unknown entry field: wait/)
    const F = await runner(v1([], [{ fn: 'fib', in: 6, out: 8 }]))
    await refuses(() => F.runset(F.spec.g, fib), /unknown entry field: fn/)
  })

  test('an unknown fn is a spec error', async () => {
    const R = await runner(v1(['fn'], [{ fn: 'nope', in: 6, out: 8 }]))
    await refuses(() => R.runset(R.spec.g, fib), /unknown fn: nope/)
  })

  test('ctx with args needs ctxargs, and never takes in', async () => {
    const N = await runner(v1([], [{ ctx: { shift: 0 }, args: [0, 1], out: [0, 1] }]))
    await refuses(() => N.runset(N.spec.g, fibshifted), /more than one of in, args, ctx/)
    const I = await runner(v1(['ctxargs'], [{ in: 1, ctx: { shift: 0 }, out: [0] }]))
    await refuses(() => I.runset(I.spec.g, fibshifted), /entry has in beside args or ctx/)
  })

  test('a legacy spec ignores fn and wait', async () => {
    const R = await runner({ fib: { g: { set: [{ in: 6, out: 8, fn: 'nope', wait: { cause: 'c' } }] } } })
    await R.runset(R.spec.g, fib)
  })

  test('a raising hook is the entry\'s error, not the set\'s', async () => {
    const boom = () => { throw new Error('contextify boom') }
    const provider = { subject: () => fib, contextify: boom }
    const run = async (spec) => (await makeRunner(spec, provider))('fib')
    const E = await run(v1([], [{ ctx: { n: 6 }, err: 'contextify boom' }]))
    await E.runset(E.spec.g, fib)
    const U = await run(v1([], [{ ctx: { n: 6 }, out: 8 }]))
    await refuses(() => U.runset(U.spec.g, fib), /\[0\]: unexpected error\n\s+actual:\s+contextify boom/)
    const W = await run(v1(['wait'], [{ ctx: { n: 6 }, out: 8, wait: { cause: 'hook#1' } }]))
    await W.runset(W.spec.g, fib)
    const F = await (await makeRunner(v1(['fn'], [{ fn: 'boom', in: 6, err: 'subject boom' }]), {
      subject: (name) => {
        if ('boom' === name) {
          throw new Error('subject boom')
        }
        return fib
      },
    }))('fib')
    await F.runset(F.spec.g, fib)
  })

  test('a waiting entry holds a hook\'s error raised before the subject starts', async () => {
    const provider = {
      subject: (name) => {
        if ('boom' === name) {
          throw new Error('subject boom')
        }
        return 'fib' === name ? fib : undefined
      },
    }
    const run = async (spec) => (await makeRunner(spec, provider))('fib')
    const H = await run(v1(['fn', 'wait'], [{ fn: 'boom', in: 6, out: 8, wait: { cause: 'hook#2' } }]))
    await H.runset(H.spec.g, fib)
    const S = await run(v1(['fn', 'wait'], [{ fn: 'boom', in: 6, err: 'subject boom', wait: { cause: 'hook#3' } }]))
    await refuses(() => S.runset(S.spec.g, fib), /\[0\]: stale wait: hook#3/)
  })

  test('fn needs no default subject, but an entry without fn does', async () => {
    const provider = { subject: (name) => ('fibx' === name ? fib : undefined) }
    const R = await (await makeRunner(v1(['fn'], [{ fn: 'fibx', in: 6, out: 8 }]), provider))('fib')
    await R.runset(R.spec.g)
    const N = await (await makeRunner(v1(['fn'], [{ fn: 'fibx', in: 6, out: 8 }, { in: 6, out: 8 }]),
      provider))('fib')
    await refuses(() => N.runset(N.spec.g), /^omni: no test subject for: fib$/)
    const L = await (await makeRunner(v1([], [{ in: 6, out: 8 }]), provider))('fib')
    await refuses(() => L.runset(L.spec.g), /^omni: no test subject for: fib$/)
  })

  test('a wait is found by an id the entry owns, never an inherited one', async () => {
    const R = await runner(v1([], [{ id: 'constructor', in: 6, out: 8 }, { id: 'toString', in: 7, out: 13 }]))
    await R.runset(R.spec.g, fib)
    await R.runsetflags(R.spec.g, { wait: {} }, fib)
  })

  test('all reports every failure at once', async () => {
    const R = await runner(v1([], [{ in: 5, out: 6 }, { in: 6, out: 8 }, { in: 7, out: 14 }]))
    await refuses(() => R.runsetflags(R.spec.g, { all: true }, fib),
      /^omni: fib: 2 of 3 entries failed\n[^]*fib\[0\]: result mismatch[^]*fib\[2\]: result mismatch/)
    await refuses(() => R.runset(R.spec.g, fib), /^omni: fib\[0\]: result mismatch/)
  })
})
