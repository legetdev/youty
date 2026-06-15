#!/usr/bin/env bash
#
# Fetch the on-device Core ML models (EmbeddingGemma text encoder + SigLIP
# image encoder) that building Youty from source requires.
#
# These weights live OUTSIDE git — they're ~415 MB and would bloat a lean,
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
MODELS_VERSION="1.0.0"
MODELS_SHA256="c3139d78af916c3a77ab57986b9729b26d243a1544b2555011b1d59c2560b6d7"
MODELS_URL="https://github.com/legetdev/youty/releases/download/v${MODELS_VERSION}/youty-models-${MODELS_VERSION}.tar.gz"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The large files the asset provides (relative to repo root). The tiny
# Manifest.json companions stay in git, so the .mlpackages reassemble correctly.
REQUIRED=(
  "Vendor/embeddinggemma/models/EmbeddingGemma-300m_text.mlpackage/Data/com.apple.CoreML/model.mlmodel"
  "Vendor/embeddinggemma/models/EmbeddingGemma-300m_text.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
  "Vendor/embeddinggemma/tokenizer/added_tokens.bin"
  "Vendor/embeddinggemma/tokenizer/merges.bin"
  "Vendor/embeddinggemma/tokenizer/vocab.bin"
  "Vendor/siglip/models/SigLIP-Base-224_image.mlpackage/Data/com.apple.CoreML/model.mlmodel"
  "Vendor/siglip/models/SigLIP-Base-224_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
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

echo "==> Fetching Youty models (v${MODELS_VERSION}, ~415 MB)…"
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
