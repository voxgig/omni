#!/bin/sh
# Check what the npm ports would actually PUBLISH, as a consumer receives it.
#
# The test suites run against the working tree, where every file is present
# whatever `files` says, and where the shims sit at their checkout paths.
# Two bugs lived in exactly that blind spot:
#
#   - @voxgig/omni-js shipped `files: ["src"]` and omitted compat/struct.js,
#     the one module voxgig/struct's JavaScript port consumes.
#   - the same shim identified "frames inside omni" by the literal path
#     fragment `omni/javascript`, true only of a checkout. Installed under
#     node_modules nothing matched, the shim took its own frame for the
#     caller, and a relative spec path resolved inside node_modules.
#   - @voxgig/omni-js built its export object by spread, which node's
#     cjs-module-lexer cannot read statically, so `import { makeRunner }
#     from '@voxgig/omni-js'` failed where the same import from
#     @voxgig/omni worked. Only reachable once installed.
#   - both shims resolved a relative spec path against a caller frame that
#     an ESM caller reports as a file:// URL, so it became
#     `file:/.../fib.json` and the read failed.
#   - the typescript tarball is 100% build output and dist/ is not
#     committed, so `npm publish` from a clean tree shipped LICENSE,
#     README and package.json - nothing else.
#
# So: pack the tarball, install it into an empty directory OUTSIDE this
# repository, and exercise it there.
#
# Usage: tools/pack_check.sh [port ...]   (default: typescript javascript)

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORTS=${*:-"typescript javascript"}

for PORT in $PORTS; do
  NAME=$(node -p "require('$ROOT/$PORT/package.json').name")
  printf '======== %s (%s) ========\n' "$PORT" "$NAME"

  # Install only - deliberately NOT `npm run build`. dist/ is not committed
  # and the tarball is entirely build output, so the port's `prepack` is
  # what has to produce it. Building here would mask a missing prepack and
  # this check would pass over a tarball that a real publish ships hollow.
  if [ -f "$ROOT/$PORT/tsconfig.json" ]; then
    (cd "$ROOT/$PORT" && npm install --no-audit --no-fund --silent)
    rm -rf "$ROOT/$PORT/dist"
  fi

  SMOKE=$(mktemp -d)

  # NODE RESOLVES UP THE DIRECTORY TREE. A smoke directory nested inside a
  # tree that already has these packages installed would find those instead
  # and pass for the wrong reason - which is how the first attempt at
  # proving the `files` bug passed. Refuse that outright.
  case "$SMOKE" in
    "$ROOT"|"$ROOT"/*)
      echo "omni: smoke dir $SMOKE is inside the repository; set TMPDIR elsewhere" >&2
      exit 1
      ;;
  esac

  TARBALL=$(cd "$ROOT/$PORT" && npm pack --pack-destination "$SMOKE" --silent | tail -1)
  echo "packed $TARBALL"
  tar tzf "$SMOKE/$TARBALL"

  mkdir -p "$SMOKE/consumer"
  cp "$ROOT/spec/fib.json" "$SMOKE/consumer/fib.json"

  # The spec sits beside the consumer module, one level below where node is
  # invoked, and is named RELATIVELY. That makes the check discriminating:
  # a caller-relative answer finds it, while both a cwd-relative answer and
  # the shim's own directory do not.
  cat > "$SMOKE/consumer/consume.js" <<'JS'
const assert = require('node:assert')

const NAME = process.env.OMNI_PKG
const SMOKE = process.env.OMNI_SMOKE

function fib(n) {
  let prev = 0
  let cur = 1
  if (0 === n) return 0
  for (let i = 1; i < n; i++) {
    const next = prev + cur
    prev = cur
    cur = next
  }
  return cur
}

// Every subpath the manifest declares must resolve, export something, and
// resolve to a file INSIDE the smoke directory - never to a copy found by
// walking up the tree.
const pkg = require(NAME + '/package.json')
assert.ok(pkg.exports, NAME + ': manifest declares no exports map')

const subpaths = Object.keys(pkg.exports).filter((s) => s !== './package.json')
assert.ok(0 < subpaths.length, NAME + ': exports map has no entry points')

const PKGDIR = require('node:path').dirname(require.resolve(NAME + '/package.json'))

for (const sub of subpaths) {
  const spec = '.' === sub ? NAME : NAME + sub.slice(1)
  const at = require.resolve(spec)
  assert.ok(
    at.startsWith(SMOKE),
    spec + ' resolved to ' + at + ', outside the smoke dir - node walked up the tree',
  )
  const mod = require(spec)
  assert.ok(0 < Object.keys(mod).length, spec + ' resolved but exported nothing')

  // A declared `types` condition must actually be in the tarball. Requiring
  // the subpath proves only the RUNTIME half; a `files` list that dropped
  // the .d.ts files would ship a typeless package and still pass.
  const entry = pkg.exports[sub]
  const types = entry && 'object' === typeof entry ? entry.types : null
  if (types) {
    const dts = require('node:path').join(PKGDIR, types)
    assert.ok(require('node:fs').existsSync(dts), spec + ': declared types ' + types + ' is not in the tarball')
  }

  console.log('  ' + spec + ': ' + Object.keys(mod).length + ' exports' + (types ? ' + types' : ''))
}

// `types` at the top level too, for consumers that never look at `exports`.
if (pkg.types) {
  const dts = require('node:path').join(PKGDIR, pkg.types)
  assert.ok(require('node:fs').existsSync(dts), NAME + ': declared types ' + pkg.types + ' is not in the tarball')
}

// The compat shim, behind a struct-shaped SDK, given a RELATIVE spec path.
function sdkfor(shift) {
  const sdk = {
    utility: () => ({
      fib: (n) => fib('number' === typeof n ? n + shift : n),
      contextify: (v) => v,
      struct: { inject: (o) => o },
    }),
    tester: async (o) => sdkfor(o && o.shift ? o.shift : 0),
  }
  return sdk
}

async function main() {
  const compat = require(NAME + '/compat/struct')
  const runner = await compat.makeRunner('./fib.json', sdkfor(0))
  const R = await runner('fib')
  await R.runset(R.spec.basic, fib)
  console.log('  compat/struct: relative spec resolved against the caller, corpus ran')
}

main().catch((e) => {
  console.error('  FAILED: ' + e.message)
  process.exit(1)
})
JS

  # Every subpath must also import as ESM by NAME. A CommonJS entry point is
  # only importable that way if node's cjs-module-lexer can see the names
  # statically: an object built by spread is opaque to it, and
  # `import { makeRunner } from '@voxgig/omni-js'` failed for exactly that
  # reason while the same import from @voxgig/omni worked.
  cat > "$SMOKE/consumer/esm.mjs" <<'MJS'
import { createRequire } from 'node:module'
import assert from 'node:assert'

const NAME = process.env.OMNI_PKG
const require = createRequire(import.meta.url)
const pkg = require(NAME + '/package.json')

for (const sub of Object.keys(pkg.exports).filter((s) => s !== './package.json')) {
  const spec = '.' === sub ? NAME : NAME + sub.slice(1)
  const mod = await import(spec)
  const named = Object.keys(mod).filter((k) => 'default' !== k)
  assert.ok(
    named.includes('makeRunner'),
    spec + ': no named ESM export `makeRunner` - the entry point is opaque to cjs-module-lexer',
  )
  console.log('  ' + spec + ': ' + named.length + ' named ESM exports')
}

// IMPORTING THE SHIM IS NOT USING IT. The compat shim resolves a relative
// spec path by walking the stack for the first frame outside omni, and an
// ESM caller's frame is a file:// URL rather than a path - so this file
// must actually CALL it, from ESM, with a relative path. Importing alone
// left that bug invisible.
function fib(n) {
  let prev = 0
  let cur = 1
  if (0 === n) return 0
  for (let i = 1; i < n; i++) {
    const next = prev + cur
    prev = cur
    cur = next
  }
  return cur
}

function sdkfor(shift) {
  const sdk = {
    utility: () => ({
      fib: (n) => fib('number' === typeof n ? n + shift : n),
      contextify: (v) => v,
      struct: { inject: (o) => o },
    }),
    tester: async (o) => sdkfor(o && o.shift ? o.shift : 0),
  }
  return sdk
}

const compat = await import(NAME + '/compat/struct')
const runner = await compat.makeRunner('./fib.json', sdkfor(0))
const R = await runner('fib')
await R.runset(R.spec.basic, fib)
console.log('  compat/struct: relative spec resolved from an ESM caller, corpus ran')
MJS

  (
    cd "$SMOKE"
    npm init -y >/dev/null 2>&1
    npm install "./$TARBALL" --no-audit --no-fund --silent
    # Invoked from the smoke ROOT, while the spec lives in consumer/.
    OMNI_PKG="$NAME" OMNI_SMOKE="$SMOKE" node consumer/consume.js
    OMNI_PKG="$NAME" node consumer/esm.mjs
  )

  rm -rf "$SMOKE"
  echo "$NAME ok"
  echo ""
done

echo "omni: packaged ports ok"
