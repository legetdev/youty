#!/usr/bin/env bash
# Build a distributable wheel for the youty-mcp server.
#
# Output: youty-mcp/dist/youty_mcp-<version>-py3-none-any.whl
#         youty-mcp/dist/youty_mcp-<version>.tar.gz
#
# Verifies install + import end-to-end against a clean uv-managed env,
# then runs `twine check` on both artefacts to catch PyPI-grade metadata
# issues (long-description rendering, missing classifiers, etc.) before
# they hit a real index.
#
# Never uploads. Scripts/release.sh coordinates production publication;
# GitHub Actions publishes to PyPI through Trusted Publishing (OIDC).

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
# Confirm the entry script resolves and Python can import the server.
"$TMP_VENV/bin/python" -c "from youty_mcp import server; print('import-ok')"
test -x "$TMP_VENV/bin/youty-mcp"
echo "==> Entry script: $TMP_VENV/bin/youty-mcp"
echo "==> Wheel verified."

# ---- PyPI metadata validation ----
#
# `twine check` reads the long-description, validates the README
# rendering, and confirms every required classifier is present. PyPI
# itself runs the same check before accepting an upload — catching it
# here catches metadata errors before production publication.

echo "==> Running twine check..."
uvx --quiet --from twine twine check "$WHEEL" "$SDIST" || {
    echo "error: twine check failed. Fix the issues above before release." >&2
    exit 1
}

echo
echo "==> All checks passed."
echo "    Wheel:  $WHEEL"
echo "    Sdist:  $SDIST"
echo
echo "    Release all channels through Scripts/release.sh; see docs/releasing.md."
