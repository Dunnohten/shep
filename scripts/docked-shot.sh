#!/bin/bash
# Docked screenshot: launches the built Shep with --dock-demo --capturable, waits until the tracker has put the tab on
# the frontmost "Shep test" TextEdit window, captures that window's bounds plus ONLY the tab's rectangle above it, then
# quits Shep and prints the PNG path. The PNG goes outside the repo.
#   scripts/shep-test-window.sh && scripts/docked-shot.sh
# Needs: a built app (scripts/build.sh), Screen Recording for the terminal running this, Xcode's swiftc for the
# window lookup. Keep the "Shep test" window frontmost (click it) while this runs.
# Capture: the union of the window and the tab (tab + 12 pt of headroom for the head) is grabbed, then everything outside
# those two rectangles is made transparent (scripts/shep-mask.swift), so no background-window content above the window
# survives, not even beside the tab. Shep's log is kept next to the PNG (same stem, .log). Needs the Shep test window to
# be frontmost and focused (the script brings it there and fails with a message if it cannot).
# Env: SHEP_APP (default build/Build/Products/Debug/Shep.app), SHEP_EVIDENCE_DIR (default ~/shep-evidence),
#      SHEP_SHOT_TIMEOUT (seconds to wait for the window and for the dock, default 25).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/capture-lib.sh
app="${SHEP_APP:-build/Build/Products/Debug/Shep.app}"
bin="$app/Contents/MacOS/Shep"
[ -x "$bin" ] || { echo "app not built: $bin (run scripts/build.sh)" >&2; exit 2; }
out_dir="${SHEP_EVIDENCE_DIR:-$HOME/shep-evidence}"
timeout_s="${SHEP_SHOT_TIMEOUT:-25}"
mkdir -p "$out_dir"
work="$(mktemp -d -t shep-docked-shot)"
log="$work/shep.log"
shep_pid=""
file=""
cleanup() {
  # Keep the Shep log (it is how failures get read): beside the PNG, or in the evidence dir when no PNG was taken.
  if [ -s "$log" ]; then
    if [ -n "$file" ]; then cp "$log" "${file%.png}.log"; else cp "$log" "$out_dir/docked-shot-$(date +%Y%m%d-%H%M%S).log"; fi
  fi
  [ -n "$shep_pid" ] && kill "$shep_pid" 2>/dev/null || true
  [ -n "$shep_pid" ] && wait "$shep_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# Compile the window lookup once (an interpreted run costs seconds per call and hides compile errors).
winfo_bin="$work/shep-winfo"
xcrun swiftc -O scripts/shep-winfo.swift -o "$winfo_bin" || { echo "could not compile scripts/shep-winfo.swift" >&2; exit 2; }
winfo() { "$winfo_bin" TextEdit "Shep test"; }
mask_bin="$work/shep-mask"
xcrun swiftc -O scripts/shep-mask.swift -o "$mask_bin" || { echo "could not compile scripts/shep-mask.swift" >&2; exit 2; }

# TextEdit opens its window a moment after `open` returns.
info=""
for _ in $(seq 1 "$timeout_s"); do
  if info="$(winfo)"; then break; fi
  info=""; sleep 1
done
[ -n "$info" ] || { echo "no TextEdit window titled 'Shep test' within ${timeout_s}s: run scripts/shep-test-window.sh first" >&2; exit 3; }

# TextEdit must be in front with the Shep test window focused before Shep starts.
if ! bring_frontmost "$winfo_bin" TextEdit "Shep test" "$timeout_s" "${SHEP_TEST_DIR:-$HOME/shep-test}/Shep test.rtf"; then
  echo "TextEdit is not frontmost with the 'Shep test' window focused (${FRONT_REPORT:-no report}). Run scripts/shep-test-window.sh, click the window, and try again." >&2
  exit 7
fi

"$bin" --dock-demo --capturable >"$log" 2>&1 &
shep_pid=$!

# Docked means the tracker's latest line for TextEdit ends in a tab placement (not "hidden", not the demo fallback) AND its
# window frame is the Shep test window's frame, so a different focused window cannot be mistaken for it.
near() { local d=$(( $1 - $2 )); [ "${d#-}" -le 3 ]; }
docked=0
for _ in $(seq 1 "$timeout_s"); do
  line="$(grep 'com.apple.TextEdit' "$log" | grep -v 'demo fallback' | tail -n 1 || true)"
  if [[ "$line" == *"-> tab "* ]]; then
    ax="$(printf '%s' "$line" | sed -nE 's/.*ax=\(([-0-9]+),([-0-9]+) ([0-9]+)x([0-9]+)\).*/\1 \2 \3 \4/p')"
    info="$(winfo)" || info=""
    if [ -n "$ax" ] && [ -n "$info" ]; then
      read -r ax_x ax_y ax_w ax_h <<<"$ax"
      read -r _ wx wy ww wh _ <<<"$info"
      if near "$ax_x" "$wx" && near "$ax_y" "$wy" && near "$ax_w" "$ww" && near "$ax_h" "$wh"; then docked=1; break; fi
    fi
  fi
  kill -0 "$shep_pid" 2>/dev/null || { echo "Shep exited early:" >&2; cat "$log" >&2; exit 4; }
  sleep 1
done
[ "$docked" -eq 1 ] || { echo "Shep never docked on the 'Shep test' window within ${timeout_s}s (is it the frontmost window?). Last log lines:" >&2; tail -n 5 "$log" >&2; exit 5; }
sleep 1.5   # let the panel and the page settle

info="$(winfo)" || { echo "the Shep test window went away" >&2; exit 3; }
read -r _ x y w h _ <<<"$info"
tab="$(tab_from_log "$log")" || tab=""
read -r style tx ty tw th <<<"${tab:-inside 0 0 0 0}"
plan_capture "$x" "$y" "$w" "$h" "$style" "$tx" "$ty" "$tw" "$th"
# A window near the top of the screen has less room above it: plan_capture never reaches past the screen's top edge.
file="$out_dir/docked-tab-$(date +%Y%m%d-%H%M%S).png"
if [ -z "$keep_tab" ]; then
  screencapture -x -R "$cap_x,$cap_y,$cap_w,$cap_h" "$file"
else
  raw="$work/raw.png"
  screencapture -x -R "$cap_x,$cap_y,$cap_w,$cap_h" "$raw"
  [ -s "$raw" ] || { echo "screencapture produced no image (is Screen Recording allowed for this terminal?)" >&2; exit 6; }
  "$mask_bin" "$raw" "$file" "$cap_x,$cap_y,$cap_w,$cap_h" "$keep_window" "$keep_tab" || { echo "masking the capture failed" >&2; exit 6; }
fi
[ -s "$file" ] || { echo "screencapture produced no image (is Screen Recording allowed for this terminal?)" >&2; exit 6; }
echo "$file"
echo "capture: window $keep_window, tab ${keep_tab:-none (inside the title bar)}; everything else transparent"
echo "log: ${file%.png}.log"
