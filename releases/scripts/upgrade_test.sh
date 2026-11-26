#!/usr/bin/env bash
# Hot-upgrades a running audio_flow_sfu release during a live call.
#
# 1. Builds release 0.1.0 from this tree.
# 2. Builds a candidate 0.1.1 in a copy of the tree. The candidate changes the
#    AudioFlowSFU.Room state (@vsn 2) and has an appup and a relup for it.
# 3. Starts 0.1.0, holds a two-party LiveKit Python SDK call through it,
#    installs 0.1.1 with Castle, and checks that the call had no reconnect,
#    no audio gap over MAX_GAP_MS (100), and that the room state migrated.
#
# Needs mix, uv and network access for the Python SDK. Set BEFORE_RELEASE to
# a command that runs in each releases/ directory after compilation (for
# example, to fix native library paths on a development machine).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
port="${PORT:-7891}"
max_gap="${MAX_GAP_MS:-100}"
room="upgrade-$(date +%s)"
export MIX_ENV=prod
trap 'stop_all' EXIT

stop_all() {
  [ -n "${monitor:-}" ] && kill "$monitor" 2>/dev/null || true
  [ -x "$work/deploy/bin/audio_flow_sfu" ] && "$work/deploy/bin/audio_flow_sfu" stop 2>/dev/null || true
  rm -rf "$work"
}

build() { # directory, extra environment
  (
    cd "$1/releases"
    mix deps.get >/dev/null
    mix compile >/dev/null
    if [ -n "${BEFORE_RELEASE:-}" ]; then eval "$BEFORE_RELEASE"; fi
    env "${@:2}" mix release audio_flow_sfu --overwrite --quiet
  )
}

echo "== build 0.1.0"
build "$root" CASTLE_UPGRADE_FROM=
cp "$root/releases/_build/prod/audio_flow_sfu-0.1.0.tar.gz" "$work/"

echo "== build candidate 0.1.1"
mkdir -p "$work/candidate"
rsync -a --exclude compat --exclude '_build/test' "$root/sfu" "$root/releases" "$work/candidate/"
(
  cd "$work/candidate"
  sed -i.bak 's/version: "0.1.0"/version: "0.1.1"/' sfu/mix.exs releases/mix.exs
  python3 - <<'EOF'
import re
p = "sfu/lib/audio_flow_sfu/room.ex"
s = open(p).read()
s = s.replace("@vsn 1", "@vsn 2", 1)
s = s.replace(
    "  def code_change(_old_vsn, state, _extra), do: {:ok, state}",
    "  def code_change(1, state, _extra), do: {:ok, Map.put(state, :upgraded, true)}\n"
    "  def code_change({:down, 1}, state, _extra), do: {:ok, Map.delete(state, :upgraded)}\n"
    "  def code_change(_old_vsn, state, _extra), do: {:ok, state}",
    1,
)
open(p, "w").write(s)
room = '{:update, AudioFlowSFU.Room, {:advanced, []}}'
open("sfu/appup.exs", "w").write(
    '{~c"0.1.1", [{~c"0.1.0", [%s]}], [{~c"0.1.0", [%s]}]}\n' % (room, room)
)
open("releases/appup.exs", "w").write('{~c"0.1.1", [{~c"0.1.0", []}], [{~c"0.1.0", []}]}\n')
EOF
)
build "$work/candidate" "CASTLE_UPGRADE_FROM=tar:$work/audio_flow_sfu-0.1.0.tar.gz"

echo "== start 0.1.0 and hold a call"
mkdir -p "$work/deploy"
tar xzf "$work/audio_flow_sfu-0.1.0.tar.gz" -C "$work/deploy"
export AUDIOFLOW_SFU_PORT="$port" AUDIOFLOW_SFU_API_KEY=devkey AUDIOFLOW_SFU_API_SECRET=devsecret
export RELEASE_NODE="sfu_upgrade_$$@127.0.0.1" RELEASE_DISTRIBUTION=name
"$work/deploy/bin/audio_flow_sfu" daemon
for _ in $(seq 1 60); do
  curl -s -o /dev/null "http://127.0.0.1:$port/rtc/v1/validate" && break
  sleep 1
done

export SFU_URL="ws://127.0.0.1:$port" API_KEY=devkey API_SECRET=devsecret ROOM="$room"
export READY_FILE="$work/ready" STOP_FILE="$work/stop"
(cd "$root/sfu/compat/python" && uv run --quiet python hold_call.py >"$work/call.json") &
monitor=$!
for _ in $(seq 1 60); do [ -e "$READY_FILE" ] && break; sleep 1; done
[ -e "$READY_FILE" ] || { echo "the call did not start"; exit 1; }

rpc() { "$work/deploy/bin/audio_flow_sfu" rpc "$1"; }

echo "== install 0.1.1 during the call"
cp "$work/candidate/releases/_build/prod/audio_flow_sfu-0.1.1.tar.gz" "$work/deploy/releases/"
"$work/deploy/bin/castle" unpack 0.1.1
"$work/deploy/bin/castle" install 0.1.1
"$work/deploy/bin/castle" commit
sleep 3

version="$(rpc 'IO.write(Application.spec(:audio_flow_sfu, :vsn))')"
upgraded="$(rpc "IO.write(Map.get(:sys.get_state(AudioFlowSFU.Room.whereis(\"$room\")), :upgraded, false))")"
touch "$STOP_FILE"
wait "$monitor"
monitor=
cat "$work/call.json"

python3 - "$work/call.json" "$version" "$upgraded" "$max_gap" <<'EOF'
import json, sys
call = json.load(open(sys.argv[1]))
version, upgraded, max_gap = sys.argv[2], sys.argv[3], int(sys.argv[4])
errors = []
if version != "0.1.1": errors.append(f"running version {version}")
if upgraded != "true": errors.append("room state was not migrated")
if call["reconnects"]: errors.append(f"{call['reconnects']} reconnects")
if call["max_gap_ms"] > max_gap: errors.append(f"audio gap {call['max_gap_ms']} ms")
if errors:
    sys.exit("FAIL " + "; ".join(errors))
print(f"PASS hot upgrade to {version} during a call (max gap {call['max_gap_ms']} ms)")
EOF
