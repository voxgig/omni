# omni - TypeScript (canonical)

The canonical omni implementation. Every other port is a translation of
[`src/Runner.ts`](src/Runner.ts) and [`src/Util.ts`](src/Util.ts).

## Install

omni is a test runner, so it belongs in `devDependencies`:

```sh
npm install --save-dev @voxgig/omni
```

Types are bundled. Zero runtime dependencies, and nothing here is imported
by a consumer's shipped code.

**Server-side only.** omni reads spec files from disk and runs a system
under test in-process; it does not target a browser and the package
carries no `browser` export condition.

Working in this repository instead: `npm install && npm test`.

## Use

```ts
import { makeRunner, Provider } from '@voxgig/omni'

const provider: Provider = { subject: (name) => subjects[name] }

const runner = await makeRunner('spec/fib.json', provider)
const R = await runner('fib')

await R.runset(R.spec.basic, fib)
await R.runsetflags(R.spec.nulls, { null: false }, fibinfo)
```

A failing check throws `OmniError`, which `node:test`, Jest, Vitest and
Mocha all report as a test failure. Subjects may be async - the runner
awaits every call.

## struct compatibility

[`compat/struct.ts`](compat/struct.ts) exposes omni behind the exact runner
API used by `voxgig/struct`, so a struct port switches over by changing one
import:

```diff
-import { makeRunner, nullModifier, NULLMARK } from './runner'
+import { makeRunner, nullModifier, NULLMARK } from './omni'
```

where `./omni` is the resolver in the consuming port's test directory that
locates a local omni checkout. Installed from npm no resolver is needed -
the shim is a declared subpath, `require('@voxgig/omni/compat/struct')`.
The shim wraps struct's SDK as a provider and forwards
`utility()`/`tester()`, so test code that reaches through the returned
client keeps working. It is the typed peer of
[`../javascript/compat/struct.js`](../javascript/compat/struct.js), and
being a build artifact it lives at `dist/compat/struct.js` once `npm run
build` has run.

## Layout

| File | Contents |
|---|---|
| `src/Runner.ts` | the runner: spec resolution, entry execution, matching |
| `src/Util.ts` | clone, deep equality, path lookup, walk, stringify |
| `src/index.ts` | the public API - the parity tool reads this list |
| `compat/struct.ts` | drop-in replacement for struct's runner |
| `test/fib.ts` | the system under test: a tiny Fibonacci library |
| `test/fib.test.ts` | the shared conformance suite, plus runner self-checks |

## Notes

- Zero runtime dependencies. `typescript` and `@types/node` are dev-only.
- `npm test` builds first: the suite runs the compiled JavaScript in
  `dist/`.
- Node's own `assert` is deliberately not used for comparison - `deepequal`
  in `Util.ts` is the shared definition every port implements.
