#!/usr/bin/env bash
# End-to-end Release pipeline for the Mac app (R.5).
#
# Builds the Release configuration, codesigns every binary inside the
# bundle (main executable, Sparkle.framework, Save to Youty.appex,
# Autoupdate helper, embedded CLI if present), submits the result to
# Apple's notary service, staples the ticket, and validates the result
# against Gatekeeper as if the DMG had just been downloaded.
#
# This is the script Phase R.5 standardises on. It is safe to run
# repeatedly — each pass produces an identical signed + notarized
# youty.app under build/release/Build/Products/Release/.
#
# Required environment:
#   DEVELOPER_ID_APPLICATION_CERT — e.g. "Developer ID Application: Bent Eisheuer (TEAMID)"
#   NOTARY_KEYCHAIN_PROFILE       — the notarytool keychain profile name
#                                   (set up once via `xcrun notarytool store-credentials`).
#
# Optional:
#   TEAM_ID — auto-detected from the cert if not set.
#   SKIP_NOTARY=1 — sign locally but skip notary submission (useful for
#                   smoke testing the codesign half on a dev machine
#                   before the real cert is on the Keychain).
#
# Tools used: xcodebuild, codesign, xcrun notarytool, spctl. All Apple
# first-party. No third-party.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build/release"
APP="$BUILD_DIR/Build/Products/Release/youty.app"
LOG=/tmp/youty-release.log

# ---- Pre-flight ----

if [ -z "${DEVELOPER_ID_APPLICATION_CERT:-}" ]; then
    cat >&2 <<EOF
error: DEVELOPER_ID_APPLICATION_CERT not set.

  Set it to your Developer ID Application certificate's common name, e.g.
    export DEVELOPER_ID_APPLICATION_CERT="Developer ID Application: Bent Eisheuer (ABCDE12345)"

  List installed certs with:
    security find-identity -v -p codesigning

EOF
    exit 2
fi

if [ -z "${NOTARY_KEYCHAIN_PROFILE:-}" ] && [ -z "${SKIP_NOTARY:-}" ]; then
    cat >&2 <<EOF
error: NOTARY_KEYCHAIN_PROFILE not set (and SKIP_NOTARY not set).

  Create a keychain-stored credential once with:
    xcrun notarytool store-credentials "youty-notary" \\
        --apple-id <your-apple-id> \\
        --team-id <YOUR_TEAM_ID> \\
        --password <app-specific-password>

  Then export the profile name:
    export NOTARY_KEYCHAIN_PROFILE="youty-notary"

  Or set SKIP_NOTARY=1 to dry-run just the codesign half.

EOF
    exit 2
fi

# Auto-detect TEAM_ID from the cert string ("Common Name (TEAMID)") if
# the caller didn't pass one. Used purely for diagnostic output.
TEAM_ID="${TEAM_ID:-$(echo "$DEVELOPER_ID_APPLICATION_CERT" | sed -nE 's/.*\(([A-Z0-9]+)\).*/\1/p')}"
echo "==> Signing with: $DEVELOPER_ID_APPLICATION_CERT"
echo "==> Team ID:      ${TEAM_ID:-<unknown>}"
[ -n "${SKIP_NOTARY:-}" ] && echo "==> SKIP_NOTARY=1 — codesign only, no notary submission"

# ---- Build ----

echo "==> Building Release youty.app..."
xcodebuild \
    -project "$ROOT/youty.xcodeproj" \
    -scheme youty \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION_CERT" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="${TEAM_ID:-}" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    build > "$LOG" 2>&1 || {
        echo "error: build failed. Tail of $LOG:" >&2
        tail -30 "$LOG" >&2
        exit 1
    }

if [ ! -d "$APP" ]; then
    echo "error: built app not found at $APP" >&2
    exit 1
fi

# ---- Codesign every nested signable item explicitly ----
#
# Order matters: inner-most first. Apple's signing semantics require
# nested frameworks + plugins to carry valid signatures before the
# enclosing bundle is signed, otherwise the outer signature won't seal.
# The build phase signs once with ad-hoc on Debug; we re-sign every
# layer here with the real Developer ID identity so notary accepts it.

ENTITLEMENTS="$ROOT/Sources/youty.entitlements"

sign_one() {
    local target="$1"
    [ -e "$target" ] || return 0
    echo "    signing $(basename "$target")"
    codesign --force \
             --sign "$DEVELOPER_ID_APPLICATION_CERT" \
             --options runtime \
             --timestamp \
             "$target" >> "$LOG" 2>&1
}

sign_one_with_entitlements() {
    local target="$1"
    local entitlements="$2"
    echo "    signing $(basename "$target") with entitlements"
    codesign --force \
             --sign "$DEVELOPER_ID_APPLICATION_CERT" \
             --options runtime \
             --timestamp \
             --entitlements "$entitlements" \
             "$target" >> "$LOG" 2>&1
}

echo "==> Signing nested binaries..."
# Sparkle framework + its helpers (Autoupdate + Updater.app). Signed
# inner-to-outer so the framework's seal is valid before the app's seal
# references it.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    find "$SPARKLE/Versions/Current/Resources" -type f \( -name "Autoupdate" -o -name "fileop" -o -name "Updater" \) | while read -r helper; do
        sign_one "$helper"
    done
    if [ -d "$SPARKLE/Versions/Current/Resources/Updater.app" ]; then
        sign_one "$SPARKLE/Versions/Current/Resources/Updater.app"
    fi
    sign_one "$SPARKLE"
fi

# Share extension. Carries its own entitlements file.
APPEX="$APP/Contents/PlugIns/Save to Youty.appex"
APPEX_ENTITLEMENTS="$ROOT/ShareExtension/ShareExtension.entitlements"
if [ -d "$APPEX" ] && [ -f "$APPEX_ENTITLEMENTS" ]; then
    sign_one_with_entitlements "$APPEX" "$APPEX_ENTITLEMENTS"
fi

# Any other dylibs / frameworks that may have been added by SPM.
find "$APP/Contents/Frameworks" -maxdepth 2 -type d -name "*.framework" 2>/dev/null | while read -r framework; do
    [ "$framework" = "$SPARKLE" ] && continue
    sign_one "$framework"
done

# ---- Sign the main app last, with entitlements ----
echo "==> Signing main app bundle..."
sign_one_with_entitlements "$APP" "$ENTITLEMENTS"

# ---- Verify the signature seals correctly ----
echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP" >> "$LOG" 2>&1 || {
    echo "error: codesign verification failed. Tail of $LOG:" >&2
    tail -30 "$LOG" >&2
    exit 1
}

# Confirm the runtime flag is set (notary rejects bundles without it).
RUNTIME=$(codesign --display --verbose=2 "$APP" 2>&1 | grep -c "flags=0x10000.runtime." || true)
if [ "$RUNTIME" -eq 0 ]; then
    echo "warn: main app appears to be missing the hardened runtime flag" >&2
fi

# ---- Notarize ----

if [ -n "${SKIP_NOTARY:-}" ]; then
    echo "==> SKIP_NOTARY=1 — stopping after codesign. App at $APP"
    exit 0
fi

echo "==> Submitting to Apple's notary service..."
SUBMIT_ZIP="/tmp/youty-notarize.zip"
rm -f "$SUBMIT_ZIP"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

xcrun notarytool submit "$SUBMIT_ZIP" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait \
    --timeout 30m \
    2>&1 | tee -a "$LOG" || {
        echo "error: notarytool submission failed. Tail of $LOG:" >&2
        tail -40 "$LOG" >&2
        exit 1
    }

# ---- Staple ----

echo "==> Stapling the notary ticket..."
xcrun stapler staple "$APP" >> "$LOG" 2>&1 || {
    echo "error: staple failed. Tail of $LOG:" >&2
    tail -20 "$LOG" >&2
    exit 1
}
xcrun stapler validate "$APP" >> "$LOG" 2>&1

# ---- Gatekeeper acceptance check ----
#
# `spctl` simulates the same check macOS performs when the user
# double-clicks a downloaded copy. If this passes, Gatekeeper will
# accept the app with one-click consent — no scary "macOS cannot
# verify" dialog.

echo "==> Verifying Gatekeeper acceptance..."
spctl --assess --type execute --verbose "$APP" 2>&1 | tee -a "$LOG" || {
    echo "error: spctl assessment failed. App not Gatekeeper-acceptable."
    exit 1
}

echo
echo "==> Done."
echo "    Signed + notarized + stapled: $APP"
echo "    Next: Scripts/make-dmg.sh (with same DEVELOPER_ID_APPLICATION_CERT)"
echo "    Then: Scripts/sparkle-sign-and-cut.sh build/Youty.dmg"
