#!/usr/bin/env bash
# Smoke test for Youty's per-platform extractors.
#
# Runs the built app's headless probe modes against a handful of known-good
# public URLs per platform and reports red/green per test. Used as the
# quarterly canary discipline called out in implementation.md — when a
# platform changes its API shape, this script trips first.
#
# Returns 0 if every test passes, nonzero (count of failures) otherwise.
#
# Prerequisite: a Debug build at build/dd/Build/Products/Debug/youty.app.
# Run `xcodebuild -scheme youty -configuration Debug -derivedDataPath build/dd build`
# beforehand if the binary is missing.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/dd/Build/Products/Debug/youty.app/Contents/MacOS/youty"

if [ ! -x "$BIN" ]; then
    echo "error: binary not found at $BIN"
    echo "       run: xcodebuild -scheme youty -configuration Debug -derivedDataPath build/dd build"
    exit 2
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
DIM='\033[0;90m'
NC='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

# Run one probe. Captures stdout, looks for the canonical OK signal we expect
# from each probe (the first positive line emitted before any ERROR= line).
# - $1: human-readable name
# - $2: expected-OK pattern (regex passed to grep -E)
# - rest: command + args
#
# A test counts as PASS iff the command exits 0 AND stdout has the expected
# pattern AND there's no ERROR= line.
run() {
    local name="$1"; shift
    local ok_pattern="$1"; shift
    local out exit_code

    out=$("$@" 2>&1) && exit_code=0 || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        printf "%b✗%b %s ${DIM}(exit %d)${NC}\n" "$RED" "$NC" "$name" "$exit_code"
        echo "$out" | head -3 | sed 's/^/    /'
        FAILED=$((FAILED+1))
        return
    fi

    if echo "$out" | grep -qE '^ERROR=|^EXTRACTION_ERROR='; then
        printf "%b✗%b %s\n" "$RED" "$NC" "$name"
        echo "$out" | grep -E '^ERROR=|^EXTRACTION_ERROR=' | head -1 | sed 's/^/    /'
        FAILED=$((FAILED+1))
        return
    fi

    if echo "$out" | grep -qE "$ok_pattern"; then
        printf "%b✓%b %s\n" "$GREEN" "$NC" "$name"
        PASSED=$((PASSED+1))
    else
        printf "%b✗%b %s ${DIM}(no match for /%s/)${NC}\n" "$RED" "$NC" "$name" "$ok_pattern"
        echo "$out" | head -3 | sed 's/^/    /'
        FAILED=$((FAILED+1))
    fi
}

# Instagram is intentionally NOT tested by this script.
#
# The Instagram extractor relies on a WKWebView whose host page hydrates a
# React app — that hydration requires the view to be attached to a visible
# (alpha-near-zero is OK) window. The CLI probe creates the WebView but has
# no window context, so the page never finishes loading and the probe hangs.
#
# The right place to exercise Instagram is the in-app flow: launch the app,
# paste a Reel URL, click Load Reel. That path attaches the WebView to the
# main window and works correctly.
#
# This `run_instagram_skip` helper exists only to make the omission explicit
# in the smoke-test output (the IG section visually appears alongside the
# others, but is always marked Skipped with a clear reason).
run_instagram_skip() {
    local name="$1"
    printf "%b∼%b %s ${DIM}(headless not supported — verify via the app's UI)${NC}\n" \
        "$YELLOW" "$NC" "$name"
    SKIPPED=$((SKIPPED+1))
}

echo "== YouTube =="
# Rick Astley — 213 s 1080p, used as the canonical Phase I benchmark.
run "Rick Astley — Never Gonna Give You Up (3.5 min)" \
    'FRAMES_DISTINCT_SHA=' \
    "$BIN" --extract "https://www.youtube.com/watch?v=dQw4w9WgXcQ" --count 50 --mode auto
# Karpathy — long-form 116 min, exercises Phase I's segment-skipping.
run "Karpathy — GPT from scratch (116 min)" \
    'FRAMES_DISTINCT_SHA=' \
    "$BIN" --extract "https://www.youtube.com/watch?v=kCc8FmEb1nY" --count 50 --mode auto
# Gangnam Style — short high-bitrate, exercises the bitrate gate (should pick F.1).
run "Gangnam Style (4 min, 1080p)" \
    'FRAMES_DISTINCT_SHA=' \
    "$BIN" --extract "https://www.youtube.com/watch?v=9bZkp7q19f0" --count 50 --mode auto

echo
echo "== TikTok =="
# Anonymous URLSession path (no WKWebView), no WAF challenge expected.
run "@scout2015 (10s, 576×1024)" \
    'video_id=6718335390845095173' \
    "$BIN" --tiktok-probe "https://www.tiktok.com/@scout2015/video/6718335390845095173"
run "@tiktok official (24s)" \
    'video_id=7106594312292453675' \
    "$BIN" --tiktok-probe "https://www.tiktok.com/@tiktok/video/7106594312292453675"
echo
echo "== Instagram =="
run_instagram_skip "veganer.wandel — Kartoffelpuffer Crunchwrap"

echo
echo "== Phase L surfaces =="
# Headless probe — exercises IngestionFunnel queue serialization, URL
# classifier, SpotlightIndexer reconcile, and VaultLocalSearch. Share
# Sheet activation / Services menu click / menu bar popover require
# driving the system UI and are verified via the in-app flow.
run "Ingestion + classifier + spotlight + local search" \
    'PHASE_L_PROBE OK' \
    "$BIN" --phase-l-probe

echo
echo "== Phase M — youty CLI =="
CLI_BIN="$ROOT/build/dd/Build/Products/Debug/youty"
CLI_VAULT="$(mktemp -d)/youty-cli-smoke"
mkdir -p "$CLI_VAULT"
if [ ! -x "$CLI_BIN" ]; then
    printf "%b∼%b CLI smoke (binary missing — run xcodebuild for youty-cli)${NC}\n" "$YELLOW" "$NC"
    SKIPPED=$((SKIPPED+1))
else
    run "youty --version" \
        'youty 1' \
        "$CLI_BIN" --version

    run "youty --help" \
        'COMMANDS' \
        "$CLI_BIN" --help

    run "youty save dQw4w9WgXcQ (YouTube)" \
        '"video_id" : "dQw4w9WgXcQ"' \
        "$CLI_BIN" save "https://www.youtube.com/watch?v=dQw4w9WgXcQ" \
            --vault "$CLI_VAULT" --count 10 --no-index --json

    run "youty list" \
        'dQw4w9WgXcQ' \
        "$CLI_BIN" list --vault "$CLI_VAULT"

    run "youty search 'rick astley'" \
        'dQw4w9WgXcQ' \
        "$CLI_BIN" search "rick astley" --vault "$CLI_VAULT"

    run "youty transcript by id" \
        '## Transcript' \
        "$CLI_BIN" transcript "yt:dQw4w9WgXcQ" --vault "$CLI_VAULT"

    rm -rf "$CLI_VAULT"
fi

echo
printf "Result: ${GREEN}%d passed${NC}" "$PASSED"
[ $SKIPPED -gt 0 ] && printf ", ${YELLOW}%d skipped${NC}" "$SKIPPED"
[ $FAILED -gt 0 ] && printf ", ${RED}%d failed${NC}" "$FAILED"
echo
exit $FAILED
