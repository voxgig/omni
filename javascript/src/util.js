// Omni internal JSON utilities.
//
// This module is deliberately self-contained: the omni runner must be able
// to test *any* library, including libraries that provide these same
// operations, so it can never borrow them from the system under test.
// Zero third-party dependencies, by design.

const NULLMARK = '__NULL__' // Value is JSON null.
const UNDEFMARK = '__UNDEF__' // Value is not present (thus, undefined).
const EXISTSMARK = '__EXISTS__' // Value exists (not undefined).

// A map (JSON object)?
function ismap(val) {
  return null != val && 'object' === typeof val && !Array.isArray(val)
}

// A list (JSON array)?
function islist(val) {
  return Array.isArray(val)
}

// A container (map or list)?
function isnode(val) {
  return ismap(val) || islist(val)
}

// Deep copy a JSON value. Non-JSON values (functions, class instances) are
// passed through by reference - the runner only ever clones test data.
function clone(val) {
  if (islist(val)) {
    return val.map((entry) => clone(entry))
  }

  if (ismap(val)) {
    const out = {}
    for (const key of Object.keys(val)) {
      out[key] = clone(val[key])
    }
    return out
  }

  return val
}

// Read a value from a nested structure by path. Returns undefined when any
// step is missing.
function getpath(val, path) {
  let current = val

  for (const part of path) {
    if (islist(current)) {
      const index = 'number' === typeof part ? part : parseInt(String(part), 10)
      if (isNaN(index) || index < 0 || index >= current.length) {
        return undefined
      }
      current = current[index]
    } else if (ismap(current)) {
      const key = String(part)
      if (!Object.prototype.hasOwnProperty.call(current, key)) {
        return undefined
      }
      current = current[key]
    } else {
      return undefined
    }
  }

  return current
}

// Depth-first walk, applying `apply` to every node and leaf, children
// first, then the containing node. `apply` may replace the value.
function walk(val, apply, key, parent, path) {
  const curpath = path || []

  if (isnode(val)) {
    if (islist(val)) {
      for (let index = 0; index < val.length; index++) {
        val[index] = walk(val[index], apply, index, val, [...curpath, index])
      }
    } else {
      for (const childkey of Object.keys(val)) {
        val[childkey] = walk(val[childkey], apply, childkey, val, [...curpath, childkey])
      }
    }
  }

  return apply(key, val, parent, curpath)
}

// Deep structural equality. Numbers compare by value, booleans never equal
// numbers, map key order is not significant.
function deepequal(a, b) {
  if (a === b) {
    return true
  }

  if (null == a || null == b) {
    return (undefined === a && undefined === b) || (null === a && null === b)
  }

  const atype = typeof a
  const btype = typeof b

  if ('number' === atype && 'number' === btype) {
    return a === b || (isNaN(a) && isNaN(b))
  }

  if (atype !== btype) {
    return false
  }

  if (islist(a) && islist(b)) {
    if (a.length !== b.length) {
      return false
    }
    for (let index = 0; index < a.length; index++) {
      if (!deepequal(a[index], b[index])) {
        return false
      }
    }
    return true
  }

  if (ismap(a) && ismap(b)) {
    const akeys = Object.keys(a)
    const bkeys = Object.keys(b)
    if (akeys.length !== bkeys.length) {
      return false
    }
    for (const key of akeys) {
      if (!Object.prototype.hasOwnProperty.call(b, key)) {
        return false
      }
      if (!deepequal(a[key], b[key])) {
        return false
      }
    }
    return true
  }

  return false
}

// Compact JSON text with map keys sorted, so that messages are identical
// in every port regardless of local map ordering.
function jsonstr(val) {
  if (undefined === val) {
    return 'undefined'
  }

  if (null === val) {
    return 'null'
  }

  if ('string' === typeof val) {
    return JSON.stringify(val)
  }

  if ('number' === typeof val) {
    return Number.isFinite(val) ? String(val) : 'null'
  }

  if ('boolean' === typeof val) {
    return val ? 'true' : 'false'
  }

  if (islist(val)) {
    return '[' + val.map((entry) => jsonstr(entry)).join(',') + ']'
  }

  if (ismap(val)) {
    const keys = Object.keys(val).sort()
    return '{' + keys.map((key) => JSON.stringify(key) + ':' + jsonstr(val[key])).join(',') + '}'
  }

  if ('function' === typeof val) {
    return '[Function' + (val.name ? ' ' + val.name : '') + ']'
  }

  return JSON.stringify(String(val))
}

// Human readable form of a value: strings verbatim, everything else as
// compact JSON.
function stringify(val) {
  return 'string' === typeof val ? val : jsonstr(val)
}

// Render a path as a dotted string.
function pathify(path) {
  return (path || []).map((part) => String(part)).join('.')
}

module.exports = {
  NULLMARK,
  UNDEFMARK,
  EXISTSMARK,
  clone,
  deepequal,
  getpath,
  islist,
  ismap,
  isnode,
  jsonstr,
  pathify,
  stringify,
  walk,
}
