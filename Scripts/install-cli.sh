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

# --- Shared resources the bare CLI binary can't bundle on its own ---
# A command-line tool has no Resources/ directory, so the SQLite index
# schema and the SigLIP image encoder live in a shared per-user dir that
# IndexStore + SigLIPLoader consult (see SharedResourceLocator.swift).
# Populating it here gives `youty save` the exact same full text + frame
# indexing the Mac app performs — not a degraded capture-only mode.
RES_DIR="$HOME/Library/Application Support/Youty/resources"
mkdir -p "$RES_DIR"
cp "$ROOT/Sources/IndexSchema.sql" "$RES_DIR/IndexSchema.sql"
echo "==> Installed search-index schema."

MLPACKAGE="$ROOT/Vendor/siglip/models/SigLIP-Base-224_image.mlpackage"
if [ -d "$MLPACKAGE" ]; then
    echo "==> Compiling image-search model (one-time, ~10s)…"
    rm -rf "$RES_DIR/SigLIP-Base-224_image.mlmodelc"
    if xcrun coremlcompiler compile "$MLPACKAGE" "$RES_DIR" >/dev/null 2>&1; then
        echo "==> Installed image-search model."
    else
        echo "warning: image-search model compile failed; CLI frame indexing will be unavailable." >&2
    fi
else
    echo "warning: SigLIP model not found at $MLPACKAGE (Git LFS not pulled?); CLI frame indexing unavailable." >&2
fi

# EmbeddingGemma on-device text encoder (Phase S.1): the Core ML model + the
# compact native tokenizer artifact (vocab/merges/added_tokens .bin). Dormant
# until S.2, but installed now so the CLI has it ready when the default flips.
GEMMA_PKG="$ROOT/Vendor/embeddinggemma/models/EmbeddingGemma-300m_text.mlpackage"
GEMMA_TOK="$ROOT/Vendor/embeddinggemma/tokenizer"
if [ -d "$GEMMA_PKG" ] && [ -f "$GEMMA_TOK/vocab.bin" ]; then
    echo "==> Compiling on-device text model (one-time, ~10s)…"
    rm -rf "$RES_DIR/EmbeddingGemma-300m_text.mlmodelc"
    if xcrun coremlcompiler compile "$GEMMA_PKG" "$RES_DIR" >/dev/null 2>&1; then
        cp "$GEMMA_TOK/vocab.bin" "$GEMMA_TOK/merges.bin" "$GEMMA_TOK/added_tokens.bin" "$RES_DIR/"
        echo "==> Installed on-device text model + tokenizer."
    else
        echo "warning: text model compile failed; CLI on-device text embedding unavailable." >&2
    fi
else
    echo "warning: EmbeddingGemma model/tokenizer not found (Git LFS not pulled?); CLI on-device text embedding unavailable." >&2
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
