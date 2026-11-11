#!/usr/bin/env bash
# Disable the simulated iPhone's first-run background services (wallpaper posters, News, widgets, Shortcuts,
# App Store engagement, Home, mail, ...), in one shell inside the Simulator. Used when preparing the cached,
# settled Simulator (sim-image job): nothing in our app or tests uses these.
# Usage: scripts/sim-quiet.sh UDID
set -uo pipefail
UDID="$1"
PATTERN='Poster|poster|News|news|Shortcut|siriactions|amsengagement|sociallayer|homed|homeevents|HomeKit|gamed|gamesaved|remindd|maild|icloudmail|mobileassetd|MobileAsset|STExtraction|fitness|fitcore|Fitness|health|Health|Calendar|calaccessd|chronod|Widget|cloudd|cloudphotod|bird|photoanalysisd|mediaanalysisd|suggestd|knowledge|intelligence|assistant|siri|parsecd|dataaccess|exchangesync|addressbooksync|bulletindistributor|companion|weather|Weather|stocks|Stocks|tips|corespotlight|searchd|duetexpert|biome|appstored|itunesstored|itunescloud|passd|financed|finhealth|activityawards|activitysharing|generative|imageplayground|avatarsd|feedbackd|findmy|geoanalytics|jetpack|bookdatastored|facetime|familycircle|followupd|handwriting|corespeech|livetranscription|carkit|CarPlay|promotedcontent|adprivacy|diagnosticextensions'
LABELS="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | tail -n +2 | awk '{print $3}' | grep -E "$PATTERN" | tr '\n' ' ')"
xcrun simctl spawn "$UDID" /bin/sh -c "for l in $LABELS; do launchctl disable system/\$l; launchctl bootout system/\$l 2>/dev/null; done" 2>/dev/null
echo "quieted $(echo "$LABELS" | wc -w | tr -d ' ') background services on $UDID"
