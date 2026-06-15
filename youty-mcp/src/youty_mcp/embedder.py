"""Query heuristics for the `search` tool.

Text search is 100% on-device via EmbeddingGemma (`embeddinggemma_text.py`);
this module no longer talks to any cloud API. It retains only the pure
`looks_compound` heuristic, which used to gate cloud query decomposition and is
kept as a small, dependency-free utility.
"""

from __future__ import annotations


def looks_compound(query: str) -> bool:
    """Heuristic: does the query bundle multiple distinct sub-questions?

    Pure string check, no network. Triggers on:
      - any query with 4+ tokens (covers conversational phrasing and most
        German queries — "Friedrich Merz politische Probleme Kritik" is 5
        tokens and is plainly compound)
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
