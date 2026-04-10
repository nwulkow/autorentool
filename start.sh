#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-7001}"
PID_FILE="/tmp/autorentool-http-server-${PORT}.pid"

cleanup() {
  if [[ -f "$PID_FILE" ]]; then
    old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "${old_pid:-}" ]] && kill -0 "$old_pid" 2>/dev/null; then
      kill "$old_pid" 2>/dev/null || true
      for _ in {1..20}; do
        if ! kill -0 "$old_pid" 2>/dev/null; then
          break
        fi
        sleep 0.1
      done
      kill -9 "$old_pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
}

trap cleanup EXIT INT TERM HUP

cleanup

if command -v lsof >/dev/null 2>&1; then
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done < <(lsof -ti tcp:"$PORT" 2>/dev/null || true)
fi

if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
fi

python3 "$ROOT_DIR/server.py" "$PORT" &
SERVER_PID="$!"
echo "$SERVER_PID" > "$PID_FILE"

wait "$SERVER_PID"