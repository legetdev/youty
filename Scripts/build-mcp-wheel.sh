#!/usr/bin/env bash
# Build a distributable wheel for the youty-mcp server.
#
# Output: youty-mcp/dist/youty_mcp-<version>-py3-none-any.whl
#
# Verifies install + import end-to-end against a clean uv-managed env,
# but never uploads to PyPI (Phase R does that). Run this any time the
# MCP server's source or pyproject changes.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/youty-mcp"

echo "==> Building wheel..."
rm -rf dist
uv build > /tmp/youty-mcp-build.log 2>&1 || {
    echo "error: build failed. Tail of /tmp/youty-mcp-build.log:" >&2
    tail -10 /tmp/youty-mcp-build.log >&2
    exit 1
}

WHEEL=$(ls -1 dist/*.whl | head -1)
SDIST=$(ls -1 dist/*.tar.gz | head -1)
WHEEL_SIZE=$(du -k "$WHEEL" | awk '{print $1}')
echo "==> Built:"
echo "    $WHEEL (${WHEEL_SIZE} KB)"
echo "    $SDIST"

echo "==> Verifying install + entry point in a temp uv env..."
TMP_VENV=$(mktemp -d)
trap 'rm -rf "$TMP_VENV"' EXIT
uv venv --quiet "$TMP_VENV"
uv pip install --python "$TMP_VENV/bin/python" --quiet "$WHEEL"
# `youty-mcp` is a stdio server — no --version or --help, so just confirm the
# entry script resolves + Python can import the package.
"$TMP_VENV/bin/python" -c "from youty_mcp import server; print('import-ok')"
test -x "$TMP_VENV/bin/youty-mcp"
echo "==> Entry script: $TMP_VENV/bin/youty-mcp"
echo "==> Wheel verified."
