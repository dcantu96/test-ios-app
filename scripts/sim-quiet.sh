#!/usr/bin/env bash
# Stop the simulated iPhone's first-run background work. Right after a fresh boot, iOS spends minutes
# rendering wallpaper posters, warming News/Health/Calendar widgets, running Shortcuts automations, App Store
# engagement, Home, Game Center, mail sync and more: load average goes past 300 on a 5-CPU runner, and the
# build and tests crawl. None of it is used by our app or tests, so stop and disable it for this boot.
# Usage: scripts/sim-quiet.sh UDID
set -uo pipefail
UDID="$1"
PATTERN='Poster|News|Shortcut|siriactions|amsengagement|sociallayer|homed|HomeKit|gamed|remindd|maild|mobileassetd|MobileAsset|STExtraction|Fitness|Health|healthd|Calendar|calaccessd|chronod|Widget|cloudd|bird|photoanalysisd|mediaanalysisd|suggestd|knowledge|intelligence|assistant|siri|parsecd|icloudmail|dataaccessd|addressbooksync|bulletindistributor|companionapp|NPKCompanion|Weather|Stocks|Tips|ReportCrash|spotlight|corespotlight|searchd|duetexpertd|coreduetd|biome|Fitness|tipsd|appstored|gamepolicyd|passd|financed'
LIST="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null)"
n=0
while read -r pid status label; do
  [ -z "${label:-}" ] && continue
  if echo "$label" | grep -Eq "$PATTERN"; then
    xcrun simctl spawn "$UDID" launchctl disable "system/$label" 2>/dev/null
    xcrun simctl spawn "$UDID" launchctl bootout "system/$label" 2>/dev/null
    n=$((n + 1))
  fi
done <<< "$(echo "$LIST" | tail -n +2)"
echo "quieted $n background services on $UDID"
