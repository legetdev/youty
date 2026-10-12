#!/usr/bin/env bash
#
# Weekly extractor canary, run on the owner's Mac (residential network).
# GitHub's runners are blocked by YouTube, so the network probes only mean
# something here. Builds Debug app + CLI, runs Scripts/smoke-test-extractors.sh,
# and mirrors the result into one GitHub issue: opened or commented on failure,
# closed when the canary is green again. Installed as a launchd job by
# Scripts/install-canary.sh; safe to run by hand.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="legetdev/youty"
TITLE="🔴 Extractor canary failing"
LOG="$(mktemp -t youty-canary)"
trap 'rm -f "$LOG"' EXIT

{
  echo "== $(date -u +%Y-%m-%dT%H:%MZ) on $(sw_vers -productVersion) =="
  git rev-parse --short HEAD
  ./Scripts/fetch-models.sh &&
  xcodebuild -project youty.xcodeproj -scheme youty -configuration Debug \
      -derivedDataPath build/dd ENABLE_HARDENED_RUNTIME=NO build -quiet &&
  xcodebuild -project youty.xcodeproj -scheme youty-cli -configuration Debug \
      -derivedDataPath build/dd ENABLE_HARDENED_RUNTIME=NO build -quiet &&
  ./Scripts/smoke-test-extractors.sh
} >"$LOG" 2>&1
STATUS=$?
cat "$LOG"

ISSUE="$(gh issue list --repo "$REPO" --state open --search "\"$TITLE\" in:title" --json number --jq '.[0].number // empty' 2>/dev/null)"
SUMMARY="$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E '✗|Result:|error' | head -20)"
if [ $STATUS -ne 0 ]; then
  BODY="$(printf 'The weekly extractor canary failed on the owner'"'"'s Mac.\n\n```\n%s\n```\n' "$SUMMARY")"
  if [ -n "$ISSUE" ]; then
    gh issue comment "$ISSUE" --repo "$REPO" --body "$BODY"
  else
    gh issue create --repo "$REPO" --title "$TITLE" --body "$BODY"
  fi
elif [ -n "$ISSUE" ]; then
  gh issue close "$ISSUE" --repo "$REPO" --comment "Canary green again on $(date -u +%Y-%m-%d) (local run)."
fi
exit $STATUS
