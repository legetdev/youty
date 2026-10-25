"""Query-embedding helper process.

The server starts this on the first search and stops it after ten minutes without
one, so the model's memory is fully returned to macOS between uses (a model
freed inside a long-running Python process mostly stays allocated).

Protocol, one JSON object per line: the server writes ``{"q": "<query>"}`` to
stdin, the helper answers ``{"v": "<base64 little-endian float32 vector>"}`` or
``{"error": "<message>"}`` on stdout. It exits when stdin closes, including
when the server itself exits.
"""
from __future__ import annotations

import base64
import json
import sys


def main() -> None:
    from .query_encoder import QueryEncoder

    encoder = QueryEncoder()
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            vector = encoder.embed(json.loads(line)["q"])
            reply = {"v": base64.b64encode(vector.astype("<f4").tobytes()).decode("ascii")}
        except Exception as exc:  # noqa: BLE001
            reply = {"error": str(exc) or type(exc).__name__}
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
