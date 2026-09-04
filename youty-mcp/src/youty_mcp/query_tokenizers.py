# SigLIP compatibility logic adapted from Transformers 4.57.6:
# Copyright 2024 The HuggingFace Inc. team. Licensed under Apache-2.0.
# Modified for Youty: query-only SentencePiece adapter, fixed assets, no model
# loading or Transformers runtime. See THIRD_PARTY_NOTICES.txt for the license.
"""Load fixed query tokenizer assets using the existing native tokenizer engines.

Only text-to-token preparation lives here; inference remains in Core ML. Asset
revisions match the previously shipped Transformers tokenizers, avoiding changes
to the embedding space when an upstream repository updates its defaults.
"""
from __future__ import annotations

import re
import string

GEMMA_REPO = "google/embeddinggemma-300m"
GEMMA_REVISION = "57c266a740f537b4dc058e1b0cda161fd15afa75"
SIGLIP_REPO = "google/siglip-base-patch16-224"
SIGLIP_REVISION = "7fd15f0689c79d79e38b1c2e2e2370a7bf2761ed"


def load_gemma_tokenizer():
    """Load the existing Rust tokenizer, including its saved BOS/EOS template."""
    from huggingface_hub import hf_hub_download
    from tokenizers import Tokenizer

    path = hf_hub_download(GEMMA_REPO, "tokenizer.json", revision=GEMMA_REVISION)
    return Tokenizer.from_file(path)


class SiglipQueryTokenizer:
    """Preserve SigLIP's query normalization around the SentencePiece engine.

    The compatibility rules follow Transformers' Apache-2.0 SiglipTokenizer:
    per-character lowercasing, ASCII punctuation removal, special-token splitting,
    and removal of SentencePiece's unknown-token prefix before encoding.
    """

    def __init__(self) -> None:
        """Load the pinned vocabulary with the original dummy-prefix setting."""
        from huggingface_hub import hf_hub_download
        from sentencepiece import SentencePieceProcessor, sentencepiece_model_pb2

        path = hf_hub_download(SIGLIP_REPO, "spiece.model", revision=SIGLIP_REVISION)
        with open(path, "rb") as source:
            model = sentencepiece_model_pb2.ModelProto.FromString(source.read())
        model.normalizer_spec.add_dummy_prefix = False
        self._sp = SentencePieceProcessor(model_proto=model.SerializeToString())
        self._prefix_length = len(self._sp.encode("<unk>"))
        self._punctuation = str.maketrans("", "", string.punctuation)

    def encode(self, text: str) -> list[int]:
        """Return exactly 64 IDs, retaining the original EOS/truncation rules."""
        # Lower one character at a time: str.lower() would change Greek final
        # sigma relative to the original tokenizer's regex-based lowercasing.
        text = "".join(char.lower() for char in "▁" + text.replace("▁", " "))
        parts = re.split(r"(</s>|<unk>)", text)
        special = {"</s>", "<unk>"}
        for i, part in enumerate(parts):
            if part in special:
                if i:
                    parts[i - 1] = parts[i - 1].rstrip()
                if i + 1 < len(parts):
                    parts[i + 1] = parts[i + 1].lstrip()
        pieces = []
        for part in parts:
            if not part:
                continue
            if part in special:
                pieces.append(part)
                continue
            normalized = re.sub(r"\s+", " ", part.translate(self._punctuation)).strip()
            encoded = self._sp.encode("<unk>" + normalized, out_type=str)
            pieces.extend(encoded[self._prefix_length:])
        if len(pieces) > 1 and pieces[0] == "▁" and pieces[1] in special:
            pieces = pieces[1:]
        ids = [self._sp.piece_to_id(piece) for piece in pieces][:63]
        if not ids or ids[-1] != 1:
            ids.append(1)
        return ids + [1] * (64 - len(ids))
