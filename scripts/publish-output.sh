#!/usr/bin/env bash
# Commit the latest run's screenshot, video and logs to the `simulator-output`
# branch so they can be viewed on GitHub (or fetched with git) without
# downloading the Actions artifact.
set -euo pipefail

OUT="$PWD/out"
[ -d "$OUT" ] || { echo "No output to publish"; exit 0; }

STATUS="$(cat "$OUT/status.txt" 2>/dev/null || echo "Build or launch failed")"
XCODE="$(head -1 "$OUT/xcode-version.txt" 2>/dev/null || echo "unknown")"
DEVICE="$(sed -E 's/^ +//; s/ \(Booted\)| \(Shutdown\)//' "$OUT/device.txt" 2>/dev/null || echo "unknown")"
RUNTIME="$(cat "$OUT/runtime.txt" 2>/dev/null || echo "unknown")"
RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

WORK="$(mktemp -d)"
cp -R "$OUT"/. "$WORK"/
rm -f "$WORK"/runtimes.json "$WORK"/devices.json

cat > "$WORK/README.md" <<EOF
# Latest simulator run

**${STATUS}** · commit \`${GITHUB_SHA::7}\` · [workflow run](${RUN_URL})

- ${XCODE}
- Runtime: ${RUNTIME}
- Device: ${DEVICE}

![Screenshot](screenshot.png)

[Screen recording (run.mp4)](run.mp4) · [Build log](build.log)
EOF

cd "$WORK"
git init -q -b simulator-output
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add -A
git commit -q -m "Simulator output for ${GITHUB_SHA::7}"
git push -q --force \
  "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" \
  simulator-output:simulator-output
echo "Published to ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/tree/simulator-output"
