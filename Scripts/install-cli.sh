#!/usr/bin/env bash
# Build and install the `youty` CLI binary to a directory on $PATH.
#
# Tries (in order):
#   1. $YOUTY_INSTALL_DIR if set
#   2. /usr/local/bin (asks for sudo if not writable)
#   3. $HOME/.local/bin (creates if missing)
#
# Builds the Release configuration so the user gets the fast binary.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Building youty-cli (Release)…"
xcodebuild \
    -project "$ROOT/youty.xcodeproj" \
    -scheme youty-cli \
    -configuration Release \
    -derivedDataPath "$ROOT/build/release" \
    build > /tmp/youty-cli-install.log 2>&1 || {
        echo "error: build failed. See /tmp/youty-cli-install.log for details." >&2
        exit 1
    }

BIN="$ROOT/build/release/Build/Products/Release/youty"
if [ ! -x "$BIN" ]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

# Pick the destination.
if [ -n "${YOUTY_INSTALL_DIR:-}" ]; then
    DEST="$YOUTY_INSTALL_DIR/youty"
elif [ -w /usr/local/bin ]; then
    DEST="/usr/local/bin/youty"
elif [ -d /usr/local/bin ] && command -v sudo >/dev/null 2>&1; then
    echo "==> /usr/local/bin not writable; installing with sudo."
    sudo cp "$BIN" /usr/local/bin/youty
    sudo chmod 0755 /usr/local/bin/youty
    DEST="/usr/local/bin/youty"
    echo "==> Installed to $DEST"
    "$DEST" --version
    exit 0
else
    DEST="$HOME/.local/bin/youty"
    mkdir -p "$HOME/.local/bin"
fi

cp "$BIN" "$DEST"
chmod 0755 "$DEST"
echo "==> Installed to $DEST"

# Make sure the destination is on $PATH; warn if not.
case ":$PATH:" in
    *":$(dirname "$DEST"):"*)
        ;;
    *)
        echo "warning: $(dirname "$DEST") is not on your \$PATH." >&2
        echo "         Add this to your shell rc:" >&2
        echo "         export PATH=\"$(dirname "$DEST"):\$PATH\"" >&2
        ;;
esac

"$DEST" --version
