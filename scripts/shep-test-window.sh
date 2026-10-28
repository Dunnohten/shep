#!/bin/bash
# Opens a fresh, EMPTY TextEdit document titled "Shep test" so the dock demo has a clean window to sit on, then moves
# that one window down to x=200, y=200 (points from the top-left of the primary display) so there is room above it for the tab.
#   scripts/shep-test-window.sh
# The file lives outside the repo (~/shep-test/Shep test.rtf) and is only created when absent; an existing
# file is left as it is. No scripting-bridge automation: `open -a TextEdit <file>`, then the Accessibility API
# (scripts/shep-winfo.swift --move, kAXPositionAttribute on that window only). The terminal needs Accessibility access.
# Env: SHEP_TEST_DIR, SHEP_TEST_X / SHEP_TEST_Y (default 200 / 200).
set -euo pipefail
cd "$(dirname "$0")/.."
dir="${SHEP_TEST_DIR:-$HOME/shep-test}"
file="$dir/Shep test.rtf"
x="${SHEP_TEST_X:-200}"
y="${SHEP_TEST_Y:-200}"
mkdir -p "$dir"
if [ ! -e "$file" ]; then
  # An empty rich-text document: the smallest RTF TextEdit opens as a blank page.
  printf '%s' '{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0\fs24 }' > "$file"
fi
open -a TextEdit "$file"
echo "opened: $file"

work="$(mktemp -d -t shep-test-window)"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -O scripts/shep-winfo.swift -o "$work/shep-winfo" || { echo "could not compile scripts/shep-winfo.swift" >&2; exit 2; }
# TextEdit opens its window a moment after `open` returns.
for _ in $(seq 1 20); do
  if "$work/shep-winfo" TextEdit "Shep test" >/dev/null 2>&1; then break; fi
  sleep 1
done
if info="$("$work/shep-winfo" --move TextEdit "Shep test" "$x" "$y")"; then
  echo "window: $info"
else
  echo "could not move the 'Shep test' window to $x,$y (allow Accessibility for this terminal); drag it down by hand" >&2
  exit 3
fi
