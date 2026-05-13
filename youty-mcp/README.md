# youty-mcp

Local MCP server that exposes the Youty vault's vector index to any
MCP-compatible AI (Claude Desktop, Claude Code, Cursor).

## What it does

Six tools, hybrid dense + BM25 retrieval over your captured YouTube /
Instagram / TikTok videos, plus joint text → frame retrieval via Apple
MobileCLIP. Queries land in ~300 ms for text, ~1.2 s cold / 10 ms warm
for frames.

| Tool | Returns |
|---|---|
| `search(query, k=15, platform?, since_iso?)` | hybrid dense + BM25 + RRF over transcript chunks; top-k results with `frame` paths + `video_md_path` |
| `search_frames(query, k=10, platform?)` | MobileCLIP-S2 joint text→image; top-k frame matches with parent video metadata |
| `get_transcript(video_id)` | full `video.md` + parsed frontmatter |
| `get_video(video_id)` | frontmatter + folder listing + frame paths |
| `list_videos(platform?, channel?, limit=100)` | newest-first listing |
| `find_similar(video_id, k=10)` | nearest videos by averaged body-chunk vectors |

## Install

```bash
cd youty-mcp
uv sync                       # creates .venv, installs deps
```

Dependencies: `mcp`, `sqlite-vec`, `httpx`, `numpy`, `coremltools`. Python ≥ 3.11.

## Gemini API key (required for text search)

```bash
security add-generic-password -a youty -s gemini-api -w 'YOUR_GEMINI_KEY'
```

The server pulls the key from Keychain at first query. Sent via
`x-goog-api-key` header — never appears in URLs or HTTP logs.

For CI / non-Mac: set `YOUTY_GEMINI_API_KEY` instead.

## MobileCLIP models (auto-downloaded for frame search)

On first `search_frames` call (or first `--index-frames` run from the Mac
app), ~190 MB of Apple's MobileCLIP-S2 image + text CoreML packages
download to:

```
~/Library/Application Support/Youty/models/
```

The Swift indexer and the Python query side share this directory. No
manual setup. Re-runs are instant after the first download.

## Claude Desktop wiring

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```jsonc
{
  "mcpServers": {
    "youty": {
      "command": "uv",
      "args": [
        "--directory", "~/AI/youty/youty-mcp",
        "run", "youty-mcp"
      ]
    }
  }
}
```

Restart Claude Desktop. Then ask: _"What are best practices on creating
AI influencers, and what tools should I use? Use my Youty vault."_

## Claude Code wiring

```bash
claude mcp add youty -- uv --directory ~/AI/youty/youty-mcp run youty-mcp
```

## Tests

```bash
uv run pytest -q          # 21 passing
uv run python tests/smoke_live.py    # one-shot live Gemini smoke (uses Keychain key)
```

## Index location

Default: `~/Library/Application Support/Youty/index.db` (Apple-canonical).
Override with `YOUTY_INDEX_DB=/abs/path`.

The Mac app writes here when it saves a video (background, non-blocking).
The MCP server reads here and promotes data to `sqlite-vec` and FTS5
virtual tables at startup.

The index is **rebuildable** from the vault's `video.md` files alone —
losing it is recoverable, never catastrophic. Use the Mac app's Settings
sheet → "Re-index entire vault", or run headless:

```bash
"/path/to/youty.app/Contents/MacOS/youty" --reindex "/path/to/vault"
"/path/to/youty.app/Contents/MacOS/youty" --index-frames "/path/to/vault"
```

## Troubleshooting

- **`search` returns 0 results** — the index is empty. Save a video from
  the Mac app (with the Gemini key in Keychain and indexer enabled in
  Settings) or run `--reindex` on an existing vault.
- **`search_frames` is slow** on the first call — the MobileCLIP CoreML
  model compiles to Neural Engine on first load (~1 s). Subsequent
  queries are ~10 ms.
- **Legacy bundles with 4-digit-second JPEG names** (`0717.jpg`) are
  silently skipped by frame indexing. The current contract is 8-digit
  milliseconds (`00718000.jpg`). Re-saving the video regenerates frames
  in the new format.
- **Vault location unknown** error from `get_transcript` — the indexer
  records the vault path; if you've changed it, run `--reindex` once
  against the new path so `index_meta.vault_root` updates.
