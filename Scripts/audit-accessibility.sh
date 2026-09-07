#!/usr/bin/env bash
# Static check: flag every SwiftUI control (Button, Toggle, Picker,
# TextField, SecureField, Link) that has *no* accessibilityLabel /
# visible Text label within its block.
#
# Heuristic, not perfect — false positives possible for controls whose
# label is derived from a `Label("text", systemImage:)` or a passed-in
# closure. Run it after every UI change and review the hits manually.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATTERN='(^|[^[:alnum:]_])(Button[ (]|Toggle\(|Picker\(|TextField\(|SecureField\(|Link\()'

# Include onboarding and app-menu controls as well as the main window.
FILES=("$ROOT"/Sources/*.swift)

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

CONTROLS=0
LABELED=0
FLAGGED=0
for f in "${FILES[@]}"; do
    rel="${f#$ROOT/}"
    while IFS=: read -r line _; do
        CONTROLS=$((CONTROLS + 1))
        # 30-line window catches modifiers placed after a multi-line label closure.
        ctx=$(sed -n "${line},$((line + 30))p" "$f")
        if grep -qE 'accessibilityLabel\(' <<< "$ctx"; then
            LABELED=$((LABELED + 1))
            continue
        fi
        # Inline string constructor counts as labeled.
        start=$(sed -n "${line},$((line + 2))p" "$f")
        if grep -qE '(Button|Toggle|Picker|TextField|SecureField|Link)\("[^"]+"' <<< "$start"; then
            LABELED=$((LABELED + 1))
            continue
        fi
        # Label("…", systemImage:) inside the body.
        if grep -qE 'Label\("[^"]+", systemImage:' <<< "$ctx"; then
            LABELED=$((LABELED + 1))
            continue
        fi
        # Text("…") inside the button's label closure → SwiftUI uses it as the
        # accessibility label automatically.
        if grep -qE 'Text\("[^"]+"|Text\(label\)|Text\(buttonLabel\)|Text\([^)]*\? "[^"]+" : "[^"]+"\)' <<< "$ctx"; then
            LABELED=$((LABELED + 1))
            continue
        fi
        FLAGGED=$((FLAGGED + 1))
        printf "%b✗%b %s:%d — no accessibility label\n" "$RED" "$NC" "$rel" "$line"
        sed -n "${line}p" "$f" | sed 's/^/    /'
    done < <(grep -nE "$PATTERN" "$f" | grep -v '//')
done

echo
printf "Total controls scanned: %d   Labeled: %b%d%b   Flagged: %b%d%b\n" \
    "$CONTROLS" "$GREEN" "$LABELED" "$NC" \
    "$([ "$FLAGGED" -eq 0 ] && echo "$GREEN" || echo "$RED")" "$FLAGGED" "$NC"

if [ "$FLAGGED" -eq 0 ]; then
    exit 0
fi
exit 1
