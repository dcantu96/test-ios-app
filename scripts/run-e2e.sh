#!/usr/bin/env bash
# Pick the newest Xcode and iOS Simulator on this Mac, then run the XCUITest
# end-to-end suite against the live API, recording video and exporting step screenshots to ./out.
set -euo pipefail

SCHEME="${SCHEME:-CloudSim}"
BUNDLE_ID="${BUNDLE_ID:-com.dcantu96.CloudSim}"
OUT="${OUT:-$PWD/out}"
mkdir -p "$OUT"

echo "::group::Select newest Xcode"
echo "Installed:"; ls -d /Applications/Xcode*.app
XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | grep -v -i beta | sort -V | tail -1)"
sudo xcode-select -s "$XCODE/Contents/Developer"
xcodebuild -version | tee "$OUT/xcode-version.txt"
echo "::endgroup::"

echo "::group::Pick newest iOS runtime and an iPhone"
xcrun simctl list runtimes -j > "$OUT/runtimes.json"
RUNTIME_ID="$(python3 - "$OUT/runtimes.json" "$OUT/runtime.txt" <<'PY'
import json, re, sys
rts = [r for r in json.load(open(sys.argv[1]))["runtimes"]
       if r.get("isAvailable") and r.get("platform", r["name"].split()[0]) == "iOS"]
# Prefer general runtimes (…SimRuntime.iOS-27-2) over device-specific ones
# (…SimRuntime.iOS-27-2-iPhone19-4), which only run a single new device model.
general = re.compile(r"\.iOS-\d+(-\d+)*$")
rts.sort(key=lambda r: (bool(general.search(r["identifier"])),
                        [int(x) for x in r["version"].split(".")]))
label = lambda r: "%s (%s)" % (r["name"], r.get("buildversion", ""))
for r in rts:
    print("Available runtime: " + label(r), file=sys.stderr)
open(sys.argv[2], "w").write(label(rts[-1]) + "\n")
print(rts[-1]["identifier"])
PY
)"
echo "Runtime: $RUNTIME_ID ($(cat "$OUT/runtime.txt"))"

xcrun simctl list devices -j > "$OUT/devices.json"
UDID="$(python3 - "$OUT/devices.json" "$RUNTIME_ID" <<'PY'
import json, sys
devs = json.load(open(sys.argv[1]))["devices"].get(sys.argv[2], [])
phones = [d for d in devs if d.get("isAvailable") and d["name"].startswith("iPhone")]
pref = [d for d in phones if "Pro" in d["name"] and "Max" not in d["name"]] or phones
print(pref[-1]["udid"] if pref else "")
PY
)"
if [ -z "$UDID" ]; then
  # No ready-made iPhone for this runtime: create one from a device type it supports.
  DEVTYPE="$(python3 - "$OUT/runtimes.json" "$RUNTIME_ID" <<'PY'
import json, sys
r = [x for x in json.load(open(sys.argv[1]))["runtimes"] if x["identifier"] == sys.argv[2]][0]
phones = [d for d in r.get("supportedDeviceTypes", []) if d.get("productFamily") == "iPhone"]
pref = [d for d in phones if "Pro" in d["name"] and "Max" not in d["name"]] or phones
print(pref[-1]["identifier"])
PY
)"
  UDID="$(xcrun simctl create "CloudSim iPhone" "$DEVTYPE" "$RUNTIME_ID")"
fi
xcrun simctl list devices | grep "$UDID" | tee "$OUT/device.txt"
echo "::endgroup::"

echo "::group::Boot simulator"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance light || true
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 || true
echo "::endgroup::"


echo "::group::Generate project"
xcodegen generate
echo "::endgroup::"

echo "::group::Run end-to-end UI tests"
rm -rf "$OUT/e2e.xcresult"
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/e2e.mp4" &
REC_PID=$!
sleep 1
set +e
API_URL="${API_URL:-http://localhost:8787}" \
TEST_RUNNER_API_URL="${API_URL:-http://localhost:8787}" \
xcodebuild test \
  -project "$SCHEME.xcodeproj" \
  -scheme "$SCHEME" \
  -destination "id=$UDID" \
  -derivedDataPath build \
  -resultBundlePath "$OUT/e2e.xcresult" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  > "$OUT/xcodebuild-test.log" 2>&1
TEST_STATUS=$?
set -e
kill -INT "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true
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
