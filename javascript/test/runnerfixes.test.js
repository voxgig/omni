// Regression pins for the runner fixes ported from the typescript
// reference (the "omni#54" set): a cyclic match base must not blow the
// stack, jsonstr must render a cycle as [Circular] (a DAG in full), and
// an error-shaped plain map thrown by a subject must keep its message
// and fields. Each of these went red on the unfixed code.

const { test } = require('node:test')
const assert = require('node:assert')

const { match, jsonstr, makeRunner, OmniError } = require('../src')

test('match reads a cyclic base without blowing the stack', () => {
  const base = { name: 'ctx' }
  base.self = base // a live client context reaches itself

  assert.doesNotThrow(() => match({}, 0, { id: 'cyc' }, { name: 'ctx' }, base))
  assert.throws(() => match({}, 0, { id: 'cyc' }, { name: 'wrong' }, base),
    /match failed/)
})

test('jsonstr renders a cycle as [Circular] and a DAG in full', () => {
  const cyc = { a: 1 }
  cyc.me = cyc
  assert.match(jsonstr(cyc), /\[Circular\]/)

  const leaf = { x: 1 }
  const dag = { a: leaf, b: leaf }
  const out = jsonstr(dag)
  assert.doesNotMatch(out, /\[Circular\]/)
  assert.strictEqual(out.split('"x":1').length - 1, 2)
})

test('an error-shaped map throwable keeps its message and fields', async () => {
  const SPEC = {
    primary: {
      mapthrow: {
        basic: {
          set: [
            { in: 1, err: 'refused politely', match: { err: { code: 'polite' } } },
          ],
        },
      },
    },
  }

  const subject = () => {
    // Not an Error instance: an error-shaped plain map, thrown verbatim -
    // voxgig/sdkgen's generated makeError rethrows the fixture's own
    // error object this way.
    throw { message: 'refused politely', code: 'polite' }
  }

  const runner = await makeRunner(SPEC)
  const run = await runner('mapthrow')
  await run.runset(run.spec.basic, subject)

  // And the failure path still fails: a WRONG expected message must
  // reject with the map's real message in it, not '[object Object]'.
  const BAD = JSON.parse(JSON.stringify(SPEC))
  BAD.primary.mapthrow.basic.set[0].err = 'some other refusal'
  delete BAD.primary.mapthrow.basic.set[0].match
  const badrunner = await makeRunner(BAD)
  const badrun = await badrunner('mapthrow')
  await assert.rejects(
    badrun.runset(badrun.spec.basic, subject),
    (err) => {
      assert.ok(err instanceof OmniError)
      assert.doesNotMatch(String(err.message), /object Object/)
      return true
    })
})
