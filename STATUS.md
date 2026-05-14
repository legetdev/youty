# STATUS — verification snapshot

Tracks what's been directly verified vs what's still untested, so nothing
ships in Phase R while still in this column. Updated as work progresses.

Last reviewed: 2026-05-14, after Phase Q.3 → Q.6.

## Verified working end-to-end ✓

- **CLI** — all four subcommands (`save`, `list`, `search`, `transcript`),
  Release + Debug builds, JSON + text output, `--quiet`, `--platform`,
  `--limit`.
- **CLI vault auto-discovery** — resolves the Mac app's sandboxed
  `vaultBookmark` plist from `~/Library/Containers/dev.leget.youty/Data/Library/Preferences/`.
- **`youty login instagram`** — visible window, real IG login, cookies
  persist, subsequent IG saves work.
- **Mac app cold launch** — Release binary opens, 1 visible window, no
  crash.
- **`--hardness-probe`** — 18 weird-vault states (empty, vault-is-a-file,
  7 corrupt manifests, 7 corrupt video.md, read-only, ghost, mixed)
  all return cleanly, no Swift trap.
- **`--phase-l-probe`** — IngestionFunnel queue, URL classifier,
  SpotlightIndexer reconcile, VaultLocalSearch.
- **MCP server** — boots under the new pinned dep bounds, awaits stdio.
- **`Scripts/install-cli.sh`** — build Release → install → run → save.
- **YouTube + TikTok extraction** — 3 + 2 known-good URLs in the smoke
  suite, runs every commit.
- **Instagram extraction (CLI)** — verified once with a real Reel URL
  after `youty login instagram`.
- **Smoke suite total** — 19 passed, 1 skipped (documented IG-headless
  skip), 0 failed.

## Untested but low risk — code unchanged since last working ⚠️

- **Mac app paste-URL → Save-to-Vault** with the new Q.3 error strings.
  Build + launch verified; full save flow not exercised since the copy
  sweep. Mitigation: 30-second manual test in the app.
- **Frame indexing during save** (the `--no-index`-off path). Code
  unchanged from Phase B/C hardening; never re-run end-to-end in
  sessions L/M/Q.3/Q.4/Q.5/Q.6. Mitigation: needs a real Gemini key —
  one indexed save will confirm.
- **MCP tool calls returning correct results.** Server boots; actual
  search/get_transcript responses against a real vault not re-verified
  this quarter.

## Plumbing verified, full user flow not driven 🟡

- **Share Sheet click in Safari** — URL-scheme relay proven, but the
  literal Safari → Share → Save click-through wasn't tested on the
  latest build. Mitigation: 1-minute manual test.
- **Services menu click in TextEdit** — same. Requires the System
  Settings tick-box step (already done in this user profile).
- **Spotlight result click → Finder reveal** — indexing verified via
  log lines; click-through not driven.
- **Menu bar popover end-to-end** — paste field works; "Sent ✓" flash
  + popover auto-close not user-tested on the latest build.
- **Settings UI** with Q.3's new copy — strings changed, layout
  untouched. Open Settings once to confirm no weird text wrapping.

## Lowest confidence — possible subtle regressions ⚪

- **Release-build edge cases.** LTO + dead-strip + whole-module
  optimisation in Phase Q.5 *could* over-eliminate something the
  optimiser can't prove is reachable. Smoke + manual CLI round-trip
  pass, but this is the most likely place for a "works in Debug but
  breaks in Release" surprise.

## Out of scope here, gated on Phase R

- Hardware-bound crash cases: external drive disconnect, disk full,
  network drop mid-fetch. Part of the pre-launch manual checklist.
- App Store / DMG / Homebrew / website / public repo flip. All Phase R.

## What to verify before any public step

1. One full UI save in the Mac app (any platform) — confirms Q.3 copy
   + window flow look right.
2. One indexed save with a real Gemini key — confirms indexer path.
3. One `mcp__youty__search` call against the vault — confirms server.
4. Open Settings, scroll through every section — visual sanity check.
5. Share Sheet + Services + Spotlight click-throughs — system surface
   sanity.

About 15 minutes of hands-on. After that, the gap column above goes
empty and Phase R is unblocked.
