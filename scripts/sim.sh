#!/usr/bin/env bash
# Simulator helpers for CI.
#
#   scripts/sim.sh prepare   Select the newest Xcode, pick the newest *general* iOS runtime and an iPhone Pro,
#                            and start booting it in the background. A first boot takes ~100 s on a fresh runner
#                            (most of it one-time data migration), so it runs while Postgres, the API tests and
#                            the build happen. Writes SIM_UDID to $GITHUB_ENV and $OUT/sim.env.
#                            One Simulator per machine: two booting at once starve a 5-CPU runner.
#   scripts/sim.sh wait UDID Wait until that simulator has finished booting, then give it a clean status bar.
set -euo pipefail

OUT="${OUT:-$PWD/out}"
mkdir -p "$OUT"
cmd="${1:-}"

if [ "$cmd" = "prepare" ]; then
  XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | grep -v -i beta | sort -V | tail -1)"
  sudo xcode-select -s "$XCODE/Contents/Developer"
  xcodebuild -version | tee "$OUT/xcode-version.txt"
  echo "CPUs: $(sysctl -n hw.ncpu), memory: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB" | tee "$OUT/machine.txt"

  if [ "${SIM_CACHE_HIT:-}" = "true" ]; then
    # Simulator devices were restored from the cache: restart CoreSimulator so it reads them from disk.
    sudo killall -9 com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null || true
    echo "Using cached Simulator devices ($(du -sh ~/Library/Developer/CoreSimulator/Devices | cut -f1))"
  fi
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
  # simctl boot blocks until the device is up, so it goes to the background; `wait` joins it later.
  date +%s > "$OUT/boot-started-at"
  [ "${NO_BOOT:-0}" = "1" ] || nohup xcrun simctl boot "$SIM_UDID" > "$OUT/boot.log" 2>&1 &
  echo "SIM_UDID=$SIM_UDID" | tee "$OUT/sim.env"
  cat "$OUT/sim.env" >> "${GITHUB_ENV:-/dev/null}"
  exit 0
fi

if [ "$cmd" = "wait" ]; then
  UDID="$2"
  t0=$(date +%s)
  xcrun simctl bootstatus "$UDID" -b > /dev/null
  xcrun simctl ui "$UDID" appearance light || true
  xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 || true
  started="$(cat "$OUT/boot-started-at" 2>/dev/null || echo "$t0")"
  echo "Simulator $UDID ready: waited $(( $(date +%s) - t0 ))s here, $(( $(date +%s) - started ))s since boot began"
  exit 0
fi

echo "usage: $0 prepare | wait UDID" >&2
exit 2
