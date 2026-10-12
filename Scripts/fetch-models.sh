#!/usr/bin/env bash
#
# Fetch the on-device EmbeddingGemma 2 models (text + vision Core ML packages,
# token and position tables, tokenizer) that building Youty from source requires.
#
# These weights live OUTSIDE git — they're ~880 MB and would bloat a lean,
# public repo and burn its Git-LFS bandwidth quota. Instead they're published
# as a single checksummed asset on the matching GitHub Release and fetched on
# demand into Vendor/.
#
# End users never run this: the shipped, notarized DMG already bundles the
# models. It's only for building the app/CLI from source (contributors, the
# Homebrew --build-from-source path, CI).
#
# Idempotent + checksum-verified: a no-op once the models are in place, so it's
# safe to call unconditionally from other build scripts.
set -euo pipefail

# Pinned to the release whose asset carries these exact weights. Bump all three
# together if the models ever change. SHA-256 is enforced before extraction.
MODELS_VERSION="2.0.0"
MODELS_SHA256="d0fb8541138a0460a59eb869cdc4cb13563d31fb8bc30bbd1a69793c5b3340f4"
MODELS_URL="https://github.com/legetdev/youty/releases/download/models-${MODELS_VERSION}/youty-models-${MODELS_VERSION}.tar.gz"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The large files the asset provides (relative to repo root). The tiny
# Manifest.json companions stay in git, so the .mlpackages reassemble correctly.
REQUIRED=(
  "Vendor/embeddinggemma2/models/EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/model.mlmodel"
  "Vendor/embeddinggemma2/models/EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
  "Vendor/embeddinggemma2/models/EmbeddingGemma2Vision.mlpackage/Data/com.apple.CoreML/model.mlmodel"
  "Vendor/embeddinggemma2/models/EmbeddingGemma2Vision.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
  "Vendor/embeddinggemma2/resources/EmbeddingGemma2Tokens.bf16"
  "Vendor/embeddinggemma2/resources/EmbeddingGemma2Positions.f16"
  "Vendor/embeddinggemma2/tokenizer/added_tokens.bin"
  "Vendor/embeddinggemma2/tokenizer/merges.bin"
  "Vendor/embeddinggemma2/tokenizer/vocab.bin"
  "Vendor/embeddinggemma2/tokenizer/tokenizer.json"
)

all_present() {
  local f
  for f in "${REQUIRED[@]}"; do [ -s "$f" ] || return 1; done
  return 0
}

if all_present; then
  echo "==> Models already present — nothing to fetch."
  exit 0
fi

echo "==> Fetching Youty models (v${MODELS_VERSION}, ~880 MB)…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TARBALL="$TMP/models.tar.gz"

curl -fL --progress-bar -o "$TARBALL" "$MODELS_URL" || {
  echo "error: download failed from $MODELS_URL" >&2
  echo "       Check your connection, or that the v${MODELS_VERSION} release asset exists yet." >&2
  exit 1
}

echo "==> Verifying checksum…"
ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ "$ACTUAL" != "$MODELS_SHA256" ]; then
  echo "error: checksum mismatch — refusing to extract a tampered or truncated file." >&2
  echo "       expected $MODELS_SHA256" >&2
  echo "       got      $ACTUAL" >&2
  exit 1
fi

echo "==> Extracting into Vendor/…"
tar -xzf "$TARBALL" -C "$ROOT"

all_present || { echo "error: models still missing after extraction." >&2; exit 1; }
echo "==> Models ready."
