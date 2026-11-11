#!/usr/bin/env bash
# Run the XCUITest end-to-end suite (UITests/) on the e2e simulator against the live API, from the build that
# scripts/build.sh made, and export the step screenshots to ./out. Needs UDID_E2E (scripts/sim.sh prepare).
set -euo pipefail

SCHEME="${SCHEME:-CloudSim}"
OUT="${OUT:-$PWD/out}"
UDID="${SIM_UDID:?run scripts/sim.sh prepare first}"
mkdir -p "$OUT"

echo "::group::Run end-to-end UI tests"
rm -rf "$OUT/e2e.xcresult"
set +e
API_URL="${API_URL:-http://localhost:8787}" \
TEST_RUNNER_API_URL="${API_URL:-http://localhost:8787}" \
xcodebuild test-without-building \
  -project CloudSim.xcodeproj \
  -scheme "$SCHEME" \
  -destination "id=$UDID" \
  -derivedDataPath build \
  -resultBundlePath "$OUT/e2e.xcresult" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  > "$OUT/xcodebuild-test.log" 2>&1
TEST_STATUS=$?
set -e
grep -E "Test Case|error:|failed|passed|\*\* TEST" "$OUT/xcodebuild-test.log" | tail -40 || true
echo "::endgroup::"

echo "::group::Export screenshots"
if [ -d "$OUT/e2e.xcresult" ]; then
  xcrun xcresulttool get test-results summary --path "$OUT/e2e.xcresult" > "$OUT/test-summary.json" || true
  mkdir -p "$OUT/raw-attachments" "$OUT/steps"
  xcrun xcresulttool export attachments --path "$OUT/e2e.xcresult" --output-path "$OUT/raw-attachments" || true
  python3 - "$OUT/raw-attachments" "$OUT/steps" <<'PY'
import json, os, re, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
manifest = os.path.join(src, "manifest.json")
if not os.path.exists(manifest):
    sys.exit(0)
for test in json.load(open(manifest)):
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
        name = re.sub(r"_\d+_[0-9A-F-]{36}", "", name)          # drop Xcode's index/UUID suffix
        stem, ext = os.path.splitext(name)
        slug = re.sub(r"[^a-z0-9]+", "-", stem.lower()).strip("-")
        shutil.copy(os.path.join(src, a["exportedFileName"]), os.path.join(dst, slug + (ext or ".png")))
        print("step:", slug)
PY
fi
echo "::endgroup::"

if [ "$TEST_STATUS" -eq 0 ]; then
  echo "E2E passed" | tee "$OUT/status.txt"
else
  echo "E2E failed" | tee "$OUT/status.txt"
  tail -80 "$OUT/xcodebuild-test.log"
fi
exit "$TEST_STATUS"
