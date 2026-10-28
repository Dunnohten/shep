#!/bin/bash
# Records the doghouse cycle: Shep asleep (3 s), called, travels along its arc to the "Shep test" window's tab, works there
# (listening 2 s, thinking 2 s), is sent home, walks back, sleeps (3 s). Launches Shep with --demo-script=cycle --capturable.
#   scripts/record-cycle.sh
# What is recorded, and only that:
#   * the doghouse rectangle (the house panel, which stands below the menu bar: no menu-bar item, Shep's status item included, is in it);
#   * the Shep test window, the tab's rectangle above it (plus 12 pt of headroom), and the travel arc's corridor.
# The test window is first moved (Accessibility, that window only) to sit directly below the house, SHEP_CYCLE_GAP points under it
# (default 170), so the arc is short enough to record in one small region. Shep then logs the planned arc (SIGUSR2) so the
# corridor is known before the recorder starts.
# With ffmpeg on the PATH: the bounding box of house + window + tab + corridor is recorded to a temp file and every pixel outside
# those rectangles is replaced by a flat neutral colour (filter_complex: a background with only the kept rectangles overlaid);
# the unmasked temp file is deleted. Without ffmpeg: three separate recordings (house, window, tab), nothing in between.
# Output (outside the repo): ~/shep-evidence/cycle-<time>.mov (and -house/-window/-tab.mov without ffmpeg) and the
# Shep log beside it (.log). Prints the CPU of Shep and of the Web Content processes that appeared after launch, measured with
# `top -l 6 -s 2` (first sample dropped, 5 averaged) while Shep is asleep again, after the recording.
# Needs: a built app (scripts/build.sh); Screen Recording and Accessibility for the terminal running this; Xcode's swiftc.
# With --backdrop: Shep is launched with --demo-backdrop and paints its own plain backdrop window (below the Shep test window,
# above every other app, under the menu bar) over the house, the corridor, the tab and the test window, and logs its rectangle.
# Only that one rectangle is recorded (screencapture -v -R, never the full screen), nothing needs masking, and ffmpeg then adds
# the synthesized woof (`Shep --export-bark`) as the audio track, delayed to the "finish" step of the cycle: the delay is
# (time from starting the recorder to starting the cycle) + (the log's `demo-state finish t=`) + 0.2 s woof delay. The
# recorder's own start-up latency is not known: SHEP_AUDIO_NUDGE (seconds, may be negative) corrects the sync after one look.
# Output: $SHEP_EVIDENCE_DIR/cycle-<time>.mov (video + audio) and the log beside it; the clip's path is printed last.
# Env: SHEP_APP, SHEP_EVIDENCE_DIR, SHEP_SHOT_TIMEOUT (default 25), SHEP_PIXEL_SCALE (default 2), SHEP_CYCLE_GAP, SHEP_CYCLE_NO_FFMPEG=1,
#      SHEP_AUDIO_NUDGE (default 0), SHEP_WOOF_DELAY (default 0.2).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/capture-lib.sh
export TZ=America/Chicago
backdrop=0
for arg in "$@"; do
  case "$arg" in
    --backdrop) backdrop=1 ;;
    *) echo "usage: scripts/record-cycle.sh [--backdrop]" >&2; exit 2 ;;
  esac
done
app="${SHEP_APP:-build/Build/Products/Debug/Shep.app}"
bin="$app/Contents/MacOS/Shep"
[ -x "$bin" ] || { echo "app not built: $bin (run scripts/build.sh)" >&2; exit 2; }
out_dir="${SHEP_EVIDENCE_DIR:-$HOME/shep-evidence}"
timeout_s="${SHEP_SHOT_TIMEOUT:-25}"
scale="${SHEP_PIXEL_SCALE:-2}"
gap="${SHEP_CYCLE_GAP:-170}"
if [ "$backdrop" -eq 1 ]; then
  command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 || { echo "--backdrop needs ffmpeg and ffprobe on the PATH (they add the woof to the clip)" >&2; exit 2; }
fi
mkdir -p "$out_dir"
stamp="$(date +%Y%m%d-%H%M%S)"
mov="$out_dir/cycle-$stamp.mov"
work="$(mktemp -d -t shep-record-cycle)"
log="$work/shep.log"
shep_pid=""
rec_pids=()
cleanup() {
  [ -s "$log" ] && cp "$log" "${mov%.mov}.log" || true
  for p in "${rec_pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  [ -n "$shep_pid" ] && kill "$shep_pid" 2>/dev/null || true
  [ -n "$shep_pid" ] && wait "$shep_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

if [ "$backdrop" -eq 1 ]; then
  "$bin" --export-bark="$work/bark.wav" >"$work/bark.log" 2>&1 || { echo "could not export the bark: $(cat "$work/bark.log")" >&2; exit 2; }
  [ -s "$work/bark.wav" ] || { echo "the bark WAV is empty" >&2; exit 2; }
fi

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
test_file="${SHEP_TEST_DIR:-$HOME/shep-test}/Shep test.rtf"

# Shep first: it asleep and showing the house, so the house's place is known.
web_before="$(pgrep -f com.apple.WebKit.WebContent 2>/dev/null | sort || true)"
shep_args=(--demo-script=cycle --capturable)
[ "$backdrop" -eq 1 ] && shep_args+=(--demo-backdrop)
SHEP_DEMO_AUTOSTART=0 "$bin" "${shep_args[@]}" >"$log" 2>&1 &
shep_pid=$!
home=""
for _ in $(seq 1 "$timeout_s"); do
  if grep -q 'cycle armed' "$log"; then home="$(log_field "$log" "home" "rect")"; [ -n "$home" ] && break; fi
  kill -0 "$shep_pid" 2>/dev/null || { echo "Shep exited early:" >&2; cat "$log" >&2; exit 4; }
  sleep 1
done
[ -n "$home" ] || { echo "Shep never showed its doghouse within ${timeout_s}s. Last log lines:" >&2; tail -n 5 "$log" >&2; exit 5; }
# The house is placed once at launch and again half a second later, when the status item has a window: take the last place.
sleep 1.5
home="$(log_field "$log" "home" "rect")"
IFS=, read -r hx hy hw hh <<<"$home"
home_kind="$(log_field "$log" "home" "kind")"
cycle_seconds="$(log_field "$log" "cycle armed" "duration")"
cycle_seconds="${cycle_seconds%%.*}"; cycle_seconds="${cycle_seconds:-16}"
record_seconds=$(( cycle_seconds + 5 ))
echo "doghouse ($home_kind): $hx,$hy,$hw,$hh"

# Move the test window directly below the house: centred under it, $gap points under its bottom edge.
read -r _ wx wy ww wh _ <<<"$info"
want_x=$(( hx + hw / 2 - ww / 2 )); [ "$want_x" -ge 20 ] || want_x=20
want_y=$(( hy + hh + gap ))
"$winfo_bin" --move TextEdit "Shep test" "$want_x" "$want_y" >/dev/null || { echo "could not move the 'Shep test' window (allow Accessibility for this terminal)" >&2; exit 3; }
sleep 1

# TextEdit in front with the Shep test window focused, BEFORE anything is planned or armed.
if ! bring_frontmost "$winfo_bin" TextEdit "Shep test" "$timeout_s" "$test_file"; then
  echo "TextEdit is not frontmost with the 'Shep test' window focused (${FRONT_REPORT:-no report}). Nothing was recorded. Click the Shep test window and run this again." >&2
  exit 7
fi
info="$(winfo)" || { echo "the Shep test window went away" >&2; exit 3; }
read -r _ wx wy ww wh _ <<<"$info"
echo "test window: $wx,$wy,$ww,$wh"

# Ask Shep for the planned arc (it does not wake).
kill -USR2 "$shep_pid"
plan=""
for _ in $(seq 1 "$timeout_s"); do
  if grep -q 'cycle plan' "$log"; then plan="$(grep -F '[shep] cycle plan' "$log" | tail -n 1)"; break; fi
  sleep 1
done
case "$plan" in
  *"plan window="*) ;;
  *) echo "Shep could not plan the travel: ${plan:-no answer}. Keep the Shep test window in front and run this again." >&2; exit 5 ;;
esac
tab="$(printf '%s\n' "$plan" | sed -nE 's/.* tab=([-0-9]+,[-0-9]+,[0-9]+,[0-9]+).*/\1/p')"
corridor="$(printf '%s\n' "$plan" | sed -nE 's/.* corridor=([^ ]*).*/\1/p')"
[ -n "$tab" ] || { echo "no tab rectangle in Shep's plan: $plan" >&2; exit 5; }
IFS=, read -r tx ty tw th <<<"$tab"

if [ "$backdrop" -eq 1 ]; then
  # Shep has painted the backdrop and logged its rectangle: that rectangle is the whole recording.
  bd=""
  for _ in $(seq 1 "$timeout_s"); do
    if grep -qF '[shep] backdrop failed' "$log"; then echo "Shep could not place its backdrop: $(grep -F '[shep] backdrop failed' "$log" | tail -n 1)" >&2; exit 5; fi
    bd="$(log_field "$log" "backdrop" "rect")"; [ -n "$bd" ] && break
    sleep 1
  done
  [ -n "$bd" ] || { echo "Shep never logged its backdrop rectangle within ${timeout_s}s" >&2; exit 5; }
  IFS=, read -r cap_x cap_y cap_w cap_h <<<"$bd"
  pieces=()
  echo "backdrop: recording $cap_x,$cap_y,$cap_w,$cap_h (only this rectangle)"
else
# Kept rectangles (global points, top-left origin). Nothing above the house panel's top edge is ever kept (that is the menu bar).
rects="$work/rects"
: >"$rects"
min_y="$hy"
min_x=0; [ "$hx" -lt "$min_x" ] && min_x="$hx"; [ "$wx" -lt "$min_x" ] && min_x="$wx"   # a display left of the primary has negative x
clip_rect "$hx" "$hy" "$hw" "$hh" "$min_x" "$min_y" >>"$rects"
clip_rect "$wx" "$wy" "$ww" "$wh" "$min_x" "$min_y" >>"$rects"
ky=$(( ty - tab_peek )); kh=$(( th + tab_peek ))
clip_rect "$tx" "$ky" "$tw" "$kh" "$min_x" "$min_y" >>"$rects"
IFS=';' read -r -a pieces <<<"$corridor"
for piece in "${pieces[@]:-}"; do
  [ -n "$piece" ] || continue
  IFS=, read -r cx0 cy0 cw0 ch0 <<<"$piece"
  clip_rect "$cx0" "$cy0" "$cw0" "$ch0" "$min_x" "$min_y" >>"$rects"
done
read -r cap_x cap_y cap_w cap_h <<<"$(bounding_box <"$rects")"
[ -n "${cap_w:-}" ] || { echo "nothing to record" >&2; exit 5; }
echo "kept: house, window, tab and $(( ${#pieces[@]} )) corridor pieces; recording $cap_x,$cap_y,$cap_w,$cap_h"
fi

use_ffmpeg=0
if [ "${SHEP_CYCLE_NO_FFMPEG:-0}" != "1" ] && command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then use_ffmpeg=1; fi
[ "$backdrop" -eq 1 ] && use_ffmpeg=1   # the clip needs the woof muxed in
raw_mov="$work/raw.mov"
movs=()
if [ "$use_ffmpeg" -eq 1 ]; then
  screencapture -v -V "$record_seconds" -R "$cap_x,$cap_y,$cap_w,$cap_h" "$raw_mov" 2>"$work/screencapture.err" &
  rec_pids+=($!)
else
  echo "ffmpeg not found: recording the house, the window and the tab separately (nothing in between)" >&2
  base="${mov%.mov}"
  screencapture -v -V "$record_seconds" -R "$hx,$hy,$hw,$hh" "$base-house.mov" 2>"$work/screencapture-house.err" &
  rec_pids+=($!)
  screencapture -v -V "$record_seconds" -R "$wx,$wy,$ww,$wh" "$base-window.mov" 2>"$work/screencapture-window.err" &
  rec_pids+=($!)
  screencapture -v -V "$record_seconds" -R "$tx,$ky,$tw,$kh" "$base-tab.mov" 2>"$work/screencapture-tab.err" &
  rec_pids+=($!)
  movs=("$base-house.mov" "$base-window.mov" "$base-tab.mov")
fi
sleep 1.5   # recorder warm-up
if ! kill -0 "${rec_pids[0]}" 2>/dev/null; then
  echo "screencapture -v -V -R did not start ($(head -n 1 "$work/screencapture.err" 2>/dev/null)). Check 'screencapture -h' for this macOS and Screen Recording access." >&2
  exit 6
fi
rec_started="$(now_seconds)"
kill -USR1 "$shep_pid"   # start the cycle
cycle_started="$(now_seconds)"
for _ in $(seq 1 $(( cycle_seconds + 15 ))); do
  grep -q 'cycle done' "$log" && break
  sleep 1
done
grep -q 'cycle done' "$log" || echo "the cycle did not finish; see ${mov%.mov}.log" >&2
for p in "${rec_pids[@]}"; do wait "$p" 2>/dev/null || true; done   # the recorders run for their full length
rec_pids=()

# Asleep again? Then measure.
last_state="$(grep -F '[shep] lifecycle' "$log" | tail -n 1 | sed -nE 's/.*-> ([a-z]+) on.*/\1/p')"
avg_cpu() {   # pid -> average of samples 2..6
  top -l 6 -s 2 -pid "$1" -stats pid,cpu 2>/dev/null | awk -v p="$1" '$1 == p { n++; if (n > 1) { s += $2; c++ } } END { if (c) printf "%.1f", s / c; else print "n/a" }'
}
avg_cpu "$shep_pid" >"$work/cpu-shep" &
cpu_jobs="$!"
web_after="$(pgrep -f com.apple.WebKit.WebContent 2>/dev/null | sort || true)"
web_new="$(comm -13 <(printf '%s\n' "$web_before") <(printf '%s\n' "$web_after") || true)"
i=0
for wp in $web_new; do avg_cpu "$wp" >"$work/cpu-web-$i" & cpu_jobs="$cpu_jobs $!"; i=$(( i + 1 )); done
for job in $cpu_jobs; do wait "$job" 2>/dev/null || true; done

if [ "$use_ffmpeg" -eq 1 ]; then
  [ -s "$raw_mov" ] || { echo "no recording was written (is Screen Recording allowed for this terminal?)" >&2; exit 6; }
  px_w="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$raw_mov" 2>/dev/null || true)"
  px_scale=$(( ${px_w:-0} / cap_w ))
  [ "$px_scale" -ge 1 ] || px_scale=$scale
  if [ "$backdrop" -eq 1 ]; then
    # The recording holds only Shep-owned pixels and the test window: add the woof at the finish step.
    finish_t="$(log_field "$log" "demo-state finish" "t")"
    [ -n "$finish_t" ] || { echo "the log has no 'demo-state finish' line, so the woof cannot be placed (see ${mov%.mov}.log)" >&2; exit 6; }
    delay_ms="$(awk -v a="$rec_started" -v b="$cycle_started" -v f="$finish_t" -v w="${SHEP_WOOF_DELAY:-0.2}" -v n="${SHEP_AUDIO_NUDGE:-0}" \
      'BEGIN { d = (b - a) + f + w + n; if (d < 0) d = 0; printf "%d", d * 1000 + 0.5 }')"
    echo "woof at ${delay_ms} ms into the clip (recorder-to-cycle $(awk -v a="$rec_started" -v b="$cycle_started" 'BEGIN { printf "%.2f", b - a }') s, finish at ${finish_t} s)"
    mux_bark "$raw_mov" "$work/bark.wav" "$delay_ms" "$mov" || { echo "ffmpeg could not add the woof to the clip" >&2; exit 6; }
  else
    graph="$(ffmpeg_keep_filter "$px_scale" "$cap_x" "$cap_y" "$cap_w" "$cap_h" <"$rects")"
    ffmpeg -loglevel error -y -i "$raw_mov" -filter_complex "$graph" -map "[out]" -t "$record_seconds" "$mov" \
      || { echo "ffmpeg could not mask the recording; the unmasked file was not kept" >&2; exit 6; }
  fi
  movs=("$mov")
fi
for f in "${movs[@]}"; do [ -s "$f" ] || { echo "no recording was written: $f (is Screen Recording allowed for this terminal?)" >&2; exit 6; }; done
for f in "${movs[@]}"; do echo "recording: $f"; done
if [ "$backdrop" -eq 1 ]; then echo "clip: $mov"; fi
echo "log: ${mov%.mov}.log"
echo "final state: ${last_state:-unknown} (expected asleep)"
echo "Shep CPU while asleep (average of 5 samples): $(cat "$work/cpu-shep")%"
j=0
for wp in $web_new; do
  echo "web content process $wp (new since launch, best effort): $(cat "$work/cpu-web-$j")%"
  j=$(( j + 1 ))
done
