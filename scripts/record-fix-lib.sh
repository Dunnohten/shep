#!/bin/bash
# Helpers for scripts/record-fix-demo.sh, kept apart so scripts/test-scripts.sh can test them. Sourcing has no side effects.
# Nothing here removes a file: an existing path is never touched.
#
#   fix_valid_bundle <id>               0 when <id> is 1 to 255 characters of [A-Za-z0-9._-] (no spaces, no leading dash).
#   fix_reserve_output <dir> [stem]     reserves fix-demo-<yyyymmdd-HHMMSS>-<pid>-<4 hex>.mov (and the .log with the same stem) in
#                                       <dir>. Sets FIX_MOV and FIX_LOG. The log is created empty, exclusively (noclobber); the movie
#                                       is left for Shep to create (Shep refuses an existing file). Returns 6 with a message when
#                                       either path already exists. With no stem a fresh random suffix is tried up to 5 times; with
#                                       a stem (SHEP_FIX_DEMO_STEM, for tests) exactly once.
#   fix_make_nonce                      sets FIX_NONCE to 32 random hex characters from /dev/urandom (one per run, never printed).
#   fix_status_events <status> <nonce>  prints the events of the STATUS FILE (Shep's `--live-status`): only lines that start with
#                                       `<nonce> ` exactly, whose event is in the closed set and which have at most one token after it.
#   fix_has_event <ere>                 0 when one of those events (FIX_EVENTS) matches the whole-line pattern.
#   fix_log_settled <status> <nonce>    0 when the status already allows a verdict: a refusal, `target-left`, a failed outcome or `finished`.
#   fix_log_refused_early <status> <nonce>  0 when the status shows a refusal before anything was read (no recording is coming).
#   fix_verdict <status> <nonce> <alive 0|1>  sets FIX_CODE and FIX_MSG for the run as the status file shows it (alive: Shep is running).
# The classifier never reads the human `[shep] live:` log: that log prints the request text and can be forged by it. The status file
# holds closed events only (stage and outcome names, never free text), written by Shep, created exclusively, tagged with a nonce the
# script drew from /dev/urandom and hands to Shep through the environment (SHEP_LIVE_NONCE); it is not printed before the run ends.
#
# Exit codes of record-fix-demo.sh (FIX_CODE):
#   0 the run reached the approval card (and, when recording, the clip was written)
#   2 usage or preflight (bad arguments, a never-capture app, not built, evidence dir inside the repo, no app name, no winfo)
#   3 the target could not be brought up or left the front during the run (open failed, not frontmost, no window; or the status
#     event `target-left`, before or after the approval card)
#   4 the run did not reach an approval card (outcome failed or nothing-to-offer, finished or timed out without a card)
#   5 refused: a `reason: target:` line, `outcome: refused`, no target app in front, Shep did not arrive, backdrop failed
#   6 recording problem (record refused or discarded, nothing written in time, clip missing) or the output name was already taken
#   7 Shep exited before `live: finished`
#   130 interrupted

fix_valid_bundle() {
  local id="${1-}"
  [ -n "$id" ] && [ "${#id}" -le 255 ] || return 1
  case "$id" in -*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

fix_reserve_output() {
  local dir="$1" stem="${2:-}" attempts=5 stamp rand n=0
  FIX_MOV=""; FIX_LOG=""
  [ -z "$stem" ] || attempts=1
  while [ "$n" -lt "$attempts" ]; do
    n=$((n + 1))
    if [ -z "$stem" ]; then
      stamp="$(TZ=America/Chicago date +%Y%m%d-%H%M%S)"
      rand="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
      stem="fix-demo-$stamp-$$-$rand"
      local generated=1
    else
      local generated=0
    fi
    local mov="$dir/$stem.mov" log="$dir/$stem.log"
    if [ -e "$mov" ] || [ -L "$mov" ] || [ -e "$log" ] || [ -L "$log" ]; then
      if [ "$generated" -eq 1 ]; then stem=""; continue; fi
      echo "refused: $stem.mov or $stem.log already exists in $dir; I do not overwrite files" >&2
      return 6
    fi
    if ( set -o noclobber; : > "$log" ) 2>/dev/null; then
      FIX_MOV="$mov"; FIX_LOG="$log"
      return 0
    fi
    if [ "$generated" -eq 1 ]; then stem=""; continue; fi
    echo "refused: could not reserve $log (it exists or the directory is not writable)" >&2
    return 6
  done
  echo "refused: could not reserve a free output name in $dir" >&2
  return 6
}

FIX_EVENT_SET='target-ok|target-left|request-submitted|card-shown|answered-(approve|cancel)|outcome-[a-z-]+|reason-[a-z-]+|recording-written|recording-discarded|discard-failed|discard-unknown|recording-already-published|finished'
FIX_EVENTS=""

fix_make_nonce() {
  FIX_NONCE="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
}

fix_status_events() {
  [ -r "$1" ] || return 1
  case "$2" in ''|*[!0-9a-f]*) return 1 ;; esac
  awk -v n="$2" -v set="^($FIX_EVENT_SET)$" '
    index($0, n " ") == 1 {
      rest = substr($0, length(n) + 2)
      cnt = split(rest, w, " ")
      if (cnt < 1 || cnt > 2 || rest ~ /^ / || rest ~ / $/ || rest ~ /  /) next
      if (w[1] ~ set && (cnt == 1 || w[1] == "recording-discarded")) print rest
    }' "$1"
}

fix_has_event() { printf '%s\n' "$FIX_EVENTS" | grep -qE "^($1)$"; }

# How the recording's discard ended, from the status file (code reviews of 6d026eb and d8213e1): sets FIX_DISCARD to one of
#   failed             discard-failed: a clip or its working directory could not be removed (the worst word wins)
#   unknown            discard-unknown: Shep could not confirm the discard within its bounds (a start or a stop was still running);
#                      a clip or a .shep-rec-* directory MAY remain
#   already-published  recording-already-published: the clip reached its final path before the target left; it stays there
#   discarded          recording-discarded (or recording-discarded refused: no recording ever started)
#   (empty)            no outcome event yet
# Shep writes the outcome BEFORE target-left; the script still waits for it after target-left (record-fix-demo.sh), and an outcome
# does not end the wait for target-left or finished.
FIX_DISCARD=""
fix_discard_outcome() {
  FIX_EVENTS="$(fix_status_events "$1" "$2" || true)"
  fix_discard_from_events
}
fix_discard_from_events() {   # classify the discard outcome in the FIX_EVENTS already read (one snapshot for several questions)
  FIX_DISCARD=""
  if fix_has_event 'discard-failed'; then FIX_DISCARD="failed"
  elif fix_has_event 'discard-unknown'; then FIX_DISCARD="unknown"
  elif fix_has_event 'recording-already-published'; then FIX_DISCARD="already-published"
  elif fix_has_event 'recording-discarded( refused)?'; then FIX_DISCARD="discarded"
  fi
  return 0
}

FIX_EARLY_STAGES='reason-(target|no-target|arrival|backdrop|status)'

fix_log_refused_early() {
  FIX_EVENTS="$(fix_status_events "$1" "$2" || true)"
  fix_has_event "$FIX_EARLY_STAGES|target-left"
}

fix_log_settled() {
  FIX_EVENTS="$(fix_status_events "$1" "$2" || true)"
  [ -r "$1" ] || return 1
  fix_has_event "$FIX_EARLY_STAGES" && return 0
  fix_has_event 'target-left' && return 0
  fix_has_event 'outcome-refused' && ! fix_has_event 'card-shown' && return 0
  fix_has_event 'finished'
}

fix_verdict() {
  local status="$1" nonce="$2" alive="${3:-0}" card=0 finished=0 line
  FIX_CODE=0; FIX_MSG=""
  if [ ! -r "$status" ]; then FIX_CODE=7; FIX_MSG="no status file: Shep exited before saying anything"; return 0; fi
  FIX_EVENTS="$(fix_status_events "$status" "$nonce" || true)"
  # The target left the front while the run was going on (Shep stopped, discarded any clip, and said so): 3, whether or not a card
  # had been shown and whatever reason and outcome lines follow it.
  if fix_has_event 'target-left'; then FIX_CODE=3; FIX_MSG="the target left the front during the run (Shep stopped)"; return 0; fi
  fix_has_event 'card-shown' && card=1
  fix_has_event 'finished' && finished=1
  line="$(printf '%s\n' "$FIX_EVENTS" | grep -E "^$FIX_EARLY_STAGES$" | tail -n 1 || true)"
  if [ -n "$line" ]; then FIX_CODE=5; FIX_MSG="refused: $line"; return 0; fi
  if [ "$card" -eq 0 ]; then
    if fix_has_event 'outcome-refused'; then FIX_CODE=5; FIX_MSG="refused: outcome refused (see the reason line in the log)"; return 0; fi
    line="$(printf '%s\n' "$FIX_EVENTS" | grep -E '^outcome-(failed|nothing-to-offer)$' | tail -n 1 || true)"
    if [ -n "$line" ]; then FIX_CODE=4; FIX_MSG="no approval card was reached: $line"; return 0; fi
  fi
  if [ "$finished" -eq 0 ] && [ "$alive" -eq 0 ]; then FIX_CODE=7; FIX_MSG="Shep exited before 'finished'"; return 0; fi
  if [ "$card" -eq 1 ]; then FIX_CODE=0; FIX_MSG="the approval card was shown"; return 0; fi
  FIX_CODE=4
  if [ "$finished" -eq 1 ]; then FIX_MSG="the run finished without an approval card"; else FIX_MSG="no approval card before the timeout"; fi
  return 0
}

# The evidence folder must be private to the person (the shell mirror of RecordingParentTrust in ShepCore; Shep checks again itself).
# ScreenCaptureKit records into a path, so what keeps other users out of that path is the permissions of the folders it goes through.
# fix_private_dir <dir>: resolves <dir> (links followed) into FIX_REAL_DIR and judges the RESOLVED path with stat. The folder must be
# owned by this user and not group- or other-writable (mode & 022 == 0; a sticky bit does not help); every ancestor up to / must be owned
# by this user or root and either not group/other-writable or sticky (/tmp, /private/var/folders). Returns 1 with FIX_TRUST_WHY set to
# the failing check (a component name, never a path). A process of the SAME user is out of scope: it can do what the person can.
FIX_REAL_DIR=""
FIX_TRUST_WHY=""

# GNU `%a` prints 1777 for a sticky directory. BSD/macOS `%Lp` alone DROPS the sticky/setuid/setgid bits (777 for 1777), so the BSD path
# asks for `%Mp%Lp` (the high-bits digit then the three low digits: 1777 sticky, 0755 plain) and strips leading zeros to match GNU.
# FIX_STAT_CMD is a test seam (a fake stat); the default is the real one. A mode that still lacks the high bits reads as non-sticky: fail closed.
fix_stat_owner_mode() { # prints "<uid> <octal mode>" (GNU stat first, then BSD/macOS stat)
  local st="${FIX_STAT_CMD:-stat}" out uid mode
  if "$st" -c '%u %a' -- "$1" 2>/dev/null; then return 0; fi
  out="$("$st" -f '%u %Mp%Lp' "$1" 2>/dev/null)" || return 1
  read -r uid mode <<<"$out"
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  while [ "${#mode}" -gt 1 ] && [ "${mode#0}" != "$mode" ]; do mode="${mode#0}"; done
  printf '%s %s\n' "$uid" "$mode"
}

# ACLs (macOS): the mode can read 0700/0755 while an ACL lets ANOTHER user add files, add subdirectories, delete children or change the
# security of the folder, which is enough to rename our private work folder and plant a link at its old name. `ls -led` prints the ACL
# under the entry (" 0: group:everyone allow add_file"). Rule: an ALLOW entry carrying add_file, add_subdirectory, delete_child, delete,
# write, writedata, append, writesecurity, chown or change_owner is acceptable only for user:<id -un>; any other principal (another
# user, a group, a uuid) refuses. Deny entries and allow entries with benign rights (read, list, search, attributes, readsecurity, sync,
# inherit flags) pass, so the home folder's `group:everyone deny delete` is fine. An ACL line that does not parse, or an `ls` that fails
# on a path that exists, refuses (fail closed). A positively identified GNU ls has no -e and prints no ACL: the rule is then a no-op. FIX_LS_CMD is a test seam.
FIX_ACL_WHY=""

# Fail closed: `ls -led` has to succeed AND print a long-listing header. The no-ACL fallback is only for a tool positively identified as GNU
# coreutils (`ls --version`, first line contains GNU) whose -led failure says the option is unsupported ("invalid option" / "unrecognized
# option"). Any other failure (unreadable path, unknown tool, BSD ls failing, a fake) means the ACL could not be read. The header marker
# says whether ACL lines are expected: a `+` with no ACL lines is truncated output; ACL lines with no `+` (or `@`, which macOS shows when
# the folder also has extended attributes) are inconsistent. Both refuse. Every rights token must be a known macOS name (deny lines too).
FIX_ACL_HEADER_RE='^[-dlbcpsw?][-rwxsStTlL?]{9}([+@.[:space:]]|$)'
FIX_ACL_RIGHTS=" read list readdata write add_file writedata execute search delete append add_subdirectory delete_child readattr writeattr readextattr writeextattr readsecurity writesecurity chown change_owner synchronize sync file_inherit directory_inherit limit_inherit only_inherit "

fix_acl_lines() { # prints the ACL lines of <path> (nothing for GNU ls); 1 when the ACL cannot be read
  local ls="${FIX_LS_CMD:-ls}" out err ver header marker body
  if out="$(LC_ALL=C "$ls" -led "$1" 2>/dev/null)"; then
    header="${out%%$'\n'*}"
    [[ "$header" =~ $FIX_ACL_HEADER_RE ]] || return 1
    marker="${header:10:1}"
    if [ "$header" = "$out" ]; then body=""; else body="${out#*$'\n'}"; fi
    if [ -n "${body//[[:space:]]/}" ]; then
      [ "$marker" = "+" ] || [ "$marker" = "@" ] || return 1
      printf '%s\n' "$body"
    else
      [ "$marker" != "+" ] || return 1
    fi
    return 0
  fi
  err="$(LC_ALL=C "$ls" -led "$1" 2>&1 >/dev/null)"
  ver="$(LC_ALL=C "$ls" --version 2>/dev/null)" || return 1
  [[ "${ver%%$'\n'*}" == *GNU* ]] || return 1
  [[ "$err" == *"invalid option"* || "$err" == *"unrecognized option"* ]] || return 1
  LC_ALL=C "$ls" -ld "$1" >/dev/null 2>&1
}

fix_acl_ok() { # fix_acl_ok <path>: 0 acceptable, 1 refused with FIX_ACL_WHY set
  local lines line rest rights verdict principal me token
  local -a tokens
  FIX_ACL_WHY=""
  lines="$(fix_acl_lines "$1")" || { FIX_ACL_WHY="its ACL could not be read"; return 1; }
  me="$(id -un)"
  while IFS= read -r line; do
    [ -n "${line//[[:space:]]/}" ] || continue
    rest="${line#"${line%%[![:space:]]*}"}"
    case "$rest" in [0-9]*:\ *) rest="${rest#*: }" ;; *) FIX_ACL_WHY="its ACL could not be read"; return 1 ;; esac
    [[ "$rest" == *" "* ]] || { FIX_ACL_WHY="its ACL could not be read"; return 1; }
    rights="${rest##* }"; rest="${rest% *}"
    [[ "$rest" == *" "* ]] || { FIX_ACL_WHY="its ACL could not be read"; return 1; }
    verdict="${rest##* }"; principal="${rest% *}"
    case "$verdict" in allow|deny) ;; *) FIX_ACL_WHY="its ACL could not be read"; return 1 ;; esac
    case "$principal" in user:?*|group:?*|uuid:?*) ;; *) FIX_ACL_WHY="its ACL could not be read"; return 1 ;; esac
    # read -a splits on the comma and never expands a pattern; the shape checks catch the empty tokens read would drop
    case "$rights" in ''|,*|*,|*,,*) FIX_ACL_WHY="its ACL could not be read"; return 1 ;; esac
    IFS=, read -r -a tokens <<<"$rights"
    for token in "${tokens[@]}"; do
      case "$token" in ''|*[!a-z_]*) FIX_ACL_WHY="its ACL could not be read"; return 1 ;; esac
      case "$FIX_ACL_RIGHTS" in *" $token "*) ;; *) FIX_ACL_WHY="its ACL could not be read"; return 1 ;; esac
    done
    [ "$verdict" = allow ] || continue
    for token in "${tokens[@]}"; do
      case "$token" in
        add_file|add_subdirectory|delete_child|delete|write|writedata|append|writesecurity|chown|change_owner)
          [ "$principal" = "user:$me" ] || { FIX_ACL_WHY="an ACL lets another user change it"; return 1; } ;;
      esac
    done
  done <<<"$lines"
  return 0
}

fix_private_dir() {
  local dir="$1" euid p name info uid mode
  FIX_REAL_DIR=""; FIX_TRUST_WHY=""
  p="$(cd -P -- "$dir" 2>/dev/null && pwd -P)" || { FIX_TRUST_WHY="the folder could not be opened"; return 1; }
  euid="$(id -u)"
  info="$(fix_stat_owner_mode "$p")" || { FIX_TRUST_WHY="the folder could not be inspected"; return 1; }
  read -r uid mode <<<"$info"
  case "$mode" in ''|*[!0-7]*) FIX_TRUST_WHY="the folder could not be inspected"; return 1 ;; esac
  [ "$uid" = "$euid" ] || { FIX_TRUST_WHY="not owned by you"; return 1; }
  [ $(( 8#$mode & 8#022 )) -eq 0 ] || { FIX_TRUST_WHY="writable by group or others"; return 1; }
  fix_acl_ok "$p" || { FIX_TRUST_WHY="$(basename -- "$p"): $FIX_ACL_WHY"; return 1; }
  FIX_REAL_DIR="$p"
  while [ "$p" != "/" ]; do
    p="$(dirname -- "$p")"
    name="$(basename -- "$p")"
    info="$(fix_stat_owner_mode "$p")" || { FIX_TRUST_WHY="ancestor $name could not be inspected"; FIX_REAL_DIR=""; return 1; }
    read -r uid mode <<<"$info"
    case "$mode" in ''|*[!0-7]*) FIX_TRUST_WHY="ancestor $name could not be inspected"; FIX_REAL_DIR=""; return 1 ;; esac
    if [ "$uid" != "$euid" ] && [ "$uid" != "0" ]; then FIX_TRUST_WHY="ancestor $name is not owned by you or root"; FIX_REAL_DIR=""; return 1; fi
    if [ $(( 8#$mode & 8#022 )) -ne 0 ] && [ $(( 8#$mode & 8#1000 )) -eq 0 ]; then
      FIX_TRUST_WHY="ancestor $name is writable by others and not sticky"; FIX_REAL_DIR=""; return 1
    fi
    fix_acl_ok "$p" || { FIX_TRUST_WHY="ancestor $name: $FIX_ACL_WHY"; FIX_REAL_DIR=""; return 1; }
  done
  return 0
}
