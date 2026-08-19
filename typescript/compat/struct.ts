// Drop-in replacement for the in-situ test runner in the voxgig/struct
// repository (`typescript/test/runner.ts`).
//
// struct's own runner and omni's runner implement the same spec format;
// this module exposes omni behind struct's exact runner API, so a struct
// port switches over by changing one import:
//
//   -import { makeRunner, nullModifier, NULLMARK } from './runner'
//   +import { makeRunner, nullModifier, NULLMARK } from './omni'
//
// where `./omni` is a small resolver in the port's test directory that
// locates a local omni checkout. Everything else - the corpus, the SDK,
// the test file - is unchanged. This is the TypeScript peer of
// javascript/compat/struct.js and python/voxgig_omni/compat/struct.py.

import { dirname, isAbsolute, join } from 'node:path'

import { EXISTSMARK, NULLMARK, UNDEFMARK, makeRunner as omnimakerunner, nullmodifier } from '../src'

import type { Json, Provider, Subject } from '../src'

// struct's data model is JSON-shaped `any` at its boundaries, and so is
// its SDK; these aliases say that on purpose rather than by omission.
export type StructSDK = any
export type StructUtility = any

// struct's runner API, name for name.
export type StructSubject = (...args: any[]) => any

export type StructRunSet = (testspec: any, testsubject?: StructSubject) => Promise<void>

export type StructRunSetFlags = (
  testspec: any,
  flags: Record<string, any>,
  testsubject?: StructSubject,
) => Promise<void>

export type StructRunPack = {
  spec: any
  runset: StructRunSet
  runsetflags: StructRunSetFlags
  subject?: StructSubject
  client: StructProvider
}

export type StructRunner = (name: string, store?: any) => Promise<StructRunPack>

// An omni provider that is also a struct client: test code reaches through
// the runpack's `client` as an SDK (`client.utility().struct`), so the
// wrapper forwards `utility()` and `tester()` alongside the four hooks.
export type StructProvider = Provider & {
  utility: () => StructUtility
  tester: (options?: any) => any
  sdk: StructSDK
}

// The directory this shim was loaded from: dist/compat when built, compat
// when run from source. Its parent is the port root, so every frame from
// inside omni is skipped when locating the caller.
const OMNIDIR = dirname(__dirname)

// struct passes a test-file path relative to the module that loads the
// runner, so resolve it the same way: the first stack frame outside omni
// is the caller. (A consumer that resolves the path itself - as struct's
// TypeScript port does, its test files sitting a directory below the
// loader - passes an absolute path and never reaches this.)
function callerdir(): string {
  const original = Error.prepareStackTrace
  Error.prepareStackTrace = (_err, stack) => stack
  const holder: any = {}
  Error.captureStackTrace(holder, callerdir)
  const stack: any = holder.stack
  Error.prepareStackTrace = original

  for (const frame of stack) {
    const file = 'function' === typeof frame.getFileName ? frame.getFileName() : null
    if (file && !file.startsWith(OMNIDIR)) {
      return dirname(file)
    }
  }

  return process.cwd()
}

// Wrap a struct SDK client as an omni provider.
function structprovider(sdk: StructSDK): StructProvider {
  return {
    // struct resolves a subject from the utility, or from utility.struct.
    subject: (name: string): Subject | undefined => {
      const utility = sdk.utility()
      return utility[name] || (utility.struct && utility.struct[name])
    },

    // A DEF.client entry becomes another SDK instance.
    client: async (options: Json) => structprovider(await sdk.tester(options)),

    // struct's SDK supplies its own context wrapper.
    contextify: (val: Json): Json => {
      const utility = sdk.utility()
      const hook =
        'function' === typeof utility.contextify
          ? utility.contextify
          : 'function' === typeof utility.makeContext
            ? utility.makeContext
            : null
      const ctx = null == hook ? val : hook.call(utility, val)
      if (null != ctx && 'object' === typeof ctx) {
        ;(ctx as any).utility = utility
      }
      return ctx
    },

    // Client options may reference the runner store.
    inject: (options: Json, store: Json): Json => {
      const structutils = sdk.utility().struct
      if (structutils && 'function' === typeof structutils.inject) {
        return structutils.inject(options, store)
      }
      return options
    },

    utility: () => sdk.utility(),
    tester: (options?: any) => sdk.tester(options),
    sdk,
  }
}

// struct's makeRunner(testfile, client) signature, backed by omni.
async function makeRunner(testfile: string, client: StructSDK): Promise<StructRunner> {
  const specpath = isAbsolute(testfile) ? testfile : join(callerdir(), testfile)
  const provider = structprovider(client)
  const runner = await omnimakerunner(specpath, provider)

  return async function structrunner(name: string, store?: any): Promise<StructRunPack> {
    const runpack = await runner(name, store)

    return {
      spec: runpack.spec,
      runset: runpack.runset,
      runsetflags: runpack.runsetflags,
      subject: runpack.subject,
      client: provider,
    }
  }
}

const nullModifier = nullmodifier

export { EXISTSMARK, NULLMARK, UNDEFMARK, makeRunner, nullModifier, structprovider }
