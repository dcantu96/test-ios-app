#!/usr/bin/env bash
# Sourced by run-e2e.sh and run-demo.sh: pick the newest Xcode, the newest general iOS runtime and an
# iPhone Pro, then boot it with a clean status bar. Expects OUT; sets XCODE, RUNTIME_ID and UDID.

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
