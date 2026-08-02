# omni - TypeScript (canonical)

The canonical omni implementation. Every other port is a translation of
[`src/Runner.ts`](src/Runner.ts) and [`src/Util.ts`](src/Util.ts).

```sh
npm install
npm test
```

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

## Layout

| File | Contents |
|---|---|
| `src/Runner.ts` | the runner: spec resolution, entry execution, matching |
| `src/Util.ts` | clone, deep equality, path lookup, walk, stringify |
| `src/index.ts` | the public API - the parity tool reads this list |
| `test/fib.ts` | the system under test: a tiny Fibonacci library |
| `test/fib.test.ts` | the shared conformance suite, plus runner self-checks |

## Notes

- Zero runtime dependencies. `typescript` and `@types/node` are dev-only.
- `npm test` builds first: the suite runs the compiled JavaScript in
  `dist/`.
- Node's own `assert` is deliberately not used for comparison - `deepequal`
  in `Util.ts` is the shared definition every port implements.
