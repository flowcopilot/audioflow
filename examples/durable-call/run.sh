#!/usr/bin/env bash
# Runs the durable-call example: an SFU node, agent node A with a call in a
# new room, and the browser page. With SMOKE=1, smoke.mjs drives a headless
# browser, kills node A and starts node B. Needs AUDIOFLOW_POSTGRES_URL.
set -euo pipefail
: "${AUDIOFLOW_POSTGRES_URL:?set AUDIOFLOW_POSTGRES_URL to a PostgreSQL database}"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
room="durable-$(date +%s)"
logs="$(mktemp -d)"
echo "logs: $logs"
export AUDIOFLOW_SFU=1 LEASE_MS="${LEASE_MS:-5000}"
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT

(cd "$root/sfu" && AUDIOFLOW_SFU_PORT=7880 AUDIOFLOW_SFU_API_KEY=devkey \
  AUDIOFLOW_SFU_API_SECRET=devsecret \
  exec elixir --name sfu@127.0.0.1 --cookie audioflow -S mix run --no-halt) >"$logs/sfu.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 120); do
  curl -s -o /dev/null "http://127.0.0.1:7880/rtc/v1/validate" && break
  sleep 1
done

token="$(cd "$root/sfu" && mix run --no-start -e \
  "IO.write(AudioFlowSFU.Token.generate(\"devkey\", \"devsecret\", \"user\", \"$room\"))")"

agent() { # name, extra arguments
  echo "cd '$root' && exec elixir --name $1@127.0.0.1 --cookie audioflow -S mix run --no-start examples/durable-call/agent.exs ${2:-}"
}

sh -c "$(agent agent_a "--create $room")" >"$logs/agent_a.log" 2>&1 &
agent_a=$!
pids+=("$agent_a")
for _ in $(seq 1 180); do grep -q "in room" "$logs/agent_a.log" && break; sleep 1; done
grep "in room" "$logs/agent_a.log" || { cat "$logs/agent_a.log"; exit 1; }

cd "$here"
if [ "${SMOKE:-0}" = 1 ]; then
  SFU_URL=ws://127.0.0.1:7880 TOKEN="$token" AGENT_A_PID="$agent_a" \
    AGENT_B_CMD="$(agent agent_b)" node smoke.mjs
else
  echo "Open: http://127.0.0.1:8080/?url=ws://127.0.0.1:7880&token=$token"
  echo "Stop node A with: kill -9 $agent_a"
  echo "Start node B with: $(agent agent_b)"
  node serve.mjs
fi
