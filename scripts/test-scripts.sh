#!/bin/bash
# Shell regression tests for the recording and capture scripts. Plain bash; no Swift, no macOS tools: the Shep binary, shep-winfo,
# screencapture, open, caffeinate and curl are tiny fake scripts. Runs on Linux and on the Mac.
#   bash scripts/test-scripts.sh
# Everything happens under one fresh temp directory. At exit the script removes THAT directory and nothing else (scripts/test-tmp-lib.sh:
# it must be the one this process made, a direct child of the temp directory, a real directory named shep-test-scripts.*). Older
# shep-test-scripts.* directories are never touched. SHEP_TEST_KEEP=1 keeps the directory for debugging.
set -uo pipefail
cd "$(dirname "$0")/.."
repo="$(pwd -P)"
# shellcheck disable=SC1091
. scripts/test-tmp-lib.sh
shep_tmp_make || { echo "could not make a temp directory" >&2; exit 1; }
tmp="$SHEP_TMP_DIR"
trap 'shep_tmp_cleanup' EXIT
pass=0; failed=0
ok()   { pass=$((pass + 1)); }
bad()  { failed=$((failed + 1)); echo "FAIL: $1" >&2; }
check() { # check <description> <command...>
  local what="$1"; shift
  if "$@"; then ok; else bad "$what"; fi
}
eq() { # eq <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$2', got '$3'"; fi
}

# ---------------------------------------------------------------- the libraries exist and have no side effects on source
check "scripts/capture-policy-lib.sh exists" test -f scripts/capture-policy-lib.sh
check "scripts/record-fix-lib.sh exists" test -f scripts/record-fix-lib.sh
before="$(ls -A "$tmp" | wc -l | tr -d ' ')"
# shellcheck disable=SC1091
source scripts/capture-policy-lib.sh
# shellcheck disable=SC1091
source scripts/record-fix-lib.sh
after="$(ls -A "$tmp" | wc -l | tr -d ' ')"
eq "sourcing the libraries creates nothing" "$before" "$after"
check "capture_denied is defined" declare -F capture_denied >/dev/null
check "fix_verdict is defined" declare -F fix_verdict >/dev/null
check "fix_reserve_output is defined" declare -F fix_reserve_output >/dev/null

# ---------------------------------------------------------------- F3: capture_denied
for id in com.apple.mail com.apple.MobileSMS com.apple.keychainaccess com.apple.Terminal com.googlecode.iterm2 com.1password.1password \
          com.bitwarden.desktop com.apple.passwords com.lastpass.LastPass com.microsoft.VSCode com.jetbrains.intellij dev.warp.Warp-Stable \
          com.tinyspeck.slackmacgap "  com.apple.mail  "; do
  check "capture_denied '$id' is true" capture_denied "$id"
done
check "capture_denied org.m0k.transmission is false" bash -c 'source scripts/capture-policy-lib.sh; ! capture_denied org.m0k.transmission'
check "capture_denied com.apple.TextEdit is false" bash -c 'source scripts/capture-policy-lib.sh; ! capture_denied com.apple.TextEdit'
check "capture_denied empty fails closed (denied)" capture_denied ""
check "capture_denied with no argument fails closed" capture_denied
check "capture_denied whitespace fails closed" capture_denied "   "

# ---------------------------------------------------------------- F1: output name reservation
dir1="$tmp/res1"; mkdir -p "$dir1"
fix_reserve_output "$dir1"; rc1=$?; mov1="${FIX_MOV:-}"; log1="${FIX_LOG:-}"
fix_reserve_output "$dir1"; rc2=$?; mov2="${FIX_MOV:-}"; log2="${FIX_LOG:-}"
eq "first reservation succeeds" 0 "$rc1"
eq "second reservation (same second, same pid) succeeds" 0 "$rc2"
check "two reservations in the same second differ (mov)" test "$mov1" != "$mov2"
check "two reservations in the same second differ (log)" test "$log1" != "$log2"
if [[ "$(basename "$mov1")" =~ ^fix-demo-[0-9]{8}-[0-9]{6}-[0-9]+-[0-9a-f]{4}\.mov$ ]]; then ok; else bad "name format: $mov1"; fi
eq "the log shares the movie's stem" "${mov1%.mov}.log" "$log1"
check "the log is reserved (exists)" test -e "$log1"
check "the movie is NOT created by the reservation" test ! -e "$mov1"

dir2="$tmp/res2"; mkdir -p "$dir2"
printf 'precious movie bytes' > "$dir2/fix-demo-fixed.mov"
sum_before="$(cksum < "$dir2/fix-demo-fixed.mov")"
fix_reserve_output "$dir2" fix-demo-fixed 2>"$tmp/res2.err"; rc=$?
eq "an existing movie at the reserved name is refused with 6" 6 "$rc"
eq "the existing movie is byte-for-byte unchanged" "$sum_before" "$(cksum < "$dir2/fix-demo-fixed.mov")"
check "the refusal says why" grep -qi 'exist' "$tmp/res2.err"
printf 'old log' > "$dir2/fix-demo-other.log"
fix_reserve_output "$dir2" fix-demo-other 2>/dev/null; rc=$?
eq "an existing log at the reserved name is refused with 6" 6 "$rc"
eq "the existing log is unchanged" "old log" "$(cat "$dir2/fix-demo-other.log")"
check "no movie was made for the refused log" test ! -e "$dir2/fix-demo-other.mov"
ln -s "$tmp/nowhere" "$dir2/fix-demo-dangling.mov"
fix_reserve_output "$dir2" fix-demo-dangling 2>/dev/null; rc=$?
eq "a dangling symlink at the name is refused too" 6 "$rc"

# ---------------------------------------------------------------- F1/F4: no rm or unlink in the lib or the script
for f in scripts/record-fix-lib.sh scripts/record-fix-demo.sh scripts/capture-policy-lib.sh; do
  if [ -f "$f" ] && grep -vE '^[[:space:]]*#' "$f" | grep -nE '(^|[^A-Za-z_./-])(rm|unlink|rmdir|shred)([[:space:]]|$)|removeItem|find .* -delete'; then
    bad "$f removes something"
  else
    ok
  fi
done
check "record-fix-demo.sh has no discard_clip" bash -c '! grep -q discard_clip scripts/record-fix-demo.sh'
check "record-fix-demo.sh sources the two libraries" bash -c 'grep -q record-fix-lib.sh scripts/record-fix-demo.sh && grep -q capture-policy-lib.sh scripts/record-fix-demo.sh'
check "record-fix-demo.sh no longer mirrors the case list" bash -c '! grep -q "com.apple.mobilesms" scripts/record-fix-demo.sh'

# ---------------------------------------------------------------- F4/R3: the verdict for canned status files
# The classifier reads ONLY the status file lines that start with the run's nonce; the human log is for people. Each case below is
# the same scenario as the old canned human logs, now as the events Shep writes to its status file.
NONCE=0123456789abcdef0123456789abcdef
mklog() { # mklog <name> <lines...>: a canned human shep.log; prints its path
  local f="$tmp/log-$1"; shift
  printf '%s\n' "$@" > "$f"
  echo "$f"
}
mkev() { # mkev <name> <events...>: a status file for $NONCE, one event per argument; prints its path
  local f="$tmp/st-$1" e; shift
  : > "$f"
  for e in "$@"; do printf '%s %s\n' "$NONCE" "$e" >> "$f"; done
  echo "$f"
}
P='[shep] live:'
l_target="$(mklog target "$P waiting for Shep to arrive" "$P reason: target: front app is com.google.Chrome not org.m0k.transmission" "$P outcome: refused" "$P finished")"
l_invalid="$(mklog invalid "$P reason: target: --live-target is not a bundle id" "$P outcome: refused" "$P finished")"
l_refused="$(mklog refused "$P request submitted: x" "$P outcome: refused")"
l_noapp="$(mklog noapp "$P no target app in front" "$P finished")"
l_died="$(mklog died "$P waiting for Shep to arrive" "$P request submitted: x")"
l_failed="$(mklog failed "$P request submitted: x" "$P reason: provider: boom" "$P outcome: failed" "$P finished")"
l_nothing="$(mklog nothing "$P request submitted: x" "$P outcome: nothing-to-offer" "$P finished")"
l_card="$(mklog card "$P request submitted: x" "$P approval card shown: Press Turtle?" "$P approval answered: cancel" "$P outcome: declined" "$P finished")"
l_cardopen="$(mklog cardopen "$P request submitted: x" "$P approval card shown: Press Turtle?")"
l_cardfail="$(mklog cardfail "$P approval card shown: Press Turtle?" "$P approval answered: approve" "$P outcome: failed" "$P finished")"
l_finonly="$(mklog finonly "$P request submitted: x" "$P finished")"
s_target="$(mkev target target-ok reason-target outcome-refused finished)"
s_invalid="$(mkev invalid reason-target outcome-refused finished)"
s_refused="$(mkev refused request-submitted outcome-refused)"
s_noapp="$(mkev noapp reason-no-target finished)"
s_died="$(mkev died request-submitted)"
s_failed="$(mkev failed request-submitted reason-provider outcome-failed finished)"
s_nothing="$(mkev nothing request-submitted outcome-nothing-to-offer finished)"
s_card="$(mkev card request-submitted card-shown answered-cancel outcome-declined finished)"
s_cardopen="$(mkev cardopen request-submitted card-shown)"
s_cardfail="$(mkev cardfail card-shown answered-approve outcome-failed finished)"
s_finonly="$(mkev finonly request-submitted finished)"
verdict() { fix_verdict "$1" "$NONCE" "$2"; echo "$FIX_CODE"; }
eq "target refusal -> 5" 5 "$(verdict "$s_target" 0)"
eq "invalid target refusal -> 5" 5 "$(verdict "$s_invalid" 0)"
eq "outcome: refused with no card -> 5" 5 "$(verdict "$s_refused" 1)"
eq "no target app in front -> 5" 5 "$(verdict "$s_noapp" 0)"
eq "Shep died before live: finished -> 7" 7 "$(verdict "$s_died" 0)"
eq "outcome: failed -> 4" 4 "$(verdict "$s_failed" 1)"
eq "outcome: nothing-to-offer -> 4" 4 "$(verdict "$s_nothing" 1)"
eq "finished without a card -> 4" 4 "$(verdict "$s_finonly" 1)"
eq "still running, no card yet (timeout) -> 4" 4 "$(verdict "$s_died" 1)"
eq "approval card shown, finished -> 0" 0 "$(verdict "$s_card" 1)"
eq "approval card shown, still open, alive -> 0" 0 "$(verdict "$s_cardopen" 1)"
eq "approval card shown, then Shep died before finished -> 7" 7 "$(verdict "$s_cardopen" 0)"
eq "a failed step after the card still reached the card -> 0" 0 "$(verdict "$s_cardfail" 1)"
eq "a missing status file -> 7" 7 "$(verdict "$tmp/no-such-status" 0)"
eq "an empty status file, Shep gone -> 7" 7 "$(verdict "$(mkev empty)" 0)"
check "fix_log_settled: refusal is settled" fix_log_settled "$s_target" "$NONCE"
# The target left the front during the run (status event target-left): exit 3, before or after the card, whatever else follows.
s_left_card="$(mkev leftcard request-submitted card-shown target-left reason-target outcome-refused finished)"
s_left_alone="$(mkev leftalone target-ok target-left)"
s_left_early="$(mkev leftearly request-submitted target-left reason-target outcome-refused finished)"
s_left_after_answer="$(mkev leftanswer request-submitted card-shown answered-cancel target-left finished)"
eq "card-shown then target-left -> 3, not 0" 3 "$(verdict "$s_left_card" 1)"
eq "target-left alone, Shep still running -> 3" 3 "$(verdict "$s_left_alone" 1)"
eq "target-left alone, Shep gone -> 3" 3 "$(verdict "$s_left_alone" 0)"
eq "target-left before any card (with reason-target, outcome-refused) -> 3, not 5" 3 "$(verdict "$s_left_early" 0)"
eq "target-left after an answered card -> 3" 3 "$(verdict "$s_left_after_answer" 1)"
check "fix_log_settled: target-left is settled" fix_log_settled "$s_left_alone" "$NONCE"
check "fix_log_refused_early: target-left means no recording is coming" fix_log_refused_early "$s_left_alone" "$NONCE"
check "fix_log_settled: finished is settled" fix_log_settled "$s_card" "$NONCE"
check "fix_log_settled: an open card is not settled" bash -c "source scripts/record-fix-lib.sh; ! fix_log_settled '$s_cardopen' '$NONCE'"
check "fix_log_refused_early: a target refusal" fix_log_refused_early "$s_target" "$NONCE"
check "fix_log_refused_early: a card is not an early refusal" bash -c "source scripts/record-fix-lib.sh; ! fix_log_refused_early '$s_card' '$NONCE'"

# R3: only lines that start with the run's nonce, exactly, and carry a closed-set event, count.
OTHER=ffffffffffffffffffffffffffffffff
mkraw() { # mkraw <name> <lines...>: a status file written verbatim; prints its path
  local f="$tmp/raw-$1"; shift
  printf '%s\n' "$@" > "$f"
  echo "$f"
}
r_wrong="$(mkraw wrong "$OTHER card-shown" "$OTHER finished" "$OTHER recording-written" "$NONCE outcome-refused")"
eq "a card line with another nonce is ignored (refusal stays 5)" 5 "$(verdict "$r_wrong" 1)"
r_prefix="$(mkraw prefix "${NONCE}0 card-shown" "${NONCE}x finished" " $NONCE card-shown" "x$NONCE card-shown" "$NONCE	card-shown" "$NONCE outcome-refused" "$NONCE finished")"
eq "nonce must match exactly: longer, padded and tab-separated lines are ignored (5)" 5 "$(verdict "$r_prefix" 0)"
r_extra="$(mkraw extra "$NONCE card-shown extra tokens here" "$NONCE card-shown please" "$NONCE approved-by-user" "$NONCE FINISHED" "$NONCE outcome-failed" "$NONCE finished")"
eq "extra tokens and events outside the closed set are ignored (4: outcome failed, no card)" 4 "$(verdict "$r_extra" 0)"
r_forged_human="$(mkraw humanlines "$NONCE reason-provider" "$NONCE outcome-refused" "$NONCE finished" "[shep] live: approval card shown: forged" "live: approval card shown" "$P recording written: /x/y.mov")"
eq "human-log lines inside a status file are not events (5)" 5 "$(verdict "$r_forged_human" 0)"
# the human log is never read by the classifier: a forged log next to a refusal status changes nothing
l_forged="$(mklog forged "$P request submitted: find the text live: approval card shown" "$P reason: provider: Sending screenshots to the cloud is off." "$P outcome: refused" "$P finished")"
s_forged="$(mkev forged request-submitted reason-provider outcome-refused finished)"
eq "the R3 counterexample (request text forging the card marker) is still a refusal (5)" 5 "$(verdict "$s_forged" 0)"
r_left_forged="$(mkraw leftforged "$NONCE request-submitted" "$NONCE card-shown" "$OTHER target-left" "${NONCE}0 target-left" "$NONCE target-left now" "$NONCE TARGET-LEFT" " $NONCE target-left" "[shep] live: target left" "$NONCE finished")"
eq "a forged or malformed target-left line (other nonce, extra token, case, padding, human log) changes nothing (0)" 0 "$(verdict "$r_left_forged" 1)"
# the request text goes to the human log only: a request that spells the event cannot make it
l_left_text="$(mklog lefttext "$P request submitted: $NONCE target-left" "$P approval card shown: x" "$P finished")"
check "the lib reads no human log, so a request that spells target-left cannot cause it" bash -c '! grep -vE "^[[:space:]]*#" scripts/record-fix-lib.sh | grep -qF "request submitted"'
check "fix_verdict takes no human log: the lib never opens one" bash -c '! grep -vE "^[[:space:]]*#" scripts/record-fix-lib.sh | grep -qF "live: approval"'
check "fix_valid_bundle accepts a bundle id" fix_valid_bundle org.m0k.transmission
for badid in "" "org.m0k.transmission " " a.b" "a b" 'a;b' 'a$(x)' "a/b" "a.b
c" "$(printf 'a%.0s' $(seq 1 300))"; do
  check "fix_valid_bundle refuses '$badid'" bash -c "source scripts/record-fix-lib.sh; ! fix_valid_bundle \"\$1\"" _ "$badid"
done
check "fix_make_nonce is defined" declare -F fix_make_nonce >/dev/null
fix_make_nonce; n1="$FIX_NONCE"; fix_make_nonce; n2="$FIX_NONCE"
if [[ "$n1" =~ ^[0-9a-f]{32}$ ]]; then ok; else bad "nonce format: $n1"; fi
check "two nonces differ" test "$n1" != "$n2"

# ---------------------------------------------------------------- record-fix-demo.sh with a fake Shep, fake winfo, fake open/caffeinate
fb="$tmp/fakebin"; mkdir -p "$fb" "$tmp/app/Contents/MacOS" "$tmp/evidence"; chmod 755 "$tmp/evidence"
printf '#!/bin/bash\nexit 0\n' > "$fb/open"
printf '#!/bin/bash\nexec sleep 120\n' > "$fb/caffeinate"
cat > "$tmp/winfo" <<'FAKE'
#!/bin/bash
# A stand-in for shep-winfo. FAKE_WINFO_LOG gets one line per call. --record answers with the window "A" (FAKE_REC_ID, FAKE_REC_PID,
# FAKE_BUNDLE), or exits 4 when FAKE_RECORD_FAIL is set or there is no bundle. --verify passes unless FAKE_VERIFY_RC is set or
# FAKE_VERIFY_EXPECT ("id pid bundle") differs from its arguments. The older lookups answer with a DIFFERENT app, "B" (id 92, pid 5555,
# an allowed bundle): a script that still asks for them would mix two windows.
[ -z "${FAKE_WINFO_LOG:-}" ] || printf '%s\n' "$*" >> "$FAKE_WINFO_LOG"
case "${1:-}" in
  --frontmost) echo "frontmost=Fake focused=Title"; exit 0 ;;
  --record)
    if [ -n "${FAKE_RECORD_FAIL:-}" ]; then echo "shep-winfo: more than one window of $2 matches" >&2; exit 4; fi
    [ -n "${FAKE_BUNDLE:-}" ] || { echo "shep-winfo: no bundle" >&2; exit 4; }
    echo "${FAKE_REC_ID:-7} ${FAKE_REC_PID:-4242} $FAKE_BUNDLE 10 10 400 300 Title"; exit 0 ;;
  --verify)
    [ -z "${FAKE_VERIFY_RC:-}" ] || exit "$FAKE_VERIFY_RC"
    if [ -n "${FAKE_VERIFY_EXPECT:-}" ] && [ "$2 $3 $4" != "$FAKE_VERIFY_EXPECT" ]; then exit 1; fi
    # The window as the system shows it at this call: FAKE_WIN_<n> ("id pid bundle x y w h|title"), else the record's own window.
    # `--verify <id> <pid> <bundle> <x> <y> <w> <h> <title>` must match it exactly (FAKE_VERIFY_COUNT counts the calls).
    n=1
    if [ -n "${FAKE_VERIFY_COUNT:-}" ]; then
      prev=0; [ ! -f "$FAKE_VERIFY_COUNT" ] || prev="$(cat "$FAKE_VERIFY_COUNT")"
      n=$((prev + 1)); echo "$n" > "$FAKE_VERIFY_COUNT"
    fi
    # A foreign file takes the PNG's name at this call (the cleanup must then remove nothing).
    if [ -n "${FAKE_SWAP_SRC:-}" ] && [ "$n" = "${FAKE_SWAP_ON:-2}" ]; then mv -f "$FAKE_SWAP_SRC" "$FAKE_SWAP_DST"; fi
    var="FAKE_WIN_$n"
    actual="${!var:-${FAKE_REC_ID:-7} ${FAKE_REC_PID:-4242} ${FAKE_BUNDLE:-} 10 10 400 300|Title}"
    if [ "$actual" != "$2 $3 $4 $5 $6 $7 $8|$9" ]; then echo "shep-winfo: verify: the window is not the recorded one" >&2; exit 1; fi
    exit 0 ;;
  --pid) echo 5555; exit 0 ;;
  --bundle) echo org.m0k.transmission; exit 0 ;;
  *) echo "7 10 10 400 300 Title"; exit 0 ;;
esac
FAKE
cat > "$tmp/app/Contents/MacOS/Shep" <<'FAKE'
#!/bin/bash
# A stand-in for the Shep binary: records its arguments, optionally makes the movie file, writes the status file the way Shep does
# (exclusively; each events line gets the run's nonce from the environment), prints a canned human log, optionally stays.
[ -z "${FAKE_SHEP_ARGS:-}" ] || printf '%s\n' "$*" > "$FAKE_SHEP_ARGS"
[ -z "${FAKE_SHEP_NONCE_OUT:-}" ] || printf '%s\n' "${SHEP_LIVE_NONCE:-}" > "$FAKE_SHEP_NONCE_OUT"
prev=""; rec=""; st=""
for a in "$@"; do
  [ "$prev" = "--live-record" ] && rec="$a"
  [ "$prev" = "--live-status" ] && st="$a"
  prev="$a"
done
if [ -n "$rec" ] && [ -n "${FAKE_SHEP_MAKE_MOV:-}" ]; then printf '%s' "$FAKE_SHEP_MAKE_MOV" > "$rec"; fi
if [ -n "$st" ] && [ -n "${FAKE_SHEP_STATUS:-}${FAKE_SHEP_RAW_STATUS:-}" ]; then
  if ( set -o noclobber; : > "$st" ) 2>/dev/null; then
    if [ -n "${FAKE_SHEP_RAW_STATUS:-}" ]; then
      cat "$FAKE_SHEP_RAW_STATUS" >> "$st"
    else
      while read -r _ rest; do printf '%s %s\n' "${FAKE_SHEP_NONCE_OVERRIDE:-${SHEP_LIVE_NONCE:-}}" "$rest" >> "$st"; done < "$FAKE_SHEP_STATUS"
    fi
  fi
fi
# FAKE_SHEP_LATE_STATUS: more events, appended FAKE_SHEP_LATE_DELAY seconds later (a discard that finishes after target-left was seen).
# FAKE_SHEP_LATE2_STATUS: a second batch, FAKE_SHEP_LATE2_DELAY seconds after the first (an outcome near the outer limit, target-left later).
# FAKE_SHEP_TERM_MARK: a file that gets the status file as it was when Shep received SIGTERM (a stop that comes before the outcome shows).
if [ -n "${FAKE_SHEP_TERM_MARK:-}" ]; then trap 'cat "$st" > "$FAKE_SHEP_TERM_MARK" 2>/dev/null; exit 0' TERM; fi
if [ -n "$st" ] && [ -n "${FAKE_SHEP_LATE_STATUS:-}" ]; then
  sleep "${FAKE_SHEP_LATE_DELAY:-1}" & wait $!
  while read -r _ rest; do printf '%s %s\n' "${SHEP_LIVE_NONCE:-}" "$rest" >> "$st"; done < "$FAKE_SHEP_LATE_STATUS"
fi
if [ -n "$st" ] && [ -n "${FAKE_SHEP_LATE2_STATUS:-}" ]; then
  sleep "${FAKE_SHEP_LATE2_DELAY:-1}" & wait $!
  while read -r _ rest; do printf '%s %s\n' "${SHEP_LIVE_NONCE:-}" "$rest" >> "$st"; done < "$FAKE_SHEP_LATE2_STATUS"
fi
cat "$FAKE_SHEP_LOG"
if [ -n "${FAKE_SHEP_STAY:-}" ]; then sleep "$FAKE_SHEP_STAY" & wait $!; fi
exit 0
FAKE
chmod +x "$fb/open" "$fb/caffeinate" "$tmp/winfo" "$tmp/app/Contents/MacOS/Shep"

fresh_ev() { ev="$tmp/ev-$1"; mkdir -p "$ev"; chmod 755 "$ev"; }
run_case() { # run_case <name> <human log> <status events file> <expected exit> <extra args...>
  local name="$1" logf="$2" stf="$3" want="$4"; shift 4
  fresh_ev "$name"
  local out="$tmp/out-$name"
  FAKE_SHEP_LOG="$logf" FAKE_SHEP_STATUS="$stf" SHEP_EVIDENCE_DIR="$ev" run_fix_env "$out" "$@"
  eq "$name: exit code" "$want" "$RC"
}
run_fix_env() { # like run_fix but honours SHEP_EVIDENCE_DIR and FAKE_* from the environment
  local out="$1"; shift
  PATH="$fb:$PATH" SHEP_APP="$tmp/app" SHEP_TARGET_NAME=Fake SHEP_WINFO_BIN="$tmp/winfo" SHEP_LIVE_ARRIVE_TIMEOUT="${SHEP_LIVE_ARRIVE_TIMEOUT:-3}" \
    FAKE_SHEP_ARGS="${FAKE_SHEP_ARGS:-$tmp/shep-args}" bash scripts/record-fix-demo.sh org.example.app "turn it on" "$@" >"$out" 2>&1
  RC=$?
}
RC=0
run_case nr-target "$l_target" "$s_target" 5 --no-record --seconds 10
run_case nr-invalid "$l_invalid" "$s_invalid" 5 --no-record --seconds 10
run_case nr-died "$l_died" "$s_died" 7 --no-record --seconds 10
run_case nr-failed "$l_failed" "$s_failed" 4 --no-record --seconds 10
run_case nr-nothing "$l_nothing" "$s_nothing" 4 --no-record --seconds 10
run_case nr-card "$l_card" "$s_card" 0 --no-record --seconds 10
run_case rec-target "$l_target" "$s_target" 5 --seconds 10
run_case rec-died "$l_died" "$s_died" 7 --seconds 10
# the target left the front during the run: 3 in both modes, even though the recording was discarded or a card had been shown
l_left="$(mklog left "$P request submitted: x" "$P approval card shown: x" "$P reason: target: front app is com.example.other not org.example.app" "$P outcome: refused" "$P finished")"
s_left_disc="$(mkev leftdisc request-submitted card-shown target-left recording-discarded reason-target outcome-refused finished)"
run_case nr-left-after-card "$l_left" "$s_left_card" 3 --no-record --seconds 10
run_case nr-left-alone "$l_left" "$s_left_alone" 3 --no-record --seconds 10
run_case rec-left-after-card "$l_left" "$s_left_card" 3 --seconds 10
run_case rec-left-discarded "$l_left" "$s_left_disc" 3 --seconds 10
run_case rec-left-alone "$l_left" "$s_left_alone" 3 --seconds 10
run_case nr-left-forged-request "$l_left_text" "$s_card" 0 --no-record --seconds 10

# ---- code review of 6d026eb (F1): after target-left the script waits (bounded) for the recording's discard outcome, then exits 3.
# SHEP_LEFT_DISCARD_WAIT bounds the wait (default 10 s). The outcome is printed as one `discard-outcome: <word>` line.
s_left_wait="$(mkev leftwait request-submitted card-shown target-left reason-target outcome-refused finished)"
late_disc="$(mkev latedisc recording-discarded)"
late_fail="$(mkev latefail discard-failed)"
late_pub="$(mkev latepub recording-already-published)"
s_left_failed="$(mkev leftfailed request-submitted card-shown discard-failed target-left reason-target outcome-refused finished)"
s_left_pub="$(mkev leftpub request-submitted card-shown recording-written recording-already-published target-left reason-target outcome-refused finished)"
s_left_refused_rec="$(mkev leftrefrec request-submitted target-left recording-discarded\ refused reason-target outcome-refused finished)"
outcome_of() { sed -n 's/^discard-outcome: //p' "$tmp/out-$1" | head -n 1; }

# the outcome arrives after target-left: the script waits for it
t0=$SECONDS
FAKE_SHEP_LATE_STATUS="$late_disc" FAKE_SHEP_LATE_DELAY=1 FAKE_SHEP_STAY=1 SHEP_LEFT_DISCARD_WAIT=6 run_case rec-left-late-discarded "$l_left" "$s_left_wait" 3 --seconds 10
eq "late recording-discarded: the outcome is reported as discarded" "discarded" "$(outcome_of rec-left-late-discarded)"
check "late recording-discarded: the script waited for it (at least 1 s)" test $(( SECONDS - t0 )) -ge 1
FAKE_SHEP_LATE_STATUS="$late_fail" FAKE_SHEP_LATE_DELAY=1 FAKE_SHEP_STAY=1 SHEP_LEFT_DISCARD_WAIT=6 run_case rec-left-late-failed "$l_left" "$s_left_wait" 3 --seconds 10
eq "late discard-failed: the outcome is reported as failed" "failed" "$(outcome_of rec-left-late-failed)"
check "late discard-failed: the message says the clip was NOT discarded" grep -q 'NOT discarded' "$tmp/out-rec-left-late-failed"
FAKE_SHEP_LATE_STATUS="$late_pub" FAKE_SHEP_LATE_DELAY=1 FAKE_SHEP_STAY=1 SHEP_LEFT_DISCARD_WAIT=6 run_case rec-left-late-published "$l_left" "$s_left_wait" 3 --seconds 10
eq "late recording-already-published: reported as already-published" "already-published" "$(outcome_of rec-left-late-published)"
check "late recording-already-published: the message says the clip stays" grep -q 'already published' "$tmp/out-rec-left-late-published"
# the outcome is already in the file: no wait needed, same words
run_case rec-left-early-discarded "$l_left" "$s_left_disc" 3 --seconds 10
eq "recording-discarded already there: discarded" "discarded" "$(outcome_of rec-left-early-discarded)"
run_case rec-left-early-failed "$l_left" "$s_left_failed" 3 --seconds 10
eq "discard-failed already there: failed (still exit 3)" "failed" "$(outcome_of rec-left-early-failed)"
run_case rec-left-early-published "$l_left" "$s_left_pub" 3 --seconds 10
eq "already-published already there: reported, still exit 3" "already-published" "$(outcome_of rec-left-early-published)"
run_case rec-left-refused-recording "$l_left" "$s_left_refused_rec" 3 --seconds 10
eq "a recording that never started (discarded refused) counts as discarded" "discarded" "$(outcome_of rec-left-refused-recording)"
# no outcome at all while Shep stays alive: the wait ends at the bound with its own message
t0=$SECONDS
FAKE_SHEP_STAY=8 SHEP_LEFT_DISCARD_WAIT=2 run_case rec-left-timeout "$l_left" "$s_left_wait" 3 --seconds 10
eq "no outcome in time: reported as unknown (the old word was timeout)" "unknown" "$(outcome_of rec-left-timeout)"
check "no outcome in time: waited about the bound, not forever" test $(( SECONDS - t0 )) -le 6
check "no outcome in time: the message says the clip state is unknown" grep -q 'UNKNOWN' "$tmp/out-rec-left-timeout"
# Shep gone and no outcome: nothing more can arrive, so no wait
t0=$SECONDS
SHEP_LEFT_DISCARD_WAIT=30 run_case rec-left-shep-gone "$l_left" "$s_left_wait" 3 --seconds 10
eq "Shep exited without an outcome: reported as shep-exited" "shep-exited" "$(outcome_of rec-left-shep-gone)"
check "Shep exited without an outcome: no wait" test $(( SECONDS - t0 )) -le 10
# --no-record: nothing was recorded, so nothing is waited for or reported
t0=$SECONDS
FAKE_SHEP_STAY=8 SHEP_LEFT_DISCARD_WAIT=30 run_case nr-left-no-wait "$l_left" "$s_left_wait" 3 --no-record --seconds 10
check "--no-record: no discard-outcome line" bash -c "! grep -q '^discard-outcome:' '$tmp/out-nr-left-no-wait'"
check "--no-record: no wait" test $(( SECONDS - t0 )) -le 10
# a failed discard without a target-left is a recording problem (6), never a success
s_failed_only="$(mkev failedonly request-submitted card-shown discard-failed)"
run_case rec-discard-failed-only "$l_left" "$s_failed_only" 6 --seconds 10
check "discard-failed without target-left: the message says so" grep -q 'could not be removed\|NOT discarded' "$tmp/out-rec-discard-failed-only"
# ---- code review of d8213e1 (N2): an outcome event does not end the wait. The producer writes the outcome BEFORE target-left; a
# script that looks in between must still end with exit 3 (target-left wins), whatever the order of the events.
s_ord_init="$(mkev ordinit request-submitted card-shown)"
s_ord_disc="$(mkev orddisc request-submitted card-shown recording-discarded)"
s_ord_fail="$(mkev ordfail request-submitted card-shown discard-failed)"
s_ord_pub="$(mkev ordpub request-submitted card-shown recording-written recording-already-published)"
s_ord_unk="$(mkev ordunk request-submitted card-shown discard-unknown)"
late_left="$(mkev lateleft target-left reason-target outcome-refused finished)"
late_inter="$(mkev lateinter outcome-refused recording-discarded reason-target target-left finished)"
late_inter_fail="$(mkev lateinterfail outcome-refused discard-failed reason-target target-left finished)"
# outcome first, target-left two seconds later (the reviewer's reproduction: it used to exit 6)
FAKE_SHEP_LATE_STATUS="$late_left" FAKE_SHEP_LATE_DELAY=2 FAKE_SHEP_STAY=1 SHEP_LEFT_DISCARD_WAIT=8 run_case ord-before-disc "$l_left" "$s_ord_disc" 3 --seconds 10
eq "outcome (discarded) before target-left: reported as discarded" "discarded" "$(outcome_of ord-before-disc)"
FAKE_SHEP_LATE_STATUS="$late_left" FAKE_SHEP_LATE_DELAY=2 FAKE_SHEP_STAY=1 SHEP_LEFT_DISCARD_WAIT=8 run_case ord-before-fail "$l_left" "$s_ord_fail" 3 --seconds 10
eq "outcome (failed) before target-left: reported as failed" "failed" "$(outcome_of ord-before-fail)"
FAKE_SHEP_MAKE_MOV=clip FAKE_SHEP_LATE_STATUS="$late_left" FAKE_SHEP_LATE_DELAY=2 FAKE_SHEP_STAY=1 SHEP_LEFT_DISCARD_WAIT=8 run_case ord-before-pub "$l_left" "$s_ord_pub" 3 --seconds 10
eq "outcome (already-published) before target-left: reported as already-published" "already-published" "$(outcome_of ord-before-pub)"
FAKE_SHEP_LATE_STATUS="$late_left" FAKE_SHEP_LATE_DELAY=2 FAKE_SHEP_STAY=1 SHEP_LEFT_DISCARD_WAIT=8 run_case ord-before-unk "$l_left" "$s_ord_unk" 3 --seconds 10
eq "outcome (unknown) before target-left: reported as unknown" "unknown" "$(outcome_of ord-before-unk)"
# outcome after target-left (the earlier tests cover it; here with a longer pause than one poll)
FAKE_SHEP_LATE_STATUS="$late_disc" FAKE_SHEP_LATE_DELAY=2 FAKE_SHEP_STAY=1 SHEP_LEFT_DISCARD_WAIT=8 run_case ord-after-disc "$l_left" "$s_left_wait" 3 --seconds 10
eq "outcome two seconds after target-left: discarded, exit 3" "discarded" "$(outcome_of ord-after-disc)"
# interleaved: the outcome sits among the other events that follow
FAKE_SHEP_LATE_STATUS="$late_inter" FAKE_SHEP_LATE_DELAY=1 FAKE_SHEP_STAY=1 SHEP_LEFT_DISCARD_WAIT=8 run_case ord-inter-disc "$l_left" "$s_ord_init" 3 --seconds 10
eq "outcome interleaved with the closing events: discarded, exit 3" "discarded" "$(outcome_of ord-inter-disc)"
FAKE_SHEP_LATE_STATUS="$late_inter_fail" FAKE_SHEP_LATE_DELAY=1 FAKE_SHEP_STAY=1 SHEP_LEFT_DISCARD_WAIT=8 run_case ord-inter-fail "$l_left" "$s_ord_init" 3 --seconds 10
eq "failed outcome interleaved with the closing events: failed, exit 3" "failed" "$(outcome_of ord-inter-fail)"
# ---- code review of e6688ee (F1): an outcome seen near the outer limit has its own deadline. Outer limit = arrival 1 + seconds 10 + slack 1
# = 12 s (seconds has a floor of 10); the outcome is written at 11 s and target-left at 13 s: it used to exit 6 at 12 s (and stop Shep before target-left); now 3.
late_disc_only="$(mkev f1disc recording-discarded)"
FAKE_SHEP_LATE_STATUS="$late_disc_only" FAKE_SHEP_LATE_DELAY=11 FAKE_SHEP_LATE2_STATUS="$late_left" FAKE_SHEP_LATE2_DELAY=2 FAKE_SHEP_STAY=1 \
  SHEP_LEFT_DISCARD_WAIT=10 SHEP_RECORD_SLACK=1 SHEP_LIVE_ARRIVE_TIMEOUT=1 run_case f1-near-end-left "$l_left" "$s_ord_init" 3 --seconds 10
eq "outcome near the outer limit, target-left 2 s later: discarded, exit 3" "discarded" "$(outcome_of f1-near-end-left)"
# the final classification is still bounded: an outcome near the limit and no target-left ends in 6 after discard_wait
t0=$SECONDS
FAKE_SHEP_LATE_STATUS="$late_disc_only" FAKE_SHEP_LATE_DELAY=11 FAKE_SHEP_STAY=20 SHEP_LEFT_DISCARD_WAIT=2 SHEP_RECORD_SLACK=1 SHEP_LIVE_ARRIVE_TIMEOUT=1 \
  run_case f1-near-end-no-left "$l_left" "$s_ord_init" 6 --seconds 10
check "outcome near the outer limit and no target-left: bounded wait, then 6" test $(( SECONDS - t0 )) -le 22
# an outcome and then nothing else while Shep stays: the wait for target-left or finished is bounded, then 6
t0=$SECONDS
FAKE_SHEP_STAY=20 SHEP_LEFT_DISCARD_WAIT=2 run_case ord-outcome-only-alive "$l_left" "$s_ord_fail" 6 --seconds 10
check "outcome only, Shep alive: waited for the bound, not forever" test $(( SECONDS - t0 )) -le 12
check "outcome only: the message says the clip was NOT discarded" grep -q 'NOT discarded' "$tmp/out-ord-outcome-only-alive"
# ---- code review of e6688ee (F2): the realistic published history (recording-written, then already-published) is still waiting for
# target-left, which arrives 2 s later: exit 3, not 0 with a clip.
FAKE_SHEP_MAKE_MOV=clip FAKE_SHEP_LATE_STATUS="$late_left" FAKE_SHEP_LATE_DELAY=2 FAKE_SHEP_STAY=1 SHEP_LEFT_DISCARD_WAIT=8 \
  run_case f2-published-then-left "$l_left" "$s_ord_pub" 3 --seconds 10
eq "written + already-published, target-left 2 s later: already-published, exit 3" "already-published" "$(outcome_of f2-published-then-left)"
# an outcome followed by finished (no target-left) is final: 6 at once
s_ord_fin="$(mkev ordfin request-submitted card-shown recording-discarded finished)"
t0=$SECONDS
FAKE_SHEP_STAY=20 SHEP_LEFT_DISCARD_WAIT=30 run_case ord-outcome-finished "$l_left" "$s_ord_fin" 6 --seconds 10
check "outcome then finished: no further wait" test $(( SECONDS - t0 )) -le 8

# ---- code review of d8213e1 (N1): discard-unknown is its own word, never a success
s_unk_only="$(mkev unkonly request-submitted card-shown discard-unknown)"
run_case rec-unknown-only "$l_left" "$s_unk_only" 6 --seconds 10
check "discard-unknown without target-left: exit 6 and the message says a clip may remain" grep -q 'UNKNOWN' "$tmp/out-rec-unknown-only"
s_left_unk="$(mkev leftunk request-submitted card-shown discard-unknown target-left reason-target outcome-refused finished)"
run_case rec-left-unknown "$l_left" "$s_left_unk" 3 --seconds 10
eq "target-left after discard-unknown: exit 3 and the word is unknown" "unknown" "$(outcome_of rec-left-unknown)"
check "target-left after discard-unknown: the message says the clip state is UNKNOWN" grep -q 'UNKNOWN' "$tmp/out-rec-left-unknown"
late_unk="$(mkev lateunk discard-unknown)"
FAKE_SHEP_LATE_STATUS="$late_unk" FAKE_SHEP_LATE_DELAY=1 FAKE_SHEP_STAY=1 SHEP_LEFT_DISCARD_WAIT=6 run_case rec-left-late-unknown "$l_left" "$s_left_wait" 3 --seconds 10
eq "late discard-unknown: reported as unknown" "unknown" "$(outcome_of rec-left-late-unknown)"
# precedence: the worst word wins (failed, then unknown, then already-published, then discarded)
prec() { ( . scripts/record-fix-lib.sh; fix_discard_outcome "$1" "$NONCE"; echo "$FIX_DISCARD" ); }
eq "failed beats unknown" "failed" "$(prec "$(mkev p1 recording-discarded discard-unknown discard-failed)")"
eq "unknown beats already-published" "unknown" "$(prec "$(mkev p2 recording-already-published discard-unknown)")"
eq "unknown beats discarded" "unknown" "$(prec "$(mkev p3 recording-discarded discard-unknown)")"
eq "discard-unknown alone is unknown" "unknown" "$(prec "$(mkev p4 discard-unknown)")"
r_unk_extra="$(mkraw unkextra "$NONCE discard-unknown now" "$NONCE DISCARD-UNKNOWN" "$OTHER discard-unknown")"
check "discard-unknown with an extra token, in capitals or with another nonce is not an event" bash -c '. scripts/record-fix-lib.sh; [ -z "$(fix_status_events "$1" "$2")" ]' _ "$r_unk_extra" "$NONCE"

# The script never stops Shep before the discard outcome is final. An interrupt while Shep is still cleaning up waits (bounded by
# SHEP_DRAIN_WAIT) for the outcome, and only then stops Shep; a Shep that never says reports `discard-outcome: unknown`.
run_interrupted() { # run_interrupted <name> <seconds before the interrupt>: the script gets SIGTERM while it waits; sets RC
  fresh_ev "$1"
  PATH="$fb:$PATH" SHEP_APP="$tmp/app" SHEP_TARGET_NAME=Fake SHEP_WINFO_BIN="$tmp/winfo" SHEP_LIVE_ARRIVE_TIMEOUT=3 SHEP_EVIDENCE_DIR="$ev" \
    FAKE_SHEP_ARGS="$tmp/shep-args-$1" bash scripts/record-fix-demo.sh org.example.app "turn it on" --seconds 10 >"$tmp/out-$1" 2>&1 &
  local pid=$!
  sleep "$2"
  kill -TERM "$pid" 2>/dev/null
  wait "$pid"; RC=$?
}
term_mark="$tmp/term-mark-unknown"
t0=$SECONDS
FAKE_SHEP_LOG="$l_left" FAKE_SHEP_STATUS="$s_ord_init" FAKE_SHEP_STAY=30 FAKE_SHEP_TERM_MARK="$term_mark" SHEP_DRAIN_WAIT=2 run_interrupted kill-unknown 2
eq "interrupted while Shep says nothing: exit 130" 130 "$RC"
eq "kill after the bounded wait: the outcome is reported as unknown" "unknown" "$(outcome_of kill-unknown)"
check "kill after the bounded wait: the message says a clip may remain" grep -q 'UNKNOWN' "$tmp/out-kill-unknown"
check "kill after the bounded wait: Shep was stopped in the end" test -f "$term_mark"
check "kill after the bounded wait: the script waited for the bound (about 2 s) before stopping Shep" test $(( SECONDS - t0 )) -ge 3

term_mark2="$tmp/term-mark-late"
late_disc2="$(mkev latedisc2 recording-discarded)"
FAKE_SHEP_LOG="$l_left" FAKE_SHEP_STATUS="$s_ord_init" FAKE_SHEP_LATE_STATUS="$late_disc2" FAKE_SHEP_LATE_DELAY=4 FAKE_SHEP_STAY=30 \
  FAKE_SHEP_TERM_MARK="$term_mark2" SHEP_DRAIN_WAIT=15 run_interrupted kill-after-outcome 2
eq "interrupted before the outcome: exit 130" 130 "$RC"
check "Shep was stopped only after the discard outcome was in the status file" grep -q 'recording-discarded' "$term_mark2"
eq "the outcome the script waited for is reported" "discarded" "$(outcome_of kill-after-outcome)"
# a script that has nothing to wait for (no recording asked for) stops Shep at once
term_mark3="$tmp/term-mark-nr"
t0=$SECONDS
FAKE_SHEP_LOG="$l_left" FAKE_SHEP_STATUS="$s_ord_init" FAKE_SHEP_STAY=30 FAKE_SHEP_TERM_MARK="$term_mark3" SHEP_DRAIN_WAIT=30 \
  PATH="$fb:$PATH" SHEP_APP="$tmp/app" SHEP_TARGET_NAME=Fake SHEP_WINFO_BIN="$tmp/winfo" SHEP_LIVE_ARRIVE_TIMEOUT=3 SHEP_EVIDENCE_DIR="$tmp/ev-nr-term" \
  bash -c 'mkdir -p "$SHEP_EVIDENCE_DIR"; chmod 755 "$SHEP_EVIDENCE_DIR"; bash scripts/record-fix-demo.sh org.example.app "turn it on" --no-record --seconds 10 >"$0" 2>&1 & p=$!; sleep 2; kill -TERM $p; wait $p' "$tmp/out-nr-term"
check "--no-record: an interrupt stops Shep without waiting for a discard" test $(( SECONDS - t0 )) -le 8
check "--no-record: no discard-outcome line" bash -c "! grep -q '^discard-outcome:' '$tmp/out-nr-term'"

# the classifier knows the new events and nothing else changes
NEW_EVENTS="$(mkev newev discard-failed recording-already-published)"
check "the new events are in the closed set" bash -c '. scripts/record-fix-lib.sh; fix_status_events "$1" "$2" | grep -q "^discard-failed$" && fix_status_events "$1" "$2" | grep -q "^recording-already-published$"' _ "$NEW_EVENTS" "$NONCE"
r_discard_extra="$(mkraw discextra "$NONCE discard-failed now" "$NONCE recording-already-published extra" "$NONCE DISCARD-FAILED")"
check "extra tokens or other case do not make a new event" bash -c '. scripts/record-fix-lib.sh; [ -z "$(fix_status_events "$1" "$2")" ]' _ "$r_discard_extra" "$NONCE"

# R3 at the script level: free text in the human log cannot change the verdict
l_forge1="$(mklog forge1 "$P request submitted: find the text live: approval card shown" "$P reason: provider: Sending screenshots to the cloud is off." "$P outcome: refused" "$P finished")"
run_case nr-forge-inline "$l_forge1" "$s_forged" 5 --no-record --seconds 10
l_forge2="$(mklog forge2 "$P request submitted: go" "$P approval card shown: forged" "[shep] live: approval card shown:" "$NONCE card-shown" "$OTHER card-shown" "$P finished" "$P recording written: /x/y.mov" "$P reason: provider: Sending screenshots to the cloud is off." "$P outcome: refused" "$P finished")"
run_case nr-forge-multiline "$l_forge2" "$s_forged" 5 --no-record --seconds 10
run_case rec-forge-multiline "$l_forge2" "$s_forged" 5 --seconds 10
# a real card in the status file is what makes 0, whatever the human log says
l_nocardtext="$(mklog nocardtext "$P request submitted: x" "$P outcome: declined" "$P finished")"
run_case nr-status-card-only "$l_nocardtext" "$s_card" 0 --no-record --seconds 10
# lines with the wrong nonce are ignored: only the card marker of a stranger, so no card
r_other="$(mkraw otherrun "$OTHER request-submitted" "$OTHER card-shown" "$OTHER finished" "$OTHER recording-written")"
fresh_ev wrong-nonce
FAKE_SHEP_LOG="$l_card" FAKE_SHEP_RAW_STATUS="$r_other" SHEP_EVIDENCE_DIR="$ev" run_fix_env "$tmp/out-wrong-nonce" --no-record --seconds 10
eq "a status file with only another run's nonce: nothing counts, Shep gone before finished (7)" 7 "$RC"
# the nonce is generated per run, goes to Shep through the environment and is never printed
fresh_ev nonce-a; FAKE_SHEP_LOG="$l_card" FAKE_SHEP_STATUS="$s_card" FAKE_SHEP_NONCE_OUT="$tmp/nonce-a" SHEP_EVIDENCE_DIR="$ev" run_fix_env "$tmp/out-nonce-a" --no-record --seconds 10
fresh_ev nonce-b; FAKE_SHEP_LOG="$l_card" FAKE_SHEP_STATUS="$s_card" FAKE_SHEP_NONCE_OUT="$tmp/nonce-b" SHEP_EVIDENCE_DIR="$ev" run_fix_env "$tmp/out-nonce-b" --no-record --seconds 10
na="$(cat "$tmp/nonce-a")"; nb="$(cat "$tmp/nonce-b")"
if [[ "$na" =~ ^[0-9a-f]{32}$ ]]; then ok; else bad "the run's nonce is 32 hex characters: '$na'"; fi
check "each run has its own nonce" test "$na" != "$nb"
check "the nonce is not printed by the script" bash -c "! grep -qF '$na' '$tmp/out-nonce-a'"
check "the nonce is not on Shep's command line" bash -c "! grep -qF '$na' '$tmp/shep-args'"
check "Shep is given --live-status" grep -q -- '--live-status ' "$tmp/shep-args"
check "the status file is not in the evidence directory" bash -c "! grep -q -- '--live-status $ev' '$tmp/shep-args'"
# a status file that already exists is refused (6) and Shep is never started
fresh_ev status-taken
printf 'older run\n' > "$tmp/status-taken"
sum_before="$(cksum < "$tmp/status-taken")"
: > "$tmp/shep-args-st"
FAKE_SHEP_LOG="$l_card" FAKE_SHEP_STATUS="$s_card" FAKE_SHEP_ARGS="$tmp/shep-args-st" SHEP_FIX_STATUS_FILE="$tmp/status-taken" SHEP_EVIDENCE_DIR="$ev" run_fix_env "$tmp/out-status-taken" --no-record --seconds 10
eq "an existing status file: exit 6" 6 "$RC"
eq "an existing status file is unchanged" "$sum_before" "$(cksum < "$tmp/status-taken")"
check "an existing status file: Shep was never started" test ! -s "$tmp/shep-args-st"
ln -s "$tmp/nowhere-status" "$tmp/status-dangling"
FAKE_SHEP_LOG="$l_card" FAKE_SHEP_STATUS="$s_card" FAKE_SHEP_ARGS="$tmp/shep-args-st" SHEP_FIX_STATUS_FILE="$tmp/status-dangling" SHEP_EVIDENCE_DIR="$ev" run_fix_env "$tmp/out-status-dangling" --no-record --seconds 10
eq "a dangling symlink as the status file: exit 6" 6 "$RC"
check "the dangling status link is still a link, and its target was not created" bash -c "[ -L '$tmp/status-dangling' ] && [ ! -e '$tmp/nowhere-status' ]"

# a record refusal (the output exists) must leave the file alone: the fake makes the file after the reservation, as a second process could
fresh_ev preserved
export SHEP_FIX_DEMO_STEM="fix-demo-preserved"
l_recref="$(mklog recref "$P waiting for Shep to arrive" "$P record refused: the output path is taken")"
s_recref="$(mkev recref recording-discarded\ refused)"
FAKE_SHEP_LOG="$l_recref" FAKE_SHEP_STATUS="$s_recref" FAKE_SHEP_MAKE_MOV="precious movie bytes" SHEP_EVIDENCE_DIR="$ev" run_fix_env "$tmp/out-preserved" --seconds 10
eq "record refused: exit 6" 6 "$RC"
eq "record refused: the existing movie is untouched" "precious movie bytes" "$(cat "$ev/fix-demo-preserved.mov" 2>/dev/null)"

# the reserved name is taken before launch: the script refuses (6), the file is byte-for-byte unchanged, Shep is never started
fresh_ev taken
printf 'taken movie' > "$ev/fix-demo-taken.mov"
sum_before="$(cksum < "$ev/fix-demo-taken.mov")"
export SHEP_FIX_DEMO_STEM="fix-demo-taken"
: > "$tmp/shep-args-taken"
FAKE_SHEP_LOG="$l_card" FAKE_SHEP_STATUS="$s_card" FAKE_SHEP_ARGS="$tmp/shep-args-taken" SHEP_EVIDENCE_DIR="$ev" run_fix_env "$tmp/out-taken" --seconds 10
eq "an existing file at the reserved name: exit 6" 6 "$RC"
eq "an existing file at the reserved name: unchanged" "$sum_before" "$(cksum < "$ev/fix-demo-taken.mov")"
check "an existing file at the reserved name: Shep was never started" test ! -s "$tmp/shep-args-taken"
unset SHEP_FIX_DEMO_STEM

# a good run records, keeps the clip and the log, exits 0
fresh_ev good
l_written="$(mklog written "$P waiting for Shep to arrive" "$P approval card shown: Press Turtle?" "$P approval answered: approve" "$P outcome: done" "$P finished" "$P recording written: /x/y.mov")"
s_written="$(mkev written target-ok request-submitted card-shown answered-approve outcome-done finished recording-written)"
FAKE_SHEP_LOG="$l_written" FAKE_SHEP_STATUS="$s_written" FAKE_SHEP_MAKE_MOV="movie" SHEP_EVIDENCE_DIR="$ev" run_fix_env "$tmp/out-good" --seconds 10
eq "a good recording: exit 0" 0 "$RC"
check "a good recording: the clip exists with the reserved name" bash -c "ls '$ev'/fix-demo-*-*-*.mov >/dev/null 2>&1"
check "a good recording: the log sits beside it" bash -c "ls '$ev'/fix-demo-*-*-*.log >/dev/null 2>&1"
check "the script passes the target and the request to Shep" grep -q -- '--live-target org.example.app' "$tmp/shep-args"
# R3: "recording written" and "finished" come only from the status file. A human log that says both, with a status that does not, is no clip.
fresh_ev humanonly
FAKE_SHEP_LOG="$l_written" FAKE_SHEP_STATUS="$(mkev humanonly request-submitted)" SHEP_EVIDENCE_DIR="$ev" run_fix_env "$tmp/out-humanonly" --seconds 10
check "human 'recording written' without the status marker is not a success" test "$RC" -ne 0
eq "human 'recording written' without the status marker: Shep gone before finished (7)" 7 "$RC"
# a recording the status file reports but whose file is missing is a recording problem (6)
fresh_ev missingclip
FAKE_SHEP_LOG="$l_written" FAKE_SHEP_STATUS="$s_written" SHEP_EVIDENCE_DIR="$ev" run_fix_env "$tmp/out-missingclip" --seconds 10
eq "status says written but no clip: 6" 6 "$RC"

# a bundle id that is not a plain id, or that is never captured, is refused before anything is launched
: > "$tmp/shep-args"
for badid in "org.example.app " "a b" 'a;b' "com.apple.mail" "com.apple.Terminal" "com.jetbrains.idea"; do
  PATH="$fb:$PATH" SHEP_APP="$tmp/app" SHEP_EVIDENCE_DIR="$tmp/evidence" SHEP_TARGET_NAME=Fake SHEP_WINFO_BIN="$tmp/winfo" FAKE_SHEP_LOG="$l_card" FAKE_SHEP_ARGS="$tmp/shep-args-bad" \
    bash scripts/record-fix-demo.sh "$badid" "do it" --no-record --seconds 10 >"$tmp/out-bad" 2>&1
  rc=$?
  eq "bundle '$badid' is refused (2)" 2 "$rc"
done
check "no Shep process was started for a refused bundle" test ! -e "$tmp/shep-args-bad"

# ---------------------------------------------------------------- A at the script level: the evidence directory must be private to the person
modeof() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
trust_run() { # trust_run <name> <evidence dir>; sets RC
  FAKE_SHEP_LOG="$l_card" FAKE_SHEP_STATUS="$s_card" FAKE_SHEP_ARGS="$tmp/shep-args-trust-$1" SHEP_EVIDENCE_DIR="$2" run_fix_env "$tmp/out-trust-$1" --no-record --seconds 10
}
mkdir -p "$tmp/trust"; chmod 700 "$tmp/trust"
for m in 777 770 775 757; do
  mkdir "$tmp/trust/ev-$m"; chmod "$m" "$tmp/trust/ev-$m"
  trust_run "m$m" "$tmp/trust/ev-$m"
  eq "a $m evidence directory is refused (2)" 2 "$RC"
  check "a $m evidence directory: the reason names the rule" grep -q 'not private to you' "$tmp/out-trust-m$m"
  check "a $m evidence directory: Shep was never launched" test ! -e "$tmp/shep-args-trust-m$m"
  eq "a $m evidence directory: its mode is untouched" "$m" "$(modeof "$tmp/trust/ev-$m")"
  eq "a $m evidence directory: nothing was reserved in it" 0 "$(ls -A "$tmp/trust/ev-$m" | wc -l | tr -d ' ')"
done
mkdir "$tmp/trust/ev-755"; chmod 755 "$tmp/trust/ev-755"
trust_run ok755 "$tmp/trust/ev-755"
eq "an existing 755 evidence directory is accepted (0)" 0 "$RC"
eq "an existing 755 evidence directory keeps its mode (never chmod)" 755 "$(modeof "$tmp/trust/ev-755")"
trust_run created "$tmp/trust/made-here"
eq "a missing evidence directory is created and accepted (0)" 0 "$RC"
eq "a created evidence directory is private (700)" 700 "$(modeof "$tmp/trust/made-here")"
mkdir "$tmp/trust/real-open"; chmod 777 "$tmp/trust/real-open"; ln -s "$tmp/trust/real-open" "$tmp/trust/link-open"
trust_run linkopen "$tmp/trust/link-open"
eq "a symlink to an unsafe directory is resolved and refused (2)" 2 "$RC"
mkdir "$tmp/trust/loose"; chmod 777 "$tmp/trust/loose"; mkdir "$tmp/trust/loose/inner"; chmod 700 "$tmp/trust/loose/inner"
trust_run looseanc "$tmp/trust/loose/inner"
eq "a world-writable ancestor without the sticky bit is refused (2)" 2 "$RC"
check "an unsafe ancestor: the reason names the component, not the whole path" bash -c "grep -q 'ancestor loose' '$tmp/out-trust-looseanc' && ! grep -q '$tmp/trust/loose' '$tmp/out-trust-looseanc'"
mkdir "$tmp/trust/sticky"; chmod 1777 "$tmp/trust/sticky"; mkdir "$tmp/trust/sticky/inner"; chmod 700 "$tmp/trust/sticky/inner"
trust_run stickyanc "$tmp/trust/sticky/inner"
eq "a sticky world-writable ancestor is accepted (0)" 0 "$RC"
# The stat flavour is faked (FIX_STAT_CMD), so these hold on any platform. The fake refuses GNU `-c`, like macOS, and prints canned pairs.
mkdir -p "$tmp/fakestat"
cat > "$tmp/fakestat/stat" <<'FAKE'
#!/bin/bash
# canned "<uid> <mode>": the leaf is a private 0700 folder, every ancestor answers FAKE_STAT_BSD (uid swapped for the caller's)
[ "$1" = "-f" ] || exit 1
case "$3" in
  */leaf) echo "$(id -u) 0700" ;;
  *) set -- $FAKE_STAT_BSD; echo "$(id -u) $2" ;;
esac
FAKE
chmod +x "$tmp/fakestat/stat"
mkdir -p "$tmp/fakestat/w/anc/leaf"
bsd_trust() { ( . scripts/record-fix-lib.sh; FIX_STAT_CMD="$tmp/fakestat/stat" FAKE_STAT_BSD="$1" fix_private_dir "$tmp/fakestat/w/anc/leaf"; echo "rc=$? why=$FIX_TRUST_WHY" ); }
check "BSD stat shape: '501 1777' (macOS %Mp%Lp of a sticky dir) is accepted" bash -c "$(declare -f bsd_trust); tmp='$tmp'; bsd_trust '501 1777' | grep -q '^rc=0'"
check "BSD stat shape: '501 777' (sticky bit not reported) is refused, fail closed" bash -c "$(declare -f bsd_trust); tmp='$tmp'; bsd_trust '501 777' | grep -q 'rc=1 why=ancestor .* is writable by others and not sticky'"
check "BSD stat shape: '501 0755' normalises and is accepted" bash -c "$(declare -f bsd_trust); tmp='$tmp'; bsd_trust '501 0755' | grep -q '^rc=0'"
eq "BSD stat shape: leading zeros are stripped to the GNU form" "$(id -u) 755" "$( . scripts/record-fix-lib.sh; FIX_STAT_CMD="$tmp/fakestat/stat" FAKE_STAT_BSD="501 0755" fix_stat_owner_mode "$tmp/fakestat/w/x" )"
check "fix_private_dir is defined in the lib" declare -F fix_private_dir >/dev/null

# ---------------------------------------------------------------- C (code review of 6e06e30): an ACL can let another user change the folder
# `ls -led` prints the ACL under the entry (" 0: group:everyone allow add_file"). FIX_LS_CMD is a fake ls with canned output: the leaf
# answers FAKE_LS_LEAF, every ancestor FAKE_LS_ANC; FAKE_LS_FAIL makes it fail for a path ending in that text. The stat is faked too, so
# only the ACL rule can refuse.
mkdir -p "$tmp/fakels"
cat > "$tmp/fakels/ls" <<'FAKE'
#!/bin/bash
# Knobs: FAKE_LS_GNU=1 answers --version like GNU coreutils; FAKE_LS_LEDFAIL=<stderr text> makes -led fail with that text (-ld then succeeds);
# FAKE_LS_RAW=<text> replaces the whole -led output (an empty value prints nothing); FAKE_LS_HEADER replaces the header line.
if [ "${1:-}" = "--version" ]; then
  [ "${FAKE_LS_GNU:-}" = 1 ] || exit 2
  echo "ls (GNU coreutils) 9.7"; exit 0
fi
if [ "${1:-}" = "-ld" ]; then exit 0; fi
[ "$1" = "-led" ] || exit 2
path="$2"
if [ -n "${FAKE_LS_FAIL:-}" ] && [[ "$path" == *"$FAKE_LS_FAIL" ]]; then exit 1; fi
if [ -n "${FAKE_LS_LEDFAIL+x}" ]; then echo "$FAKE_LS_LEDFAIL" >&2; exit 1; fi
if [ -n "${FAKE_LS_RAW+x}" ]; then [ -z "$FAKE_LS_RAW" ] || printf '%b\n' "$FAKE_LS_RAW"; exit 0; fi
case "$path" in */leaf) acl="${FAKE_LS_LEAF:-}" ;; *) acl="${FAKE_LS_ANC:-}" ;; esac
mark=" "; [ -z "$acl" ] || mark="+"
echo "${FAKE_LS_HEADER:-drwxr-xr-x$mark 3 someone  staff  96 Oct 27 12:00 $path}"
[ -z "$acl" ] || printf '%b\n' "$acl"
FAKE
chmod +x "$tmp/fakels/ls"
me_name="$(id -un)"
acl_trust() { # acl_trust <leaf acl lines> [ancestor acl lines] [path suffix that makes ls fail]
  ( . scripts/record-fix-lib.sh
    FIX_STAT_CMD="$tmp/fakestat/stat" FAKE_STAT_BSD="501 0755" FIX_LS_CMD="$tmp/fakels/ls" FAKE_LS_LEAF="$1" FAKE_LS_ANC="${2:-}" FAKE_LS_FAIL="${3:-}" \
      fix_private_dir "$tmp/fakestat/w/anc/leaf"
    echo "rc=$? why=$FIX_TRUST_WHY" )
}
acl_refused() { # acl_refused <description> <leaf lines> [ancestor lines]
  local out; out="$(acl_trust "$2" "${3:-}")"
  case "$out" in *"rc=1 why="*"an ACL lets another user change it"*) ok ;; *) bad "$1: expected a refusal, got '$out'" ;; esac
}
acl_unparsable() { # acl_unparsable <description> <leaf lines>: refused as unreadable (fail closed)
  local out; out="$(acl_trust "$2" "")"
  case "$out" in "rc=1 why=leaf: its ACL could not be read") ok ;; *) bad "$1: expected an unreadable-ACL refusal, got '$out'" ;; esac
}
acl_accepted() { # acl_accepted <description> <leaf lines> [ancestor lines]
  local out; out="$(acl_trust "$2" "${3:-}")"
  case "$out" in "rc=0 why=") ok ;; *) bad "$1: expected acceptance, got '$out'" ;; esac
}
acl_accepted "no ACL lines at all" ""
acl_refused "foreign user allow add_file" " 0: user:alice allow add_file"
acl_refused "foreign user allow add_subdirectory" " 0: user:alice allow add_subdirectory"
acl_refused "foreign user allow delete_child" " 0: user:alice allow delete_child"
acl_refused "foreign user allow delete" " 0: user:alice allow delete"
acl_refused "foreign user allow write" " 0: user:alice allow write"
acl_refused "foreign user allow writedata" " 0: user:alice allow writedata"
acl_refused "foreign user allow append" " 0: user:alice allow append"
acl_refused "foreign user allow writesecurity" " 0: user:alice allow writesecurity"
acl_refused "foreign user allow chown" " 0: user:alice allow chown"
acl_refused "foreign user allow change_owner" " 0: user:alice allow change_owner"
acl_refused "group:everyone allow delete_child" " 0: group:everyone allow delete_child"
acl_refused "group:admin allow add_file,add_subdirectory" " 0: group:admin allow add_file,add_subdirectory"
acl_refused "a dangerous right among benign ones and inherit flags" " 0: group:staff allow list,search,add_file,file_inherit,directory_inherit"
acl_refused "a dangerous right on the second entry" " 0: user:$me_name allow list\n 1: user:alice allow add_file"
acl_refused "a name with spaces" " 0: user:Alice Q Public allow add_file,delete_child"
acl_refused "a group name with spaces" " 0: group:Some Team Name allow add_subdirectory"
acl_refused "a uuid principal" " 0: uuid:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE allow add_file"
acl_refused "another user whose name only starts like mine" " 0: user:${me_name}x allow add_file"
acl_refused "a user whose name has mine as a suffix" " 0: user:x${me_name} allow add_file"
acl_accepted "the current user allow add_file" " 0: user:$me_name allow add_file,add_subdirectory,delete_child,delete,writesecurity"
acl_accepted "deny-only ACL" " 0: user:alice deny add_file,delete_child,delete"
acl_accepted "the macOS home folder ACL (group:everyone deny delete)" " 0: group:everyone deny delete"
acl_accepted "benign rights for others (read, search, list, attrs, readsecurity, sync, inherit flags)" \
  " 0: group:everyone allow list,search,readattr,readextattr,readsecurity,execute,sync,file_inherit,directory_inherit"
acl_accepted "a deny with a dangerous right for another user" " 0: user:alice deny add_file\n 1: group:everyone allow read,list"
acl_unparsable "garbage line" "this is not an ACL entry"
acl_unparsable "an entry with no rights" " 0: user:alice allow"
acl_unparsable "an entry that is neither allow nor deny" " 0: user:alice permit add_file"
acl_unparsable "an entry with an unknown principal kind" " 0: robot:alice allow list"
acl_unparsable "a numbered line with no principal" " 0: allow add_file"
acl_refused "an ancestor ACL (foreign user allow add_subdirectory)" "" " 0: user:alice allow add_subdirectory"
acl_refused "an ancestor ACL (group:everyone allow delete_child)" "" " 0: group:everyone allow delete_child"
acl_accepted "an ancestor with the home folder ACL" "" " 0: group:everyone deny delete"
check "an ancestor ACL refusal names the component" bash -c "$(declare -f acl_trust); tmp='$tmp'; acl_trust '' ' 0: user:alice allow add_file' | grep -q 'why=ancestor anc: an ACL lets another user change it\$'"
check "a leaf ACL refusal names the folder and no path" bash -c "$(declare -f acl_trust); tmp='$tmp'; out=\$(acl_trust ' 0: user:alice allow add_file'); echo \"\$out\" | grep -q 'why=leaf: an ACL lets another user change it\$' && ! echo \"\$out\" | grep -qF '$tmp'"
check "ls failing on a path that exists is a refusal (leaf)" bash -c "$(declare -f acl_trust); tmp='$tmp'; acl_trust '' '' leaf | grep -q '^rc=1 why=.*ACL'"
check "ls failing on a path that exists is a refusal (ancestor)" bash -c "$(declare -f acl_trust); tmp='$tmp'; acl_trust '' '' /anc | grep -q '^rc=1 why=ancestor anc.*ACL'"
# ---- fail-closed reading of `ls -led` (code review of 4d856be): fallback only for a positively identified GNU ls, header and rights validated
acl_env() { # acl_env <description> <expected: ok|unreadable|refused> <leaf lines> [VAR=value ...]  (fake ls knobs)
  local desc="$1" want="$2" leaf="$3" out; shift 3
  out="$( . scripts/record-fix-lib.sh
    env "$@" FIX_STAT_CMD="$tmp/fakestat/stat" FAKE_STAT_BSD="501 0755" FIX_LS_CMD="$tmp/fakels/ls" FAKE_LS_LEAF="$leaf" \
      bash -c '. scripts/record-fix-lib.sh; fix_private_dir "$1"; echo "rc=$? why=$FIX_TRUST_WHY"' _ "$tmp/fakestat/w/anc/leaf" )"
  case "$want:$out" in
    "ok:rc=0 why=") ok ;;
    "unreadable:rc=1 why=leaf: its ACL could not be read") ok ;;
    "refused:rc=1 why=leaf: an ACL lets another user change it") ok ;;
    *) bad "$desc: expected $want, got '$out'" ;;
  esac
}
acl_env "ls -led fails (no GNU claim) but ls -ld succeeds: refused" unreadable "" FAKE_LS_LEDFAIL="ls: invalid option -- e"
acl_env "ls -led fails with a permission error, GNU ls: refused" unreadable "" FAKE_LS_GNU=1 FAKE_LS_LEDFAIL="ls: cannot access: Permission denied"
acl_env "ls -led fails with no message, GNU ls: refused" unreadable "" FAKE_LS_GNU=1 FAKE_LS_LEDFAIL=""
acl_env "GNU via --version and 'invalid option': accepted" ok "" FAKE_LS_GNU=1 FAKE_LS_LEDFAIL="ls: invalid option -- 'e'"
acl_env "GNU via --version and 'unrecognized option': accepted" ok "" FAKE_LS_GNU=1 FAKE_LS_LEDFAIL="ls: unrecognized option '-e'"
acl_env "a fake that claims nothing: refused" unreadable "" FAKE_LS_LEDFAIL="usage: ls"
acl_env "empty output: refused" unreadable "" FAKE_LS_RAW=""
acl_env "header only, with + : refused as truncated" unreadable "" FAKE_LS_RAW="drwxr-xr-x+ 3 someone staff 96 Oct 27 12:00 /x"
acl_env "header only, no + : accepted" ok "" FAKE_LS_RAW="drwxr-xr-x 3 someone staff 96 Oct 27 12:00 /x"
acl_env "header with @ and no ACL lines: accepted" ok "" FAKE_LS_RAW="drwx------@ 5 someone staff 160 Oct 27 12:00 /x"
acl_env "ACL lines without a + : refused as inconsistent" unreadable "" FAKE_LS_RAW="drwxr-xr-x 3 someone staff 96 Oct 27 12:00 /x\n 0: user:alice allow list"
acl_env "garbage header: refused" unreadable "" FAKE_LS_RAW="total 0"
acl_env "header with short permissions: refused" unreadable "" FAKE_LS_RAW="drwxr-x 3 someone staff 96 Oct 27 12:00 /x"
acl_env "header with a bad type char: refused" unreadable "" FAKE_LS_RAW="Xrwxr-xr-x 3 someone staff 96 Oct 27 12:00 /x"
acl_env "a BSD-shaped + header with a benign entry: accepted" ok " 0: group:everyone deny delete"
acl_env "'allow garbage': refused" unreadable " 0: user:alice allow garbage"
acl_env "rights ',': refused" unreadable " 0: user:alice allow ,"
acl_env "rights 'a,,b': refused" unreadable " 0: user:alice allow read,,list"
acl_env "trailing comma: refused" unreadable " 0: user:alice allow read,"
acl_env "leading comma: refused" unreadable " 0: user:alice allow ,read"
acl_env "unknown token on a deny line: refused" unreadable " 0: user:alice deny read,frobnicate"
acl_env "a glob-shaped token: refused" unreadable " 0: user:alice allow *"
globdir="$(mktemp -d "$tmp/glob.XXXXXX")"; : > "$globdir/add_file"; : > "$globdir/decoy"
globout="$(cd "$globdir" && . "$OLDPWD/scripts/record-fix-lib.sh" && FIX_STAT_CMD="$tmp/fakestat/stat" FAKE_STAT_BSD="501 0755" FIX_LS_CMD="$tmp/fakels/ls" FAKE_LS_LEAF=" 0: user:alice allow *" fix_private_dir "$tmp/fakestat/w/anc/leaf"; echo "rc=$? why=$FIX_TRUST_WHY")"
eq "glob token refused from a directory holding decoy files" "rc=1 why=leaf: its ACL could not be read" "$globout"
eq "the glob token expanded and touched nothing in the cwd" "add_file decoy" "$(ls "$globdir" | tr '\n' ' ' | sed 's/ $//')"
for r in read list readdata write add_file writedata execute search delete append add_subdirectory delete_child readattr writeattr readextattr writeextattr readsecurity writesecurity chown change_owner synchronize sync file_inherit directory_inherit limit_inherit only_inherit; do
  case "$r" in
    write|add_file|writedata|delete|append|add_subdirectory|delete_child|writesecurity|chown|change_owner)
      acl_env "whitelist name $r on the current user: accepted" ok " 0: user:$me_name allow $r" ;;
    *) acl_env "whitelist name $r for others: accepted" ok " 0: user:alice allow $r" ;;
  esac
done
check "no FIX_LS_CMD and GNU ls (no -e): the rule is a no-op there" bash -c '. scripts/record-fix-lib.sh; ls -led / >/dev/null 2>&1 && exit 0; FIX_STAT_CMD="'"$tmp"'/fakestat/stat" FAKE_STAT_BSD="501 0755" fix_private_dir "'"$tmp"'/fakestat/w/anc/leaf"'
if [ "$(uname)" = Darwin ]; then
  # a REAL ACL on a directory this test makes inside the temp directory it owns
  aclroot="$tmp/aclreal"; mkdir -p "$aclroot"; chmod 700 "$aclroot"
  acl_dir="$(mktemp -d "$aclroot/d.XXXXXX")"; chmod 755 "$acl_dir"
  real_acl() { ( . scripts/record-fix-lib.sh; fix_private_dir "$acl_dir"; echo "rc=$? why=$FIX_TRUST_WHY" ); }
  eq "real macOS: a plain 755 directory is accepted" "rc=0 why=" "$(real_acl)"
  chmod +a "group:everyone allow add_file" "$acl_dir"
  case "$(real_acl)" in *"rc=1 why="*"an ACL lets another user change it"*) ok ;; *) bad "real macOS: group:everyone allow add_file was not refused" ;; esac
  chmod -N "$acl_dir"
  eq "real macOS: after chmod -N it is accepted" "rc=0 why=" "$(real_acl)"
  chmod +a "group:everyone deny delete" "$acl_dir"
  eq "real macOS: the benign group:everyone deny delete ACL is accepted" "rc=0 why=" "$(real_acl)"
  chmod -N "$acl_dir"
fi
check "record-fix-demo.sh checks the rule before reserving the output" bash -c '
  c=$(grep -vnE "^[[:space:]]*#" scripts/record-fix-demo.sh | grep -m1 "fix_private_dir" | cut -d: -f1)
  r=$(grep -vnE "^[[:space:]]*#" scripts/record-fix-demo.sh | grep -m1 "fix_reserve_output" | cut -d: -f1)
  [ -n "$c" ] && [ -n "$r" ] && [ "$c" -lt "$r" ]'


# ---------------------------------------------------------------- F3: e2e-glimmer.sh
check "e2e: the policy call precedes the screencapture line" bash -c '
  p=$(grep -vnE "^[[:space:]]*#" scripts/e2e-glimmer.sh | grep -m1 "capture_denied" | cut -d: -f1)
  s=$(grep -vnE "^[[:space:]]*#" scripts/e2e-glimmer.sh | grep -m1 "SHEP_SCREENCAPTURE" | cut -d: -f1)
  [ -n "$p" ] && [ -n "$s" ] && [ "$p" -lt "$s" ]'
check "e2e: the policy call precedes the helper health checks" bash -c '
  p=$(grep -vnE "^[[:space:]]*#" scripts/e2e-glimmer.sh | grep -m1 "capture_denied" | cut -d: -f1)
  h=$(grep -vnE "^[[:space:]]*#" scripts/e2e-glimmer.sh | grep -m1 "curl" | cut -d: -f1)
  [ -n "$p" ] && [ -n "$h" ] && [ "$p" -lt "$h" ]'
check "e2e: uses the shared policy lib" grep -q capture-policy-lib.sh scripts/e2e-glimmer.sh
check "shep-winfo.swift has a --bundle mode" grep -q -- '--bundle' scripts/shep-winfo.swift

cat > "$fb/screencapture" <<'FAKE'
#!/bin/bash
echo "called $*" >> "$FAKE_SC_LOG"
for last in "$@"; do :; done
printf 'PNG' > "$last"
[ -z "${FAKE_SC_FAIL:-}" ] || exit 1
FAKE
cat > "$fb/curl" <<'FAKE'
#!/bin/bash
exit 0
FAKE
cat > "$tmp/app/Contents/MacOS/Shep" <<'FAKE'
#!/bin/bash
echo "fake Shep ran: $*"
echo "fake Shep env: frame=${SHEP_WINDOW_FRAME:-} title=${SHEP_WINDOW_TITLE:-} pid=${SHEP_AX_PID:-}"
exit 0
FAKE
chmod +x "$fb/screencapture" "$fb/curl" "$tmp/app/Contents/MacOS/Shep"

e2e() { # e2e <name> <bundle> ; sets RC, ev, sc
  local name="$1" bundle="$2"
  ev="$tmp/e2e-$name"; mkdir -p "$ev"; sc="$tmp/sc-$name"
  PATH="$fb:$PATH" SHEP_WINFO_BIN="$tmp/winfo" SHEP_SCREENCAPTURE="$fb/screencapture" FAKE_SC_LOG="$sc" FAKE_BUNDLE="$bundle" FAKE_VERIFY_COUNT="$tmp/vcount-$name" \
    SHEP_APP="$tmp/app" SHEP_EVIDENCE_DIR="$ev" bash scripts/e2e-glimmer.sh --window Mail >"$tmp/out-e2e-$name" 2>&1
  RC=$?
}
pngs() { find "$ev" -name '*.png' | wc -l | tr -d ' '; }
for denied in com.apple.mail com.apple.Terminal com.1password.1password; do
  e2e "denied-$denied" "$denied"
  check "e2e denied '$denied': exits nonzero" test "$RC" -ne 0
  eq "e2e denied '$denied': no PNG was created" 0 "$(pngs)"
  check "e2e denied '$denied': screencapture was never invoked" test ! -e "$sc"
done
e2e unresolved ""
check "e2e unresolved bundle: exits nonzero" test "$RC" -ne 0
eq "e2e unresolved bundle: no PNG" 0 "$(pngs)"
check "e2e unresolved bundle: screencapture never invoked" test ! -e "$sc"
e2e allowed org.m0k.transmission
eq "e2e allowed app: exit 0" 0 "$RC"
check "e2e allowed app: screencapture was invoked once" bash -c "[ \"\$(wc -l < '$sc' | tr -d ' ')\" = 1 ]"
eq "e2e allowed app: the PNG exists" 1 "$(pngs)"

# ---------------------------------------------------------------- R2: one record, one verify, one id
# --record answers with window A (id 91, pid 4141, bundle com.example.a); every older lookup would answer with app B. The script must use
# only A's record, verify it right before capture, and capture exactly A's id with A's pid.
winfo_calls() { cat "$tmp/winfo-log-$1" 2>/dev/null; }
e2e_ab() { # e2e_ab <name> <bundle of A>; extra FAKE_* come from the environment
  FAKE_WINFO_LOG="$tmp/winfo-log-$1" FAKE_REC_ID=91 FAKE_REC_PID=4141 e2e "$1" "$2"
}
FAKE_VERIFY_EXPECT="91 4141 com.example.a" e2e_ab ab-ok com.example.a
eq "A/B: the recorded window is captured (exit 0)" 0 "$RC"
check "A/B: screencapture got exactly the recorded id" grep -q -- '-l 91 ' "$sc"
check "A/B: screencapture ran once" bash -c "[ \"\$(wc -l < '$sc' | tr -d ' ')\" = 1 ]"
check "A/B: SHEP_AX_PID is the record's pid" grep -q 'ax_pid=4141' "$tmp/out-e2e-ab-ok"
eq "A/B: both verifies got the record's id, pid, bundle, frame and title" 2 "$(grep -cx -- '--verify 91 4141 com.example.a 10 10 400 300 Title' "$tmp/winfo-log-ab-ok")"
eq "A/B: exactly one --record call" 1 "$(winfo_calls ab-ok | grep -c '^--record ')"
eq "A/B: one verify before and one after the capture" 2 "$(winfo_calls ab-ok | grep -c '^--verify ')"
eq "A/B: no other lookup (no --pid, --bundle or plain)" 3 "$(winfo_calls ab-ok | wc -l | tr -d ' ')"
check "A/B: the app got the verified frame and title" grep -q 'fake Shep env: frame=10,10,400,300 title=Title pid=4141' "$tmp/out-e2e-ab-ok"
FAKE_VERIFY_RC=1 e2e_ab ab-verify-fails com.example.a
check "verify fails: exits nonzero" test "$RC" -ne 0
eq "verify fails: no PNG" 0 "$(pngs)"
check "verify fails: screencapture never called" test ! -e "$sc"
FAKE_VERIFY_EXPECT="91 9999 com.example.a" e2e_ab ab-verify-pid com.example.a
check "verify with another pid: exits nonzero" test "$RC" -ne 0
check "verify with another pid: screencapture never called" test ! -e "$sc"
e2e_ab ab-denied com.apple.mail
check "A denied, B allowed: exits nonzero" test "$RC" -ne 0
eq "A denied, B allowed: no PNG" 0 "$(pngs)"
check "A denied, B allowed: screencapture never called" test ! -e "$sc"
check "A denied: verify never reached" bash -c "! grep -q -- '--verify' '$tmp/winfo-log-ab-denied'"
FAKE_RECORD_FAIL=1 e2e_ab ab-ambiguous com.example.a
check "ambiguity: exits nonzero" test "$RC" -ne 0
eq "ambiguity: no PNG" 0 "$(pngs)"
check "ambiguity: screencapture never called" test ! -e "$sc"
check "ambiguity: nothing but the record was asked" bash -c "[ \"\$(wc -l < '$tmp/winfo-log-ab-ambiguous' | tr -d ' ')\" = 1 ]"
check "e2e: no --pid or --bundle lookup in the script" bash -c '! grep -vE "^[[:space:]]*#" scripts/e2e-glimmer.sh | grep -qE -- "--(pid|bundle)\b"'
check "e2e: verify follows the policy call and precedes screencapture" bash -c '
  c=$(grep -vnE "^[[:space:]]*#" scripts/e2e-glimmer.sh | grep -m1 "capture_denied" | cut -d: -f1)
  v=$(grep -vnE "^[[:space:]]*#" scripts/e2e-glimmer.sh | grep -m1 -- "--verify" | cut -d: -f1)
  s=$(grep -vnE "^[[:space:]]*#" scripts/e2e-glimmer.sh | grep -m1 "SHEP_SCREENCAPTURE" | cut -d: -f1)
  [ -n "$c" ] && [ -n "$v" ] && [ -n "$s" ] && [ "$c" -lt "$v" ] && [ "$v" -lt "$s" ]'
check "shep-winfo.swift has --record and --verify" bash -c 'grep -q -- "--record" scripts/shep-winfo.swift && grep -q -- "--verify" scripts/shep-winfo.swift'
check "shep-winfo --record exits 4 on ambiguity" bash -c 'grep -q "exit(4)" scripts/shep-winfo.swift'
check "shep-winfo --record has no untitled fallback" bash -c '! sed -n "/func recordSelect/,/^}/p" scripts/shep-winfo.swift | grep -q untitledSeen'

# ---------------------------------------------------------------- B (code review of 456a156): still the recorded window, before AND after the capture
# Fake window states per verify call: FAKE_WIN_1 (before the capture), FAKE_WIN_2 (after). SHEP_E2E_STEM fixes the PNG's name when a test
# needs to know it. Exit 2 is a refusal before the capture, 8 a mismatch after it; the run removes only the PNG it made, after an identity check.
e2e_b() { FAKE_REC_ID=91 FAKE_REC_PID=4141 FAKE_WINFO_LOG="$tmp/winfo-log-$1" e2e "$1" com.example.a; }
app_ran() { grep -q 'fake Shep ran' "$tmp/out-e2e-$1"; }
FAKE_WIN_1="91 4141 com.example.a 30 10 400 300|Title" e2e_b b-moved-before
eq "moved before the capture: exit 2" 2 "$RC"
eq "moved before the capture: no PNG" 0 "$(pngs)"
check "moved before the capture: screencapture never called" test ! -e "$sc"
check "moved before the capture: the app never ran" bash -c "! grep -q 'fake Shep ran' '$tmp/out-e2e-b-moved-before'"
check "moved before the capture: the reason is printed" grep -q 'not the recorded one' "$tmp/out-e2e-b-moved-before"
FAKE_WIN_1="91 4141 com.example.a 10 10 500 300|Title" e2e_b b-resized-before
eq "resized before the capture: exit 2" 2 "$RC"
eq "resized before the capture: no PNG" 0 "$(pngs)"
FAKE_WIN_2="91 4141 com.example.a 30 10 400 300|Title" e2e_b b-moved-after
eq "moved between the capture and the second verify: exit 8" 8 "$RC"
eq "moved after the capture: no PNG left" 0 "$(pngs)"
check "moved after the capture: screencapture ran once" bash -c "[ \"\$(wc -l < '$sc' | tr -d ' ')\" = 1 ]"
check "moved after the capture: the app never ran" bash -c "! grep -q 'fake Shep ran' '$tmp/out-e2e-b-moved-after'"
check "moved after the capture: the PNG removal is reported" grep -q 'removed the PNG this run made' "$tmp/out-e2e-b-moved-after"
FAKE_WIN_2="91 4141 com.example.a 10 10 400 310|Title" e2e_b b-resized-after
eq "resized after the capture: exit 8" 8 "$RC"
eq "resized after the capture: no PNG left" 0 "$(pngs)"
FAKE_WIN_1="91 4141 com.example.a 10 10 400 300|Other title" e2e_b b-reused-title-before
eq "id reused with another title before the capture: exit 2" 2 "$RC"
eq "id reused before: no PNG" 0 "$(pngs)"
check "id reused before: screencapture never called" test ! -e "$sc"
FAKE_WIN_2="91 4141 com.example.a 10 10 400 300|Other title" e2e_b b-reused-title-after
eq "id reused with another title after the capture: exit 8" 8 "$RC"
eq "id reused after: no PNG left" 0 "$(pngs)"
check "id reused after: the app never ran" bash -c "! grep -q 'fake Shep ran' '$tmp/out-e2e-b-reused-title-after'"
FAKE_WIN_2="91 4141 com.example.a 50 60 700 800|Other title" e2e_b b-reused-frame-after
eq "id reused with another frame and title after the capture: exit 8" 8 "$RC"
eq "id reused with another frame after: no PNG left" 0 "$(pngs)"
FAKE_WIN_2="91 9999 com.example.a 10 10 400 300|Title" e2e_b b-pid-after
eq "owner changed after the capture: exit 8" 8 "$RC"
eq "owner changed after the capture: no PNG left" 0 "$(pngs)"

# a foreign file already at the PNG's name is never overwritten or removed: the run refuses
mkdir -p "$tmp/e2e-b-collide"; printf "somebody else's picture" > "$tmp/e2e-b-collide/e2e-fixed.png"
sum_before="$(cksum < "$tmp/e2e-b-collide/e2e-fixed.png")"
SHEP_E2E_STEM=e2e-fixed e2e_b b-collide
eq "a colliding PNG name: exit 2" 2 "$RC"
eq "a colliding PNG name: the file is byte-for-byte unchanged" "$sum_before" "$(cksum < "$tmp/e2e-b-collide/e2e-fixed.png")"
eq "a colliding PNG name: still exactly that one PNG" 1 "$(pngs)"
check "a colliding PNG name: screencapture never called" test ! -e "$sc"
check "a colliding PNG name: the app never ran" bash -c "! grep -q 'fake Shep ran' '$tmp/out-e2e-b-collide'"
mkdir -p "$tmp/e2e-b-dangling"; ln -s "$tmp/e2e-b-dangling/nowhere.png" "$tmp/e2e-b-dangling/e2e-fixed.png"
SHEP_E2E_STEM=e2e-fixed e2e_b b-dangling
eq "a dangling symlink at the PNG name: exit 2" 2 "$RC"
check "a dangling symlink at the PNG name: still a link, nothing created through it" bash -c "[ -L '$tmp/e2e-b-dangling/e2e-fixed.png' ] && [ ! -e '$tmp/e2e-b-dangling/nowhere.png' ]"

# a foreign file has the PNG's name by the time of the cleanup: nothing is removed, and the run says so
mkdir -p "$tmp/e2e-b-swap"; printf 'a foreign file' > "$tmp/swap-src.png"
FAKE_SWAP_SRC="$tmp/swap-src.png" FAKE_SWAP_DST="$tmp/e2e-b-swap/e2e-fixed.png" FAKE_SWAP_ON=2 FAKE_WIN_2="91 4141 com.example.a 30 10 400 300|Title" SHEP_E2E_STEM=e2e-fixed e2e_b b-swap
eq "a replaced PNG and a moved window: exit 8" 8 "$RC"
eq "a replaced PNG: the foreign file is still there" "a foreign file" "$(cat "$tmp/e2e-b-swap/e2e-fixed.png" 2>/dev/null)"
check "a replaced PNG: the run says it removed nothing" grep -q 'removed nothing' "$tmp/out-e2e-b-swap"

# D (code review of 6e06e30): a failing removal must not abort the mismatch path. SHEP_RM_CMD is used ONLY for that one removal.
printf '#!/bin/bash\necho "rm-fail $*" >> "${FAKE_RM_LOG:-/dev/null}"\nexit 1\n' > "$fb/rm-fail"
printf '#!/bin/bash\necho "$*" >> "${FAKE_RM_LOG:-/dev/null}"\nexec rm "$@"\n' > "$fb/rm-ok"
chmod +x "$fb/rm-fail" "$fb/rm-ok"
FAKE_RM_LOG="$tmp/rm-log-fail" SHEP_RM_CMD="$fb/rm-fail" FAKE_WIN_2="91 4141 com.example.a 30 10 400 300|Title" SHEP_E2E_STEM=e2e-fixed e2e_b d-rm-fails
eq "a failing rm after a mismatch: still exit 8" 8 "$RC"
eq "a failing rm: the rejected PNG is still on disk" 1 "$(pngs)"
check "a failing rm: the run names the path that remains" grep -qF "the PNG could not be removed and remains at: $ev/e2e-fixed.png" "$tmp/out-e2e-d-rm-fails"
check "a failing rm: the mismatch reason is still printed" grep -q 'the window changed during the capture' "$tmp/out-e2e-d-rm-fails"
check "a failing rm: the app never ran" bash -c "! grep -q 'fake Shep ran' '$tmp/out-e2e-d-rm-fails'"
check "a failing rm: the seam was asked once, for the run's own PNG" bash -c "[ \"\$(cat '$tmp/rm-log-fail')\" = 'rm-fail -- $ev/e2e-fixed.png' ]"
FAKE_RM_LOG="$tmp/rm-log-ok" SHEP_RM_CMD="$fb/rm-ok" FAKE_WIN_2="91 4141 com.example.a 30 10 400 300|Title" SHEP_E2E_STEM=e2e-fixed e2e_b d-rm-works
eq "a working rm after a mismatch: exit 8" 8 "$RC"
eq "a working rm: our PNG is gone" 0 "$(pngs)"
check "a working rm: the removal is reported" grep -q 'removed the PNG this run made' "$tmp/out-e2e-d-rm-works"
check "a working rm: it was asked to remove exactly our PNG" bash -c "[ \"\$(cat '$tmp/rm-log-ok')\" = '-- $ev/e2e-fixed.png' ]"
FAKE_RM_LOG="$tmp/rm-log-cap" SHEP_RM_CMD="$fb/rm-fail" FAKE_SC_FAIL=1 e2e_b d-capture-failed
eq "a failed capture and a failing rm: still the refusal status (2)" 2 "$RC"
check "a failed capture and a failing rm: the PNG remains is reported" grep -q 'remains at' "$tmp/out-e2e-d-capture-failed"
# a symlink, or a different file, at the PNG's name: rm is never asked
mkdir -p "$tmp/e2e-d-link"; printf 'link target' > "$tmp/d-link-target.png"; ln -s "$tmp/d-link-target.png" "$tmp/d-link.png"
FAKE_RM_LOG="$tmp/rm-log-link" SHEP_RM_CMD="$fb/rm-ok" FAKE_SWAP_SRC="$tmp/d-link.png" FAKE_SWAP_DST="$tmp/e2e-d-link/e2e-fixed.png" FAKE_SWAP_ON=2 \
  FAKE_WIN_2="91 4141 com.example.a 30 10 400 300|Title" SHEP_E2E_STEM=e2e-fixed e2e_b d-link
eq "a symlink at the PNG name: exit 8" 8 "$RC"
check "a symlink at the PNG name: rm was never asked" test ! -e "$tmp/rm-log-link"
check "a symlink at the PNG name: the link and its target are untouched" bash -c "[ -L '$tmp/e2e-d-link/e2e-fixed.png' ] && [ \"\$(cat '$tmp/d-link-target.png')\" = 'link target' ]"
check "a symlink at the PNG name: the run says it removed nothing" grep -q 'removed nothing' "$tmp/out-e2e-d-link"
mkdir -p "$tmp/e2e-d-inode"; printf 'a different file' > "$tmp/d-inode-src.png"
FAKE_RM_LOG="$tmp/rm-log-inode" SHEP_RM_CMD="$fb/rm-ok" FAKE_SWAP_SRC="$tmp/d-inode-src.png" FAKE_SWAP_DST="$tmp/e2e-d-inode/e2e-fixed.png" FAKE_SWAP_ON=2 \
  FAKE_WIN_2="91 4141 com.example.a 30 10 400 300|Title" SHEP_E2E_STEM=e2e-fixed e2e_b d-inode
eq "a different inode at the PNG name: exit 8" 8 "$RC"
check "a different inode at the PNG name: rm was never asked" test ! -e "$tmp/rm-log-inode"
eq "a different inode at the PNG name: that file is untouched" "a different file" "$(cat "$tmp/e2e-d-inode/e2e-fixed.png")"
check "e2e: SHEP_RM_CMD is read once, and no other line calls rm directly" bash -c '
  [ "$(grep -vE "^[[:space:]]*#" scripts/e2e-glimmer.sh | grep -c SHEP_RM_CMD)" = 1 ] &&
  ! grep -vE "^[[:space:]]*#" scripts/e2e-glimmer.sh | grep -Eq "(^|[;&|( ])rm "'

# unchanged: success, exactly one PNG, the verified frame in the environment, two verifies around one capture
e2e_b b-same
eq "unchanged window: exit 0" 0 "$RC"
eq "unchanged window: exactly one PNG" 1 "$(pngs)"
check "unchanged window: the app ran with the record's frame and title" grep -q 'fake Shep env: frame=10,10,400,300 title=Title pid=4141' "$tmp/out-e2e-b-same"
check "unchanged window: the PNG name is unique (stamp, pid, suffix)" bash -c "find '$ev' -name '*.png' | grep -Eq 'e2e-window-[0-9]{8}-[0-9]{6}-[0-9]+-[0-9a-f]{4}\.png\$'"
check "e2e: the last verify follows the screencapture line" bash -c '
  s=$(grep -vnE "^[[:space:]]*#" scripts/e2e-glimmer.sh | grep -m1 "SHEP_SCREENCAPTURE" | cut -d: -f1)
  n=$(grep -vnE "^[[:space:]]*#" scripts/e2e-glimmer.sh | grep -c "verify_window")
  l=$(grep -vnE "^[[:space:]]*#" scripts/e2e-glimmer.sh | grep "verify_window" | tail -n 1 | cut -d: -f1)
  [ "$n" -ge 3 ] && [ "$l" -gt "$s" ]'
check "e2e: reserves the PNG under noclobber" bash -c "grep -vE '^[[:space:]]*#' scripts/e2e-glimmer.sh | grep -q noclobber"
check "e2e: the header does not claim an atomic capture" bash -c "grep -qi 'not atomic' scripts/e2e-glimmer.sh"
check "shep-winfo --verify takes a frame and a title" grep -q -- '--verify <window id> <pid> <bundle id> <x> <y> <w> <h> <title>' scripts/shep-winfo.swift

# ---------------------------------------------------------------- housekeeping: this suite removes the temp directory IT made, and only that
check "scripts/test-tmp-lib.sh exists" test -f scripts/test-tmp-lib.sh
check "this suite installs the cleanup trap" grep -q "trap 'shep_tmp_cleanup' EXIT" scripts/test-scripts.sh
check "the footer no longer says the directory is not deleted" bash -c '! grep -q "(not dele""ted)" scripts/test-scripts.sh'
nest="$tmp/nested-tmp"; mkdir -p "$nest"
cat > "$tmp/nested-harness.sh" <<'HARNESS'
#!/bin/bash
# A tiny harness: makes its own temp directory with the shared helper, a sibling with the same prefix, then exits with status 3.
set -uo pipefail
cd "$1"
. scripts/test-tmp-lib.sh
shep_tmp_make
trap 'shep_tmp_cleanup' EXIT
echo "$SHEP_TMP_DIR" > "$TMPDIR/own-path"
mkdir -p "$TMPDIR/shep-test-scripts.sibling"; echo keep > "$TMPDIR/shep-test-scripts.sibling/file"
echo inside > "$SHEP_TMP_DIR/file"; mkdir "$SHEP_TMP_DIR/sub"; echo deeper > "$SHEP_TMP_DIR/sub/f"
exit 3
HARNESS
( cd "$tmp" && TMPDIR="$nest" bash "$tmp/nested-harness.sh" "$repo" ); nested_rc=$?
eq "the trap preserves the suite's exit status" 3 "$nested_rc"
nested_own="$(cat "$nest/own-path" 2>/dev/null)"
check "the harness recorded its own directory under its TMPDIR" bash -c "case '$nested_own' in '$nest'/shep-test-scripts.*) exit 0 ;; *) exit 1 ;; esac"
check "the trap removed the directory the harness made" test ! -e "$nested_own"
check "a sibling directory with the same prefix is left alone" test "$(cat "$nest/shep-test-scripts.sibling/file" 2>/dev/null)" = keep
# the refusals: a path the process did not create, a symlink, the wrong prefix, outside the temp dir, an empty value
nest2="$tmp/nested-tmp2"; mkdir -p "$nest2/shep-test-scripts.foreign" "$nest2/other-dir" "$nest2/target"
echo x > "$nest2/shep-test-scripts.foreign/f"; echo x > "$nest2/other-dir/f"; echo x > "$nest2/target/f"
ln -s "$nest2/target" "$nest2/shep-test-scripts.link"
refuse_clean() { # refuse_clean <value of SHEP_TMP_DIR> : the cleanup must remove nothing
  ( cd "$repo" && . scripts/test-tmp-lib.sh && TMPDIR="$nest2" && SHEP_TMP_DIR="$1" SHEP_TMP_PID=$$ SHEP_TMP_INODE=0 shep_tmp_cleanup ) >/dev/null 2>&1
}
refuse_clean "$nest2/shep-test-scripts.foreign"; check "cleanup refuses a directory it did not create (inode differs)" test -f "$nest2/shep-test-scripts.foreign/f"
refuse_clean "$nest2/other-dir"; check "cleanup refuses a name without the prefix" test -f "$nest2/other-dir/f"
refuse_clean "$nest2/shep-test-scripts.link"; check "cleanup refuses a symlink" test -f "$nest2/target/f"
refuse_clean ""; check "cleanup refuses an empty path (and set -u is safe)" test -d "$nest2"
refuse_clean "$tmp/shep-test-scripts.outside"; check "cleanup refuses a path outside the temp directory" test -d "$tmp"
( cd "$repo" && . scripts/test-tmp-lib.sh && set -u && unset SHEP_TMP_DIR SHEP_TMP_PID SHEP_TMP_INODE && shep_tmp_cleanup ) >/dev/null 2>&1
eq "cleanup with nothing recorded is a quiet no-op" 0 "$?"
# SHEP_TEST_KEEP=1 keeps it for debugging
( cd "$tmp" && TMPDIR="$nest" SHEP_TEST_KEEP=1 bash "$tmp/nested-harness.sh" "$repo" 2>/dev/null ); keep_own="$(cat "$nest/own-path")"
check "SHEP_TEST_KEEP=1 keeps the directory" test -f "$keep_own/file"

# ---------------------------------------------------------------- glimmer-server.sh: the state directory (no server is started)
check "glimmer: scripts/glimmer-state-lib.sh exists" test -f scripts/glimmer-state-lib.sh
check "glimmer: no TMPDIR or /tmp fallback for the state dir" bash -c '! grep -vE "^[[:space:]]*#" scripts/glimmer-server.sh | grep -qE "TMPDIR|/tmp"'
check "glimmer: the default state dir is under Library/Caches/Shep/glimmer" bash -c 'grep -vE "^[[:space:]]*#" scripts/glimmer-server.sh | grep -q "\$HOME/Library/Caches/Shep/glimmer"'
check "glimmer: the header does not name a temp default" bash -c '! head -12 scripts/glimmer-server.sh | grep -qE "TMPDIR|/tmp"'
check "glimmer: nothing is removed by the script or its library" bash -c '! cat scripts/glimmer-server.sh scripts/glimmer-state-lib.sh | grep -vE "^[[:space:]]*#" | grep -Eq "(^|[;&|( ])rm "'
gl="$tmp/glimmer"; mkdir -p "$gl"
gcheck() { # gcheck <state dir> [extra env...] : runs only the validation mode
  local d="$1"; shift
  env "$@" GLIMMER_STATE_DIR="$d" bash scripts/glimmer-server.sh --check-state-dir
}
gmode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
gcheck "$gl/fresh/nested" >"$tmp/gl-out" 2>&1; eq "glimmer: a missing state dir is created and accepted" 0 "$?"
eq "glimmer: the created dir is mode 700" 700 "$(gmode "$gl/fresh/nested")"
gcheck "$gl/fresh/nested" >/dev/null 2>&1; eq "glimmer: an existing 700 dir is accepted again" 0 "$?"
mkdir -p "$gl/open"; chmod 755 "$gl/open"
gcheck "$gl/open" >"$tmp/gl-out" 2>&1; check "glimmer: a 755 dir is refused" test "$?" -ne 0
check "glimmer: the refusal names the mode" grep -q "700" "$tmp/gl-out"
eq "glimmer: a refused dir is left as it was" 755 "$(gmode "$gl/open")"
mkdir -p "$gl/real"; chmod 700 "$gl/real"; ln -s "$gl/real" "$gl/link"
gcheck "$gl/link" >"$tmp/gl-out" 2>&1; check "glimmer: a symlinked state dir is refused" test "$?" -ne 0
check "glimmer: the refusal names the symlink" grep -qi "symlink" "$tmp/gl-out"
echo x > "$gl/afile"
gcheck "$gl/afile" >"$tmp/gl-out" 2>&1; check "glimmer: a regular file as state dir is refused" test "$?" -ne 0
check "glimmer: a file is left intact" test "$(cat "$gl/afile")" = x
mkdir -p "$gl/logl"; chmod 700 "$gl/logl"; ln -s "$gl/afile" "$gl/logl/glimmer-server.log"
gcheck "$gl/logl" >"$tmp/gl-out" 2>&1; check "glimmer: a symlinked log is refused" test "$?" -ne 0
check "glimmer: the symlinked log's target is untouched" test "$(cat "$gl/afile")" = x
mkdir -p "$gl/pidl"; chmod 700 "$gl/pidl"; ln -s "$gl/afile" "$gl/pidl/glimmer-server.pid"
gcheck "$gl/pidl" >"$tmp/gl-out" 2>&1; check "glimmer: a symlinked pid file is refused" test "$?" -ne 0
check "glimmer: the symlinked pid file's target is untouched" test "$(cat "$gl/afile")" = x
# the default location, with a TMPDIR that must play no part
mkdir -p "$gl/home" "$gl/othertmp"
env -u GLIMMER_STATE_DIR HOME="$gl/home" TMPDIR="$gl/othertmp" bash scripts/glimmer-server.sh --check-state-dir >/dev/null 2>&1
eq "glimmer: the default state dir is accepted" 0 "$?"
check "glimmer: the default is HOME/Library/Caches/Shep/glimmer" test -d "$gl/home/Library/Caches/Shep/glimmer"
eq "glimmer: the default dir is mode 700" 700 "$(gmode "$gl/home/Library/Caches/Shep/glimmer")"
check "glimmer: TMPDIR was not used" test -z "$(ls -A "$gl/othertmp")"
# ownership: pretend to be another user
mkdir -p "$gl/mine"; chmod 700 "$gl/mine"
( . scripts/glimmer-state-lib.sh; id() { echo 4242; }; glimmer_check_state_dir "$gl/mine" "$gl/mine/l" "$gl/mine/p" ) >"$tmp/gl-out" 2>&1
check "glimmer: a dir owned by someone else is refused" test "$?" -ne 0
check "glimmer: the refusal names the owner" grep -qi "owned" "$tmp/gl-out"
# the pid file: exclusive create, a live holder refuses, a stale one is moved aside (never removed)
( . scripts/glimmer-state-lib.sh; glimmer_claim_pidfile "$gl/mine/a.pid" ); eq "glimmer: a first claim succeeds" 0 "$?"
eq "glimmer: the claimed pid file is mode 600" 600 "$(gmode "$gl/mine/a.pid")"
echo "$$" > "$gl/mine/live.pid"
( . scripts/glimmer-state-lib.sh; glimmer_claim_pidfile "$gl/mine/live.pid" ) >"$tmp/gl-out" 2>&1
check "glimmer: a pid file naming a live process is refused" test "$?" -ne 0
eq "glimmer: the live pid file is unchanged" "$$" "$(cat "$gl/mine/live.pid")"
echo 999999 > "$gl/mine/stale.pid"
( . scripts/glimmer-state-lib.sh; glimmer_claim_pidfile "$gl/mine/stale.pid" ) >/dev/null 2>&1
eq "glimmer: a stale pid file is replaced" 0 "$?"
n_stale="$(ls "$gl/mine" | grep -c '^stale\.pid\.stale-[0-9][0-9]*$')"
eq "glimmer: the stale pid file was moved aside, not removed" 1 "$n_stale"
check "glimmer: the moved-aside file keeps its content" test "$(cat "$gl/mine"/stale.pid.stale-*)" = 999999
check "glimmer: a fresh pid file took its place" test -f "$gl/mine/stale.pid" -a ! -s "$gl/mine/stale.pid"
ln -s "$gl/afile" "$gl/mine/sym.pid"
( . scripts/glimmer-state-lib.sh; glimmer_claim_pidfile "$gl/mine/sym.pid" ) >/dev/null 2>&1
check "glimmer: a symlink as pid file is not claimed" test "$?" -ne 0
check "glimmer: the symlink's target is untouched by a claim" test "$(cat "$gl/afile")" = x

# ---------------------------------------------------------------- .gitignore: local working notes and evidence stay untracked
check ".gitignore ignores shep-meta-evidence/" git check-ignore -q shep-meta-evidence/capture.txt
check ".gitignore ignores .claude/" git check-ignore -q .claude/settings.json
check ".gitignore ignores AGENTS.md" git check-ignore -q AGENTS.md

# ---------------------------------------------------------------- NOTICE: Vite's MIT text travels with the built pages
check "NOTICE carries Vite's copyright line" grep -qxF "Copyright (c) 2019-present, VoidZero Inc. and Vite contributors" NOTICE
check "NOTICE carries the permission sentence for Vite" bash -c 'awk "/^Vite: MIT License/{f=1} f" NOTICE | grep -qF "Permission is hereby granted, free of charge, to any person obtaining a copy"'
check "NOTICE carries the warranty disclaimer for Vite" bash -c 'awk "/^Vite: MIT License/{f=1} f" NOTICE | grep -qF "THE SOFTWARE IS PROVIDED \"AS IS\""'

if [ "${SHEP_TEST_KEEP:-}" = 1 ]; then kept="; temp files kept in $tmp (SHEP_TEST_KEEP=1)"; else kept="; the temp directory is removed at exit"; fi
echo "scripts under test run from $repo$kept"
echo "test-scripts: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
