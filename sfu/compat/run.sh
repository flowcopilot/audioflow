#!/usr/bin/env bash
# Runs the LiveKit SDK compatibility tests against a local SFU:
#   compat/run.sh          both SDKs
#   compat/run.sh js       livekit-client 2.24.0 in headless Chromium
#   compat/run.sh python   livekit 1.2.1 (Python, Rust core)
set -euo pipefail
cd "$(dirname "$0")/.."

export SFU_URL="ws://127.0.0.1:${PORT:-7880}" API_KEY=devkey API_SECRET=devsecret
AUDIOFLOW_SFU_PORT="${PORT:-7880}" AUDIOFLOW_SFU_API_KEY=$API_KEY \
  AUDIOFLOW_SFU_API_SECRET=$API_SECRET mix run --no-halt &
sfu=$!
trap 'kill $sfu 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
  curl -s -o /dev/null "http://127.0.0.1:${PORT:-7880}/rtc/v1/validate" && break
  sleep 1
done

suites="${1:-js python}"
for suite in $suites; do
  case $suite in
    js)
      (cd compat/js && npm ci --no-audit --no-fund && npx playwright install chromium-headless-shell &&
        node compat.mjs)
      ;;
    python) (cd compat/python && uv run --quiet python compat.py) ;;
  esac
done
