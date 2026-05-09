#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# benchmark-app.sh — Local app latency + throughput benchmark.
#
# Boots the app with DB_FAKE=1 / REDIS_FAKE=1 on a sandbox port, fires N
# requests at concurrency C against every endpoint, prints p50 / p95 / p99 /
# avg / requests-per-sec / error count.
#
# Run:
#   make bench-app                                          # default 500@10
#   make bench-app ARGS="--requests 2000 --concurrency 25"
#   ./scripts/benchmark-app.sh --json                       # JSON to stdout
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REQUESTS=500
CONCURRENCY=10
JSON_OUT=0
PORT=3099

while [[ $# -gt 0 ]]; do
  case "$1" in
    --requests)    REQUESTS="$2"; shift 2;;
    --concurrency) CONCURRENCY="$2"; shift 2;;
    --port)        PORT="$2"; shift 2;;
    --json)        JSON_OUT=1; shift;;
    -h|--help)
      echo "Usage: $0 [--requests 500] [--concurrency 10] [--port 3099] [--json]"
      exit 0;;
    *) echo "unknown arg: $1"; exit 1;;
  esac
done

# Free the port if something stale is bound to it (use lsof, not pkill -f, to
# avoid killing unrelated processes that happen to match a substring).
if command -v lsof >/dev/null 2>&1; then
  STALE=$(lsof -t -i :$PORT 2>/dev/null || true)
  if [[ -n "$STALE" ]]; then
    kill -KILL $STALE 2>/dev/null || true
    sleep 0.3
  fi
fi

# Start app
cd "$ROOT/app"
DB_FAKE=1 REDIS_FAKE=1 NODE_ENV=production PORT=$PORT \
  node src/server.js > /tmp/bench-app.log 2>&1 &
APP_PID=$!
cleanup() { kill -KILL $APP_PID 2>/dev/null || true; }
trap cleanup EXIT

# Wait for ready (max ~5s)
for _ in 1 2 3 4 5; do
  if curl -sf "http://127.0.0.1:$PORT/health/live" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -sf "http://127.0.0.1:$PORT/health/live" >/dev/null 2>&1; then
  echo "ERROR: app failed to boot on port $PORT"
  echo "── log tail ──"
  tail -10 /tmp/bench-app.log
  exit 1
fi

[[ $JSON_OUT -eq 0 ]] && echo "▸ App benchmark — $REQUESTS requests / $CONCURRENCY concurrency / port $PORT"

# Hand off to the Node runner — it's faster than shelling out to curl in a loop
node "$ROOT/scripts/_bench-runner.mjs" "$PORT" "$REQUESTS" "$CONCURRENCY" "$JSON_OUT"
