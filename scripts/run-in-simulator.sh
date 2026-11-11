#!/usr/bin/env bash
# Build the app with the newest Xcode on this Mac, boot the newest iOS Simulator,
# launch the app and capture screenshots + a short video into ./out.
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
import json, sys
rts = [r for r in json.load(open(sys.argv[1]))["runtimes"]
       if r.get("isAvailable") and r.get("platform", r["name"].split()[0]) == "iOS"]
rts.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
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

echo "::group::Generate project and build"
xcodegen generate
xcodebuild \
  -project "$SCHEME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build > "$OUT/build.log" 2>&1 || {
    echo "Build failed. Last lines of the log:"; grep -E "error:|warning:" "$OUT/build.log" | head -50
    tail -60 "$OUT/build.log"; exit 1; }
tail -5 "$OUT/build.log"
APP="$(find build/Build/Products -maxdepth 2 -name "$SCHEME.app" -path '*iphonesimulator*' | head -1)"
echo "App: $APP"
echo "::endgroup::"

echo "::group::Install, launch, capture"
xcrun simctl install "$UDID" "$APP"
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/run.mp4" &
REC_PID=$!
sleep 2
xcrun simctl launch "$UDID" "$BUNDLE_ID"
sleep 6
xcrun simctl io "$UDID" screenshot "$OUT/screenshot.png"
sleep 2
kill -INT "$REC_PID" || true
wait "$REC_PID" || true
xcrun simctl spawn "$UDID" launchctl list | grep -q "$BUNDLE_ID" \
  && echo "App is running" | tee "$OUT/status.txt" \
  || { echo "App is NOT running" | tee "$OUT/status.txt"; exit 1; }
echo "::endgroup::"
