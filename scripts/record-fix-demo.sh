#!/bin/bash
# Records a REAL "Fix this screen" in a third-party app, with the approval card answered by a person:
#   scripts/record-fix-demo.sh <bundle-id> "<request>" [--seconds N] [--no-record]
# Example (Transmission, the turtle checkbox):
#   scripts/record-fix-demo.sh org.m0k.transmission "turn on the speed limit (turtle)" --seconds 70
# Use an explicit request: a plain "Fix this screen" on a window where nothing is wrong makes the model answer "nothing to fix"
# (a known gap, see README.md).
# The recording is made INSIDE Shep and is bound to windows, not to a screen area (ScreenCaptureKit, macOS 15 or later):
# the movie holds the target app's front window and Shep's own overlay windows, nothing else. Another app that moves over
# the area, or a target that moves, closes or changes owner, never gets into the clip (the capture policy decides first and
# is polled while recording; on a stop the partial file is deleted). This script does not record anything itself.
# What it does, in order:
#   1. Refuses bundle ids that are not plain ids ([A-Za-z0-9._-]) and ids on Shep's never-capture list (capture_denied in
#      scripts/capture-policy-lib.sh, the shared mirror of ControlPolicy.mayCapture; Shep checks again itself).
#   2. Brings the target app to the front (`open -b`, no scripting bridge) and prints its front window's frame (shep-winfo).
#   3. Starts `caffeinate -dimsu` for the duration of the job only (its own pid, killed on exit; no other caffeinate is touched).
#   4. Launches the built Shep: `Shep --live-request "<request>" --live-target <bundle-id> --live-record <mov>
#      --live-record-seconds N --capturable`, stdout to a log. --live-target binds the request to the app: Shep activates it,
#      waits up to 5 s for it to be in front, looks once more at the instant of submission, and otherwise refuses (`live: reason:
#      target: ...`, `outcome: refused`) having read, captured and sent nothing. Without it Shep would read whatever app is in
#      front when it submits, for example a browser the person switched to. --live-request calls Shep to the front window and submits the request the way the ask field does. It approves
#      NOTHING. --capturable keeps Shep's own panels visible to capture (they are hidden from it by default).
#   5. Waits for `[shep] live: recording written: <path>` (Shep stops 3 s after `live: finished`, or after N seconds, default 70),
#      or for the timeout (arrival timeout + N + 15 s). A `record refused` or `recording discarded` line means no clip (exit 6).
#      The output folder must be private to you (fix_private_dir): created 0700 if missing, never chmod-ed
#      if it exists, refused (exit 2, `the output folder is not private to you (<check>)`) when it or an ancestor is unsafe.
#   6. Kills Shep. The output is $SHEP_EVIDENCE_DIR/fix-demo-<yyyymmdd-HHMMSS>-<pid>-<4 hex>.mov (default dir
#      ~/shep-evidence, never the repo) with the log of the same stem beside it. The name is reserved before launch
#      (the log is created exclusively under noclobber); if either path already exists the script exits 6 and touches nothing.
#      This script NEVER removes a file: no clip, no partial file, no log. On any failure it says "no clip" and leaves every path
#      alone. The clip's path is the final path: Shep records into a private working directory `.shep-rec-<pid>-<16 hex>` next to
#      it (`<workdir>/clip.mov`) and publishes it to the final path with link() when the movie is finished, then removes only its own
#      clip name and its own directory. After a crash such a `.shep-rec-*` directory may be left behind: it is not removed
#      automatically; the person may remove it. The clip's path is printed last.
# The approval card is answered by a person (or a separate keyboard helper) while it records. This script
# never presses Approve, never sends a key, and has no auto-approve path.
# --no-record: launch without --live-record and log only (a dry run); nothing is recorded. Still bound with --live-target.
# The verdict is read from Shep's STATUS FILE (--live-status <file> in the script's private work directory, created exclusively by
# Shep; a per-run nonce from /dev/urandom in SHEP_LIVE_NONCE, never printed), not from the human log: the human log prints the request
# text, which can forge any marker. Only status lines that start with `<nonce> ` exactly count. Same classifier in both modes
# (fix_verdict in scripts/record-fix-lib.sh). Exit codes:
#   0 the run reached the approval card (and, when recording, the clip was written)
#   2 usage or preflight (bad arguments or bundle id, a never-capture app, app not built, evidence dir inside the repo, no app name)
#   3 the target could not be brought up or left the front during the run (open failed, not frontmost, no window; or Shep wrote the
#     status event `target-left`: the person moved to another app, so Shep stopped, discarded any clip and read nothing more).
#     With a recording, Shep awaits the discard and writes its outcome (`recording-discarded`, `discard-failed`, `discard-unknown` or
#     `recording-already-published`) BEFORE `target-left`. An outcome does not end this script's wait: it keeps waiting for
#     `target-left` or `finished` (at most SHEP_LEFT_DISCARD_WAIT seconds after the outcome) so the order of the events does not matter.
#     After `target-left` it also waits for the outcome (at most SHEP_LEFT_DISCARD_WAIT seconds, default 10; no wait with --no-record or
#     when Shep has exited) and prints one `discard-outcome: discarded|failed|unknown|already-published|shep-exited` line plus a
#     sentence. The exit stays 3 in every case; the outcome word, not the code, says whether a clip may remain (failed, unknown,
#     already-published and shep-exited all say so). `unknown` is Shep's own `discard-unknown` (a start or a stop did not finish within
#     Shep's bounds) or this script's wait running out. The script never stops Shep before the outcome is final: before it does (any
#     exit, an interrupt included) with a recording in doubt it waits up to SHEP_DRAIN_WAIT seconds (default 60, more than Shep's
#     own bounds) for the outcome, and if none arrives it stops Shep anyway and prints `discard-outcome: unknown` (a clip or a
#     .shep-rec-* directory may remain).
#   4 the run did not reach an approval card: `outcome: failed` or `nothing-to-offer`, finished or timed out without a card
#     (a dry run that ends here did not reach an approval card)
#   5 refused: a `reason: target:` line (including an unusable --live-target), `outcome: refused`, no target app in front,
#     Shep did not arrive, backdrop failed
#   6 recording problem (record refused or discarded, `discard-failed`, `discard-unknown`, nothing written in time, clip missing) or the output name or the status file
#     name was already taken
#   7 Shep exited before `live: finished`
#   130 interrupted
# scripts/test-scripts.sh tests every code with canned logs and a fake Shep.
# SHEP_LIVE_DEBUG_DIR (a directory outside any git checkout): Shep reads it itself (--live-debug-dir) and dumps each run's input
# there; the script prints the path.
# Needs: a built app (scripts/build.sh; SHEP_APP overrides the path), Accessibility for the terminal, Screen Recording for the
# terminal that launches Shep (Shep inherits it), and Xcode's swiftc (shep-winfo). The target app must be installed; set
# SHEP_TARGET_NAME if its name cannot be found from the id.
# Env: SHEP_LEFT_DISCARD_WAIT (seconds to wait for the discard outcome after target-left, and for target-left after an outcome, default 10), SHEP_DRAIN_WAIT (seconds to wait for the outcome before stopping Shep, default 60), SHEP_APP, SHEP_WINFO_BIN (a stand-in for the compiled shep-winfo, used by the tests), SHEP_FIX_DEMO_STEM (a fixed output stem; refused if it exists), SHEP_LIVE_DEBUG_DIR, SHEP_EVIDENCE_DIR, SHEP_TARGET_NAME, SHEP_LIVE_ARRIVE_TIMEOUT (default 60, seconds to wait for Shep to arrive), SHEP_RECORD_SLACK (default 15, seconds added to the outer limit arrival + N; a discard outcome seen gets its own SHEP_LEFT_DISCARD_WAIT deadline beyond it).
set -euo pipefail
set -o noclobber   # a plain `>` never overwrites an existing file
cd "$(dirname "$0")/.."
export TZ=America/Chicago
# shellcheck disable=SC1091
source scripts/capture-policy-lib.sh
# shellcheck disable=SC1091
source scripts/record-fix-lib.sh
usage='usage: scripts/record-fix-demo.sh <bundle-id> "<request>" [--seconds N] [--no-record]'
bundle=""; request=""; seconds=70; record=1
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds)   [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }; seconds="$2"; shift 2 ;;
    --seconds=*) seconds="${1#--seconds=}"; shift ;;
    --no-record) record=0; shift ;;
    --*)         echo "unknown option: $1" >&2; echo "$usage" >&2; exit 2 ;;
    *)           if [ -z "$bundle" ]; then bundle="$1"; elif [ -z "$request" ]; then request="$1"; else echo "$usage" >&2; exit 2; fi; shift ;;
  esac
done
[ -n "$bundle" ] && [ -n "${request// }" ] || { echo "$usage" >&2; exit 2; }
case "$request" in --*) echo "refused: the request must not look like a flag" >&2; exit 2 ;; esac
case "$seconds" in ''|*[!0-9]*) echo "--seconds needs a whole number" >&2; exit 2 ;; esac
[ "$seconds" -ge 10 ] || { echo "--seconds must be at least 10" >&2; exit 2; }
fix_valid_bundle "$bundle" || { echo "refused: that does not look like a bundle id: $bundle" >&2; exit 2; }

# 1. Never-capture list (scripts/capture-policy-lib.sh, the shared mirror of ControlPolicy.mayCapture).
if capture_denied "$bundle"; then
  echo "refused: $bundle is on Shep's never-capture list; nothing was launched or recorded" >&2; exit 2
fi

app="${SHEP_APP:-build/Build/Products/Debug/Shep.app}"
bin="$app/Contents/MacOS/Shep"
[ -x "$bin" ] || { echo "app not built: $bin (run scripts/build.sh)" >&2; exit 2; }
out_dir="${SHEP_EVIDENCE_DIR:-$HOME/shep-evidence}"
case "$(cd "$out_dir" 2>/dev/null && pwd -P || echo "$out_dir")" in
  "$(pwd -P)"|"$(pwd -P)"/*) echo "refused: the evidence directory must be outside the repo" >&2; exit 2 ;;
esac
arrive_timeout="${SHEP_LIVE_ARRIVE_TIMEOUT:-60}"
discard_wait="${SHEP_LEFT_DISCARD_WAIT:-10}"
case "$discard_wait" in ''|*[!0-9]*) echo "SHEP_LEFT_DISCARD_WAIT needs a whole number of seconds" >&2; exit 2 ;; esac
record_slack="${SHEP_RECORD_SLACK:-15}"
case "$record_slack" in ''|*[!0-9]*) echo "SHEP_RECORD_SLACK needs a whole number of seconds" >&2; exit 2 ;; esac
drain_wait="${SHEP_DRAIN_WAIT:-60}"
case "$drain_wait" in ''|*[!0-9]*) echo "SHEP_DRAIN_WAIT needs a whole number of seconds" >&2; exit 2 ;; esac
# The evidence folder is created private (0700) when this script creates it, and an existing one is never chmod-ed; either way it is
# judged with stat before anything is reserved or launched (fix_private_dir in scripts/record-fix-lib.sh): owned by this user, not
# group/other-writable, ancestors owned by this user or root and not writable by others unless sticky. Shep checks the same rule again.
if [ ! -e "$out_dir" ] && [ ! -L "$out_dir" ]; then
  { mkdir -p -- "$(dirname -- "$out_dir")" && mkdir -m 700 -- "$out_dir"; } || { echo "refused: could not create the evidence folder" >&2; exit 2; }
fi
fix_private_dir "$out_dir" || { echo "refused: the output folder is not private to you ($FIX_TRUST_WHY); nothing was launched or recorded" >&2; exit 2; }
out_dir="$FIX_REAL_DIR"
# A unique, exclusively reserved output name (stamp, pid, random suffix); an existing file is refused, never touched.
fix_reserve_output "$out_dir" "${SHEP_FIX_DEMO_STEM:-}" || exit 6
mov="$FIX_MOV"
final_log="$FIX_LOG"
work="$(mktemp -d "${TMPDIR:-/tmp}/shep-record-fix.XXXXXX")"
log="$work/shep.log"   # the human log: for people, never classified
# The structured status channel the verdict is read from: a path in the private work directory that must not exist (Shep creates it
# exclusively), and a per-run nonce from /dev/urandom that goes to Shep through the environment and is never printed.
status="${SHEP_FIX_STATUS_FILE:-$work/shep.status}"
if [ -e "$status" ] || [ -L "$status" ]; then
  echo "refused: the status file $status already exists; I do not reuse or overwrite files" >&2; exit 6
fi
fix_make_nonce
nonce="$FIX_NONCE"
status_has() { FIX_EVENTS="$(fix_status_events "$status" "$nonce" || true)"; fix_has_event "$1"; }
shep_pid=""; caf_pid=""
discard_reported=""; drain_abort=""; discard_src=""
cleanup() {
  trap - EXIT
  trap 'drain_abort=1' INT TERM   # a second signal ends the wait below, not the stop
  if declare -F settle_before_kill >/dev/null; then settle_before_kill || true; fi
  if [ -n "$shep_pid" ]; then kill "$shep_pid" 2>/dev/null || true; wait "$shep_pid" 2>/dev/null || true; fi
  if [ -n "$caf_pid" ]; then kill "$caf_pid" 2>/dev/null || true; fi   # only our own caffeinate
  # The reserved log is ours and empty: append the run's log to it. No file is ever removed (the work directory stays in $TMPDIR).
  [ -s "$log" ] && cat "$log" >> "$final_log" || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 2. Target app to the front, and its window frame.
name="${SHEP_TARGET_NAME:-}"
if [ -z "$name" ]; then
  path="$(mdfind "kMDItemCFBundleIdentifier == '$bundle'" 2>/dev/null | head -n 1 || true)"
  [ -n "$path" ] && name="$(basename "$path" .app)"
fi
[ -n "$name" ] || { echo "cannot find the app name for $bundle; set SHEP_TARGET_NAME" >&2; exit 2; }
winfo_bin="${SHEP_WINFO_BIN:-$work/shep-winfo}"
if [ -z "${SHEP_WINFO_BIN:-}" ]; then
  xcrun swiftc -O scripts/shep-winfo.swift -o "$winfo_bin" || { echo "could not compile scripts/shep-winfo.swift" >&2; exit 2; }
fi
open -b "$bundle" || { echo "could not open $bundle" >&2; exit 3; }
front=0
for _ in $(seq 1 20); do
  if "$winfo_bin" --frontmost "$name" >/dev/null 2>&1; then front=1; break; fi
  open -b "$bundle" 2>/dev/null || true
  sleep 1
done
[ "$front" -eq 1 ] || { echo "$name is not the frontmost app (Accessibility allowed for this terminal?). Nothing was launched." >&2; exit 3; }
info="$("$winfo_bin" "$name")" || { echo "no on-screen window found for $name" >&2; exit 3; }
echo "target: $bundle ($name)"
echo "target window (id x y w h title): $info"

# 3. Keep the Mac awake for this job only.
caffeinate -dimsu &
caf_pid=$!

# 4. Shep. The request is submitted by Shep itself and the recording is made by Shep; this script never answers the card.
if [ "$record" -eq 1 ]; then
  SHEP_LIVE_NONCE="$nonce" "$bin" --live-request "$request" --live-target "$bundle" --live-status "$status" --live-record "$mov" --live-record-seconds "$seconds" --capturable >"$log" 2>&1 &
else
  SHEP_LIVE_NONCE="$nonce" "$bin" --live-request "$request" --live-target "$bundle" --live-status "$status" --capturable >"$log" 2>&1 &
fi
shep_pid=$!
echo "Shep started (pid $shep_pid), bound to $bundle, log $log"
if [ -n "${SHEP_LIVE_DEBUG_DIR:-}" ]; then echo "debug dumps (they hold a screenshot of the target window): $SHEP_LIVE_DEBUG_DIR"; fi

is_alive() { if kill -0 "$shep_pid" 2>/dev/null; then echo 1; else echo 0; fi; }
# What the discard came to, in words (FIX_DISCARD, and discard_src for `unknown`: shep = Shep's own event, script = this script's wait ran
# out). One `discard-outcome: <word>` line and a plain sentence on stderr. Nothing is removed here either way.
say_discard() {
  echo "discard-outcome: $FIX_DISCARD" >&2
  case "$FIX_DISCARD" in
    discarded)         echo "The target left the front; the recording was discarded (no clip kept)." >&2 ;;
    failed)            echo "The target left the front and the recording was NOT discarded: its clip or working directory may remain. Look for .shep-rec-* beside $mov and read the log: $final_log" >&2 ;;
    already-published) echo "The target left the front after the clip was already published; it is kept at $mov (already published). Review it or remove it by hand." >&2 ;;
    unknown)
      if [ "${discard_src:-}" = "script" ]; then
        echo "No discard outcome arrived in time: the clip state is UNKNOWN (a clip or a .shep-rec-* directory may remain). Look for $mov and .shep-rec-* beside it." >&2
      else
        echo "Shep could not confirm the discard within its own bounds (a recording start or stop was still running): the clip state is UNKNOWN (a clip or a .shep-rec-* directory may remain). Look for $mov and .shep-rec-* beside it." >&2
      fi ;;
    *)                 echo "Shep exited without reporting a discard outcome: the clip state is UNKNOWN. Look for $mov and .shep-rec-* beside it." >&2 ;;
  esac
}
# The target left while a recording was asked for (code reviews of 6d026eb and d8213e1). Shep discards the clip BEFORE it writes
# target-left, but this script does not rely on the order: it waits (at most $discard_wait seconds, SHEP_LEFT_DISCARD_WAIT) for the
# discard outcome event, says what it was, and the verdict stays 3. The words: discarded | failed | unknown | already-published |
# shep-exited. A wait that runs out is `unknown` (the clip may remain).
report_left_discard() {
  local end_at=$(( SECONDS + discard_wait ))
  discard_reported=1; discard_src="shep"
  while :; do
    fix_discard_outcome "$status" "$nonce"
    [ -z "$FIX_DISCARD" ] || break
    if ! kill -0 "$shep_pid" 2>/dev/null; then
      fix_discard_outcome "$status" "$nonce"   # it may have written its last line just before it exited
      [ -n "$FIX_DISCARD" ] || FIX_DISCARD="shep-exited"
      break
    fi
    [ "$SECONDS" -lt "$end_at" ] || { FIX_DISCARD="unknown"; discard_src="script"; break; }
    sleep 0.5
  done
  say_discard
}
# Before Shep is stopped, a recording whose fate is not in the status file yet gets time to finish: nothing is written, nothing is
# said about target-left and no outcome is known. Stopping Shep in the middle of a discard (or of the clip's tail and publish) can cut
# the cleanup short, so the script waits up to $drain_wait seconds for an outcome, the clip, or the end of Shep; if none comes it
# stops Shep anyway and says `discard-outcome: unknown`.
recording_in_doubt() {
  FIX_EVENTS="$(fix_status_events "$status" "$nonce" || true)"
  fix_has_event "recording-written|target-left|$FIX_EARLY_STAGES|discard-failed|discard-unknown|recording-already-published|recording-discarded( refused)?" && return 1
  return 0
}
settle_before_kill() {
  [ "$record" -eq 1 ] && [ -z "$discard_reported" ] && [ -n "$shep_pid" ] || return 0
  kill -0 "$shep_pid" 2>/dev/null || return 0
  recording_in_doubt || return 0
  local end_at=$(( SECONDS + drain_wait ))
  discard_src="script"
  while :; do
    fix_discard_outcome "$status" "$nonce"
    if [ -n "$FIX_DISCARD" ]; then discard_src="shep"; break; fi
    FIX_EVENTS="$(fix_status_events "$status" "$nonce" || true)"
    fix_has_event 'recording-written|target-left' && return 0   # the recording finished, or the left path reports it
    kill -0 "$shep_pid" 2>/dev/null || break
    if [ -n "$drain_abort" ] || [ "$SECONDS" -ge "$end_at" ]; then FIX_DISCARD="unknown"; break; fi
    sleep 0.5
  done
  if [ -z "$FIX_DISCARD" ]; then fix_discard_outcome "$status" "$nonce"; [ -n "$FIX_DISCARD" ] || FIX_DISCARD="shep-exited"; fi
  say_discard
}
finish_with_verdict() {   # classify the log (same function in both modes), print the verdict, exit with its code
  fix_verdict "$status" "$nonce" "$(is_alive)"
  if [ "$FIX_CODE" -ne 0 ]; then echo "$FIX_MSG. Log: $final_log" >&2; grep -F '[shep] live:' "$log" >&2 || true; fi
  exit "$FIX_CODE"
}

if [ "$record" -eq 0 ]; then
  echo "--no-record: not recording. Answer the approval card in the overlay when it appears (this script never does)."
  end_at=$(( SECONDS + arrive_timeout + seconds ))
  while [ "$SECONDS" -lt "$end_at" ]; do
    fix_log_settled "$status" "$nonce" && break
    kill -0 "$shep_pid" 2>/dev/null || break
    sleep 0.5
  done
  echo "log: $final_log"
  grep -F '[shep] live:' "$log" || true
  finish_with_verdict
fi

echo "Shep records the target window itself, for up to ${seconds}s. Answer the approval card in the overlay when it appears: this script never approves."
end_at=$(( SECONDS + arrive_timeout + seconds + record_slack ))
written=0
outcome_at=""
# Each pass reads the status file once and decides from that one snapshot. An observed discard outcome is final but does not end the
# run, and it is looked at BEFORE the recording-written shortcut (a published clip is followed by recording-already-published, then
# target-left). From the moment an outcome is seen the wait for target-left or a final state (finished, Shep gone) has its own
# deadline, $discard_wait seconds after the outcome, independent of end_at, so an outcome just before end_at still reaches target-left.
while :; do
  FIX_EVENTS="$(fix_status_events "$status" "$nonce" || true)"
  fix_has_event 'target-left' && break   # the target left the front: the verdict is 3 (after the discard outcome, below)
  fix_discard_from_events
  if [ -n "$FIX_DISCARD" ]; then
    [ -n "$outcome_at" ] || outcome_at=$SECONDS
    fix_has_event 'finished' && break
    [ $(( SECONDS - outcome_at )) -lt "$discard_wait" ] || break
  else
    if fix_has_event 'recording-written'; then written=1; break; fi
    [ "$SECONDS" -lt "$end_at" ] || break
  fi
  if fix_has_event "$FIX_EARLY_STAGES"; then break; fi   # a refusal: no recording is coming
  kill -0 "$shep_pid" 2>/dev/null || break
  sleep 0.5
done
# The target left the front: wait (bounded) for the discard outcome, say what it was, and exit with the verdict (3).
if status_has 'target-left'; then
  report_left_discard
  echo "log: $final_log"
  finish_with_verdict
fi
# A discard outcome without target-left: no clip was kept (6), and the words say whether one may remain. Whatever the reason, the script
# reports "no clip" and leaves every path alone; Shep removes only its own working directory.
if [ "$written" -ne 1 ] && ! status_has 'recording-written'; then
  fix_discard_outcome "$status" "$nonce"
  if [ -n "$FIX_DISCARD" ]; then
    discard_reported=1; discard_src="shep"
    grep -E '^\[shep\] live: (record refused|recording discarded|record note)' "$log" | tail -n 1 >&2 || true   # the reason, for people
    case "$FIX_DISCARD" in
      failed)  echo "No clip was kept at the output path, and the recording was NOT discarded: its clip or working directory could not be removed (.shep-rec-* beside $mov may remain). Log: $final_log" >&2 ;;
      unknown) echo "No clip was kept at the output path, and Shep could not confirm the discard: the clip state is UNKNOWN (a clip or a .shep-rec-* directory beside $mov may remain). Log: $final_log" >&2 ;;
      *)       echo "No clip was kept. Log: $final_log" >&2 ;;
    esac
    echo "discard-outcome: $FIX_DISCARD" >&2
    exit 6
  fi
fi
# Shep may have written its last lines and exited between two looks: read the log once more.
if [ "$written" -ne 1 ] && status_has 'recording-written'; then written=1; fi
if [ "$written" -ne 1 ]; then
  fix_verdict "$status" "$nonce" "$(is_alive)"
  if [ "$FIX_CODE" -ne 0 ]; then echo "$FIX_MSG. Nothing was recorded. Log: $final_log" >&2; grep -F '[shep] live:' "$log" >&2 || true; exit "$FIX_CODE"; fi
  echo "Shep did not report a written recording within the timeout. Last log lines:" >&2; tail -n 5 "$log" >&2
  exit 6
fi
[ -s "$mov" ] || { echo "Shep reported a recording but $mov is missing or empty" >&2; exit 6; }
status_has 'finished' || echo "note: the status never said 'finished' (the card may still have been open); see $final_log" >&2
echo "answer and outcome from the human log (information only; the verdict comes from the status file):"
grep -E '^\[shep\] live: (approval|outcome|finished|record)' "$log" || echo "  (none)"
echo "log: $final_log"
echo "clip: $mov"
fix_verdict "$status" "$nonce" "$(is_alive)"
if [ "$FIX_CODE" -ne 0 ]; then echo "$FIX_MSG (the clip was kept)" >&2; fi
exit "$FIX_CODE"
