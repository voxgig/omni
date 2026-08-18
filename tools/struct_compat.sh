#!/bin/sh
# Run the voxgig/struct JavaScript test suite against omni's runner.
#
# Proves the replacement claim: struct's corpus, struct's library, struct's
# test file - only the runner import is swapped for omni's struct compat
# shim. Any divergence is a real behavioural difference.
#
# Usage: tools/struct_compat.sh [path-to-struct-repo]

set -e

OMNI=$(cd "$(dirname "$0")/.." && pwd)
STRUCT=${1:-$(cd "$OMNI/.." && pwd)/struct}

if [ ! -d "$STRUCT/javascript" ]; then
  echo "omni: struct repo not found at: $STRUCT"
  echo "usage: tools/struct_compat.sh [path-to-struct-repo]"
  exit 1
fi

# The rewritten test files are run from a temp directory, so every path
# substituted into them must be absolute - a relative STRUCT (the common
# `make struct-compat STRUCT=../struct`) would otherwise resolve against
# the temp dir and fail to load struct's SDK and corpus.
STRUCT=$(cd "$STRUCT" && pwd)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cp "$STRUCT/javascript/test/struct.test.js" "$WORK/struct.omni.test.js"
cp "$STRUCT/javascript/test/client.test.js" "$WORK/client.omni.test.js" 2>/dev/null || true

# The one and only edit: point the runner import at omni's compat shim.
# Two spellings, because struct migrates port by port: './runner' is the
# in-situ runner a port still carries, './omni' is the resolver a migrated
# port uses to find this very shim. Either way the suite ends up running
# against omni, which is what this gate exists to prove.
for FILE in "$WORK"/*.omni.test.js; do
  sed -i.bak "s|require('./runner')|require('$OMNI/javascript/compat/struct')|" "$FILE"
  sed -i.bak "s|require('./omni')|require('$OMNI/javascript/compat/struct')|" "$FILE"
  sed -i.bak "s|require('./sdk.js')|require('$STRUCT/javascript/test/sdk.js')|" "$FILE"
  sed -i.bak "s|require('./sdk')|require('$STRUCT/javascript/test/sdk')|" "$FILE"
  sed -i.bak "s|'../../build/test/test.json'|'$STRUCT/build/test/test.json'|" "$FILE"
  rm -f "$FILE.bak"
done

echo "omni: running struct's suite with omni's runner"
echo "  struct: $STRUCT"
echo "  omni:   $OMNI"
echo ""

cd "$STRUCT/javascript" && node --test "$WORK"/*.omni.test.js
