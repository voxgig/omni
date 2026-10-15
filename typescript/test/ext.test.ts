// RUN: npm test
//
// The capability suite: spec/ext.json requires ctxargs, fn and wait, and
// every port that carries them runs it, beside the runner flag `all`.

import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { before, describe, test } from 'node:test'
import assert from 'node:assert'

import { CAPABILITIES, OmniError, Provider, RunPack, Subject, makeRunner } from '../src'
import { fib, fibinfo, fibrange, fibseq } from './fib'

function specfile(name: string): string {
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

function fibprovider(): Provider {
  const subjects: Record<string, Subject> = { fib, fibseq, fibrange, fibinfo }
  return {
    subject: (name: string) => subjects[name],
    contextify: (val: any) => ({ ...val, mark: 'CTX' }),
  }
}

// The ctxargs subject: the context comes first, and must arrive
// contextified with its client attached.
function fibshifted(ctx: any, start: any, end: any): number[] {
  if ('CTX' !== ctx.mark || null == ctx.client) {
    throw new Error('fib: context not delivered')
  }
  return fibrange(start + ctx.shift, end + ctx.shift)
}

async function runner(spec: any, name = 'fib'): Promise<RunPack> {
  return (await makeRunner(spec, fibprovider()))(name)
}

async function refuses(run: () => Promise<any>, pattern: RegExp) {
  await assert.rejects(run, (err: any) => err instanceof OmniError && pattern.test(err.message))
}

describe('ext', () => {
  let R: RunPack

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
  const v1 = (requires: string[], set: any[]) =>
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

  test('all reports every failure at once', async () => {
    const R = await runner(v1([], [{ in: 5, out: 6 }, { in: 6, out: 8 }, { in: 7, out: 14 }]))
    await refuses(() => R.runsetflags(R.spec.g, { all: true }, fib),
      /^omni: fib: 2 of 3 entries failed\n[^]*fib\[0\]: result mismatch[^]*fib\[2\]: result mismatch/)
    await refuses(() => R.runset(R.spec.g, fib), /^omni: fib\[0\]: result mismatch/)
  })
})
