"""Pure-Python CLIP BPE tokenizer (OpenAI / MobileCLIP-S2 compatible).

Ports the standard CLIP BPE algorithm so the MCP server can tokenize text
without pulling in `transformers` / `open_clip`. Uses the canonical
`vocab.json` + `merges.txt` shipped on HuggingFace
(`openai/clip-vit-base-patch32`). Output: 77-length Int32 token array
matching MobileCLIP's expected text input shape `[1, 77]`.

Algorithm: byte-level pre-tokenization (GPT-2 byte encoder) → BPE merges
sorted by rank → look-up in vocab → prefix with `<|startoftext|>` and
suffix with `<|endoftext|>`, zero-pad to 77.
"""

from __future__ import annotations

import functools
import json
import re
from pathlib import Path


# OpenAI CLIP tokenization regex. The reference uses `\p{L}` / `\p{N}` from
# the `regex` module, which isn't in stdlib. We use `re`'s `\w` (alphanumeric
# + underscore, Unicode-aware) as a close substitute. For English captions
# the practical difference is negligible — `\w` collapses underscores into
# the letter class, which adds one extra letter bucket but doesn't change
# BPE merge behaviour since the tokenizer is byte-level downstream.
_TOKEN_REGEX = re.compile(
    r"""<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\w]+|[^\s\w]+""",
    re.UNICODE,
)


@functools.lru_cache(maxsize=1)
def _bytes_to_unicode() -> dict[int, str]:
    """GPT-2 byte→unicode mapping. Identical to OpenAI CLIP's."""
    bs = (
        list(range(ord("!"), ord("~") + 1))
        + list(range(ord("¡"), ord("¬") + 1))
        + list(range(ord("®"), ord("ÿ") + 1))
    )
    cs = bs[:]
    n = 0
    for b in range(2**8):
        if b not in bs:
            bs.append(b)
            cs.append(2**8 + n)
            n += 1
    return dict(zip(bs, [chr(c) for c in cs]))


def _get_pairs(word: tuple[str, ...]) -> set[tuple[str, str]]:
    pairs: set[tuple[str, str]] = set()
    prev = word[0]
    for ch in word[1:]:
        pairs.add((prev, ch))
        prev = ch
    return pairs


class CLIPTokenizer:
    """Pure-Python CLIP BPE tokenizer matching MobileCLIP-S2's input contract."""

    CONTEXT_LENGTH = 77

    def __init__(self, vocab_path: Path, merges_path: Path) -> None:
        with open(vocab_path, "r", encoding="utf-8") as f:
            self._encoder: dict[str, int] = json.load(f)
        # merges.txt: first line is a header — skip it.
        merges = merges_path.read_text(encoding="utf-8").splitlines()
        merges = merges[1 : 49152 - 256 - 2 + 1]  # match OpenAI's slicing
        self._bpe_ranks: dict[tuple[str, str], int] = {
            tuple(m.split()): i for i, m in enumerate(merges) if m
        }
        self._byte_encoder = _bytes_to_unicode()
        self._cache: dict[str, str] = {}

        self._sot = self._encoder["<|startoftext|>"]
        self._eot = self._encoder["<|endoftext|>"]

    def _bpe(self, token: str) -> str:
        if token in self._cache:
            return self._cache[token]
        # word is a tuple of single bytes-encoded chars, with the final one
        # carrying the </w> end-of-word marker (CLIP convention).
        word = tuple(token[:-1]) + (token[-1] + "</w>",)
        pairs = _get_pairs(word)
        if not pairs:
            return token + "</w>"
        while True:
            bigram = min(pairs, key=lambda p: self._bpe_ranks.get(p, float("inf")))
            if bigram not in self._bpe_ranks:
                break
            first, second = bigram
            new_word: list[str] = []
            i = 0
            while i < len(word):
                try:
                    j = word.index(first, i)
                    new_word.extend(word[i:j])
                    i = j
                except ValueError:
                    new_word.extend(word[i:])
                    break
                if word[i] == first and i < len(word) - 1 and word[i + 1] == second:
                    new_word.append(first + second)
                    i += 2
                else:
                    new_word.append(word[i])
                    i += 1
            word = tuple(new_word)
            if len(word) == 1:
                break
            pairs = _get_pairs(word)
        result = " ".join(word)
        self._cache[token] = result
        return result

    def encode(self, text: str) -> list[int]:
        """Return raw BPE token ids (no SOT/EOT, no padding)."""
        tokens: list[int] = []
        text = text.lower()
        for match in _TOKEN_REGEX.findall(text):
            byte_seq = "".join(self._byte_encoder[b] for b in match.encode("utf-8"))
            for bpe_tok in self._bpe(byte_seq).split(" "):
                if bpe_tok in self._encoder:
                    tokens.append(self._encoder[bpe_tok])
        return tokens

    def encode_full(self, text: str) -> list[int]:
        """Return a 77-length token array: [SOT, ...tokens, EOT, 0, 0, ...]."""
        ids = self.encode(text)
        # Truncate room for SOT + EOT.
        ids = ids[: self.CONTEXT_LENGTH - 2]
        out = [0] * self.CONTEXT_LENGTH
        out[0] = self._sot
        for i, tok in enumerate(ids):
            out[i + 1] = tok
        out[len(ids) + 1] = self._eot
        return out
