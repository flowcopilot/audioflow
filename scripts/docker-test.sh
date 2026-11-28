#!/usr/bin/env bash
# Run tests that need Linux native libraries in a container
# (docker/test.Dockerfile). Used by the hk pre-push hook.
#
#   scripts/docker-test.sh                       # root: all-profiles typecheck + tests
#   scripts/docker-test.sh --project sfu         # sfu/: tests
#   scripts/docker-test.sh [--project P] CMD...  # any command in that project
#
# deps, _build, tmp and the Hex/XLA caches live in named volumes per checkout and
# project, so worktrees do not share build state and host builds stay untouched.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=audioflow-test:latest

project=.
if [ "${1:-}" = "--project" ]; then
  project=${2:?--project needs a directory}
  shift 2
fi

if [ ! -f "$root/$project/mix.exs" ]; then
  echo "docker-test: $project is not a Mix project" >&2
  exit 1
fi

if ! docker info > /dev/null 2>&1; then
  echo "docker-test: Docker is not running; start it (for example OrbStack) and retry." >&2
  exit 1
fi

docker build --quiet -t "$image" -f "$root/docker/test.Dockerfile" "$root/docker" > /dev/null

if [ "$#" -eq 0 ]; then
  if [ "$project" = . ]; then
    set -- sh -c "mix deps.get --check-locked > /dev/null && mix typecheck && mix test --warnings-as-errors"
  else
    set -- sh -c "mix deps.get --check-locked > /dev/null && mix test"
  fi
fi

key=$(printf '%s:%s' "$root" "$project" | shasum | cut -c1-12)
workdir=/app/$project

tty=()
[ -t 1 ] && tty=(-t)

# ${tty[@]+...} keeps an empty array valid under `set -u` in macOS bash 3.2.
exec docker run --rm ${tty[@]+"${tty[@]}"} \
  -v "$root:/app" \
  -w "$workdir" \
  -v "audioflow-$key-deps:$workdir/deps" \
  -v "audioflow-$key-build:$workdir/_build" \
  -v "audioflow-$key-tmp:$workdir/tmp" \
  -v "audioflow-cache-mix:/root/.mix" \
  -v "audioflow-cache-hex:/root/.hex" \
  -v "audioflow-cache-xdg:/root/.cache" \
  "$image" "$@"
