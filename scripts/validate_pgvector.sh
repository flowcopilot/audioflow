#!/bin/sh
# Private disposable cluster only. Never connects to or alters system PostgreSQL.
set -eu
if [ -n "${PG_BINDIR:-}" ]; then PATH="$PG_BINDIR:$PATH"; export PATH; fi
for program in initdb pg_ctl createdb mix; do
  command -v "$program" >/dev/null || { echo "Missing prerequisite: $program (PostgreSQL with pgvector required)" >&2; exit 1; }
done
cluster=$(mktemp -d "${TMPDIR:-/tmp}/audioflow-pgvector.XXXXXX")
port=${AUDIOFLOW_TEST_PG_PORT:-55484}
cleanup() {
  pg_ctl -D "$cluster/data" -m immediate -w stop >/dev/null 2>&1 || true
  rm -rf "$cluster"
}
trap cleanup EXIT HUP INT TERM
initdb -D "$cluster/data" --auth=trust --username=audioflow > "$cluster/init.log"
# A bind conflict fails instead of using an existing server.
pg_ctl -D "$cluster/data" -l "$cluster/server.log" \
  -o "-h 127.0.0.1 -p $port -k $cluster" -w start
createdb -h 127.0.0.1 -p "$port" -U audioflow audioflow_test
export AUDIOFLOW_PGVECTOR_URL="postgresql://audioflow@127.0.0.1:$port/audioflow_test"
if [ "$#" -eq 0 ]; then set -- test/rag_pgvector_test.exs; fi
mix test "$@"
