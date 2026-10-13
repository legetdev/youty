"""The compact tokenizer must produce exactly Google's token ids."""
import random

import pytest

from youty_mcp import models
from youty_mcp.gemma_tokenizer import FILES, GemmaTokenizer

SAMPLES = [
    "how do I build an app", "Wie baue ich eine App mit KI? äöüß ÄÖÜ", "  leading  and  trailing  ",
    "emoji 🚀🔥👩‍💻", "日本語のテキストと中文", "def f(x):\n\treturn x**2  # code",
    "<bos> literal <eos> <start_of_turn> tokens", "https://youtube.com/watch?v=dQw4w9WgXcQ&t=42s",
    "", "a" * 300, "Ω≈ç√∫ ﬁﬂ ½ ㍿", "​ zero width ﻿", "x́ combining", "𝔘𝔫𝔦𝔠𝔬𝔡𝔢",
]


@pytest.fixture(scope="module")
def tokenizers_pair():
    try:
        directory = models.locate(prepare=False).tokenizer.parent   # never download in tests
    except Exception:  # noqa: BLE001
        pytest.skip("EmbeddingGemma 2 tokenizer files not installed")
    if not all((directory / name).exists() for name in FILES):
        pytest.skip("compact tokenizer artifacts not installed")
    from tokenizers import Tokenizer

    return GemmaTokenizer(directory), Tokenizer.from_file(str(directory / "tokenizer.json"))


def test_matches_hugging_face(tokenizers_pair):
    ours, reference = tokenizers_pair
    rng = random.Random(7)
    alphabet = [chr(c) for c in [*range(32, 127), *range(0xA0, 0x250), *range(0x400, 0x450),
                                 *range(0x4E00, 0x4E40), 0x1F600, 0x2581, 0x2028, 0x10FFFD]]
    randoms = ["".join(rng.choice(alphabet) for _ in range(rng.randint(1, 50))) for _ in range(200)]
    for text in SAMPLES + randoms:
        query = "task: search result | query: " + text
        assert ours.encode(query) == reference.encode(query, add_special_tokens=True).ids, repr(text)
