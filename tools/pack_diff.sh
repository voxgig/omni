#!/bin/sh
# Compare what a port WOULD publish against what is on the registry now, and
# refuse a release that drops files the published version has.
#
# This exists because it happened. @voxgig/omni@0.1.0 was published from a
# tree whose `files` list carried "src", while main's did not - so the next
# release from main would have removed src/Runner.ts, src/Util.ts and
# src/index.ts from the package with nothing to notice. Adding files to a
# release is ordinary; removing them silently breaks whoever imported them.
#
# Additions are reported and allowed. Removals fail. Nothing to compare
# against - the first release of a package - is not an error.
#
# Needs the network, so it is deliberately NOT part of `make pack-check`,
# which is hermetic and runs on every PR. This runs at release time.
#
# Usage: tools/pack_diff.sh [port ...]   (default: typescript javascript)

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORTS=${*:-"typescript javascript"}
status=0

for PORT in $PORTS; do
  NAME=$(node -p "require('$ROOT/$PORT/package.json').name")
  printf '======== %s (%s) ========\n' "$PORT" "$NAME"

  WORK=$(mktemp -d)

  # What the registry has now. `npm pack <name>` fetches the published
  # tarball rather than building one.
  if ! (cd "$WORK" && npm pack "$NAME" --silent >/dev/null 2>&1); then
    echo "  $NAME is not on the registry - nothing to compare against"
    rm -rf "$WORK"
    echo ""
    continue
  fi
  PUBLISHED=$(ls "$WORK"/*.tgz | head -1)
  tar tzf "$PUBLISHED" | sort > "$WORK/published.txt"
  echo "  published: $(basename "$PUBLISHED") ($(wc -l < "$WORK/published.txt" | tr -d ' ') files)"

  # What this tree would publish. prepack builds, as it does for a real
  # publish, so this is the artifact and not an approximation of it.
  mkdir -p "$WORK/next"
  (cd "$ROOT/$PORT" && npm pack --pack-destination "$WORK/next" --silent >/dev/null)
  NEXT=$(ls "$WORK"/next/*.tgz | head -1)
  tar tzf "$NEXT" | sort > "$WORK/next.txt"
  echo "  next:      $(basename "$NEXT") ($(wc -l < "$WORK/next.txt" | tr -d ' ') files)"

  ADDED=$(comm -13 "$WORK/published.txt" "$WORK/next.txt")
  REMOVED=$(comm -23 "$WORK/published.txt" "$WORK/next.txt")

  if [ -n "$ADDED" ]; then
    echo "  added:"
    echo "$ADDED" | sed 's/^/    + /'
  fi

  if [ -n "$REMOVED" ]; then
    echo "  REMOVED - these are in the published package and would disappear:"
    echo "$REMOVED" | sed 's/^/    - /'
    echo "  If the removal is deliberate, say so in the release and re-run with"
    echo "  OMNI_ALLOW_REMOVALS=1."
    if [ "${OMNI_ALLOW_REMOVALS:-}" = "1" ]; then
      echo "  OMNI_ALLOW_REMOVALS=1 - allowed"
    else
      status=1
    fi
  fi

  [ -n "$ADDED$REMOVED" ] || echo "  identical to the published file list"
  rm -rf "$WORK"
  echo ""
done

if [ 0 -ne "$status" ]; then
  echo "omni: a release would remove published files"
  exit 1
fi
echo "omni: no published file would be lost"
