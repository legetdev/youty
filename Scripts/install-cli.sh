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
# A command-line tool has no Resources/ directory, so the SQLite index schema
# and the EmbeddingGemma 2 models live in a shared per-user dir that IndexStore
# and EmbeddingGemma2 consult (see SharedResourceLocator.swift).
# Populating it here gives `youty save` the exact same full text + frame
# indexing the Mac app performs — not a degraded capture-only mode.
RES_DIR="$HOME/Library/Application Support/Youty/resources"
STAGED_RES="$(mktemp -d "${TMPDIR:-/tmp}/youty-cli-resources.XXXXXX")"
trap 'rm -rf "$STAGED_RES"' EXIT
cp "$ROOT/Sources/IndexSchema.sql" "$STAGED_RES/IndexSchema.sql"

# EmbeddingGemma 2 (text + vision): the Core ML packages, the token and
# position tables, and the tokenizer (native artifacts for Swift, tokenizer.json
# so the MCP server can reuse these files instead of downloading them).
EG2="$ROOT/Vendor/embeddinggemma2"
FILES=(
    "$EG2/resources/EmbeddingGemma2Tokens.bf16" "$EG2/resources/EmbeddingGemma2Positions.f16"
    "$EG2/tokenizer/vocab.bin" "$EG2/tokenizer/merges.bin" "$EG2/tokenizer/added_tokens.bin"
    "$EG2/tokenizer/tokenizer.json"
)
for FILE in "${FILES[@]}"; do
    if [ ! -f "$FILE" ]; then
        echo "error: $(basename "$FILE") is missing; existing installation is unchanged." >&2
        exit 1
    fi
done
for MODEL in EmbeddingGemma2Text EmbeddingGemma2Vision; do
    PKG="$EG2/models/$MODEL.mlpackage"
    if [ ! -d "$PKG" ]; then
        echo "error: $MODEL model not found at $PKG; existing installation is unchanged." >&2
        exit 1
    fi
    echo "==> Compiling $MODEL (one-time)…"
    if ! xcrun coremlcompiler compile "$PKG" "$STAGED_RES" >"$STAGED_RES/$MODEL-compile.log" 2>&1; then
        echo "error: $MODEL compilation failed; existing installation is unchanged." >&2
        cat "$STAGED_RES/$MODEL-compile.log" >&2
        exit 1
    fi
done
cp "${FILES[@]}" "$STAGED_RES/"

# Replace installed resources only after every required asset is ready.
for MODEL in EmbeddingGemma2Text EmbeddingGemma2Vision; do
    if [ ! -d "$STAGED_RES/$MODEL.mlmodelc" ]; then
        echo "error: compiled $MODEL model is missing; existing installation is unchanged." >&2
        exit 1
    fi
done
# Install the binary first: if that fails, the existing CLI and its resources
# stay untouched. Only then retire old models and move the staged ones in.
SUDO=""
if [ -n "${YOUTY_INSTALL_DIR:-}" ]; then
    DEST="$YOUTY_INSTALL_DIR/youty"
elif [ -w /usr/local/bin ]; then
    DEST="/usr/local/bin/youty"
elif [ -d /usr/local/bin ] && command -v sudo >/dev/null 2>&1; then
    echo "==> /usr/local/bin not writable; installing with sudo."
    DEST="/usr/local/bin/youty"
    SUDO="sudo"
else
    DEST="$HOME/.local/bin/youty"
    mkdir -p "$HOME/.local/bin"
fi
# Copy beside the destination, then rename: a failed copy never touches $DEST.
if ! { $SUDO cp "$BIN" "$DEST.new" && $SUDO chmod 0755 "$DEST.new" && $SUDO mv -f "$DEST.new" "$DEST"; }; then
    $SUDO rm -f "$DEST.new" 2>/dev/null || true
    echo "error: couldn't install youty to $DEST; existing installation is unchanged." >&2
    exit 1
fi
echo "==> Installed to $DEST"

mkdir -p "$RES_DIR"
# Retired models from earlier versions.
rm -rf "$RES_DIR/SigLIP-Base-224_image.mlmodelc" "$RES_DIR/EmbeddingGemma-300m_text.mlmodelc"
for MODEL in EmbeddingGemma2Text EmbeddingGemma2Vision; do
    rm -rf "$RES_DIR/$MODEL.mlmodelc"
    mv "$STAGED_RES/$MODEL.mlmodelc" "$RES_DIR/"
done
cp "$STAGED_RES/IndexSchema.sql" "$STAGED_RES/EmbeddingGemma2Tokens.bf16" "$STAGED_RES/EmbeddingGemma2Positions.f16" \
    "$STAGED_RES/vocab.bin" "$STAGED_RES/merges.bin" "$STAGED_RES/added_tokens.bin" \
    "$STAGED_RES/tokenizer.json" "$RES_DIR/"
echo "==> Installed search models, tokenizer, and index schema."

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
