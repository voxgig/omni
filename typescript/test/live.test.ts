
import { describe, test } from 'node:test'
import assert from 'node:assert'

import { errify, jsonstr, match } from '../src'


// A minimal cyclic structure of the shape a live context has: a parent
// that reaches a child, and a child that reaches the parent again.
function cyclic(): any {
  const client: any = { name: 'client' }
  const ctx: any = { client, opname: 'load' }
  client.rootctx = ctx
  return ctx
}


describe('live-object safety', () => {

  test('match reads a cyclic base without exhausting the stack', () => {
    const base = cyclic()

    // The check names a leaf that IS present, so this must simply pass.
    // Before the fix it never got that far: match cloned the base first,
    // and cloning a cycle recurses forever.
    assert.doesNotThrow(() => match({}, 0, {}, { opname: 'load' }, base))
  })


  test('match still reports a genuine mismatch against a cyclic base', () => {
    // The guard must not have been bought by making match lenient.
    assert.throws(() => match({}, 0, {}, { opname: 'save' }, cyclic()))
  })


  test('jsonstr renders a cycle rather than recursing forever', () => {
    const out = jsonstr(cyclic())

    assert.match(out, /\[Circular\]/)
    assert.match(out, /"opname":"load"/)
  })


  test('jsonstr renders a DAG in full, since it is not a cycle', () => {
    // The same object twice as SIBLINGS is not a cycle, and eliding it
    // would make failure messages lie about the value that was compared.
    const shared = { a: 1 }

    assert.equal(jsonstr({ x: shared, y: shared }), '{"x":{"a":1},"y":{"a":1}}')
    assert.equal(jsonstr([shared, shared]), '[{"a":1},{"a":1}]')
  })


  test('errify keeps the message of an error-SHAPED map', () => {
    const out: any = errify({ name: 'HttpError', message: 'not found', status: 404 })

    assert.equal(out.name, 'HttpError')
    assert.equal(out.message, 'not found')
    assert.equal(out.status, 404)
  })


  test('errify is unchanged for an Error and for a bare value', () => {
    const err: any = errify(new TypeError('bad input'))
    assert.equal(err.name, 'TypeError')
    assert.equal(err.message, 'bad input')

    const str: any = errify('plain string')
    assert.equal(str.name, 'Error')
    assert.equal(str.message, 'plain string')
  })
})
