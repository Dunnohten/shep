#!/bin/bash
# Press demo on a real app, with a guaranteed restore:
#   scripts/press-demo.sh <bundle-id> "<exact match>" [--restore]
# Shep proposes AXPress on the ONE control whose label or tooltip contains the match (for example the turtle checkbox of
# Transmission: scripts/press-demo.sh org.m0k.transmission "Speed Limit overrides"). Steps:
#   1. --ax-read-once: what Accessibility shows (the "before" count).
#   2. --press-demo-once WITHOUT --approve: prints the approval card and must change nothing.
#   3. --press-demo-once WITH --approve: the press. The value must flip.
#   4. --press-demo-once WITH --approve again: the RESTORE press. The value must be back to the original.
# Each --approve is the operator typing the flag for this one control; the app has no auto-approve mode and this script does not
# add one: it only passes the flag on the command line, three times at most (one press, one restore, one repair).
# Restore is always in force: `--restore` is accepted for clarity, `--no-restore` is refused, and an EXIT/ERR trap presses
# once more if the value is left flipped. The match must be non-empty and at least 6 characters, and must name exactly one enabled
# control (Shep itself refuses 0 or 2+ matches, listing them).
# Report: $SHEP_EVIDENCE_DIR/press-demo-<time>.txt (default ~/shep-evidence, never the repo).
# Needs: a built app (scripts/build.sh; SHEP_APP overrides the path) and Accessibility for the terminal. The app must be running.
set -uo pipefail
cd "$(dirname "$0")/.."
export TZ=America/Chicago
usage='usage: scripts/press-demo.sh <bundle-id> "<exact match, 6+ characters>" [--restore]'
bundle=""; match=""
while [ $# -gt 0 ]; do
  case "$1" in
    --restore)    shift ;;
    --no-restore) echo "refused: the restore step cannot be switched off" >&2; exit 2 ;;
    --*)          echo "unknown option: $1" >&2; echo "$usage" >&2; exit 2 ;;
    *)            if [ -z "$bundle" ]; then bundle="$1"; elif [ -z "$match" ]; then match="$1"; else echo "$usage" >&2; exit 2; fi; shift ;;
  esac
done
[ -n "$bundle" ] && [ -n "$match" ] || { echo "$usage" >&2; exit 2; }
[ "${#match}" -ge 6 ] || { echo "refused: the match must be at least 6 characters (got ${#match}); pass the exact text" >&2; exit 2; }
app="${SHEP_APP:-build/Build/Products/Debug/Shep.app}"
bin="$app/Contents/MacOS/Shep"
[ -x "$bin" ] || { echo "app not built: $bin (run scripts/build.sh)" >&2; exit 2; }
out_dir="${SHEP_EVIDENCE_DIR:-$HOME/shep-evidence}"
case "$(cd "$out_dir" 2>/dev/null && pwd -P || echo "$out_dir")" in
  "$(pwd -P)"|"$(pwd -P)"/*) echo "refused: the evidence directory must be outside the repo" >&2; exit 2 ;;
esac
mkdir -p "$out_dir"
stamp="$(date +%Y%m%d-%H%M%S)"
report="$out_dir/press-demo-$stamp.txt"

say() { echo "$@" | tee -a "$report"; }
field() { sed -n "s/^$1: //p" | head -n 1; }   # value of a "key: value" line from a Shep tool

original=""        # value before anything was pressed
pressed=0          # a press with --approve was started
restored=0         # the value was seen back at the original
status=0

press() {          # press WITHOUT or WITH --approve, print the tool's output into the report, keep it in $last
  local flag="$1"
  last="$("$bin" --press-demo-once "$bundle" --match "$match" $flag 2>&1)"; local rc=$?
  { echo "--- press-demo-once ${flag:-(no --approve)} (exit $rc)"; echo "$last"; } >> "$report"
  return $rc
}

repair() {         # on exit: if the value is not the original, press once more to put it back
  trap - EXIT
  if [ "$pressed" -eq 1 ] && [ "$restored" -eq 0 ] && [ -n "$original" ]; then
    say "!! leaving: the value may be flipped; checking"
    if press ""; then
      now="$(echo "$last" | field value_before)"
      if [ "$now" != "$original" ]; then
        say "!! value is '$now', original '$original': pressing once to restore"
        press "--approve" || true
        now="$(echo "$last" | field value_after)"
        if [ "$now" = "$original" ]; then say "restored: value is '$now' again"; restored=1
        else say "!! NOT RESTORED: value is '$now', original '$original'. Fix it by hand."; status=1; fi
      else
        say "value is '$now', the original: nothing to repair"; restored=1
      fi
    else
      say "!! could not check the value; verify it by hand (original '$original')"; status=1
    fi
  fi
  say "report: $report"
  exit "$status"
}
trap repair EXIT

say "press-demo $(date '+%Y-%m-%d %H:%M:%S %Z')"
say "app: $bundle   match: \"$match\"   restore: always"
say "== 1. ax-read-once (before)"
before_read="$("$bin" --ax-read-once "$bundle" 2>&1)"; rc=$?
echo "$before_read" >> "$report"
[ "$rc" -eq 0 ] || { say "ax-read-once failed (exit $rc): $(echo "$before_read" | tail -n 3)"; status=1; exit 1; }
say "controls_kept: $(echo "$before_read" | field controls_kept)   nodes_visited: $(echo "$before_read" | field nodes_visited)"

say "== 2. proposal without --approve (must change nothing)"
if ! press ""; then say "refused or failed: $(echo "$last" | tail -n 4)"; status=1; exit 1; fi
original="$(echo "$last" | field value_before)"
echo "$last" | grep -q "declined: no --approve given" || { say "!! expected 'declined: no --approve given'"; status=1; exit 1; }
say "value before: '$original' (nothing pressed)"

say "== 3. press with --approve"
pressed=1
press "--approve" || { say "press failed: $(echo "$last" | tail -n 4)"; status=1; exit 1; }
[ "$(echo "$last" | field value_before)" = "$original" ] || { say "!! the declined run changed the value"; status=1; exit 1; }
flipped="$(echo "$last" | field value_after)"
say "value after press: '$flipped'"
[ "$flipped" != "$original" ] || { say "!! the value did not flip"; status=1; exit 1; }

say "== 4. restore with --approve"
press "--approve" || { say "restore press failed: $(echo "$last" | tail -n 4)"; status=1; exit 1; }
[ "$(echo "$last" | field value_before)" = "$flipped" ] || { say "!! value before restore was not the flipped one"; status=1; exit 1; }
back="$(echo "$last" | field value_after)"
if [ "$back" = "$original" ]; then
  restored=1
  say "value after restore: '$back' (original)"
else
  say "!! restore did not return the original: '$back' vs '$original'"; status=1; exit 1
fi

say "== 5. ax-read-once (after)"
after_read="$("$bin" --ax-read-once "$bundle" 2>&1)" || true
echo "$after_read" >> "$report"
say "controls_kept: $(echo "$after_read" | field controls_kept)"
say "result: ok. pressed once, restored once, original value '$original'"
exit 0
