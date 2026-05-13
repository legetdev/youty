"""Gemini REST client.

Two responsibilities:
  1. Embed query strings via gemini-embedding-001 (RETRIEVAL_QUERY, 768d).
  2. Decompose compound queries via gemini-2.5-flash into ≤3 sub-queries.
Both use plain httpx — no Google SDK — to keep the dependency surface tiny.
"""

from __future__ import annotations

import json
import logging
from typing import Iterable

import httpx


_EMBED_MODEL = "gemini-embedding-001"
_DECOMPOSE_MODEL = "gemini-2.5-flash"
_BASE = "https://generativelanguage.googleapis.com/v1beta"

_DECOMPOSE_PROMPT = (
    "Decompose the following user query into AT MOST 3 focused sub-queries "
    "suitable for semantic search over a video transcript corpus. If the query "
    "is already focused, return a single-element array containing the original "
    "query. Return ONLY a JSON array of strings, no prose.\n\nQuery: "
)

_log = logging.getLogger(__name__)


class GeminiEmbedder:
    """Thin client around two Gemini REST endpoints."""

    def __init__(self, api_key: str, *, timeout: float = 10.0) -> None:
        self._api_key = api_key
        # Send the key in the x-goog-api-key header (Google's official
        # alternative to the ?key= query param). The header never appears in
        # httpx's standard log lines, so any future debug logging cannot leak
        # the secret. URLs in logs stay clean.
        self._client = httpx.Client(
            timeout=timeout,
            headers={"x-goog-api-key": api_key, "Content-Type": "application/json"},
        )

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> "GeminiEmbedder":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    # ───────── embeddings ─────────

    def embed_query(self, text: str, *, dim: int = 768) -> list[float]:
        """Embed a single query string for retrieval (returns a 768-d vector by default)."""
        url = f"{_BASE}/models/{_EMBED_MODEL}:embedContent"
        payload = {
            "content": {"parts": [{"text": text}]},
            "taskType": "RETRIEVAL_QUERY",
            "outputDimensionality": dim,
        }
        resp = self._client.post(url, json=payload)
        resp.raise_for_status()
        data = resp.json()
        emb = data.get("embedding", {}).get("values")
        if not isinstance(emb, list):
            raise RuntimeError(
                f"Gemini embed response missing embedding.values: {data!r}"
            )
        return [float(v) for v in emb]

    # ───────── multi-query decomposition ─────────

    def decompose(self, query: str, *, max_subqueries: int = 3) -> list[str]:
        """Return ≤max_subqueries focused sub-queries. Caller should fall back on error."""
        url = f"{_BASE}/models/{_DECOMPOSE_MODEL}:generateContent"
        payload = {
            "contents": [{"parts": [{"text": _DECOMPOSE_PROMPT + query}]}],
            "generationConfig": {
                "responseMimeType": "application/json",
                "responseSchema": {
                    "type": "ARRAY",
                    "items": {"type": "STRING"},
                },
                "temperature": 0.1,
                "maxOutputTokens": 256,
            },
        }
        # Tight timeout so decomposition never dominates latency.
        resp = self._client.post(url, json=payload, timeout=1.5)
        resp.raise_for_status()
        data = resp.json()
        try:
            text = data["candidates"][0]["content"]["parts"][0]["text"]
        except (KeyError, IndexError, TypeError) as exc:
            raise RuntimeError(f"unexpected Gemini Flash shape: {data!r}") from exc

        parsed = json.loads(text)
        if not isinstance(parsed, list):
            raise RuntimeError(f"decompose: expected JSON list, got {parsed!r}")
        cleaned: list[str] = []
        for item in parsed:
            if isinstance(item, str) and item.strip():
                cleaned.append(item.strip())
            if len(cleaned) >= max_subqueries:
                break
        return cleaned


def looks_compound(query: str) -> bool:
    """Heuristic: should we run the multi-query decomposer?

    Permissive — when in doubt, decompose. Cost is ~$0.000013 per
    Gemini Flash call, and the decomposer returns a single-element array
    on focused queries, so over-triggering is harmless.

    Triggers on:
      - any query with 4+ tokens (covers conversational phrasing and
        most German queries — "Friedrich Merz politische Probleme Kritik"
        is 5 tokens and is plainly compound)
      - explicit compound markers in EN + DE: " and ", " und ", " oder ",
        " vs ", " or ", ";", commas, question marks
    """
    if len(query.split()) >= 4:
        return True
    lowered = " " + query.lower() + " "
    triggers = (
        " and ", " or ", " vs ", " und ", " oder ", " sowie ",
        ", ", "; ", "? ",
    )
    return any(t in lowered for t in triggers)
