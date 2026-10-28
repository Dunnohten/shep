#!/bin/bash
# Run "Fix this screen" once against a screenshot with the real Glimmer server, print the result and timing.
#   scripts/e2e-glimmer.sh path/to/screenshot.png          a PNG you captured (window name shows as "image")
#   scripts/e2e-glimmer.sh --window "<owner>" [--title "<substr>"] [--request "<text>"]
#       live recheck: capture ONLY that app window (screencapture -x -o -l <window id>) and run the pipeline once.
#       A live capture passes the window's real frame and title to the app, so box positions are exact.
#       --request is what the person would ask ("close this window", "save"); without it the pipeline picks one next step.
#   (older form still works: --window TextEdit "Shep test")
# The report (controls, proposals, notes, timings) is printed AND written to <evidence dir>/e2e-<time>.txt, beside the
# capture. The evidence dir is ~/shep-evidence (SHEP_EVIDENCE_DIR), never the repo.
# Glimmer is reused, never started: the server must already answer at SHEP_GLIMMER_URL (default http://127.0.0.1:8080/v1),
# and the detector sidecar at SHEP_DETECTOR_URL (default http://127.0.0.1:8765, scripts/detector-server.py).
# With --window the owner's pid is exported as SHEP_AX_PID, so the app's own controls (Accessibility) are read for that window
# and merged with the vision boxes; the terminal needs Accessibility access for that. If the pid cannot be resolved the script
# stops (exit 2) before capturing: a window capture never goes on as an unattested file. A bare PNG reads no Accessibility.
# ONE lookup: `shep-winfo --record <owner> [<title>]` prints `id pid bundle x y w h title` for one window from one window-list snapshot
# (exit 4 on ambiguity, a pid with no bundle, or no match). The never-capture list (capture_denied, scripts/capture-policy-lib.sh,
# shared with record-fix-demo.sh) is applied to THAT record's bundle before the helper health checks and before screencapture; a
# denied or unresolved app exits 2 and no PNG is written. Order: record -> policy -> `shep-winfo --verify <id> <pid> <bundle> <x> <y>
# <w> <h> <title>` (a fresh snapshot must show that exact window id, owner, bundle, title and integer frame; else exit 2, nothing
# captured) -> the PNG path is reserved (unique name: stamp, pid, 4 hex; created under noclobber, an existing file or link of that name
# refuses with exit 2 and is never touched) -> `screencapture -l <that id>` -> the SAME full verify again -> only then the app runs.
# A mismatch after the capture exits 8: the PNG this run made is removed (only after checking that it is a regular file, not a symlink,
# with the inode recorded right after the capture; if that check fails nothing is removed and the run says so), and the app never
# runs. If the removal itself fails (a read-only folder, a changed permission) the run still exits 8 (or 2), prints the mismatch reason
# and says "the PNG could not be removed and remains at: <path>" (the path this run made); the app never runs. SHEP_WINDOW_FRAME is the verified frame of the record, equal by construction to what the second verify confirmed, and
# SHEP_AX_PID is that record's pid (never a separate lookup).
# What this does NOT do: no capture API binds the selected object, so the capture is not atomic with the checks. The second verify
# narrows the churn (a window moved, resized, re-titled or replaced under the same id between the record and the file); it cannot
# prove that the pixels are of the window that was checked.
# Exit codes: 0 ok; 2 usage, preflight or any refusal before the capture (including a taken PNG name); 3 no Glimmer server; 4 no
# detector sidecar; 8 the window changed after the capture; the app's own status otherwise.
# Needs: a built app (scripts/build.sh) and, for --window, Screen Recording for the terminal and Xcode's swiftc.
# Env: SHEP_GLIMMER_URL, SHEP_GLIMMER_MODEL (default ~/models/Muse-Glimmer-30B-4bit), SHEP_DETECTOR_URL,
#      SHEP_WINFO_BIN and SHEP_SCREENCAPTURE (stand-ins for the compiled shep-winfo and for screencapture; scripts/test-scripts.sh
#      uses them, default to the real tools),
#      SHEP_RM_CMD (a stand-in for rm, used ONLY to remove the PNG this run made),
#      SHEP_SAM3=1 (opt in to SAM 3), SHEP_APP (default build/Build/Products/Debug/Shep.app), SHEP_EVIDENCE_DIR,
#      SHEP_E2E_STEM (a fixed output name stem, for tests; refused if the PNG or the report already exists).
set -euo pipefail
cd "$(dirname "$0")/.."
export TZ=America/Chicago
usage='usage: scripts/e2e-glimmer.sh <screenshot.png> | --window "<owner>" [--title "<substr>"] [--request "<text>"]'
[ -n "${1:-}" ] || { echo "$usage" >&2; exit 2; }
out_dir="${SHEP_EVIDENCE_DIR:-$HOME/shep-evidence}"
mkdir -p "$out_dir"
stamp="$(date +%Y%m%d-%H%M%S)"
suffix="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
stem="${SHEP_E2E_STEM:-e2e-window-$stamp-$$-$suffix}"
report="$out_dir/${SHEP_E2E_STEM:-e2e-$stamp-$$-$suffix}.txt"
owner=""; fragment=""; request=""; png=""
while [ $# -gt 0 ]; do
  case "$1" in
    --window)  owner="${2:?$usage}"; shift 2
               # older positional form: --window <owner> <title fragment>
               if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then fragment="$1"; shift; fi ;;
    --title)   fragment="${2:?$usage}"; shift 2 ;;
    --request) request="${2:?$usage}"; shift 2 ;;
    --*)       echo "unknown option: $1" >&2; echo "$usage" >&2; exit 2 ;;
    *)         png="$1"; shift ;;
  esac
done
app="${SHEP_APP:-build/Build/Products/Debug/Shep.app}"
bin="$app/Contents/MacOS/Shep"
url="${SHEP_GLIMMER_URL:-http://127.0.0.1:8080/v1}"
detector="${SHEP_DETECTOR_URL:-http://127.0.0.1:8765}"

# Everything that can refuse runs BEFORE anything is written: the window is resolved, the owner's bundle id is looked up for that
# exact window and checked against the shared never-capture list, the app and the helper servers are checked, and only then does
# screencapture run. A denied or unresolved app leaves no PNG behind.
wid=""
if [ -n "$owner" ]; then
  # shellcheck disable=SC1091
  source scripts/capture-policy-lib.sh
  work="$(mktemp -d "${TMPDIR:-/tmp}/shep-e2e.XXXXXX")"
  winfo="${SHEP_WINFO_BIN:-$work/shep-winfo}"
  if [ -z "${SHEP_WINFO_BIN:-}" ]; then
    xcrun swiftc -O scripts/shep-winfo.swift -o "$winfo" || { echo "could not compile scripts/shep-winfo.swift" >&2; exit 2; }
  fi
  # ONE record from ONE window-list snapshot: id, owner pid, the bundle of THAT pid, frame and title. shep-winfo refuses (exit 4)
  # when the match is ambiguous, when the pid has no bundle or when nothing matches; there is no untitled fallback and no second
  # lookup, so the id, the pid and the bundle below always describe the same window.
  info="$("$winfo" --record "$owner" "$fragment" 2>"$work/record.err")" || {
    echo "refusing: no single window of '$owner'${fragment:+ matching \"$fragment\"} could be recorded: $(head -n 1 "$work/record.err" 2>/dev/null)" >&2
    exit 2
  }
  read -r wid axpid bundle wx wy ww wh wtitle <<<"$info"
  # The pid names the app for --fix-screen-once (SHEP_AX_PID) and is the record's own, never a separate lookup. A record without a
  # numeric id and pid stops the run before anything is captured.
  case "$wid" in ''|*[!0-9]*) echo "refusing: could not resolve the window of '$owner' (got '${wid:-nothing}')" >&2; exit 2 ;; esac
  case "$axpid" in ''|*[!0-9]*) echo "refusing: could not resolve the process of '$owner' (got '${axpid:-nothing}'), so I cannot tell which app this window belongs to" >&2; exit 2 ;; esac
  # The never-capture list on the record's bundle. An unresolved id is a refusal (capture_denied fails closed).
  if capture_denied "$bundle"; then
    echo "refusing: '$owner' (bundle '${bundle:-unresolved}') is on Shep's never-capture list or could not be identified; nothing was captured" >&2
    exit 2
  fi
fi
[ -n "$png" ] || [ -n "$owner" ] || { echo "$usage" >&2; exit 2; }
[ -x "$bin" ] || { echo "app not built: $bin (run scripts/build.sh)" >&2; exit 2; }
if ! curl -fsS --max-time 5 "$detector/health" >/dev/null 2>&1; then
  echo "no detector sidecar answering at $detector/health." >&2
  echo "start it with scripts/detector-server.py (see docs/detector.md), or --fake to test the wiring." >&2
  exit 4
fi
# The server must already be up; this script never starts or stops one.
if ! curl -fsS --max-time 5 "$url/models" >/dev/null 2>&1; then
  echo "no Glimmer server answering at $url/models." >&2
  echo "start one with scripts/glimmer-server.sh, or set SHEP_GLIMMER_URL. (If /v1/models is 404 but the server is up, try the URL without /v1.)" >&2
  exit 3
fi
inode_of() { ls -di -- "$1" 2>/dev/null | awk '{print $1}'; }
png_made=0; png_inode=""
RM_BIN="${SHEP_RM_CMD:-rm}"   # test seam; used ONLY to remove the PNG this run made
# Removes ONLY the PNG this run made: it must be the path this run reserved, a regular file, not a symlink, with the inode recorded
# for it. Anything else is somebody else's now: nothing is removed, and the run says so.
remove_own_png() {
  [ "$png_made" -eq 1 ] || return 0
  if [ -f "$png" ] && [ ! -L "$png" ] && [ -n "$png_inode" ] && [ "$(inode_of "$png")" = "$png_inode" ]; then
    # A failing removal never aborts the caller (set -e would skip the exit status the caller is about to give): it is reported.
    if "$RM_BIN" -- "$png" 2>/dev/null; then
      echo "removed the PNG this run made: $png" >&2
    else
      echo "the PNG could not be removed and remains at: $png" >&2
    fi
  else
    echo "removed nothing: $png is no longer the file this run made, so I left it" >&2
  fi
}
verify_window() { # the full record again: a fresh snapshot must show this exact id, owner, bundle, title and frame; prints the reason
  "$winfo" --verify "$wid" "$axpid" "$bundle" "$wx" "$wy" "$ww" "$wh" "$wtitle" 2>"$work/verify.err" >/dev/null || {
    echo "$(head -n 1 "$work/verify.err" 2>/dev/null)"; return 1
  }
}
if [ -n "$owner" ]; then
  png="$out_dir/$stem.png"
  # Before the capture: a fresh snapshot must show exactly this window (id, pid, bundle, title, frame). Anything else (the window
  # closed, moved or resized, moved to another app, the id reused) refuses; no PNG, no screencapture.
  why="$(verify_window)" || { echo "refusing: the window is not the recorded one ($why); nothing was captured" >&2; exit 2; }
  # The PNG path is reserved exclusively under noclobber; whatever is at that name (a file, a link, a dangling link) is left alone.
  if [ -e "$png" ] || [ -L "$png" ] || [ -e "$report" ] || [ -L "$report" ] || ! ( set -o noclobber; : > "$png" ) 2>/dev/null; then
    echo "refusing: $png (or its report) already exists; I do not reuse or overwrite files" >&2; exit 2
  fi
  png_made=1; png_inode="$(inode_of "$png")"
  if ! "${SHEP_SCREENCAPTURE:-screencapture}" -x -o -t png -l "$wid" "$png"; then
    remove_own_png
    echo "window capture failed (is Screen Recording allowed for this terminal?)" >&2; exit 2
  fi
  png_inode="$(inode_of "$png")"   # the file as the capture left it
  # After the capture: the same full verify. A change in between means the PNG may not show the window that was recorded.
  why="$(verify_window)" || {
    echo "refusing: the window changed during the capture ($why); the PNG is not used" >&2
    remove_own_png
    exit 8
  }
  export SHEP_WINDOW_FRAME="$wx,$wy,$ww,$wh"
  export SHEP_WINDOW_TITLE="${wtitle:-${fragment:-$owner}}"
  export SHEP_AX_PID="$axpid"
fi
[ -f "$png" ] || { echo "no such file: $png" >&2; exit 2; }
[ -z "$request" ] || export SHEP_REQUEST="$request"
{
  echo "e2e-glimmer $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "screenshot: $png"
  [ -z "$owner" ] || echo "window: $owner ${fragment:+\"$fragment\" }frame=${SHEP_WINDOW_FRAME:-?} title=\"${SHEP_WINDOW_TITLE:-}\" ax_pid=${SHEP_AX_PID:-none}"
  echo "request: ${request:-(none: one most-likely next step)}"
  echo "glimmer: $url   detector: $detector"
  echo "---"
} | tee "$report"
start=$(date +%s)
status=0
SHEP_PROVIDER=glimmer "$bin" --fix-screen-once "$png" 2>&1 | tee -a "$report" || status=$?
echo "wall time including app start: $(( $(date +%s) - start )) s" | tee -a "$report"
echo "report: $report"
exit "$status"
