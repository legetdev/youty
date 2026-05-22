#!/usr/bin/env bash
# Build a drag-installable DMG from the current Release youty.app.
#
# Output: build/Youty-<version>.dmg
#
# Layout: a single Finder window with youty.app on the left and an
# Applications symlink on the right. Drag the app onto Applications to
# install. Standard macOS convention.
#
# Behaviour:
#   • If `youty.app` already exists at build/release/Build/Products/Release/,
#     it is reused as-is (Phase R workflow: release-app.sh produces the
#     signed + notarized + stapled bundle and hands off to this script).
#   • Otherwise the script builds the Release configuration itself.
#   • If DEVELOPER_ID_APPLICATION_CERT is set, the produced DMG is
#     codesigned with that identity — required before R.9 because
#     unsigned DMGs trip the "macOS cannot verify" warning even when
#     the inner app is notarized.
#
# Tools used: xcodebuild, hdiutil, osascript, codesign. All Apple
# first-party. No third-party.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build/release"
APP="$BUILD_DIR/Build/Products/Release/youty.app"
VOLUME_NAME="Youty"

# ---- Resolve the version so the DMG filename is informative ----
#
# Read the source-of-truth from the built bundle if it exists, otherwise
# from the Info.plist in the source tree. Falls back to "dev" if neither
# is available — script still produces a DMG named Youty-dev.dmg.
read_version() {
    local plist="$1"
    [ -f "$plist" ] || { echo "dev"; return; }
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || echo "dev"
}

if [ -d "$APP" ]; then
    VERSION=$(read_version "$APP/Contents/Info.plist")
else
    VERSION=$(read_version "$ROOT/Sources/Info.plist")
fi

DMG_OUT="$ROOT/build/Youty-${VERSION}.dmg"

# ---- Build the Release app (only if not already built) ----
if [ -d "$APP" ]; then
    echo "==> Reusing existing youty.app at $APP"
else
    echo "==> Building Release youty.app..."
    xcodebuild \
        -project "$ROOT/youty.xcodeproj" \
        -scheme youty \
        -configuration Release \
        -derivedDataPath "$BUILD_DIR" \
        build > /tmp/youty-dmg-build.log 2>&1 || {
            echo "error: build failed. Tail of /tmp/youty-dmg-build.log:" >&2
            tail -20 /tmp/youty-dmg-build.log >&2
            exit 1
        }

    if [ ! -d "$APP" ]; then
        echo "error: built app not found at $APP" >&2
        exit 1
    fi
fi

# ---- Stage the DMG contents ----
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
echo "==> Staging in $STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# ---- Build a read/write DMG so Finder can save view options ----
mkdir -p "$ROOT/build"
RW_DMG="$ROOT/build/.youty-rw.dmg"
rm -f "$RW_DMG" "$DMG_OUT"

# Size = app size + 10 MB headroom for view-options metadata.
SIZE_KB=$(du -sk "$STAGE" | awk '{print $1 + 10000}')
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDRW \
    -size "${SIZE_KB}k" \
    "$RW_DMG" > /dev/null

# ---- Mount + apply Finder window layout via AppleScript ----
echo "==> Mounting + laying out window..."
MOUNT_DIR=$(hdiutil attach "$RW_DMG" -nobrowse -noverify -noautoopen | tail -1 | awk '{print $3}')
sleep 1

osascript <<APPLESCRIPT > /dev/null
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 200, 760, 540}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set position of item "youty.app" of container window to {145, 175}
        set position of item "Applications" of container window to {415, 175}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Forced sync before unmount so Finder's .DS_Store gets persisted.
sync
hdiutil detach "$MOUNT_DIR" -quiet

# ---- Convert RW → compressed read-only ----
echo "==> Compressing to $DMG_OUT..."
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" > /dev/null
rm -f "$RW_DMG"

# ---- Optional: codesign the DMG itself ----
#
# Apple's notary service only signs the .app inside; the DMG container
# is a separate artifact. Without this, downloaded copies still trigger
# Gatekeeper's "verify with developer" prompt even when the inner app
# is notarized + stapled.
if [ -n "${DEVELOPER_ID_APPLICATION_CERT:-}" ]; then
    echo "==> Signing DMG with $DEVELOPER_ID_APPLICATION_CERT..."
    codesign --force \
             --sign "$DEVELOPER_ID_APPLICATION_CERT" \
             --timestamp \
             "$DMG_OUT" > /tmp/youty-dmg-codesign.log 2>&1 || {
                echo "error: DMG codesign failed. Tail of /tmp/youty-dmg-codesign.log:" >&2
                tail -10 /tmp/youty-dmg-codesign.log >&2
                exit 1
             }
else
    echo "warn: DEVELOPER_ID_APPLICATION_CERT not set — DMG is unsigned." >&2
    echo "      Required before R.9. Set the env var and re-run." >&2
fi

# ---- Verify the result ----
hdiutil verify "$DMG_OUT" > /dev/null
SIZE_MB=$(du -m "$DMG_OUT" | awk '{print $1}')
echo "==> Built $DMG_OUT (${SIZE_MB} MB, version $VERSION)"

if [ -n "${DEVELOPER_ID_APPLICATION_CERT:-}" ]; then
    echo "==> Next: Scripts/sparkle-sign-and-cut.sh \"$DMG_OUT\""
fi
