#!/usr/bin/env bash
# Start a local Postgres and the Time Capsule API on this Mac (the same machine
# the iOS Simulator runs on, so the app reaches it at http://localhost:8787).
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
for _ in $(seq 1 30); do
  if curl -fsS http://localhost:8787/health > "$OUT/api-health.json" 2>/dev/null; then break; fi
  sleep 1
done
cat "$OUT/api-health.json"
echo
echo "::endgroup::"
