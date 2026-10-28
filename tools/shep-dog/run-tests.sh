#!/bin/bash
# Page tests that need no browser: the motion engine, the doghouse art and pose, the ear geometry (both ears visible in every pose), (TypeScript, run with jiti from the bloub checkout's node_modules)
# and the bridge in happy-dom (against the built Resources/shep-dog/index.html).
#
# BLOUB_DIR is a sibling checkout OUTSIDE this repo and not tracked by it (default: bloub-dog next to this repo, "$repo/../bloub-dog"; read-only reference). A missing BLOUB_DIR exits 2 and asks you to set it.
# jiti is taken from $BLOUB_DIR/node_modules/.bin/jiti when it is executable; otherwise from the newest jiti inside the pnpm store
# ($BLOUB_DIR/node_modules/.pnpm/jiti@*/node_modules/jiti/lib/jiti-cli.mjs, run with node). If neither exists the script says how to
# restore the dev dependencies and exits 2 (not 127). Nothing is installed or removed by this script.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
BLOUB_DIR="${BLOUB_DIR:-$repo/../bloub-dog}"
if [ ! -d "$BLOUB_DIR" ]; then
  echo "shep-dog tests: bloub checkout not found at $BLOUB_DIR; set BLOUB_DIR to the bloub-dog checkout (with its node_modules)." >&2
  exit 2
fi
export BLOUB_DIR

jiti_cmd=()
if [ -x "$BLOUB_DIR/node_modules/.bin/jiti" ]; then
  jiti_cmd=("$BLOUB_DIR/node_modules/.bin/jiti")
else
  newest=""
  for candidate in "$BLOUB_DIR"/node_modules/.pnpm/jiti@*/node_modules/jiti/lib/jiti-cli.mjs; do
    [ -f "$candidate" ] || continue
    if [ -z "$newest" ] || [ "$(printf '%s\n%s\n' "$newest" "$candidate" | sort -V | tail -n 1)" = "$candidate" ]; then newest="$candidate"; fi
  done
  if [ -n "$newest" ] && command -v node >/dev/null 2>&1; then jiti_cmd=(node "$newest"); fi
fi
if [ "${#jiti_cmd[@]}" -eq 0 ]; then
  {
    echo "shep-dog tests: jiti was not found in $BLOUB_DIR/node_modules (the bloub checkout is a sibling directory outside this repo)."
    echo "Restore its dev dependencies (pnpm 10 with node 20; pnpm 11 needs a newer node):"
    echo "  cd $BLOUB_DIR && npm_config_manage_package_manager_versions=false npx --yes pnpm@10 install --frozen-lockfile --ignore-scripts"
    echo "or point BLOUB_DIR at a checkout that has them."
  } >&2
  exit 2
fi
command -v node >/dev/null 2>&1 || { echo "shep-dog tests: node is not on PATH" >&2; exit 2; }

"${jiti_cmd[@]}" "$here/motion-test.ts"
"${jiti_cmd[@]}" "$here/house-test.ts"
"${jiti_cmd[@]}" "$here/ears-test.ts"
node "$here/bridge-test.mjs"
