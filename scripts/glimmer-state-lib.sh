#!/bin/bash
# State-directory checks for scripts/glimmer-server.sh. Sourced; defines functions only and does nothing on its own.
#   glimmer_check_state_dir <dir> <log> <pidfile>   create <dir> (umask 077) and refuse unless it is a real directory, owned by
#                                                   this user, mode exactly 700, and <log> / <pidfile> are not symlinks
#   glimmer_claim_pidfile <pidfile>                 create <pidfile> exclusively (noclobber, mode 600); refuse when it names a
#                                                   live process; a stale one is moved aside to <pidfile>.stale-<epoch>, never removed
# Every refusal prints one line to stderr and returns non-zero.

glimmer_stat() { # glimmer_stat <bsd format> <gnu format> <path>
  stat -f "$1" "$3" 2>/dev/null | grep -E '^[0-9]+$' || stat -c "$2" "$3" 2>/dev/null
}

glimmer_check_state_dir() {
  local dir="$1" log="$2" pidfile="$3" owner mode
  if [ -L "$dir" ]; then echo "refusing: state dir $dir is a symlink." >&2; return 1; fi
  if [ ! -e "$dir" ]; then
    (umask 077 && mkdir -p "$dir") || { echo "refusing: could not create state dir $dir." >&2; return 1; }
  fi
  if [ -L "$dir" ] || [ ! -d "$dir" ]; then echo "refusing: state dir $dir is not a real directory." >&2; return 1; fi
  owner="$(glimmer_stat %u %u "$dir")"
  if [ "$owner" != "$(id -u)" ]; then echo "refusing: state dir $dir is not owned by you (owner uid ${owner:-unknown})." >&2; return 1; fi
  mode="$(glimmer_stat %Lp %a "$dir")"
  if [ "$mode" != 700 ]; then echo "refusing: state dir $dir has mode ${mode:-unknown}, need exactly 700 (chmod 700 it, or set GLIMMER_STATE_DIR)." >&2; return 1; fi
  if [ -L "$log" ]; then echo "refusing: log file $log is a symlink." >&2; return 1; fi
  if [ -L "$pidfile" ]; then echo "refusing: pid file $pidfile is a symlink." >&2; return 1; fi
}

glimmer_claim_pidfile() {
  local pidfile="$1" old aside
  if [ -L "$pidfile" ]; then echo "refusing: pid file $pidfile is a symlink." >&2; return 1; fi
  if [ -e "$pidfile" ]; then
    old="$(head -n 1 "$pidfile" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && ps -p "$old" >/dev/null 2>&1; then
      echo "refusing: $pidfile names a running process (pid $old)." >&2
      return 1
    fi
    aside="$pidfile.stale-$(date +%s)"
    mv -n "$pidfile" "$aside" 2>/dev/null && [ ! -e "$pidfile" ] || { echo "refusing: could not move the stale $pidfile aside." >&2; return 1; }
  fi
  ( set -o noclobber; umask 077; : > "$pidfile" ) 2>/dev/null || { echo "refusing: could not create $pidfile exclusively." >&2; return 1; }
}
