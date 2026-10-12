#!/usr/bin/env bash
#
# Install (or with --uninstall remove) the weekly local extractor canary as a
# launchd agent: Mondays 10:00, logs in ~/Library/Logs/Youty/canary.log.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="dev.leget.youty.canary"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Youty"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$PLIST"
  echo "Removed the weekly canary."
  exit 0
fi

mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"
cat >"$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>-lc</string><string>"$ROOT/Scripts/canary-local.sh"</string></array>
  <key>StartCalendarInterval</key>
  <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>10</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$LOG_DIR/canary.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/canary.log</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PL
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed: Mondays 10:00 — log at $LOG_DIR/canary.log"
