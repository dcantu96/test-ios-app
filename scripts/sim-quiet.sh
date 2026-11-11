#!/usr/bin/env bash
# Stop the simulated iPhone's first-run background work. Right after a fresh boot, iOS spends minutes
# rendering wallpaper posters, warming News/Health/Calendar widgets, running Shortcuts automations, App Store
# engagement, Home, Game Center, mail sync and more: load average goes past 300 on a 5-CPU runner, and the
# build and tests crawl. None of it is used by our app or tests, so disable and stop it, in one shell inside
# the Simulator (one simctl call per service takes minutes under that load).
# Usage: scripts/sim-quiet.sh UDID
set -uo pipefail
UDID="$1"
PATTERN='Poster|poster|News|news|Shortcut|siriactions|amsengagement|ams|sociallayer|homed|homeevents|HomeKit|gamed|gamesaved|remindd|maild|icloudmail|mobileassetd|MobileAsset|STExtraction|fitness|fitcore|Fitness|health|Health|Calendar|calaccessd|chronod|Widget|cloudd|cloudphotod|bird|photoanalysisd|mediaanalysisd|suggestd|knowledge|intelligence|assistant|siri|parsecd|dataaccess|exchangesync|addressbooksync|bulletindistributor|companion|NPKCompanion|weather|Weather|stocks|Stocks|tips|ReportCrash|corespotlight|searchd|spotlight|duetexpert|biome|appstored|itunesstored|itunescloud|gamepolicy|passd|financed|finhealth|activityawards|activitysharing|generative|imageplayground|avatarsd|feedbackd|findmy|geoanalytics|jetpack|bookdatastored|facetime|familycircle|followupd|handwriting|corespeech|livetranscription|carkit|CarPlay|promotedcontent|adprivacy|diagnosticextensions|coresymbolication'
LABELS="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | tail -n +2 | awk '{print $3}' | grep -E "$PATTERN" | tr '\n' ' ')"
xcrun simctl spawn "$UDID" /bin/sh -c "for l in $LABELS; do launchctl disable system/\$l; launchctl bootout system/\$l 2>/dev/null; done" 2>/dev/null
echo "quieted $(echo "$LABELS" | wc -w | tr -d ' ') background services on $UDID"
