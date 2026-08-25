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

  # dist/ is not committed; the TypeScript port must be built to pack.
  if [ -f "$ROOT/$PORT/tsconfig.json" ]; then
    (cd "$ROOT/$PORT" && npm install --no-audit --no-fund --silent && npm run --silent build)
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

for (const sub of subpaths) {
  const spec = '.' === sub ? NAME : NAME + sub.slice(1)
  const at = require.resolve(spec)
  assert.ok(
    at.startsWith(SMOKE),
    spec + ' resolved to ' + at + ', outside the smoke dir - node walked up the tree',
  )
  const mod = require(spec)
  assert.ok(0 < Object.keys(mod).length, spec + ' resolved but exported nothing')
  console.log('  ' + spec + ': ' + Object.keys(mod).length + ' exports')
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

  (
    cd "$SMOKE"
    npm init -y >/dev/null 2>&1
    npm install "./$TARBALL" --no-audit --no-fund --silent
    # Invoked from the smoke ROOT, while the spec lives in consumer/.
    OMNI_PKG="$NAME" OMNI_SMOKE="$SMOKE" node consumer/consume.js
  )

  rm -rf "$SMOKE"
  echo "$NAME ok"
  echo ""
done

echo "omni: packaged ports ok"
