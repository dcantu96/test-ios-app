#!/usr/bin/env bash
# Start a local Postgres and the Time Capsule API on this Mac (the same machine
# the iOS Simulator runs on, so the app reaches it at http://localhost:8787).
# With DEMO=1 a second API runs on :8788 against its own database, for the demo recording.
set -euo pipefail

OUT="${OUT:-$PWD/out}"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"
mkdir -p "$OUT"

echo "::group::Postgres"
if ! brew list postgresql@17 >/dev/null 2>&1; then
  brew install postgresql@17
fi
PG="$(brew --prefix postgresql@17)/bin"
"$PG/initdb" -D "$TMP/pgdata" -A trust -U postgres >/dev/null
"$PG/pg_ctl" -D "$TMP/pgdata" -l "$TMP/postgres.log" -o "-p 5432 -k $TMP" -w start
"$PG/createdb" -h 127.0.0.1 -U postgres capsules        # used by the app
"$PG/createdb" -h 127.0.0.1 -U postgres capsules_test   # used by the API tests only
"$PG/createdb" -h 127.0.0.1 -U postgres capsules_demo   # used by the demo recording
"$PG/psql" -h 127.0.0.1 -U postgres -tAc "select version()" | tee "$OUT/postgres-version.txt"
echo "::endgroup::"

echo "::group::API tests"
cd api
npm ci --no-fund --no-audit
DATABASE_URL="postgres://postgres@127.0.0.1:5432/capsules_test" npm test 2>&1 | tee "$OUT/api-tests.txt"
echo "::endgroup::"

export DATABASE_URL="postgres://postgres@127.0.0.1:5432/capsules"
echo "DATABASE_URL=$DATABASE_URL" >> "${GITHUB_ENV:-/dev/null}"

echo "::group::Start API"
nohup npm start > "$OUT/api.log" 2>&1 &
if [ "${DEMO:-0}" = "1" ]; then
  PORT=8788 DATABASE_URL="postgres://postgres@127.0.0.1:5432/capsules_demo" nohup npm start > "$OUT/api-demo.log" 2>&1 &
fi
for port in 8787 $([ "${DEMO:-0}" = "1" ] && echo 8788); do
  for _ in $(seq 1 60); do
    if curl -fsS "http://localhost:$port/health" > "$OUT/api-health-$port.json" 2>/dev/null; then break; fi
    sleep 0.5
  done
  echo "API :$port $(cat "$OUT/api-health-$port.json")"
done
echo
echo "::endgroup::"
