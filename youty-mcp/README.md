# youty-mcp

Local MCP server that exposes the Youty vault's vector index to any
MCP-compatible AI (Claude Desktop, Claude Code, Cursor).

## What it does

Six tools, hybrid dense + BM25 retrieval over your captured YouTube /
Instagram / TikTok videos, plus joint text → frame retrieval via
Google's SigLIP-Base-Patch16-224 (Apache-2.0, swapped in during R.0b
on 2026-05-19 for license-compliance reasons). Queries land in ~300 ms
for text, ~32 ms warm for frames on Apple Silicon.

| Tool | Returns |
|---|---|
| `search(query, k=15, platform?, since_iso?)` | hybrid dense + BM25 + RRF over transcript chunks; top-k results with `frame` paths + `video_md_path` |
| `search_frames(query, k=10, platform?)` | SigLIP-Base joint text→image; top-k frame matches with parent video metadata |
| `get_transcript(video_id)` | full `video.md` + parsed frontmatter |
| `get_video(video_id)` | frontmatter + folder listing + frame paths |
| `list_videos(platform?, channel?, limit=100)` | newest-first listing |
| `find_similar(video_id, k=10)` | nearest videos by averaged body-chunk vectors |

## Install

```bash
cd youty-mcp
uv sync                       # creates .venv, installs deps
```

Dependencies: `mcp`, `sqlite-vec`, `httpx`, `numpy`, `transformers`,
`sentence-transformers`, `torch`, `sentencepiece`, `protobuf`. Python ≥ 3.11.
Text queries are embedded with EmbeddingGemma (on-device default) or Gemini,
matching how the index was built; frame queries use SigLIP via `transformers`.
Frame *image* embeddings come from the Mac app's bundled CoreML encoder, so
this server never needs `coremltools` itself.

## Text search: on-device by default — no key

The server embeds each query with the **same model the index was built with**,
read from `index_meta.current_text_model`, so query and document vectors share
one space:

- **On-device (default).** Google's EmbeddingGemma, run locally via
  `sentence-transformers`. No key, no Gemini call. The weights download from
  HuggingFace on the first text `search` (one-time per machine, ~1.2 GB, cached
  in `~/.cache/huggingface/`).
- **Gemini (opt-in).** Only when the index was built with the Gemini provider.
  Then the server needs your key:

  ```bash
  security add-generic-password -a youty -s gemini-api -w 'YOUR_GEMINI_KEY'
  ```

  Pulled from Keychain at first query, sent via the `x-goog-api-key` header —
  never in URLs or logs. For CI / non-Mac: set `YOUTY_GEMINI_API_KEY`.

If a Gemini-built index is queried with no key available, search degrades to
BM25 keyword retrieval rather than failing.

## SigLIP weights (auto-downloaded for frame-text queries)

The **frame side** (image embedding) is handled by the Mac app and CLI
via a CoreML `.mlpackage` of SigLIP-Base bundled inside the app at
`Youty.app/Contents/Resources/SigLIP-Base-224_image.mlmodelc`. No
download required — it ships with the binary.

The **text side** (this server's query embedding) downloads
`google/siglip-base-patch16-224` (~370 MB) from HuggingFace on the
first `search_frames` call. Cached in the standard HuggingFace cache:

```
~/.cache/huggingface/hub/models--google--siglip-base-patch16-224/
```

One-time per machine. Hot-path embed is ~32 ms on Apple Silicon.

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
window → "Re-index entire vault", or run headless:

```bash
"/path/to/youty.app/Contents/MacOS/youty" --reindex "/path/to/vault"
"/path/to/youty.app/Contents/MacOS/youty" --index-frames "/path/to/vault"
```

## Troubleshooting

- **`search` returns 0 results** — the index is empty. Save a video from
  the Mac app (indexer enabled in Settings) or run `--reindex` on an
  existing vault. No key needed — text indexing is on-device by default.
- **`search_frames` is slow** on the first call — the SigLIP text
  encoder downloads ~370 MB of weights from HuggingFace into
  `~/.cache/huggingface/` (one-time per machine). On the Mac-app side
  the bundled SigLIP CoreML image encoder compiles to Neural Engine on
  first use (~1 s). Subsequent queries are ~32 ms.
- **Legacy bundles with 4-digit-second JPEG names** (`0717.jpg`) are
  silently skipped by frame indexing. The current contract is 8-digit
  milliseconds (`00718000.jpg`). Re-saving the video regenerates frames
  in the new format.
- **Vault location unknown** error from `get_transcript` — the indexer
  records the vault path; if you've changed it, run `--reindex` once
  against the new path so `index_meta.vault_root` updates.
