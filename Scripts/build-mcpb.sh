#!/usr/bin/env bash
#
# Build the Claude Desktop extension (Youty.mcpb) from youty-mcp/mcpb/.
#
# The bundle is a deterministic zip (fixed timestamps, sorted entries) of the
# manifest, the uv project file, and the icon. Claude Desktop installs it with
# its own bundled uv, so users need no Terminal and no separately installed uv.
# The Mac app ships the bundle (Sources/Youty.mcpb) for its one-click
# "Add to Claude Desktop" button, and releases attach it for the website.
#
#   Scripts/build-mcpb.sh            # rebuild Sources/Youty.mcpb
#   Scripts/build-mcpb.sh --check    # fail if Sources/Youty.mcpb is stale
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/youty-mcp/mcpb"
OUT="$ROOT/Sources/Youty.mcpb"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$SRC" "$TMP/Youty.mcpb" <<'PY'
import json, sys, zipfile
from pathlib import Path
src, out = Path(sys.argv[1]), sys.argv[2]
json.loads((src / "manifest.json").read_text())  # fail early on invalid JSON
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for name in ("icon.png", "manifest.json", "pyproject.toml"):
        info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        info.external_attr = 0o644 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, (src / name).read_bytes())
PY

if [ "${1:-}" = "--check" ]; then
  cmp -s "$TMP/Youty.mcpb" "$OUT" || { echo "error: Sources/Youty.mcpb is stale; run Scripts/build-mcpb.sh" >&2; exit 1; }
  echo "Youty.mcpb is current."
else
  cp "$TMP/Youty.mcpb" "$OUT"
  echo "Built $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
fi
