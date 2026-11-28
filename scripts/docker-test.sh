#!/usr/bin/env bash
# Typecheck and test the combined ML, media, WebRTC and SFU build profile in a
# Linux container (docker/test.Dockerfile). Used by the hk pre-push hook.
#
#   scripts/docker-test.sh                 # typecheck + all tests
#   scripts/docker-test.sh mix test FILE   # any command in the container
#
# deps, _build, tmp and the Hex/XLA caches live in named volumes per checkout,
# so worktrees do not share build state and host builds stay untouched.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=audioflow-test:latest

if ! docker info > /dev/null 2>&1; then
  echo "docker-test: Docker is not running; start it (for example OrbStack) and retry." >&2
  exit 1
fi

docker build --quiet -t "$image" -f "$root/docker/test.Dockerfile" "$root/docker" > /dev/null

key=$(printf '%s' "$root" | shasum | cut -c1-12)

if [ "$#" -eq 0 ]; then
  set -- sh -c "mix deps.get --check-locked > /dev/null && mix typecheck && mix test --warnings-as-errors"
fi

tty=()
[ -t 1 ] && tty=(-t)

# ${tty[@]+...} keeps an empty array valid under `set -u` in macOS bash 3.2.
exec docker run --rm ${tty[@]+"${tty[@]}"} \
  -v "$root:/app" \
  -v "audioflow-$key-deps:/app/deps" \
  -v "audioflow-$key-build:/app/_build" \
  -v "audioflow-$key-tmp:/app/tmp" \
  -v "audioflow-cache-mix:/root/.mix" \
  -v "audioflow-cache-hex:/root/.hex" \
  -v "audioflow-cache-xdg:/root/.cache" \
  "$image" "$@"
