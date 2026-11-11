#!/usr/bin/env bash
# Commit the latest run's step screenshots, video and logs to the
# `simulator-output` branch so they can be viewed on GitHub (or fetched with git)
# without downloading the Actions artifact.
set -euo pipefail

OUT="$PWD/out"
[ -d "$OUT" ] || { echo "No output to publish"; exit 0; }

STATUS="$(cat "$OUT/status.txt" 2>/dev/null || echo "Did not finish")"
XCODE="$(head -1 "$OUT/xcode-version.txt" 2>/dev/null || echo "unknown")"
DEVICE="$(sed -E 's/^ +//; s/ \([0-9A-F-]{36}\)//; s/ \((Booted|Shutdown)\)//' "$OUT/device.txt" 2>/dev/null || echo "unknown")"
RUNTIME="$(cat "$OUT/runtime.txt" 2>/dev/null || echo "unknown")"
POSTGRES="$(cut -d' ' -f1-2 "$OUT/postgres-version.txt" 2>/dev/null || echo "unknown")"
API_TESTS="$(grep -E '^# (pass|fail) ' "$OUT/api-tests.txt" 2>/dev/null | tr '\n' ' ' || true)"
RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

WORK="$(mktemp -d)"
for f in e2e.mp4 api.log api-tests.txt xcodebuild-test.log test-summary.json; do
  [ -f "$OUT/$f" ] && cp "$OUT/$f" "$WORK/"
done
[ -d "$OUT/steps" ] && cp -R "$OUT/steps" "$WORK/steps"

{
  echo "# Latest e2e run"
  echo
  echo "**${STATUS}** · commit \`${GITHUB_SHA::7}\` · [workflow run](${RUN_URL})"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Xcode | ${XCODE} |"
  echo "| Simulator | ${DEVICE}, ${RUNTIME} |"
  echo "| Database | ${POSTGRES} |"
  echo "| API tests | ${API_TESTS:-n/a} |"
  echo
  echo "[Screen recording of the whole test (e2e.mp4)](e2e.mp4) · [API request log](api.log) · [xcodebuild log](xcodebuild-test.log)"
  echo
  if [ -d "$WORK/steps" ]; then
    echo "## Steps"
    echo
    for img in $(ls "$WORK/steps" | sort -V); do
      title="$(sed -E 's/\.[a-z]+$//; s/-/ /g' <<<"$img")"
      echo "### ${title}"
      echo
      echo "<img src=\"steps/${img}\" width=\"300\">"
      echo
    done
  fi
} > "$WORK/README.md"

cd "$WORK"
git init -q -b simulator-output
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add -A
git commit -q -m "E2E output for ${GITHUB_SHA::7}: ${STATUS}"
git push -q --force \
  "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" \
  simulator-output:simulator-output
echo "Published to ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/tree/simulator-output"
