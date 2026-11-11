#!/usr/bin/env bash
# Commit the latest e2e run's step screenshots and logs to a results branch
# (PUBLISH_BRANCH, e.g. e2e-output/my-feature) so they can be viewed on GitHub or fetched with git
# without downloading the Actions artifact. cleanup.yml deletes a PR's results branch when it closes.
set -euo pipefail

OUT="$PWD/out"
BRANCH="${PUBLISH_BRANCH:-e2e-output/main}"
SHA="${HEAD_SHA:-$GITHUB_SHA}"   # on a PR, GITHUB_SHA is the merge commit; HEAD_SHA is the branch tip
[ -d "$OUT" ] || { echo "No output to publish"; exit 0; }

STATUS="$(cat "$OUT/status.txt" 2>/dev/null || echo "Did not finish")"
XCODE="$(head -1 "$OUT/xcode-version.txt" 2>/dev/null || echo "unknown")"
DEVICE="$(sed -E 's/ \([0-9A-F-]{36}\)//; s/ \((Booted|Shutdown)\)//; s/^ +//; s/ +$//' "$OUT/device.txt" 2>/dev/null || echo "unknown")"
RUNTIME="$(cat "$OUT/runtime.txt" 2>/dev/null || echo "unknown")"
POSTGRES="$(cut -d' ' -f1-2 "$OUT/postgres-version.txt" 2>/dev/null || echo "unknown")"
# Node's test runner prints "ℹ pass 3" (spec reporter) or "# pass 3" (TAP).
API_TESTS="$(grep -E '^(#|ℹ) (pass|fail) ' "$OUT/api-tests.txt" 2>/dev/null | sed -E 's/^(#|ℹ) //' | paste -sd ',' - | sed 's/,/, /g' || true)"
RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

WORK="$(mktemp -d)"
for f in api.log api-tests.txt xcodebuild-test.log test-summary.json; do
  [ -f "$OUT/$f" ] && cp "$OUT/$f" "$WORK/"
done
[ -d "$OUT/steps" ] && cp -R "$OUT/steps" "$WORK/steps"

{
  echo "# Latest e2e run"
  echo
  echo "**${STATUS}** · commit \`${SHA::7}\` · [workflow run](${RUN_URL})"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Xcode | ${XCODE} |"
  echo "| Simulator | ${DEVICE}, ${RUNTIME} |"
  echo "| Database | ${POSTGRES} |"
  echo "| API tests | ${API_TESTS:-n/a} |"
  echo
  echo "Branch \`${GITHUB_HEAD_REF:-$GITHUB_REF_NAME}\` · [API request log](api.log) · [xcodebuild log](xcodebuild-test.log)"
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
git init -q -b results
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add -A
git commit -q -m "E2E output for ${SHA::7}: ${STATUS}"
git push -q --force \
  "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" \
  "results:refs/heads/$BRANCH"
echo "Published to ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/tree/$BRANCH"
