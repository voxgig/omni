// Drop-in replacement for the in-situ test runner in the voxgig/struct
// repository (`<lang>/test/runner.js` and its ports).
//
// struct's own runner and omni's runner implement the same spec format;
// this module exposes omni behind struct's exact runner API, so a struct
// port switches over by changing one import:
//
//   -const { makeRunner, nullModifier, NULLMARK } = require('./runner')
//   +const { makeRunner, nullModifier, NULLMARK } = require('@voxgig/omni-js/compat/struct')
//
// Everything else - the corpus, the SDK, the test file - is unchanged.

const { dirname, isAbsolute, join, sep } = require('node:path')

const omni = require('../src')

const { EXISTSMARK, NULLMARK, UNDEFMARK, nullmodifier } = omni

// The directory this shim was loaded from. Its parent is the package root,
// so every frame from inside omni is skipped when locating the caller.
//
// This used to test each frame for the literal fragment `omni/javascript`,
// which is only true of a CHECKOUT. Installed from npm the shim lives at
// node_modules/@voxgig/omni-js/compat/struct.js, no frame matched, and the
// first frame examined - this module's own - was taken for the caller: a
// relative spec path then resolved to
// node_modules/@voxgig/omni-js/compat/<spec>, and makeRunner died on
// ENOENT. Deriving the root from __dirname holds wherever the package sits.
// The trailing separator matters: without it a sibling whose name merely
// EXTENDS this one (`omni-js-extra` beside `omni-js`) would read as inside.
//
// This is what the typescript, python, php and ruby peers already did;
// javascript was the only port matching on a path fragment.
const OMNIDIR = dirname(__dirname)

// struct passes a test-file path relative to the test file that loads the
// runner, so resolve it the same way.
function callerdir() {
  const original = Error.prepareStackTrace
  Error.prepareStackTrace = (_err, stack) => stack
  const holder = {}
  Error.captureStackTrace(holder, callerdir)
  const stack = holder.stack
  Error.prepareStackTrace = original

  for (const frame of stack) {
    const file = 'function' === typeof frame.getFileName ? frame.getFileName() : null
    if (file && !file.startsWith(OMNIDIR + sep)) {
      return dirname(file)
    }
  }

  return process.cwd()
}

// Wrap a struct SDK client as an omni provider. The wrapper also forwards
// `utility()` and `tester()`, so test code that reaches through the
// returned client keeps working unchanged.
function structprovider(sdk) {
  return {
    // struct resolves a subject from the utility, or from utility.struct.
    subject: (name) => {
      const utility = sdk.utility()
      return utility[name] || (utility.struct && utility.struct[name])
    },

    // A DEF.client entry becomes another SDK instance.
    client: async (options) => structprovider(await sdk.tester(options)),

    // struct's SDK supplies its own context wrapper.
    contextify: (val) => {
      const utility = sdk.utility()
      const ctx = 'function' === typeof utility.contextify ? utility.contextify(val) : val
      if (null != ctx && 'object' === typeof ctx) {
        ctx.utility = utility
      }
      return ctx
    },

    // Client options may reference the runner store.
    inject: (options, store) => {
      const utility = sdk.utility()
      if (utility.struct && 'function' === typeof utility.struct.inject) {
        return utility.struct.inject(options, store)
      }
      return options
    },

    utility: () => sdk.utility(),
    tester: (options) => sdk.tester(options),
    sdk,
  }
}

// struct's makeRunner(testfile, client) signature, backed by omni.
async function makeRunner(testfile, client) {
  const specpath = isAbsolute(testfile) ? testfile : join(callerdir(), testfile)
  const provider = structprovider(client)
  const runner = await omni.makeRunner(specpath, provider)

  return async function structrunner(name, store) {
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

module.exports = {
  EXISTSMARK,
  NULLMARK,
  UNDEFMARK,
  makeRunner,
  nullModifier: nullmodifier,
  structprovider,
}
