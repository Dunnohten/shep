#!/bin/bash
# The temp directory of scripts/test-scripts.sh: made once, removed at exit, and ONLY that directory.
#   shep_tmp_make      creates <TMPDIR or /tmp>/shep-test-scripts.XXXXXX and records its identity (path, this process, inode)
#   shep_tmp_cleanup   removes the recorded directory, and nothing else, when every check below holds; quiet no-op otherwise
# Removal needs: a recorded path that is a direct child of the temp directory, a basename starting with "shep-test-scripts.", a real
# directory (not a symlink), made by THIS process, with the inode recorded at creation. Any other shep-test-scripts.* directory (an
# older run, a sibling) is never looked at. SHEP_TEST_KEEP=1 keeps the directory for debugging. The exit status of the caller is
# preserved (an EXIT trap running this function does not change it).
SHEP_TMP_DIR=""
SHEP_TMP_PID=""
SHEP_TMP_INODE=""

shep_tmp_inode() { ls -di -- "$1" 2>/dev/null | awk '{print $1}'; }

shep_tmp_make() {
  local base="${TMPDIR:-/tmp}"
  SHEP_TMP_DIR="$(mktemp -d "${base%/}/shep-test-scripts.XXXXXX")" || return 1
  SHEP_TMP_PID="$$"
  SHEP_TMP_INODE="$(shep_tmp_inode "$SHEP_TMP_DIR")"
}

shep_tmp_cleanup() {
  local rc=$? dir="${SHEP_TMP_DIR:-}" base parent
  if [ "${SHEP_TEST_KEEP:-}" = 1 ]; then
    [ -z "$dir" ] || echo "kept (SHEP_TEST_KEEP=1): $dir" >&2
    return "$rc"
  fi
  [ -n "$dir" ] || return "$rc"
  [ "${SHEP_TMP_PID:-}" = "$$" ] || return "$rc"
  case "$(basename -- "$dir")" in shep-test-scripts.?*) ;; *) return "$rc" ;; esac
  [ -d "$dir" ] && [ ! -L "$dir" ] || return "$rc"
  [ -n "${SHEP_TMP_INODE:-}" ] && [ "$(shep_tmp_inode "$dir")" = "$SHEP_TMP_INODE" ] || return "$rc"
  base="$(cd -P -- "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || return "$rc"
  parent="$(cd -P -- "$(dirname -- "$dir")" 2>/dev/null && pwd -P)" || return "$rc"
  [ -n "$base" ] && [ "$parent" = "$base" ] || return "$rc"
  rm -rf -- "$dir" || echo "could not remove $dir" >&2
  return "$rc"
}
