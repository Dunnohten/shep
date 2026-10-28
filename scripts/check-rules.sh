#!/bin/bash
# Source rules from the brief, checked by grep. Run by scripts/test.sh.
#  1. No AppleScript / osascript / NSAppleScript anywhere in Swift sources or scripts.
#  2. The app (Shep/) and the scripts never name another local model server.
#  3. Backticked commit hashes in README.md and docs/*.md resolve on main.
#  5. No network session outside MetaClient.swift.
#  6. No region video capture (screencapture -v / -R) in scripts/ except the old backdrop-rectangle scripts.
#  4. A banned word appears nowhere in the tracked files or the branch's commit messages.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
# Patterns are assembled so this file does not match itself.
a="osa""script"; b="Apple""Script"; c="OSA""Script"
if grep -rniE "$a|$b|$c" --include='*.swift' --include='*.sh' --include='*.yml' Shep ShepCore/Sources scripts project.yml \
     | grep -v 'scripts/check-rules.sh'; then
  echo "FAIL: scripting-bridge automation found (see lines above)" >&2; fail=1
fi
p="11""234"
if grep -rnE "$p" --include='*.swift' --include='*.sh' Shep scripts | grep -v 'scripts/check-rules.sh'; then
  echo "FAIL: another local model is referenced (see lines above)" >&2; fail=1
fi
# 5. One HTTP session only: URLSessionMetaTransport (MetaClient.swift) owns the redirect-refusing session. No other app or
#    library source creates a URLSession, uses URLSession.shared, or opens a URL connection.
u="URL""Session"
if grep -rnE "${u}(\(|\.shared|Configuration)|NS""URLConnection|\.dataTask\(|\.downloadTask\(|\.uploadTask\(" --include='*.swift' Shep ShepCore/Sources \
     | grep -v 'ShepCore/Sources/MetaClient.swift'; then
  echo "FAIL: a network session outside MetaClient.swift (see lines above)" >&2; fail=1
fi
# 6. The fix demo is recorded window-bound inside Shep (ScreenCaptureKit), never as a fixed screen region: no script under scripts/
#    runs screencapture with -v or -R, except the older scripts that capture only a Shep-owned plain-backdrop rectangle
#    (record-cycle.sh, record-demo.sh) or one window's still (docked-shot.sh).
sc="screen""capture"
for f in scripts/*.sh; do
  case "$(basename "$f")" in check-rules.sh|record-cycle.sh|record-demo.sh|docked-shot.sh) continue ;; esac
  if grep -vE '^[[:space:]]*#' "$f" | grep -nE "${sc}[^|;&]*( -[A-Za-z]*[vR]([A-Za-z]*| )|--video)"; then
    echo "FAIL: $f runs a region or video screen capture (use the window-bound recorder inside Shep)" >&2; fail=1
  fi
done
# 3. Every commit hash written in backticks in a tracked README.md or docs/*.md is a commit on main (a hash that does not
#    resolve sends a reader to an error). Hashes of other projects' commits are written without backticks.
if git rev-parse --git-dir >/dev/null 2>&1; then
  tip=main; git rev-parse --verify -q main >/dev/null || tip=HEAD
  for h in $(git ls-files -z README.md 'docs/*.md' | xargs -0 grep -ohE '`[0-9a-f]{7,40}`' /dev/null | tr -d '`' | grep '[0-9]' | sort -u); do
    if ! git cat-file -e "$h^{commit}" 2>/dev/null || ! git merge-base --is-ancestor "$h" "$tip" 2>/dev/null; then
      echo "FAIL: $h (README.md or docs/) is not a commit on $tip" >&2; fail=1
    fi
  done
  # 4. A word that must never appear in the tracked files or in the commit messages of the branch.
  w="d""uo"
  if git ls-files -z | xargs -0 grep -liE "$w" 2>/dev/null | grep -v 'scripts/check-rules.sh'; then
    echo "FAIL: a banned word is in the tree (files above)" >&2; fail=1
  fi
  if git log "$tip" --format=%B | grep -qiE "$w"; then
    echo "FAIL: a banned word is in a commit message on $tip" >&2; fail=1
  fi
fi
# 7. scripts/e2e-glimmer.sh --window knows which app it captured, so a pid it cannot resolve must stop the run (a capture that
#    arrives with no owner would be treated as a bare, unattested file).
if ! grep -q 'refusing: could not resolve the process' scripts/e2e-glimmer.sh; then
  echo "FAIL: scripts/e2e-glimmer.sh --window must refuse when the owner's process id cannot be resolved" >&2; fail=1
fi
[ "$fail" -eq 0 ] && echo "check-rules: ok"
exit "$fail"
