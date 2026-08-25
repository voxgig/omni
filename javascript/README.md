# omni - JavaScript

CommonJS port of the canonical TypeScript implementation. Also hosts the
compatibility shim that lets `voxgig/struct` replace its in-situ runner.

## Install

omni is a test runner, so it belongs in `devDependencies`:

```sh
npm install --save-dev @voxgig/omni-js
```

Zero runtime dependencies, and nothing here is imported by a consumer's
shipped code.

Working in this repository instead: `npm test` (there is no build step).

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
API used by `voxgig/struct`. It is a declared subpath of the package, so a
struct port switches over by changing one import:

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
