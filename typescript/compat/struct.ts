
import { dirname, isAbsolute, join, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

import { EXISTSMARK, NULLMARK, UNDEFMARK, makeRunner as omnimakerunner, nullmodifier } from '../src'

import type { Json, Provider, Subject } from '../src'

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

export type StructProvider = Provider & {
  utility: () => StructUtility
  tester: (options?: any) => any
  sdk: StructSDK
}

const OMNIDIR = dirname(__dirname)

function framepath(frame: any): string | null {
  const file = 'function' === typeof frame.getFileName ? frame.getFileName() : null
  if (null == file) {
    return null
  }
  if (file.startsWith('file://')) {
    try {
      return fileURLToPath(file)
    } catch {
      return null
    }
  }
  return isAbsolute(file) ? file : null
}

function callerdir(): string {
  const original = Error.prepareStackTrace
  Error.prepareStackTrace = (_err, stack) => stack
  const holder: any = {}
  Error.captureStackTrace(holder, callerdir)
  const stack: any = holder.stack
  Error.prepareStackTrace = original

  for (const frame of stack) {
    const file = framepath(frame)
    if (file && !file.startsWith(OMNIDIR + sep)) {
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
