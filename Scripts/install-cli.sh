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

# On-device models live outside git; fetch them if missing (no-op otherwise).
"$ROOT/Scripts/fetch-models.sh"

echo "==> Building youty-cli (Release)…"
xcodebuild \
    -project "$ROOT/youty.xcodeproj" \
    -scheme youty-cli \
    -configuration Release \
    -derivedDataPath "$ROOT/build/release" \
    ARCHS=arm64 \
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
STAGED_RES="$(mktemp -d "${TMPDIR:-/tmp}/youty-cli-resources.XXXXXX")"
trap 'rm -rf "$STAGED_RES"' EXIT
cp "$ROOT/Sources/IndexSchema.sql" "$STAGED_RES/IndexSchema.sql"

MLPACKAGE="$ROOT/Vendor/siglip/models/SigLIP-Base-224_image.mlpackage"
if [ -d "$MLPACKAGE" ]; then
    echo "==> Compiling image-search model (one-time, ~10s)…"
    if ! xcrun coremlcompiler compile "$MLPACKAGE" "$STAGED_RES" >"$STAGED_RES/image-compile.log" 2>&1; then
        echo "error: image-search model compilation failed; existing installation is unchanged." >&2
        cat "$STAGED_RES/image-compile.log" >&2
        exit 1
    fi
else
    echo "error: image-search model not found at $MLPACKAGE; existing installation is unchanged." >&2
    exit 1
fi

# EmbeddingGemma on-device text encoder (Phase S.1): the Core ML model + the
# compact native tokenizer artifact (vocab/merges/added_tokens .bin).
GEMMA_PKG="$ROOT/Vendor/embeddinggemma/models/EmbeddingGemma-300m_text.mlpackage"
GEMMA_TOK="$ROOT/Vendor/embeddinggemma/tokenizer"
if [ -d "$GEMMA_PKG" ] && [ -f "$GEMMA_TOK/vocab.bin" ] && \
   [ -f "$GEMMA_TOK/merges.bin" ] && [ -f "$GEMMA_TOK/added_tokens.bin" ]; then
    echo "==> Compiling on-device text model (one-time, ~10s)…"
    if ! xcrun coremlcompiler compile "$GEMMA_PKG" "$STAGED_RES" >"$STAGED_RES/text-compile.log" 2>&1; then
        echo "error: text model compilation failed; existing installation is unchanged." >&2
        cat "$STAGED_RES/text-compile.log" >&2
        exit 1
    fi
    cp "$GEMMA_TOK/vocab.bin" "$GEMMA_TOK/merges.bin" "$GEMMA_TOK/added_tokens.bin" "$STAGED_RES/"
else
    echo "error: text model or tokenizer assets are missing; existing installation is unchanged." >&2
    exit 1
fi

# Replace installed resources only after every required asset is ready.
for MODEL in SigLIP-Base-224_image EmbeddingGemma-300m_text; do
    if [ ! -d "$STAGED_RES/$MODEL.mlmodelc" ]; then
        echo "error: compiled $MODEL model is missing; existing installation is unchanged." >&2
        exit 1
    fi
done
mkdir -p "$RES_DIR"
for MODEL in SigLIP-Base-224_image EmbeddingGemma-300m_text; do
    rm -rf "$RES_DIR/$MODEL.mlmodelc"
    mv "$STAGED_RES/$MODEL.mlmodelc" "$RES_DIR/"
done
cp "$STAGED_RES/IndexSchema.sql" "$STAGED_RES/vocab.bin" \
    "$STAGED_RES/merges.bin" "$STAGED_RES/added_tokens.bin" "$RES_DIR/"
echo "==> Installed search models, tokenizer, and index schema."

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
