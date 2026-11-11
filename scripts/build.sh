#!/usr/bin/env bash
# Generate the Xcode project and build the app plus both UI test bundles once (build-for-testing), so the
# tests run straight from it (test-without-building). SCHEMES: CloudSim (e2e) and/or CloudSimDemo (demo).
set -euo pipefail
OUT="${OUT:-$PWD/out}"
mkdir -p "$OUT"
DEST="id=${SIM_UDID:?run scripts/sim.sh prepare first}"
xcodegen generate
for SCHEME in ${SCHEMES:-CloudSim}; do
  xcodebuild build-for-testing -project CloudSim.xcodeproj -scheme "$SCHEME" -destination "$DEST" \
    -derivedDataPath build COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO \
    > "$OUT/build-$SCHEME.log" 2>&1 || { tail -60 "$OUT/build-$SCHEME.log"; exit 1; }
  echo "built $SCHEME"
done
