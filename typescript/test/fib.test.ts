// RUN: npm test
//
// The Fibonacci conformance suite: every omni port runs this same set of
// groups, from the same spec/fib.json, against the same fib library.

import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { before, describe, test } from 'node:test'
import assert from 'node:assert'

import { OmniError, Provider, RunPack, Subject, makeRunner } from '../src'
import { fib, fibinfo, fibrange, fibseq } from './fib'

// Find the shared spec directory by walking up from this file.
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

// The provider hosts the system under test. `shift` offsets the Fibonacci
// index, so that a client-specific subject is observably different.
// `contextify` marks the map, so the context group can prove the hook ran.
function fibprovider(shift: number): Provider {
  const subjects: Record<string, Subject> = {
    fib: (n: any) => fib('number' === typeof n ? n + shift : n),
    fibseq,
    fibrange,
    fibinfo,
  }

  return {
    subject: (name: string) => subjects[name],
    client: (options: any) => fibprovider(options && options.shift ? options.shift : 0),
    contextify: (val: any) => ({ ...val, mark: 'CTX' }),
  }
}

// The context-group subject: reports what the runner delivered - the
// contextify mark and the attached client - as plain data, so the spec can
// pin both with an ordinary `out` comparison in every port.
function fibctx(ctx: any): any {
  return {
    n: ctx.n,
    val: fib(ctx.n),
    mark: ctx.mark,
    hasclient: null != ctx.client,
  }
}

describe('fib', () => {
  let R: RunPack

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
    },
  }

  async function expectfail(setname: string, subject: Subject, flags?: any) {
    const runner = await makeRunner(badspec)
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runsetflags((R.spec as any)[setname], flags || {}, subject),
      (err: any) => err instanceof OmniError,
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

  test('rejects an unsupported spec version', async () => {
    await assert.rejects(
      async () => makeRunner({ OMNI: { version: 99 }, fib: { g: { set: [] } } }),
      (err: any) => err instanceof OmniError && /unsupported spec version/.test(err.message),
    )
  })

  test('rejects an unknown required capability', async () => {
    await assert.rejects(
      async () => makeRunner({ OMNI: { version: 1, requires: ['nosuchfeature'] }, fib: { g: { set: [] } } }),
      (err: any) => err instanceof OmniError && /unsupported capability/.test(err.message),
    )
  })

  test('rejects a malformed version block', async () => {
    await assert.rejects(
      async () => makeRunner({ OMNI: { version: 'one' }, fib: { g: { set: [] } } }),
      (err: any) => err instanceof OmniError && /malformed OMNI/.test(err.message),
    )
  })

  // A present-but-null block is malformed; only a genuinely absent OMNI
  // key is legacy. Ports that test definedness rather than presence
  // silently skip strict mode here, so both cases are pinned.
  test('rejects a null OMNI block, but accepts an absent one', async () => {
    await assert.rejects(
      async () => makeRunner({ OMNI: null, fib: { g: { set: [{ in: 1, out: 1 }] } } }),
      (err: any) => err instanceof OmniError && /malformed OMNI/.test(err.message),
    )
    await assert.rejects(
      async () =>
        makeRunner({ OMNI: { version: 1, requires: null }, fib: { g: { set: [{ in: 1, out: 1 }] } } }),
      (err: any) => err instanceof OmniError && /malformed OMNI requires list/.test(err.message),
    )
    await makeRunner({ fib: { g: { set: [{ in: 1, out: 1 }] } } })
  })

  test('strict: an unknown entry field fails instead of passing vacuously', async () => {
    const runner = await makeRunner({
      OMNI: { version: 1 },
      fib: { g: { set: [{ in: 6, matches: { out: 999 } }] } },
    })
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runset((R.spec as any).g, fibinfo),
      (err: any) => err instanceof OmniError && /unknown entry field: matches/.test(err.message),
    )
  })

  test('strict: more than one of in, args, ctx fails', async () => {
    const runner = await makeRunner({
      OMNI: { version: 1 },
      fib: { g: { set: [{ in: 5, args: [5], out: 5 }] } },
    })
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runset((R.spec as any).g, fib),
      (err: any) => err instanceof OmniError && /more than one of in, args, ctx/.test(err.message),
    )
  })

  test('strict: err together with out fails', async () => {
    const runner = await makeRunner({
      OMNI: { version: 1 },
      fib: { g: { set: [{ in: -1, err: true, out: 5 }] } },
    })
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runset((R.spec as any).g, fib),
      (err: any) => err instanceof OmniError && /both err and out/.test(err.message),
    )
  })

  test('strict: a null id fails even under null-normalisation', async () => {
    const runner = await makeRunner({
      OMNI: { version: 1 },
      fib: { g: { set: [{ in: 1, out: 1, id: null }] } },
    })
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runset((R.spec as any).g, fib),
      (err: any) => err instanceof OmniError && /entry id is not a string/.test(err.message),
    )
  })

  test('strict: an empty set fails unless marked empty', async () => {
    const runner = await makeRunner({
      OMNI: { version: 1 },
      fib: { g: { set: [] }, h: { set: [], empty: true } },
    })
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runset((R.spec as any).g, fib),
      (err: any) => err instanceof OmniError && /empty test set/.test(err.message),
    )
    await R.runset((R.spec as any).h, fib)
  })

  test('a legacy spec (no OMNI block) stays lenient', async () => {
    const runner = await makeRunner({
      fib: { g: { set: [{ in: 6, matches: { out: 999 }, out: 8 }] } },
    })
    const R = await runner('fib')
    await R.runset((R.spec as any).g, fib)
  })

  test('reports entry index and id', async () => {
    const runner = await makeRunner({
      fib: { g: { set: [{ in: 1, out: 1 }, { id: 'x#2', in: 2, out: 42 }] } },
    })
    const R = await runner('fib')
    await assert.rejects(
      async () => R.runset((R.spec as any).g, fib),
      (err: any) => {
        assert.match(err.message, /fib\[1\] \(x#2\)/)
        assert.match(err.message, /expected: 42/)
        assert.match(err.message, /actual:   1/)
        return true
      },
    )
  })
})
