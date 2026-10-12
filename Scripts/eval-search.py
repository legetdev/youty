#!/usr/bin/env python3
"""Measure vault search quality against a fixed question set.

Runs the MCP server's own search code (so it scores exactly what agents see)
against an index database and prints recall@5, MRR@10, and moment hits per
question kind. The question file is private to the owner's vault; see
`eval/vault-questions.json` (git-ignored). Each question names the expected
video and, for spoken content, the expected moment in milliseconds.

    cd youty-mcp && YOUTY_INDEX_DB=/path/to/index.db \\
        uv run python ../Scripts/eval-search.py ../eval/vault-questions.json

"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from collections import defaultdict


def ranked(question: dict, k: int) -> list[tuple[str, int | None, int | None]]:
    """Return ranked (video_id, start_ms, end_ms) hits for one question."""
    from youty_mcp import server

    out = server._do_search(question["query"], videos=k)
    hits = []
    for video in out["videos"]:
        for moment in video["moments"]:
            hits.append((video["video_id"], moment.get("start_ms"), moment.get("end_ms")))
        if not video["moments"]:
            hits.append((video["video_id"], None, None))
    return hits


def score(question: dict, hits: list, tolerance: int) -> dict:
    videos: list[str] = []
    for vid, _, _ in hits:
        if vid not in videos:
            videos.append(vid)
    expected = question["video_id"]
    rank = videos.index(expected) + 1 if expected in videos else None
    moment = None
    if question.get("ms") is not None and expected:
        target = question["ms"]
        top = [h for h in hits if h[0] == expected][:5]
        moment = any(
            s is not None and (s - tolerance) <= target <= ((e if e is not None else s) + tolerance)
            for _, s, e in top
        )
    return {"rank": rank, "moment": moment}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("questions")
    parser.add_argument("--k", type=int, default=20, help="videos per search")
    parser.add_argument("--json", help="write per-question results here")
    args = parser.parse_args()

    spec = json.load(open(args.questions, encoding="utf-8"))
    tolerance = spec.get("tolerance_ms", 120_000)
    by_kind: dict[str, list[dict]] = defaultdict(list)
    rows = []
    latencies = []
    for question in spec["questions"]:
        started = time.perf_counter()
        hits = ranked(question, args.k)
        latencies.append(time.perf_counter() - started)
        if question["video_id"] is None:
            rows.append({**question, "top": [h[0] for h in hits[:3]]})
            continue
        result = score(question, hits, tolerance)
        rows.append({**question, **result})
        by_kind[question["kind"]].append(result)

    def summary(results: list[dict]) -> str:
        recall = sum(1 for r in results if r["rank"] and r["rank"] <= 5) / len(results)
        mrr = statistics.mean(1 / r["rank"] if r["rank"] and r["rank"] <= 10 else 0 for r in results)
        moments = [r["moment"] for r in results if r["moment"] is not None]
        moment = f" moment@5 {sum(moments)}/{len(moments)}" if moments else ""
        return f"recall@5 {recall:.3f}  MRR@10 {mrr:.3f}  n={len(results)}{moment}"

    every = [r for results in by_kind.values() for r in results]
    for kind in sorted(by_kind):
        print(f"  {kind:10s} {summary(by_kind[kind])}")
    german = by_kind.get("de", []) + by_kind.get("visual_de", []) + by_kind.get("hard_de", [])
    visual = by_kind.get("visual", []) + by_kind.get("visual_de", [])
    print(f"  {'GERMAN':10s} {summary(german)}")
    print(f"  {'VISUAL':10s} {summary(visual)}")
    hard = [r for kind, results in by_kind.items() if kind.startswith("hard") for r in results]
    if hard:
        print(f"  {'HARD':10s} {summary(hard)}")
    print(f"  {'OVERALL':10s} {summary(every)}")
    print(f"  latency median {statistics.median(latencies) * 1000:.0f} ms (first {latencies[0] * 1000:.0f} ms)")
    for row in rows:
        if row["video_id"] is None:
            print(f"  [none] {row['query'][:60]!r} -> {row['top']}")
    if args.json:
        json.dump(rows, open(args.json, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
