#!/usr/bin/env bash
# Record the demo walkthrough (DemoTests/) against the live API, from the build that scripts/build.sh made.
# It runs on its own machine (CI's "demo" job), so its database holds only what the walkthrough creates.
# Produces ./out-demo/raw.mp4 (the Simulator's screen) and ./out-demo/markers.json (captions, taps,
# fast-forwards, and the moment the recording started), which demo/compose.py turns into the MP4.
# This is a preview, not a test gate: the e2e suite (run-e2e.sh) is what guards main.
set -euo pipefail

SCHEME="${SCHEME:-CloudSimDemo}"
OUT="${OUT:-$PWD/out-demo}"
UDID="${SIM_UDID:?run scripts/sim.sh prepare first}"
API_URL="${DEMO_API_URL:-http://localhost:8787}"
mkdir -p "$OUT"

echo "::group::Record the walkthrough"
rm -rf "$OUT/demo.xcresult"
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/raw.mp4" 2> "$OUT/record.log" &
REC_PID=$!
# The markers are wall-clock times. This is only roughly when the first frame lands (an idle Simulator sends
# none); demo/compose.py finds the exact offset from the video itself.
for _ in $(seq 1 60); do grep -q "Recording started" "$OUT/record.log" 2>/dev/null && break; sleep 0.25; done
START="$(python3 -c 'import time; print(time.time())')"
set +e
API_URL="$API_URL" TEST_RUNNER_API_URL="$API_URL" \
xcodebuild test-without-building \
  -project CloudSim.xcodeproj -scheme "$SCHEME" -destination "id=$UDID" \
  -derivedDataPath build -resultBundlePath "$OUT/demo.xcresult" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  > "$OUT/xcodebuild-demo.log" 2>&1
STATUS=$?
set -e
sleep 1
kill -INT "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true
grep -E "Test Case|error:|\*\* TEST" "$OUT/xcodebuild-demo.log" | tail -20 || true
echo "::endgroup::"

echo "::group::Markers"
mkdir -p "$OUT/attachments"
xcrun xcresulttool export attachments --path "$OUT/demo.xcresult" --output-path "$OUT/attachments" || true
python3 - "$OUT/attachments" "$OUT/markers.json" "$START" <<'PY'
import json, os, sys
src, dst, start = sys.argv[1], sys.argv[2], float(sys.argv[3])
found = None
manifest = os.path.join(src, "manifest.json")
if os.path.exists(manifest):
    for test in json.load(open(manifest)):
        for a in test.get("attachments", []):
            if (a.get("suggestedHumanReadableName") or "").startswith("markers"):
                found = os.path.join(src, a["exportedFileName"])
if not found:
    sys.exit("no markers attachment: did the walkthrough finish?")
m = json.load(open(found))
m["recordingStart"] = start
json.dump(m, open(dst, "w"), indent=1)
print(len(m["events"]), "markers; recording started at", start)
# The walkthrough's sync screenshots (sync-NN), which compose.py lines the recording up against.
import re, shutil
shots = os.path.join(os.path.dirname(dst), "shots")
os.makedirs(shots, exist_ok=True)
n = 0
for test in json.load(open(manifest)):
    for a in test.get("attachments", []):
        hit = re.match(r"(sync-\d+)", a.get("suggestedHumanReadableName") or "")
        if hit:
            shutil.copy(os.path.join(src, a["exportedFileName"]), os.path.join(shots, hit.group(1) + ".png"))
            n += 1
print(n, "sync screenshots")
PY
echo "::endgroup::"
exit "$STATUS"
