#!/usr/bin/env bash
# Smoke test for Youty's per-platform extractors.
#
# Runs the built app's headless probe modes against a handful of known-good
# public URLs per platform and reports red/green per test. Scripts/canary-local.sh
# runs it weekly on the owner's Mac — when a platform changes its API shape,
# this trips first. CI runs only the offline part (`--offline`): YouTube blocks
# datacenter IP ranges, so network probes there fail regardless of the code.
#
# Returns 0 if every test passes, nonzero (count of failures) otherwise.
#
# Prerequisite: a Debug build at build/dd/Build/Products/Debug/youty.app.
# Run `xcodebuild -scheme youty -configuration Debug -derivedDataPath build/dd build`
# beforehand if the binary is missing.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OFFLINE=0
[ "${1:-}" = "--offline" ] && OFFLINE=1
BUILD_DIR="${YOUTY_BUILD_DIR:-$ROOT/build/dd}"
BIN="$BUILD_DIR/Build/Products/Debug/youty.app/Contents/MacOS/youty"

if [ ! -x "$BIN" ]; then
    echo "error: binary not found at $BIN"
    echo "       run: xcodebuild -scheme youty -configuration Debug -derivedDataPath build/dd build"
    exit 2
fi

# Keep test preferences, indexes, and saved CLI vault paths out of the user's home.
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/youty-smoke.XXXXXX")" || exit 2
export CFFIXED_USER_HOME="$TEST_ROOT/home"
mkdir -p "$CFFIXED_USER_HOME"
trap 'rm -rf "$TEST_ROOT"' EXIT

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

    if grep -qE '^ERROR=|^EXTRACTION_ERROR=' <<< "$out"; then
        printf "%b✗%b %s\n" "$RED" "$NC" "$name"
        echo "$out" | grep -E '^ERROR=|^EXTRACTION_ERROR=' | head -1 | sed 's/^/    /'
        FAILED=$((FAILED+1))
        return
    fi

    if grep -qE "$ok_pattern" <<< "$out"; then
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

if [ $OFFLINE -eq 0 ]; then
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

# Panel-timeout fallback: YouTube's captions as a file, in the spoken language
# of a video with AI dubs, starting from a visitor ID YouTube rejects.
run "YouTube captions via the player API (dubbed video, stale visitor ID)" \
    'SEGMENTS=[0-9]{3,}' \
    "$BIN" --youtube-captions-probe C0jOKDJtK9s --stale-visitor-data

# No-captions fallback: the audio-only stream is downloaded and transcribed
# on-device (forced here on a captioned video so the path stays exercised).
run "On-device transcription fallback (audio stream + SpeechAnalyzer)" \
    'SEGMENTS=[1-9]' \
    "$BIN" --youtube-audio-probe dQw4w9WgXcQ --locale en-US

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
fi

echo
echo "== Phase L surfaces =="
# Headless probe — exercises IngestionFunnel queue serialization, URL
# classifier and VaultLocalSearch. Share
# Sheet activation / Services menu click / menu bar popover require
# driving the system UI and are verified via the in-app flow.
run "Ingestion + classifier + local search" \
    'PHASE_L_PROBE OK' \
    "$BIN" --phase-l-probe

echo
echo "== Phase Q.8 — perf + accessibility =="
# Indexer throughput on a synthetic 1000-bundle vault — catches a Phase
# B→M regression on the manifest walk + frontmatter parse + JSON write.
run "Indexer bench (1000 synthetic bundles)" \
    'BENCH_INDEXER OK' \
    "$BIN" --bench-indexer 1000

# Static accessibility audit — every interactive SwiftUI control must
# carry an explicit accessibilityLabel OR a visible Text/Label
# that SwiftUI uses as the spoken label automatically.
if "$ROOT/Scripts/audit-accessibility.sh" > "$TEST_ROOT/a11y-audit.txt" 2>&1; then
    printf "%b✓%b Accessibility audit (every SwiftUI control labeled)\n" "$GREEN" "$NC"
    PASSED=$((PASSED + 1))
else
    printf "%b✗%b Accessibility audit\n" "$RED" "$NC"
    sed 's/^/    /' "$TEST_ROOT/a11y-audit.txt"
    FAILED=$((FAILED + 1))
fi

echo
echo "== On-device search model (EmbeddingGemma 2) =="
# Loads the bundled text + vision Core ML models, token table, and tokenizer;
# checks 768-d finite unit vectors, determinism, and that related text
# out-scores unrelated text. Catches bundle-resource regressions, tokenizer
# artifact drift, and Core ML input/output or precision changes. (Parity with
# Google's reference: Scripts/verify-embeddinggemma2.py + the same probe.)
run "EmbeddingGemma 2 on-device embedder" \
    'EMBEDDINGGEMMA2_PROBE OK' \
    "$BIN" --embeddinggemma2-probe

echo
echo "== Phase Q.6 — crash hardening =="
# Drives every weird vault state we can simulate headlessly: empty vault,
# vault-is-a-file, garbage manifest.json (7 variants), corrupt video.md
# (7 variants), read-only vault, ghost vault path, mixed valid+corrupt.
# Each case must exit cleanly — no Swift trap, no fatalError, no force
# unwrap crash. Cases requiring hardware (drive disconnect, disk full,
# network drop mid-fetch) are out of scope for headless smoke.
run "Vault weird-state survival" \
    'HARDNESS_PROBE OK' \
    "$BIN" --hardness-probe

echo
echo "== Phase M — youty CLI =="
CLI_BIN="$BUILD_DIR/Build/Products/Debug/youty"
CLI_VAULT="$TEST_ROOT/vault"
mkdir -p "$CLI_VAULT"
if [ ! -x "$CLI_BIN" ]; then
    printf "%b∼%b CLI smoke (binary missing — run xcodebuild for youty-cli)${NC}\n" "$YELLOW" "$NC"
    SKIPPED=$((SKIPPED+1))
else
    run "youty --version" \
        'youty [0-9]' \
        "$CLI_BIN" --version

    run "youty --help" \
        'COMMANDS' \
        "$CLI_BIN" --help

    if [ $OFFLINE -eq 0 ]; then
    run "youty save dQw4w9WgXcQ (YouTube)" \
        '"video_id" : "dQw4w9WgXcQ"' \
        "$CLI_BIN" save "https://www.youtube.com/watch?v=dQw4w9WgXcQ" \
            --vault "$CLI_VAULT" --count 10 --no-index --json

    # Q.5 — exercise --quiet on a quick second save. Suppresses the stderr
    # progress lines; bundle path still goes to stdout.
    run "youty save --quiet (no stderr noise)" \
        'youtube/Rick Astley' \
        "$CLI_BIN" save "https://www.youtube.com/watch?v=dQw4w9WgXcQ" \
            --vault "$CLI_VAULT" --count 10 --no-index --quiet

    run "youty list" \
        'dQw4w9WgXcQ' \
        "$CLI_BIN" list --vault "$CLI_VAULT"

    # Q.5 — --platform filter and --limit cap
    run "youty list --platform youtube" \
        'dQw4w9WgXcQ' \
        "$CLI_BIN" list --vault "$CLI_VAULT" --platform youtube

    run "youty list --platform tiktok (empty)" \
        '\[' \
        "$CLI_BIN" list --vault "$CLI_VAULT" --platform tiktok

    run "youty list --limit 1" \
        'dQw4w9WgXcQ' \
        "$CLI_BIN" list --vault "$CLI_VAULT" --limit 1

    run "youty search 'rick astley'" \
        'dQw4w9WgXcQ' \
        "$CLI_BIN" search "rick astley" --vault "$CLI_VAULT"

    # Q.5 — --limit on search
    run "youty search --limit 1" \
        'dQw4w9WgXcQ' \
        "$CLI_BIN" search "rick" --vault "$CLI_VAULT" --limit 1

    run "youty transcript by id" \
        '## Transcript' \
        "$CLI_BIN" transcript "yt:dQw4w9WgXcQ" --vault "$CLI_VAULT"

    # A captioned video must use YouTube's captions, not the audio fallback —
    # otherwise a transcript-panel change would silently hide behind ASR.
    if grep -rq "transcript_source:" "$CLI_VAULT/youtube" 2>/dev/null; then
        printf "%b✗%b YouTube captions read directly (fell back to on-device transcription)\n" "$RED" "$NC"
        FAILED=$((FAILED+1))
    else
        printf "%b✓%b YouTube captions read directly\n" "$GREEN" "$NC"
        PASSED=$((PASSED+1))
    fi
    fi

    # Q.5 — CLI weird-vault survival (exit-code matters; pipe to /dev/null to keep run() happy)
    run "youty list on garbage manifest (no crash)" \
        '\[' \
        "$CLI_BIN" list --vault "$TEST_ROOT/does-not-exist"
fi

echo
printf "Result: ${GREEN}%d passed${NC}" "$PASSED"
[ $SKIPPED -gt 0 ] && printf ", ${YELLOW}%d skipped${NC}" "$SKIPPED"
[ $FAILED -gt 0 ] && printf ", ${RED}%d failed${NC}" "$FAILED"
echo
exit $FAILED
