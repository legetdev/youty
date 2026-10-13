"""Gemma BPE tokenizer with byte fallback, read from the compact artifacts.

A port of the app's `Sources/GemmaTokenizer.swift`, which reproduces Google's
Hugging Face tokenizer exactly. It reads `vocab.bin`, `merges.bin`, and
`added_tokens.bin` (built by `Scripts/build-gemma-tokenizer-artifact.py`)
instead of the 32 MB `tokenizer.json`: those load in tens of milliseconds where
the JSON takes over half a second, which keeps a fresh search helper under a
second. `tests/test_gemma_tokenizer.py` checks it against `tokenizers`.
"""
from __future__ import annotations

import struct
from pathlib import Path

import numpy as np

BOS, EOS = 2, 1
FILES = ("vocab.bin", "merges.bin", "added_tokens.bin")


class GemmaTokenizer:
    def __init__(self, directory: Path) -> None:
        # vocab.bin: u32 count, then per id: u32 length + UTF-8. Only single
        # characters and <0xNN> byte tokens seed BPE; longer tokens come from merges.
        data = (directory / "vocab.bin").read_bytes()
        (count,) = struct.unpack_from("<I", data, 0)
        offset = 4
        self._char_id: dict[str, int] = {}
        byte_id = [-1] * 256
        for token_id in range(count):
            (length,) = struct.unpack_from("<I", data, offset)
            offset += 4
            if length <= 4:
                # Invalid UTF-8 becomes U+FFFD, as Swift's String(decoding:) does.
                text = data[offset:offset + length].decode("utf-8", "replace")
                if len(text) == 1:
                    self._char_id[text] = token_id
            elif length == 6 and data[offset:offset + 3] == b"<0x" and data[offset + 5] == ord(">"):
                try:
                    byte_id[int(data[offset + 3:offset + 5], 16)] = token_id
                except ValueError:
                    pass
            offset += length
        if -1 in byte_id:
            raise ValueError("vocab.bin is missing byte-fallback tokens")
        self._byte_id = byte_id

        # merges.bin: u32 count, then (i32 a, i32 b, i32 merged) per rank.
        # Kept as sorted pair keys for vectorized lookups.
        merges = np.fromfile(directory / "merges.bin", dtype="<i4", offset=4).reshape(-1, 3)
        keys = (merges[:, 0].astype(np.int64) << 32) | merges[:, 1].astype(np.int64)
        order = np.argsort(keys, kind="stable")
        self._keys = keys[order]
        self._rank = order.astype(np.int64)
        self._merged = merges[order, 2].astype(np.int64)

        # added_tokens.bin: u32 count, then per token: u32 id + u32 length + UTF-8.
        data = (directory / "added_tokens.bin").read_bytes()
        (count,) = struct.unpack_from("<I", data, 0)
        offset = 4
        self._added: dict[str, int] = {}
        for _ in range(count):
            token_id, length = struct.unpack_from("<II", data, offset)
            offset += 8
            self._added[data[offset:offset + length].decode("utf-8")] = token_id
            offset += length
        self._added_first = {text[0] for text in self._added if text}
        self._added_max = max((len(text) for text in self._added), default=0)

    def encode(self, text: str) -> list[int]:
        """[bos] + added-token split + BPE + [eos], like the Hugging Face tokenizer."""
        out = [BOS]
        segment_start = i = 0
        while i < len(text):
            match = self._match_added(text, i) if text[i] in self._added_first else None
            if match is None:
                i += 1
                continue
            token_id, length = match
            out += self._bpe(text[segment_start:i])
            out.append(token_id)
            i += length
            segment_start = i
        out += self._bpe(text[segment_start:])
        out.append(EOS)
        return out

    def _match_added(self, text: str, i: int) -> tuple[int, int] | None:
        for length in range(min(self._added_max, len(text) - i), 0, -1):
            token_id = self._added.get(text[i:i + length])
            if token_id is not None:
                return token_id, length
        return None

    def _bpe(self, text: str) -> list[int]:
        if not text:
            return []
        ids: list[int] = []
        for char in text.replace(" ", "▁"):   # Gemma's normalizer
            token_id = self._char_id.get(char)
            if token_id is not None:
                ids.append(token_id)
            else:
                ids += (self._byte_id[b] for b in char.encode("utf-8", "surrogatepass"))
        # Merge the lowest-rank adjacent pair (leftmost on ties) until none applies.
        while len(ids) > 1:
            pairs = np.asarray(ids, dtype=np.int64)
            pairs = (pairs[:-1] << 32) | pairs[1:]
            slots = np.minimum(np.searchsorted(self._keys, pairs), len(self._keys) - 1)
            ranks = np.where(self._keys[slots] == pairs, self._rank[slots], np.iinfo(np.int64).max)
            best = int(np.argmin(ranks))
            if ranks[best] == np.iinfo(np.int64).max:
                break
            ids[best:best + 2] = [int(self._merged[slots[best]])]
        return ids
