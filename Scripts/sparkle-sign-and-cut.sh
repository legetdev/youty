#!/usr/bin/env bash
# Take a signed + notarized + stapled DMG, sign it with the Sparkle
# EdDSA private key (held in the macOS Keychain), and emit a ready-to-
# paste appcast <item> block.
#
# Usage:
#   Scripts/sparkle-sign-and-cut.sh build/Youty-1.0.0.dmg
#
# Output: the <item> block goes to stdout. Pipe it where you want, or
# `pbcopy` it. The script also prints a sanity report on stderr so
# nothing important gets swallowed.
#
# Required: the Sparkle SPM package must already have been resolved by
# Xcode at least once (Scripts/release-app.sh does this as a side
# effect). The script auto-locates the bundled `sign_update` tool.
#
# Phase R checklist:
#   1. Run Scripts/release-app.sh → produces signed + notarized .app
#   2. Run Scripts/make-dmg.sh    → produces signed DMG
#   3. Run this script on the DMG → produces the appcast <item>
#   4. Drop the <item> into release/appcast.xml as the newest entry
#   5. Push, redeploy Vercel (auto on push to main)

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <path-to-signed.dmg>" >&2
    exit 2
fi

DMG="$1"
if [ ! -f "$DMG" ]; then
    echo "error: $DMG does not exist or is not a file" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ---- Locate Sparkle's sign_update tool ----
#
# When the youty target was built, Xcode resolved the Sparkle package
# under SourcePackages/. The signing tool ships in the artifact bundle.
# Walk the usual derived-data paths to find it without depending on a
# specific config name.

find_sign_update() {
    for candidate in \
        "$ROOT/build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
        "$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
        /tmp/youty-build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
        /tmp/youty-release/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    # Last resort: walk DerivedData
    find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f 2>/dev/null | head -1
}

SIGN_UPDATE=$(find_sign_update)
if [ -z "${SIGN_UPDATE:-}" ] || [ ! -x "$SIGN_UPDATE" ]; then
    cat >&2 <<EOF
error: sign_update not found.

  The tool ships inside the Sparkle SPM artifact. Build the youty
  scheme at least once so SPM resolves the package:

    xcodebuild -scheme youty -configuration Release \\
               -derivedDataPath build/release -resolvePackageDependencies

  Then re-run this script.

EOF
    exit 1
fi
echo "==> Using $SIGN_UPDATE" >&2

# ---- Pull version + size out of the DMG itself ----
#
# Mount read-only, read CFBundleShortVersionString out of the embedded
# app's Info.plist, unmount. Authoritative — anything we'd hand-set
# would risk drifting from the actual built binary.

MOUNT=$(hdiutil attach -nobrowse -noverify -noautoopen -readonly "$DMG" | tail -1 | awk '{print $3}')
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true' EXIT
APP_PLIST=$(find "$MOUNT" -maxdepth 3 -name "Info.plist" -path "*youty.app/Contents/Info.plist" | head -1)
if [ -z "$APP_PLIST" ]; then
    echo "error: couldn't locate youty.app/Contents/Info.plist inside the DMG" >&2
    exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP_PLIST")
hdiutil detach "$MOUNT" -quiet
trap - EXIT

LENGTH=$(stat -f %z "$DMG")
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

# ---- Run sign_update ----
#
# sign_update writes its result to stdout as `sparkle:edSignature="..."
# length="..."`. We re-parse just the signature out of it.

echo "==> Signing DMG with Sparkle EdDSA key..." >&2
# Local default: read the private key from the Keychain. CI: pass it directly
# via the SPARKLE_ED_PRIVATE_KEY env var (a repo secret) so no Keychain is
# needed on the runner.
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    SIGN_OUTPUT=$("$SIGN_UPDATE" -s "$SPARKLE_ED_PRIVATE_KEY" "$DMG")
else
    SIGN_OUTPUT=$("$SIGN_UPDATE" "$DMG")
fi
SIGNATURE=$(echo "$SIGN_OUTPUT" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')

if [ -z "$SIGNATURE" ]; then
    echo "error: sign_update returned no signature. Raw output:" >&2
    echo "$SIGN_OUTPUT" >&2
    exit 1
fi

# ---- Emit the appcast item block to stdout ----

cat <<EOF
        <item>
            <title>Youty $VERSION</title>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <pubDate>$PUBDATE</pubDate>
            <description><![CDATA[
                <h3>Youty $VERSION</h3>
                <p><!-- TODO: fill in the release notes before pushing. --></p>
            ]]></description>
            <enclosure
                url="https://github.com/legetdev/youty/releases/download/v$VERSION/$(basename "$DMG")"
                sparkle:edSignature="$SIGNATURE"
                length="$LENGTH"
                type="application/octet-stream"/>
        </item>
EOF

cat >&2 <<EOF

==> Done. Sanity report:
    DMG:          $DMG
    Version:      $VERSION (build $BUILD)
    Min macOS:    $MIN_OS
    Size:         $LENGTH bytes
    Signature:    $SIGNATURE
    Pub date:     $PUBDATE

    Next:
      1. Paste the <item> block above into release/appcast.xml as the
         newest entry (above the previous <item>).
      2. Replace the TODO release notes with the user-facing changelog.
      3. Commit + push.
      4. Verify the appcast at https://youtyapp.vercel.app/appcast.xml
         after Vercel redeploys.
EOF
