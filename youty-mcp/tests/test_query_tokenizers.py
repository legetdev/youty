"""Golden query-token parity against Transformers 4.57.6 before its removal.

Run the asset-dependent check with YOUTY_TOKENIZER_PARITY=1; it uses the same
pinned cached/downloadable vocabularies as production, never a user vault.
"""
import hashlib
import json
import os
import random

import pytest

from youty_mcp.query_tokenizers import SiglipQueryTokenizer, load_gemma_tokenizer


def parity_cases():
    """Cover ordinary queries, Unicode, literal special tokens, and truncation."""
    cases = ["", " ", "\n\t", "Find a red car.", "München Straße café 👋", "ΟΣ ΣΣ İI", "你好 世界 日本語", "مرحبا بالعالم", "<bos> literal <eos>", "<unk>", "</s>", "<UNK>", "</S>", "a<unk>b</s>c", "▁hello▁world", "hello\u0000world", "\u00a0\u2003text\r\nmore", "!@#$%^&*()_+-=[]{};:'\",.<>/?\\|`~", "A" * 5000, "word " * 600]
    rng = random.Random(146)
    alphabet = list("Aa Zz09\n\t!?<unk>/s▁éİΣσς漢字👋")
    return cases + ["".join(rng.choice(alphabet) for _ in range(rng.randrange(0, 500))) for _ in range(500)]


@pytest.mark.skipif(os.environ.get("YOUTY_TOKENIZER_PARITY") != "1", reason="requires cached tokenizer assets")
def test_query_tokenizers_match_pre_removal_golden():
    """Detect even one changed token in either query path without Transformers."""
    gemma, siglip = load_gemma_tokenizer(), SiglipQueryTokenizer()
    hashes = [hashlib.sha256(), hashlib.sha256()]
    for text in parity_cases():
        tokens = [gemma.encode("task: search result | query: " + text).ids, siglip.encode(text)]
        assert len(tokens[1]) == 64
        for digest, ids in zip(hashes, tokens):
            digest.update(json.dumps(ids, separators=(",", ":")).encode())
    assert hashes[0].hexdigest() == "4d10df45e296995486c82c795c3bf3133e9bc62467c5641f9f230f8effcf5909"
    assert hashes[1].hexdigest() == "a20a01708eeea2abeddbf0790835235ac9f41aebb30a4daf3b32ad4ce0207694"


@pytest.mark.parametrize("text,expected", [("", [1] * 64), ("</s>", [1] * 64), ("<unk>", [2] + [1] * 63)])
def test_siglip_special_tokens_without_model_download(text, expected):
    """Keep padding and special-token behavior covered on offline CI runners."""
    import string
    from types import SimpleNamespace

    tokenizer = SiglipQueryTokenizer.__new__(SiglipQueryTokenizer)
    tokenizer._prefix_length = 1
    tokenizer._punctuation = str.maketrans("", "", string.punctuation)
    tokenizer._sp = SimpleNamespace(encode=lambda text, out_type: ["prefix"], piece_to_id=lambda piece: {"</s>": 1, "<unk>": 2}[piece])
    assert tokenizer.encode(text) == expected
