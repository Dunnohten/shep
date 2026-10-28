#!/bin/bash
# Records the animation demo: opens the "Shep test" window, launches Shep with --dock-demo --capturable --demo-script, and
# records the TextEdit window's bounds plus ONLY the tab's rectangle above it, then measures Shep's CPU while it idles.
# Before anything is armed, TextEdit is brought to the front with the "Shep test" window focused (checked with
# NSWorkspace.frontmostApplication and the Accessibility focused window); the script stops with a message if it is not.
#   scripts/record-demo.sh
# The sequence (ShepCore DemoScript): dock (the head rises out of the tab), idle 3 s, blink, listening 2.5 s, thinking 2.5 s,
# a programmatic drag out and snap-back, idle. Shep waits (armed) until this script has the recorder running, then gets SIGUSR1.
# Output: ~/shep-evidence/demo-<time>.mov (outside the repo), Shep's log beside it (same stem, .log).
# Recording: `screencapture -v -V <s> -R x,y,w,h` (macOS 11+) of the union of the window and the tab. Nothing above the
# window except the tab may show, so: with ffmpeg on the PATH the union is recorded to a temp file and black boxes cover
# the rest (drawbox, scripts/capture-lib.sh); without ffmpeg the window alone is recorded and the tab gets its own small
# recording beside it (<stem>-tab.mov). If screencapture -v -R produces no file, falls back to ffmpeg avfoundation with a crop
# (SHEP_PIXEL_SCALE, default 2, is device pixels per point).
# CPU: `top -l 6 -s 2 -pid <pid> -stats pid,cpu` once the demo is over and the dog idles. The first top sample is not a
# real interval, so it is dropped and the other 5 are averaged. Web Content processes that appeared after Shep started
# (where the page's animation really runs) are measured the same way and listed separately, best effort.
# Needs: a built app (scripts/build.sh); Screen Recording and Accessibility for the terminal running this; Xcode's swiftc.
# Env: SHEP_APP, SHEP_EVIDENCE_DIR, SHEP_SHOT_TIMEOUT (default 25), SHEP_PIXEL_SCALE.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/capture-lib.sh
export TZ=America/Chicago
app="${SHEP_APP:-build/Build/Products/Debug/Shep.app}"
bin="$app/Contents/MacOS/Shep"
[ -x "$bin" ] || { echo "app not built: $bin (run scripts/build.sh)" >&2; exit 2; }
out_dir="${SHEP_EVIDENCE_DIR:-$HOME/shep-evidence}"
timeout_s="${SHEP_SHOT_TIMEOUT:-25}"
scale="${SHEP_PIXEL_SCALE:-2}"
script_seconds=14     # DemoScript.duration
record_seconds=17     # a second of warm-up before the signal, a second of slack at the end
mkdir -p "$out_dir"
stamp="$(date +%Y%m%d-%H%M%S)"
mov="$out_dir/demo-$stamp.mov"
work="$(mktemp -d -t shep-record-demo)"
log="$work/shep.log"
shep_pid=""
rec_pid=""
tab_pid=""
cleanup() {
  [ -s "$log" ] && cp "$log" "${mov%.mov}.log" || true
  [ -n "$rec_pid" ] && kill "$rec_pid" 2>/dev/null || true
  [ -n "$tab_pid" ] && kill "$tab_pid" 2>/dev/null || true
  [ -n "$shep_pid" ] && kill "$shep_pid" 2>/dev/null || true
  [ -n "$shep_pid" ] && wait "$shep_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

scripts/shep-test-window.sh
winfo_bin="$work/shep-winfo"
xcrun swiftc -O scripts/shep-winfo.swift -o "$winfo_bin" || { echo "could not compile scripts/shep-winfo.swift" >&2; exit 2; }
winfo() { "$winfo_bin" TextEdit "Shep test"; }
info=""
for _ in $(seq 1 "$timeout_s"); do
  if info="$(winfo)"; then break; fi
  info=""; sleep 1
done
[ -n "$info" ] || { echo "no TextEdit window titled 'Shep test' within ${timeout_s}s" >&2; exit 3; }

# TextEdit in front, Shep test focused: BEFORE Shep is started and armed.
test_file="${SHEP_TEST_DIR:-$HOME/shep-test}/Shep test.rtf"
if ! bring_frontmost "$winfo_bin" TextEdit "Shep test" "$timeout_s" "$test_file"; then
  echo "TextEdit is not frontmost with the 'Shep test' window focused (${FRONT_REPORT:-no report}). Nothing was armed or recorded. Click the Shep test window and run this again." >&2
  exit 7
fi

web_before="$(pgrep -f com.apple.WebKit.WebContent 2>/dev/null | sort || true)"
SHEP_DEMO_AUTOSTART=0 "$bin" --dock-demo --capturable --demo-script >"$log" 2>&1 &
shep_pid=$!

# Armed = the tab is on the Shep test window, the head is back in it and Shep waits for the signal.
armed=0
for _ in $(seq 1 "$timeout_s"); do
  if grep -q 'demo-script armed' "$log" && grep 'com.apple.TextEdit' "$log" | grep -v 'demo fallback' | tail -n 1 | grep -q -- '-> tab '; then armed=1; break; fi
  kill -0 "$shep_pid" 2>/dev/null || { echo "Shep exited early:" >&2; cat "$log" >&2; exit 4; }
  sleep 1
done
[ "$armed" -eq 1 ] || { echo "Shep never docked and armed within ${timeout_s}s (keep the Shep test window frontmost). Last log lines:" >&2; tail -n 5 "$log" >&2; exit 5; }
sleep 1

# Still in front? (Shep's launch must not have taken focus.)
if ! "$winfo_bin" --frontmost TextEdit "Shep test" >/dev/null 2>&1; then
  echo "TextEdit lost the front before recording ($("$winfo_bin" --frontmost TextEdit "Shep test" 2>&1 || true)). Nothing was recorded." >&2
  exit 7
fi
info="$(winfo)" || { echo "the Shep test window went away" >&2; exit 3; }
read -r _ x y w h _ <<<"$info"
tab="$(tab_from_log "$log")" || tab=""
read -r style tx ty tw th <<<"${tab:-inside 0 0 0 0}"
plan_capture "$x" "$y" "$w" "$h" "$style" "$tx" "$ty" "$tw" "$th"
echo "recording: window $keep_window, tab ${keep_tab:-none (inside the title bar)}"

# Which way to hide what is above the window: ffmpeg masks the union; without it the window and the tab are recorded apart.
mask_with_ffmpeg=0
tab_mov=""
rec_x=$cap_x; rec_y=$cap_y; rec_w=$cap_w; rec_h=$cap_h
raw_mov="$mov"
if [ -n "$keep_tab" ]; then
  if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    mask_with_ffmpeg=1
    raw_mov="$work/raw.mov"
  else
    echo "ffmpeg not found: recording the window alone, and the tab separately (install ffmpeg to get one masked video)" >&2
    rec_x=$x; rec_y=$y; rec_w=$w; rec_h=$h
    tab_mov="${mov%.mov}-tab.mov"
  fi
fi
echo "recording region: $rec_x,$rec_y,$rec_w,$rec_h"

record_with_screencapture() {
  screencapture -v -V "$record_seconds" -R "$rec_x,$rec_y,$rec_w,$rec_h" "$raw_mov" 2>"$work/screencapture.err" &
  rec_pid=$!
  if [ -n "$tab_mov" ]; then
    screencapture -v -V "$record_seconds" -R "$keep_tab" "$tab_mov" 2>"$work/screencapture-tab.err" &
    tab_pid=$!
  fi
}
record_with_screencapture
sleep 1.5   # recorder warm-up
if ! kill -0 "$rec_pid" 2>/dev/null; then
  echo "screencapture -v -V -R did not start ($(head -n 1 "$work/screencapture.err" 2>/dev/null)); trying ffmpeg" >&2
  command -v ffmpeg >/dev/null || { echo "no ffmpeg either: check 'screencapture -h' for this macOS and Screen Recording access" >&2; exit 6; }
  tab_mov=""; mask_with_ffmpeg=1; raw_mov="$work/raw.mov"
  rec_x=$cap_x; rec_y=$cap_y; rec_w=$cap_w; rec_h=$cap_h
  ffmpeg -loglevel error -y -f avfoundation -framerate 30 -capture_cursor 0 -i "Capture screen 0" -t "$record_seconds" \
    -vf "crop=$((rec_w * scale)):$((rec_h * scale)):$((rec_x * scale)):$((rec_y * scale))" -pix_fmt yuv420p "$raw_mov" 2>"$work/ffmpeg.err" &
  rec_pid=$!
  sleep 1.5
fi
kill -USR1 "$shep_pid"   # start the sequence
for _ in $(seq 1 $(( script_seconds + 10 ))); do
  grep -q 'demo-script done' "$log" && break
  sleep 1
done
grep -q 'demo-script done' "$log" || { echo "the demo sequence did not finish; see ${mov%.mov}.log" >&2; }
sleep 1   # idle again

# CPU of the idling dog: 6 samples 2 s apart, first dropped.
avg_cpu() {   # pid -> average of samples 2..6
  top -l 6 -s 2 -pid "$1" -stats pid,cpu 2>/dev/null | awk -v p="$1" '$1 == p { n++; if (n > 1) { s += $2; c++ } } END { if (c) printf "%.1f", s / c; else print "n/a" }'
}
avg_cpu "$shep_pid" >"$work/cpu-shep" &
cpu_jobs="$!"
web_after="$(pgrep -f com.apple.WebKit.WebContent 2>/dev/null | sort || true)"
web_new="$(comm -13 <(printf '%s\n' "$web_before") <(printf '%s\n' "$web_after") || true)"
i=0
for wp in $web_new; do avg_cpu "$wp" >"$work/cpu-web-$i" & cpu_jobs="$cpu_jobs $!"; i=$(( i + 1 )); done
for job in $cpu_jobs; do wait "$job" 2>/dev/null || true; done   # only the CPU probes: Shep and the recorder are also children

# The recorder runs for the full length; let it finish writing the file.
[ -n "$rec_pid" ] && wait "$rec_pid" 2>/dev/null || true
rec_pid=""
[ -n "$tab_pid" ] && wait "$tab_pid" 2>/dev/null || true
tab_pid=""
[ -s "$raw_mov" ] || { echo "no recording was written (is Screen Recording allowed for this terminal?)" >&2; exit 6; }
if [ "$raw_mov" != "$mov" ]; then
  filter=""
  if [ "$mask_with_ffmpeg" -eq 1 ] && [ -n "$keep_tab" ]; then
    # Pixels per point from the file itself, then black boxes over every part of the union outside the window and the tab.
    px_w="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$raw_mov" 2>/dev/null || true)"
    px_scale=$(( ${px_w:-0} / cap_w ))
    [ "$px_scale" -ge 1 ] || px_scale=$scale
    filter="$(ffmpeg_mask_filter "$px_scale")"
  fi
  if [ -n "$filter" ]; then
    ffmpeg -loglevel error -y -i "$raw_mov" -vf "$filter" -pix_fmt yuv420p "$mov" || { echo "ffmpeg could not mask the recording; the unmasked file was not kept" >&2; exit 6; }
  else
    cp "$raw_mov" "$mov"
  fi
fi
[ -s "$mov" ] || { echo "no recording was written (is Screen Recording allowed for this terminal?)" >&2; exit 6; }
echo "recording: $mov"
[ -n "$tab_mov" ] && [ -s "$tab_mov" ] && echo "tab recording: $tab_mov"
echo "log: ${mov%.mov}.log"
echo "Shep CPU while idle (average of 5 samples): $(cat "$work/cpu-shep")%"
j=0
for wp in $web_new; do
  echo "web content process $wp (new since launch, best effort): $(cat "$work/cpu-web-$j")%"
  j=$(( j + 1 ))
done
