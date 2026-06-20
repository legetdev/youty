# youty-mcp

Local MCP server that exposes the Youty vault's vector index to any
MCP-compatible AI (Claude Desktop, Claude Code, Cursor).

## What it does

Seven tools, hybrid dense + BM25 retrieval over your captured YouTube /
Instagram / TikTok videos, plus joint text → frame retrieval via
Google's SigLIP-Base-Patch16-224 (Apache-2.0). Queries land in ~300 ms
for text, ~32 ms warm for frames on Apple Silicon.

| Tool | Returns |
|---|---|
| `search(query, k=15, platform?, since_iso?)` | hybrid dense + BM25 + RRF over transcript chunks; top-k results with `frame` paths + `video_md_path` |
| `search_frames(query, k=10, platform?)` | SigLIP-Base joint text→image; top-k frame matches with parent video metadata |
| `get_transcript(video_id)` | full `video.md` + parsed frontmatter — the whole video into context |
| `get_video(video_id)` | frontmatter + folder listing + frame paths |
| `view_frames(video_id, frame_ms?, max_frames=6)` | the frame JPEGs themselves, as MCP image content — viewable in **any** client |
| `list_videos(platform?, channel?, limit=100)` | newest-first listing |
| `find_similar(video_id, k=10)` | nearest videos by averaged body-chunk vectors |

**The loop:** `search` finds the relevant moments → `get_transcript` pulls the
words into context → `view_frames` loads the matching frames into the model's
vision. `search` / `search_frames` also return raw frame *paths*, but only
Claude Code can open a path itself — `view_frames` returns the images inline, so
the visual half of the loop works in Claude Desktop, Cursor, and Claude Code
alike.

**On-screen text.** `search` covers both what a video *said* and what it
*showed*: each result's `chunk.type` is `body`/`description`/`header` (spoken +
metadata) or **`frame_text`** — text recognized on-screen via on-device OCR
(slides, code, terminal output, labels). A `frame_text` hit means the answer was
visible in the video; pair it with `view_frames` to see that moment.

## Install

```bash
cd youty-mcp
uv sync                       # creates .venv, installs deps
```

Dependencies: `mcp`, `sqlite-vec`, `httpx`, `numpy`, `transformers`,
`sentencepiece`, `protobuf`, and `coremltools` (macOS only). Python ≥ 3.11.
No PyTorch. `transformers` / `sentencepiece` are kept for **tokenization only**;
all inference runs through Core ML.

## Text + frame search: 100% on-device — no key, zero config

The server embeds each query on-device with **the same Core ML models the index
was built with** — Google's EmbeddingGemma (text) and the SigLIP-Base text tower
(frames) — so query and document vectors share one space. Inference is CPU-only
via `coremltools` to match the int8-quantized indexer. No key, no provider
option, no cloud call of any kind.

The models are **not** a ~1.6 GB HuggingFace download. They come from Youty's own
release asset (`youty-models-<ver>.tar.gz`, a few hundred MB of Core ML),
fetched once and verified by SHA-256, then cached under:

```
~/.cache/youty/coreml-models/<version>/
```

One-time per machine; every query after that is fully offline. Hot-path embed is
~300 ms for text and ~32 ms for frames on Apple Silicon. (Set
`YOUTY_COREML_MODELS_DIR` to point at a local `.mlpackage` tree in dev/CI.)

## Wiring it into your AI client

**One command wires every MCP client on this Mac:**

```bash
uvx youty-mcp@latest install
```

It detects Claude Code, Claude Desktop, Cursor, Codex, Gemini CLI, Windsurf,
Continue, and Cline, then merges a `youty` entry into each client's config —
preserving your other settings, idempotent (safe to re-run), and reversible with
`uvx youty-mcp@latest uninstall`. Useful variants:

```bash
uvx youty-mcp@latest install --list      # every supported client + its config path
uvx youty-mcp@latest install cursor      # wire just one client
uvx youty-mcp@latest uninstall           # remove Youty from all detected clients
```

> Why a command and not a button in the Youty app? The Mac app is sandboxed, so
> it can't edit other apps' config files or run their CLIs. This installer ships
> in the (non-sandboxed) `youty-mcp` package, which can. Bare `uvx youty-mcp@latest`
> still runs the MCP server itself — that's what the clients launch.

Prefer to wire a client by hand? The exact per-client config follows.

## Claude Desktop wiring

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```jsonc
{
  "mcpServers": {
    "youty": {
      "command": "uvx",
      "args": ["youty-mcp@latest"]
    }
  }
}
```

The `@latest` pin means `uvx` fetches the newest published `youty-mcp` on each
launch — so a normal restart always loads the current server with no manual
`uv tool upgrade`. (The Mac app auto-updates via Sparkle and the CLI via
Homebrew, so the whole stack stays in step on its own.)

Restart Claude Desktop. Then ask: _"What are best practices on creating
AI influencers, and what tools should I use? Use my Youty vault."_

## Claude Code wiring

```bash
claude mcp add youty -- uvx youty-mcp@latest
```

## Tests

```bash
uv run pytest -q
uv run python tests/smoke_live.py    # one-shot live on-device search smoke
```

## Index location

Default: the Mac app's sandboxed index at
`~/Library/Containers/dev.leget.youty/Data/Library/Application Support/Youty/index.db`,
falling back to `~/Library/Application Support/Youty/index.db` if that isn't
present. Override either with `YOUTY_INDEX_DB=/abs/path`.

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
- **First `search` / `search_frames` is slow** — the Core ML models asset
  downloads once (`youty-models-<ver>.tar.gz`, a few hundred MB, SHA-verified)
  into `~/.cache/youty/coreml-models/` and the encoders load lazily. Subsequent
  queries are ~300 ms (text) / ~32 ms (frames).
- **Legacy bundles with 4-digit-second JPEG names** (`0717.jpg`) are
  silently skipped by frame indexing. The current contract is 8-digit
  milliseconds (`00718000.jpg`). Re-saving the video regenerates frames
  in the new format.
- **Vault location unknown** error from `get_transcript` — the indexer
  records the vault path; if you've changed it, run `--reindex` once
  against the new path so `index_meta.vault_root` updates.
