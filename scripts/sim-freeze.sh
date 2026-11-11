#!/usr/bin/env bash
# Freeze the iOS Simulator's per-boot background work while tests run.
#
# Every boot, even of a settled device, the simulated iPhone renders wallpaper posters, refreshes widgets
# (Calendar, Health, Safari, Wallet, News...), runs photo analysis, Shortcuts, social, News, Apple Intelligence
# and Spotlight-knowledge jobs: load average passes 300 on the 5-CPU runner for minutes, and app launches and
# test steps crawl. Those are ordinary processes on the Mac, so this stops them with SIGSTOP (no crash, no
# relaunch, no crash report; they simply get no CPU). Nothing in our app or tests uses them.
#
#   scripts/sim-freeze.sh start   keep freezing them in the background (new ones keep appearing for minutes)
#   scripts/sim-freeze.sh stop    stop watching and let them run again
set -uo pipefail
PIDFILE="${RUNNER_TEMP:-/tmp}/sim-freeze.pid"
HEAVY='simruntime/.*/(([A-Za-z]+Poster[A-Za-z]*)|[A-Za-z]*PosterExtension|[A-Za-z]*WidgetExtension|[A-Za-z]*WidgetsExtension|AccessibilityControlsExtension|CalendarIntentsExtension|NewsTag|NewsTodayIntents|newsd|NewsScoringService|sociallayerd|siriactionsd|BackgroundShortcutRunner|photoanalysisd|mediaanalysisd|intelligenceflowd|intelligenceplatformd|knowledgeconstructiond|spotlightknowledged[.a-z]*|MobileCal|amsengagementd|STExtractionService|homed|healthd|gamed|remindd|maild|icloudmailagent|biomed|suggestd|parsecd|assistant_cdmd|localspeechrecognition)$'
case "${1:-}" in
  start)
    ( end=$(( $(date +%s) + ${FREEZE_SECONDS:-900} ))
      while [ "$(date +%s)" -lt "$end" ]; do
        pgrep -f -- "$HEAVY" | while read -r pid; do kill -STOP "$pid" 2>/dev/null; done
        sleep 1
      done ) > /dev/null 2>&1 &
    echo $! > "$PIDFILE"
    sleep 1
    echo "freezing $(pgrep -f -- "$HEAVY" | wc -l | tr -d ' ') background processes, and any that start later"
    ;;
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
    pgrep -f -- "$HEAVY" | while read -r pid; do kill -CONT "$pid" 2>/dev/null; done
    echo "unfrozen"
    ;;
  *) echo "usage: $0 start | stop" >&2; exit 2 ;;
esac
