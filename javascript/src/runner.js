// Omni: the shared multi-language test runner.
//
// Port of the canonical TypeScript implementation
// (typescript/src/Runner.ts). Behaviour must match, case for case.

const { readFileSync } = require('node:fs')

const {
  EXISTSMARK,
  NULLMARK,
  UNDEFMARK,
  clone,
  deepequal,
  getpath,
  islist,
  ismap,
  isnode,
  pathify,
  stringify,
  walk,
} = require('./util')

// The newest spec format version this runner understands. A spec with no
// OMNI block is version 0: the original, lenient format, frozen forever.
// Version 1 turns on strict entry validation (see checkentry).
const SPECVERSION = 1

// Capability strings this runner supports beyond the version baseline. A
// spec's OMNI.requires list is checked against this: an unknown capability
// refuses the spec loudly at load time, instead of a lagging port silently
// mis-running it. (Empty today; future format features mint a string here.)
const CAPABILITIES = []

// The complete set of fields an entry may carry. Under version 1 anything
// else is an error: an unrecognised key is almost always a typo'd
// assertion, and a typo'd assertion is a test that silently stopped
// testing.
const ENTRYFIELDS = ['in', 'args', 'ctx', 'out', 'err', 'match', 'client', 'id', 'doc']

// A test failure (or a malformed spec). Distinct from errors thrown by the
// subject under test, which are candidates for an `err` expectation.
class OmniError extends Error {
  constructor(message, entry) {
    super(message)
    this.name = 'OmniError'
    this.entry = entry
  }
}

// Load a spec: either a path to a JSON file, or an already-parsed object.
function loadspec(specref) {
  if ('string' === typeof specref) {
    return JSON.parse(readFileSync(specref, 'utf8'))
  }
  return specref
}

// Read the spec's format version from its optional top-level OMNI block,
// and refuse a spec this runner cannot faithfully run: a version newer
// than SPECVERSION, or a required capability not in CAPABILITIES.
function resolveversion(alltests) {
  const meta = ismap(alltests) ? alltests.OMNI : undefined

  if (undefined === meta) {
    return 0
  }

  if (!ismap(meta) || 'number' !== typeof meta.version || 0 !== meta.version % 1) {
    throw new OmniError('omni: malformed OMNI version block')
  }

  if (meta.version < 0 || SPECVERSION < meta.version) {
    throw new OmniError('omni: unsupported spec version: ' + meta.version)
  }

  const requires = meta.requires
  if (undefined !== requires) {
    if (!islist(requires)) {
      throw new OmniError('omni: malformed OMNI requires list')
    }
    for (const cap of requires) {
      if ('string' !== typeof cap || !CAPABILITIES.includes(cap)) {
        throw new OmniError('omni: spec requires unsupported capability: ' + stringify(cap))
      }
    }
  }

  return meta.version
}

// Strict entry validation, applied when the spec declares version 1 or
// later. The lenient format converts each of these mistakes into a silent
// pass or a dead field; here they fail with the entry named.
function checkentry(flags, index, entry) {
  if (!ismap(entry)) {
    throw fail(flags, index, entry, 'entry is not a map')
  }

  for (const key of Object.keys(entry)) {
    if (!ENTRYFIELDS.includes(key)) {
      throw fail(flags, index, entry, 'unknown entry field: ' + key)
    }
  }

  let argsources = 0
  for (const key of ['in', 'args', 'ctx']) {
    if (undefined !== entry[key]) {
      argsources++
    }
  }
  if (1 < argsources) {
    throw fail(flags, index, entry, 'entry has more than one of in, args, ctx')
  }

  if (null != entry.err && undefined !== entry.out) {
    throw fail(flags, index, entry, 'entry has both err and out')
  }

  if (undefined !== entry.id && 'string' !== typeof entry.id) {
    throw fail(flags, index, entry, 'entry id is not a string')
  }
}

// Validate a version-1 group up front, against the AUTHORED entries -
// null-normalisation would otherwise rewrite an authored null (e.g.
// id: null) into a sentinel string and hide it from validation. A
// malformed spec is a spec error, not a test result, so it fails before
// any subject runs.
function checkset(flags, testspec, normalset) {
  const origset =
    ismap(testspec) && islist(testspec.set) ? testspec.set : normalset

  if (0 === origset.length && true !== (ismap(testspec) ? testspec.empty : undefined)) {
    throw new OmniError('omni: empty test set: ' + flags.name)
  }

  for (let index = 0; index < origset.length; index++) {
    checkentry(flags, index, origset[index])
  }
}

// Find the named section of a spec: `primary.<name>`, then `<name>`, then
// the whole spec.
function resolvespec(name, alltests) {
  if (null == name) {
    return alltests
  }

  const primary = alltests.primary
  if (ismap(primary) && null != primary[name]) {
    return primary[name]
  }

  if (ismap(alltests) && null != alltests[name]) {
    return alltests[name]
  }

  return alltests
}

// Build the named clients declared by the spec's DEF.client block.
async function resolveclients(provider, spec, store) {
  const clients = {}

  const defclient = ismap(spec) && ismap(spec.DEF) ? spec.DEF.client : undefined
  if (!ismap(defclient)) {
    return clients
  }

  // A spec may define clients that a given test run never references.
  if (null == provider.client) {
    return clients
  }

  for (const clientname of Object.keys(defclient)) {
    const cdef = defclient[clientname]
    const copts = clone((ismap(cdef) && ismap(cdef.test) ? cdef.test.options : undefined) || {})

    if (ismap(store) && null != provider.inject) {
      provider.inject(copts, store)
    }

    clients[clientname] = await provider.client(copts)
  }

  return clients
}

function resolvesubject(name, provider) {
  if (null == name || null == provider.subject) {
    return undefined
  }
  return provider.subject(name) || undefined
}

function resolveflags(flags) {
  const out = null == flags ? {} : { ...flags }
  out.null = null == out.null ? true : !!out.null
  return out
}

// An entry with no `out` expects a null (or absent) result.
function resolveentry(entry, flags) {
  if (null == entry.out && flags.null) {
    entry.out = NULLMARK
  }
  return entry
}

function resolvetestpack(name, entry, subject, provider, clients) {
  const testpack = { client: provider, subject }

  if (null != entry.client) {
    const client = clients[entry.client]
    if (null == client) {
      throw new OmniError('omni: unknown client: ' + entry.client, entry)
    }
    testpack.client = client
    testpack.subject = resolvesubject(name, client) || subject
  }

  return testpack
}

// Build the argument list for one entry: `ctx`, `args`, or `in`.
function resolveargs(entry, testpack, provider) {
  let args

  if (undefined !== entry.ctx) {
    args = [entry.ctx]
  } else if (undefined !== entry.args) {
    args = entry.args
  } else {
    args = [clone(entry.in)]
  }

  if (undefined !== entry.ctx || undefined !== entry.args) {
    let first = args[0]
    if (ismap(first)) {
      first = clone(first)
      if (null != provider.contextify) {
        first = provider.contextify(first)
      }
      args[0] = first
      entry.ctx = first
      if (ismap(first)) {
        first.client = testpack.client
      }
    }
  }

  return args
}

// Normalise a value for comparison: JSON nulls (and absent values) become
// NULLMARK, errors become {name,message} maps. Always a fresh copy.
function fixjson(val, flags) {
  const donull = null == flags || null == flags.null ? true : !!flags.null
  return fixjsonval(val, donull)
}

function fixjsonval(val, donull) {
  if (null == val) {
    return donull ? NULLMARK : val
  }

  if (val instanceof Error) {
    return errify(val)
  }

  if (islist(val)) {
    return val.map((entry) => fixjsonval(entry, donull))
  }

  if (ismap(val)) {
    const out = {}
    for (const key of Object.keys(val)) {
      out[key] = fixjsonval(val[key], donull)
    }
    return out
  }

  return val
}

// The JSON form of an error: always at least {name,message}.
function errify(err) {
  if (err instanceof Error) {
    return { ...err, name: err.name, message: err.message }
  }
  return { name: 'Error', message: String(err) }
}

function errmessage(err) {
  return err instanceof Error ? err.message : String(err)
}

// The label of one entry, for failure messages.
function entryref(flags, index, entry) {
  const label = flags.name || 'set'
  const id = null != entry && null != entry.id ? ' (' + entry.id + ')' : ''
  return label + '[' + index + ']' + id
}

function fail(flags, index, entry, reason, expected, actual) {
  let msg = 'omni: ' + entryref(flags, index, entry) + ': ' + reason
  if (undefined !== expected) {
    msg += '\n  expected: ' + expected
  }
  if (undefined !== actual) {
    msg += '\n  actual:   ' + actual
  }
  msg += '\n  entry:    ' + stringify(entrysummary(entry))
  return new OmniError(msg, entry)
}

// The spec-defined part of an entry (drop runner bookkeeping).
function entrysummary(entry) {
  if (!ismap(entry)) {
    return entry
  }
  const out = {}
  for (const key of Object.keys(entry)) {
    if ('res' !== key && 'thrown' !== key && 'ctx' !== key) {
      out[key] = entry[key]
    }
  }
  return out
}

function checkresult(flags, index, entry, args, res) {
  let matched = false

  if (null != entry.err) {
    throw fail(
      flags,
      index,
      entry,
      'expected error did not occur',
      stringify(entry.err),
      stringify(res),
    )
  }

  if (null != entry.match) {
    match(flags, index, entry, entry.match, {
      in: entry.in,
      args,
      out: entry.res,
      ctx: entry.ctx,
    })
    matched = true
  }

  const out = entry.out

  if (out === res) {
    return
  }

  // NOTE: a match with no explicit out is a complete check on its own.
  if (matched && (NULLMARK === out || null == out)) {
    return
  }

  if (!deepequal(res, out)) {
    throw fail(flags, index, entry, 'result mismatch', stringify(out), stringify(res))
  }
}

function handleerror(flags, index, entry, err) {
  entry.thrown = err

  const entryerr = entry.err

  if (null != entryerr) {
    if (true === entryerr || matchval(entryerr, errmessage(err))) {
      if (null != entry.match) {
        match(flags, index, entry, entry.match, {
          in: entry.in,
          out: entry.res,
          ctx: entry.ctx,
          err: errify(err),
        })
      }
      return
    }

    throw fail(flags, index, entry, 'error mismatch', stringify(entryerr), errmessage(err))
  }

  throw fail(flags, index, entry, 'unexpected error', undefined, errmessage(err))
}

// Check that every leaf of `check` is present, and matches, in `base`.
function match(flags, index, entry, check, base) {
  const cbase = clone(base)

  const at = (path) => (0 === path.length ? '<root>' : pathify(path))

  walk(clone(check), (_key, val, _parent, path) => {
    // An empty container in the check is a structural placeholder: it has
    // no leaves to check, so it matches whatever is at that path. This is
    // deliberate - voxgig/struct's corpus relies on it (struct-compat), and
    // an empty sub-pattern matching anything is the usual partial-match
    // convention. The leaf checks below are where the strictness lives.
    if (!isnode(val)) {
      const baseval = getpath(cbase, path)

      if (baseval === val) {
        return val
      }

      // Explicitly absent: satisfied only by a genuinely missing key, never
      // by a present null (the distinction the sentinels exist to keep).
      if (UNDEFMARK === val) {
        if (undefined === baseval) {
          return val
        }
        throw fail(flags, index, entry, 'expected absent at ' + at(path), 'absent', stringify(baseval))
      }

      // Explicitly null: satisfied only by a present null.
      if (NULLMARK === val) {
        if (null === baseval || NULLMARK === baseval) {
          return val
        }
        throw fail(flags, index, entry, 'expected null at ' + at(path), 'null', stringify(baseval))
      }

      // Explicitly present: any present value, including null.
      if (EXISTSMARK === val) {
        if (undefined !== baseval) {
          return val
        }
        throw fail(flags, index, entry, 'expected present at ' + at(path), 'present', 'absent')
      }

      // A concrete expectation never matches a missing key - a match leaf
      // against an absent value must fail, not substring-match "undefined".
      if (undefined === baseval) {
        throw fail(flags, index, entry, 'match failed at ' + at(path), stringify(val), 'absent')
      }

      if (!matchval(val, baseval)) {
        throw fail(flags, index, entry, 'match failed at ' + at(path), stringify(val), stringify(baseval))
      }
    }

    return val
  })
}


// Match one leaf. Strings are matched as /regex/ or as a case-insensitive
// substring, which is what makes error-message expectations portable.
function matchval(check, base) {
  if (check === base) {
    return true
  }

  let want = check
  if (UNDEFMARK === want || NULLMARK === want) {
    want = null
  }

  if (null == want) {
    return null == base || NULLMARK === base
  }

  if ('string' === typeof want) {
    // An empty want is not a wildcard: the empty string is a substring of
    // everything, so `match:{out:""}` (or `err:""`) would accept any value.
    if ('' === want) {
      return '' === base
    }

    const basestr = stringify(base)

    const rem = want.match(/^\/(.+)\/$/)
    if (rem) {
      return new RegExp(rem[1]).test(basestr)
    }

    return basestr.toLowerCase().includes(want.toLowerCase())
  }

  if ('function' === typeof want) {
    return true
  }

  return deepequal(want, base)
}

// Convert NULLMARK sentinels back into real nulls.
function nullmodifier(val, key, parent) {
  if (NULLMARK === val) {
    parent[key] = null
  } else if ('string' === typeof val) {
    parent[key] = val.split(NULLMARK).join('null')
  }
}

// Make a runner for a spec file (or spec object) and a provider.
async function makeRunner(specref, provider) {
  const alltests = loadspec(specref)
  const specversion = resolveversion(alltests)
  const useprovider = provider || {}

  return async function runner(name, store) {
    const spec = resolvespec(name, alltests)
    const clients = await resolveclients(useprovider, spec, store || {})
    const defsubject = resolvesubject(name, useprovider)

    const runsetflags = async (testspec, flags, testsubject) => {
      const useflags = resolveflags(flags)
      useflags.name = useflags.name || name || 'set'

      const subject = testsubject || defsubject
      if (null == subject) {
        throw new OmniError('omni: no test subject for: ' + useflags.name)
      }

      const testspecmap = fixjson(testspec, useflags)

      if (!ismap(testspecmap) || !islist(testspecmap.set)) {
        throw new OmniError('omni: test spec has no set: ' + useflags.name)
      }

      const testset = testspecmap.set

      if (1 <= specversion) {
        checkset(useflags, testspec, testset)
      }

      for (let index = 0; index < testset.length; index++) {
        let entry = testset[index]

        try {
          entry = resolveentry(entry, useflags)

          const testpack = resolvetestpack(name, entry, subject, useprovider, clients)
          const args = resolveargs(entry, testpack, useprovider)

          let res = await testpack.subject(...args)
          res = fixjson(res, useflags)
          entry.res = res

          checkresult(useflags, index, entry, args, res)
        } catch (err) {
          if (err instanceof OmniError) {
            throw err
          }
          handleerror(useflags, index, entry, err)
        }
      }
    }

    const runset = async (testspec, testsubject) => runsetflags(testspec, {}, testsubject)

    return {
      spec,
      runset,
      runsetflags,
      subject: defsubject,
      client: useprovider,
    }
  }
}

module.exports = {
  CAPABILITIES,
  EXISTSMARK,
  NULLMARK,
  OmniError,
  SPECVERSION,
  UNDEFMARK,
  errify,
  fixjson,
  loadspec,
  makeRunner,
  match,
  matchval,
  nullmodifier,
  resolvespec,
}
