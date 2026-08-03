# omni - JavaScript

CommonJS port of the canonical TypeScript implementation. Also hosts the
compatibility shim that lets `voxgig/struct` replace its in-situ runner.

```sh
npm test
```

## Use

```js
const { makeRunner } = require('@voxgig/omni-js')

const runner = await makeRunner('spec/fib.json', { subject: (n) => subjects[n] })
const R = await runner('fib')

await R.runset(R.spec.basic, fib)
await R.runsetflags(R.spec.nulls, { null: false }, fibinfo)
```

A failing check throws `OmniError`.

## struct compatibility

[`compat/struct.js`](compat/struct.js) exposes omni behind the exact runner
API used by `voxgig/struct`, so a struct port switches over by changing one
import:

```diff
-const { makeRunner, nullModifier, NULLMARK } = require('./runner')
+const { makeRunner, nullModifier, NULLMARK } = require('@voxgig/omni-js/compat/struct')
```

Verified by `make struct-compat` from the repository root: struct's own
suite, struct's own corpus, omni's runner.

## Layout

| File | Contents |
|---|---|
| `src/runner.js` | the runner |
| `src/util.js` | clone, deep equality, path lookup, walk, stringify |
| `src/index.js` | the public API |
| `compat/struct.js` | drop-in replacement for struct's runner |
| `test/fib.js` | the system under test |
| `test/fib.test.js` | the shared conformance suite |
