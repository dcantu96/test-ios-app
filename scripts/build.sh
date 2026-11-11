#!/usr/bin/env bash
# Generate the Xcode project and build the app plus both UI test bundles once (build-for-testing), so the
# e2e suite and the demo walkthrough can run straight from the same build (test-without-building).
set -euo pipefail
OUT="${OUT:-$PWD/out}"
mkdir -p "$OUT"
DEST="id=${UDID_E2E:?run scripts/sim.sh prepare first}"
xcodegen generate
for SCHEME in CloudSim ${DEMO_SCHEME:-}; do
  xcodebuild build-for-testing -project CloudSim.xcodeproj -scheme "$SCHEME" -destination "$DEST" \
    -derivedDataPath build COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO \
    > "$OUT/build-$SCHEME.log" 2>&1 || { tail -60 "$OUT/build-$SCHEME.log"; exit 1; }
  echo "built $SCHEME"
done
