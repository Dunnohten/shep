#!/bin/bash
# Start the local Muse Glimmer server (mlx_vlm.server, OpenAI-compatible) in the background.
#   scripts/glimmer-server.sh            start
#   GLIMMER_PORT=8080 GLIMMER_MODEL=~/models/Muse-Glimmer-30B-4bit scripts/glimmer-server.sh
# Refuses to start when: free + inactive memory is under 24 GB, or an mlx_vlm / Glimmer server is already running
# (it prints that server's pid and port so you can reuse it). Touches no other model server and no launchd job.
# macOS only (vm_stat, lsof). State dir: GLIMMER_STATE_DIR (default ~/Library/Caches/Shep/glimmer). It is created under umask 077, and
# the script refuses to start when it is a symlink, not a directory, not owned by you, or not mode exactly 700, or when the log or
# pid file path is a symlink. A pid file naming a running process also refuses; a stale one is moved aside to <pidfile>.stale-<epoch>.
#   scripts/glimmer-server.sh --check-state-dir   only validates the state dir and the two file paths, then exits
# Logs: $GLIMMER_STATE_DIR/glimmer-server.log. Stop it with: kill $(cat "$GLIMMER_STATE_DIR/glimmer-server.pid")
set -euo pipefail

MIN_FREE_GB=24
PORT="${GLIMMER_PORT:-8080}"
HOST="127.0.0.1"
MODEL="${GLIMMER_MODEL:-$HOME/models/Muse-Glimmer-30B-4bit}"
VENV="${GLIMMER_VENV:-$HOME/models/venv}"
STATE_DIR="${GLIMMER_STATE_DIR:-$HOME/Library/Caches/Shep/glimmer}"
STATE_DIR="${STATE_DIR%/}"
LOG="$STATE_DIR/glimmer-server.log"
PIDFILE="$STATE_DIR/glimmer-server.pid"

# 0. State directory: validated before anything else starts.
# shellcheck disable=SC1091
. "$(dirname "$0")/glimmer-state-lib.sh"
glimmer_check_state_dir "$STATE_DIR" "$LOG" "$PIDFILE" || exit 1
[ "${1:-}" = "--check-state-dir" ] && exit 0

# 1. Memory: free + inactive pages, in GB.
page_size="$(sysctl -n hw.pagesize)"
pages() { vm_stat | awk -v key="$1" '$0 ~ key { gsub(/\./, "", $NF); print $NF }'; }
free_pages="$(pages 'Pages free')"
inactive_pages="$(pages 'Pages inactive')"
free_gb=$(( (free_pages + inactive_pages) * page_size / 1073741824 ))
if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
  echo "refusing to start: only ${free_gb} GB free+inactive memory, need ${MIN_FREE_GB} GB. Close something heavy first." >&2
  exit 1
fi

# 2. Already running? (any process holding a Muse-Glimmer model path)
existing="$(pgrep -f 'Muse-Glimmer' || true)"   # only a server holding a Glimmer model; other mlx_vlm servers (other models) are not a conflict
if [ -n "$existing" ]; then
  for pid in $existing; do
    [ "$pid" = "$$" ] && continue
    port="$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 { n=split($9, a, ":"); print a[n]; exit }')"
    echo "a Glimmer / mlx_vlm server is already running: pid ${pid}, port ${port:-unknown}." >&2
    echo "reuse it: set SHEP_GLIMMER_URL=http://127.0.0.1:${port:-$PORT}/v1 (or leave the default if that is 8080)." >&2
    exit 1
  done
fi

# 3. Prerequisites.
[ -d "$MODEL" ] || { echo "model folder not found: $MODEL" >&2; exit 1; }
[ -x "$VENV/bin/python" ] || { echo "python not found in $VENV" >&2; exit 1; }
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use by another process; set GLIMMER_PORT to a free port." >&2
  exit 1
fi

# 4. Start, detached. The model argument is also what Shep sends as "model" (see SHEP_GLIMMER_MODEL), so keep them equal.
glimmer_claim_pidfile "$PIDFILE" || exit 1
umask 077
nohup "$VENV/bin/python" -m mlx_vlm.server --model "$MODEL" --host "$HOST" --port "$PORT" >>"$LOG" 2>&1 &
echo $! >| "$PIDFILE"
echo "started Glimmer: pid $(cat "$PIDFILE"), http://$HOST:$PORT/v1, model $MODEL"
echo "log: $LOG   stop: kill \$(cat '$PIDFILE')   (loading 18 GiB takes a while; watch for the server's ready line)"
echo "tell Shep: SHEP_GLIMMER_MODEL='$MODEL' SHEP_GLIMMER_URL='http://$HOST:$PORT/v1'"
