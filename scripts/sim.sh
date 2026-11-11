#!/usr/bin/env bash
# Simulator helpers for CI.
#
#   scripts/sim.sh prepare   Select the newest Xcode, pick the newest *general* iOS runtime and the newest iPhone
#                            Pro, and turn off Spotlight on the runner. Writes SIM_UDID to $GITHUB_ENV and
#                            $OUT/sim.env. Does NOT boot (see below).
#   scripts/sim.sh boot UDID Boot the Simulator (if needed), wait until it's up, and give it a clean status bar.
#
# Why boot last: a freshly booted iOS Simulator spends minutes on first-run work (wallpaper posters, widgets,
# Shortcuts, App Store, Home, mail...) with load average past 300 on the 5-CPU runner. Anything overlapping it
# crawls: the build went from 13 s to 111 s, Postgres + API tests from 12 s to 119 s. Measured on xcode-27:
# backend 12 s, build 13 s and boot ~45 s back to back beat any overlap. One Simulator per machine, too.
set -euo pipefail

OUT="${OUT:-$PWD/out}"
mkdir -p "$OUT"
cmd="${1:-}"

if [ "$cmd" = "prepare" ]; then
  XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | grep -v -i beta | sort -V | tail -1)"
  sudo xcode-select -s "$XCODE/Contents/Developer"
  xcodebuild -version | tee "$OUT/xcode-version.txt"
  echo "CPUs: $(sysctl -n hw.ncpu), memory: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB" | tee "$OUT/machine.txt"

  # The runner's Spotlight indexes every new Simulator device at full CPU; we never search the runner.
  sudo mdutil -a -i off > /dev/null 2>&1 || true
  xcrun simctl list runtimes -j > "$OUT/runtimes.json"
  RUNTIME_ID="$(python3 - "$OUT/runtimes.json" "$OUT/runtime.txt" <<'PY'
import json, re, sys
rts = [r for r in json.load(open(sys.argv[1]))["runtimes"]
       if r.get("isAvailable") and r.get("platform", r["name"].split()[0]) == "iOS"]
# Prefer general runtimes (…SimRuntime.iOS-27-2) over device-specific ones
# (…SimRuntime.iOS-27-2-iPhone19-4), which only run a single new device model.
general = re.compile(r"\.iOS-\d+(-\d+)*$")
rts.sort(key=lambda r: (bool(general.search(r["identifier"])), [int(x) for x in r["version"].split(".")]))
label = lambda r: "%s (%s)" % (r["name"], r.get("buildversion", ""))
open(sys.argv[2], "w").write(label(rts[-1]) + "\n")
print(rts[-1]["identifier"])
PY
)"
  # The iPhone Pro device type this runtime supports, and an existing device of it (if any).
  read -r DEVTYPE SIM_UDID <<<"$(python3 - "$OUT/runtimes.json" "$RUNTIME_ID" <<'PY'
import json, re, subprocess, sys
r = [x for x in json.load(open(sys.argv[1]))["runtimes"] if x["identifier"] == sys.argv[2]][0]
phones = [d for d in r.get("supportedDeviceTypes", []) if d.get("productFamily") == "iPhone"]
pref = [d for d in phones if re.fullmatch(r"iPhone \d+ Pro", d["name"])] or phones
# supportedDeviceTypes is oldest first by release, not by model: pick the highest model number.
model = lambda d: int((re.search(r"iPhone (\d+)", d["name"]) or re.search(r"(\d+)", "0")).group(1))
devtype = max(pref, key=model)
print("Device type:", devtype["name"], file=sys.stderr)
devs = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))["devices"].get(sys.argv[2], [])
match = [d for d in devs if d.get("isAvailable") and d.get("deviceTypeIdentifier") == devtype["identifier"]]
print(devtype["identifier"], match[0]["udid"] if match else "-")
PY
)"
  [ "$SIM_UDID" = "-" ] && SIM_UDID="$(xcrun simctl create "CloudSim iPhone" "$DEVTYPE" "$RUNTIME_ID")"
  xcrun simctl list devices | grep "$SIM_UDID" | tee "$OUT/device.txt"
  echo "SIM_UDID=$SIM_UDID" | tee "$OUT/sim.env"
  cat "$OUT/sim.env" >> "${GITHUB_ENV:-/dev/null}"
  exit 0
fi

if [ "$cmd" = "boot" ]; then
  UDID="$2"
  if [ "${SIM_PREWARM_AX:-0}" = "1" ]; then
    # Optional. XCUITest turns accessibility on in every process when the test runner starts (~40 s on a busy,
    # freshly booted Simulator). Turned on in the device's preferences before boot, that drops to ~5 s, but in
    # our measurements the time reappeared in the app's first launch, so it's off by default.
    PREFS=~/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/Preferences
    mkdir -p "$PREFS"
    for k in AccessibilityEnabled ApplicationAccessibilityEnabled AutomationEnabled; do
      defaults write "$PREFS/com.apple.Accessibility" "$k" -bool YES
    done
    echo "accessibility pre-enabled"
  fi
  t0=$(date +%s)
  xcrun simctl bootstatus "$UDID" -b > /dev/null
  t1=$(date +%s)
  echo "Simulator $UDID booted in $(( t1 - t0 ))s"
  if [ "${SIM_STATUS_BAR:-0}" = "1" ]; then
    # A clean 9:41 status bar for recordings (the e2e screenshots don't need it).
    xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 || true
    echo "status bar set in $(( $(date +%s) - t1 ))s"
  fi
  exit 0
fi

echo "usage: $0 prepare | boot UDID" >&2
exit 2
