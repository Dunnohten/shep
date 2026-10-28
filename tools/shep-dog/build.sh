#!/bin/bash
# Build Resources/shep-dog/index.html (the dog) and Resources/shep-dog/house.html (the doghouse) from the sources in ./src.
# Needs node_modules (vite + vite-plugin-singlefile): reuse the bloub checkout's, read-only.
# BLOUB_DIR is that checkout (default: bloub-dog next to this repo, "$repo/../bloub-dog"). Missing: exits 2.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
BLOUB_DIR="${BLOUB_DIR:-$repo/../bloub-dog}"
if [ ! -d "$BLOUB_DIR" ]; then
  echo "shep-dog build: bloub checkout not found at $BLOUB_DIR; set BLOUB_DIR to the bloub-dog checkout (with its node_modules)." >&2
  exit 2
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$here/src" "$here/shep-dog.html" "$here/shep-house.html" "$here/vite.config.ts" "$work/"
ln -s "$BLOUB_DIR/node_modules" "$work/node_modules"
mkdir -p "$repo/Resources/shep-dog"
(cd "$work" && SHEP_ENTRY=shep-dog node_modules/.bin/vite build -c vite.config.ts)
cp "$work/dist/shep-dog.html" "$repo/Resources/shep-dog/index.html"
(cd "$work" && SHEP_ENTRY=shep-house node_modules/.bin/vite build -c vite.config.ts)
cp "$work/dist/shep-house.html" "$repo/Resources/shep-dog/house.html"
echo "wrote Resources/shep-dog/index.html ($(wc -c < "$repo/Resources/shep-dog/index.html") bytes) and house.html ($(wc -c < "$repo/Resources/shep-dog/house.html") bytes)"
