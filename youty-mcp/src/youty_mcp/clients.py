"""Registry of MCP clients that `youty-mcp install <client>` can auto-configure.

Design goal: wiring Youty into any MCP client should be as easy as it is for
Claude Code. Supporting a new client = ONE entry in CLIENTS — the same stdio
launch entry is reused everywhere; only the config-file location and on-disk
shape differ.

The launch entry is `uvx youty-mcp@latest`, NOT a fixed interpreter path: every
client then fetches + runs the newest published server on each launch, so users
never manually upgrade the MCP. (This is why we don't write `sys.executable` the
way a pip-pinned tool would — that would freeze the client to one version, and
break entirely when install itself runs from uvx's ephemeral environment.)

Two on-disk shapes are handled:
  - "json" : a JSON file with a top-level `mcpServers` map (Claude Code, Claude
             Desktop, Cursor, Windsurf, Continue, Cline, Gemini CLI). Merged in
             place so the client's other settings are preserved.
  - "toml" : a TOML file with `[mcp_servers.<name>]` tables (OpenAI Codex CLI).
             The stdlib reads TOML but can't write it, so we append the table
             when absent and refuse to clobber a differing hand-edited entry.
"""

from __future__ import annotations

import json
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

# Key under which Youty registers in every client's config.
SERVER_KEY = "youty"

# The canonical stdio launch entry — identical for every MCP client. `uvx
# youty-mcp@latest` resolves + runs the newest server on each client launch.
LAUNCH_ENTRY = {
    "command": "uvx",
    "args": ["youty-mcp@latest"],
}
# Claude Code tags the transport type in its config; mirror what `claude mcp
# add` writes so re-runs stay idempotent against an existing CLI-made entry.
_CLAUDE_ENTRY = {"type": "stdio", **LAUNCH_ENTRY}


class ManualEditRequired(Exception):
    """Raised when a config can't be safely auto-edited; carries a paste snippet."""

    def __init__(self, message: str, snippet: str):
        super().__init__(message)
        self.snippet = snippet


@dataclass(frozen=True)
class Client:
    key: str          # identifier used as `youty-mcp install <key>`
    label: str        # human-readable name
    path: Path        # config file location
    fmt: str          # "json" | "toml"
    note: str = ""    # shown after a successful install
    entry: dict = field(default_factory=lambda: dict(LAUNCH_ENTRY))


def _h(*parts) -> Path:
    return Path.home().joinpath(*parts)


# Order here is the order shown by `--list` and wired by a bare `install`.
CLIENTS: dict[str, Client] = {
    "claude": Client(
        "claude", "Claude Code", _h(".claude.json"), "json",
        "Restart Claude Code to load Youty.", dict(_CLAUDE_ENTRY),
    ),
    "claude-desktop": Client(
        "claude-desktop", "Claude Desktop",
        _h("Library", "Application Support", "Claude", "claude_desktop_config.json"),
        "json", "Restart Claude Desktop to load Youty.",
    ),
    "cursor": Client(
        "cursor", "Cursor", _h(".cursor", "mcp.json"), "json",
        "Restart Cursor to load Youty.",
    ),
    "codex": Client(
        "codex", "OpenAI Codex CLI", _h(".codex", "config.toml"), "toml",
        "Restart the Codex CLI to load Youty.",
    ),
    "gemini": Client(
        "gemini", "Gemini CLI", _h(".gemini", "settings.json"), "json",
        "Restart the Gemini CLI, then run /mcp to confirm Youty is listed.",
    ),
    "windsurf": Client(
        "windsurf", "Windsurf", _h(".codeium", "windsurf", "mcp_config.json"), "json",
        "Restart Windsurf to load Youty.",
    ),
    "continue": Client(
        "continue", "Continue", _h(".continue", "config.json"), "json",
        "Reload your IDE to load Youty.",
    ),
    "cline": Client(
        "cline", "Cline (VS Code)",
        _h("Library", "Application Support", "Code", "User", "globalStorage",
           "saoudrizwan.claude-dev", "settings", "cline_mcp_settings.json"),
        "json", "Reload the VS Code window to load Youty.",
    ),
}

# Alternate names a user might type for a client.
ALIASES = {"claudedesktop": "claude-desktop", "claude_desktop": "claude-desktop"}


def get(key: str) -> Client | None:
    k = key.lower()
    return CLIENTS.get(ALIASES.get(k, k))


def is_present(client: Client) -> bool:
    """Heuristic: is this client installed on this Mac? True when its config file
    exists, or its *dedicated* config directory exists (created on the client's
    first run). $HOME itself is never a signal — it always exists — so a config
    that lives directly in home (e.g. ~/.claude.json) must show the actual file
    before we treat the client as present, otherwise every client false-positives."""
    if client.path.exists():
        return True
    parent = client.path.parent
    return parent != Path.home() and parent.exists()


def snippet(client: Client) -> str:
    """The exact config block a user would paste for this client (manual path)."""
    if client.fmt == "toml":
        args = ", ".join(json.dumps(a) for a in client.entry["args"])
        return (
            f"[mcp_servers.{SERVER_KEY}]\n"
            f"command = {json.dumps(client.entry['command'])}\n"
            f"args = [{args}]\n"
        )
    return json.dumps({"mcpServers": {SERVER_KEY: client.entry}}, indent=2)


# --- read helpers --------------------------------------------------------
def current_entry(client: Client):
    """Return Youty's existing entry in this client's config, or None."""
    if not client.path.exists():
        return None
    if client.fmt == "toml":
        with open(client.path, "rb") as f:
            data = tomllib.load(f)
        return (data.get("mcp_servers") or {}).get(SERVER_KEY)
    with open(client.path, encoding="utf-8") as f:
        data = json.load(f)
    return (data.get("mcpServers") or {}).get(SERVER_KEY)


# --- write / remove ------------------------------------------------------
def write_entry(client: Client) -> str:
    """Add/refresh Youty in this client's config. Returns a status word:
    "added" | "updated" | "unchanged". Raises ManualEditRequired when a TOML
    file already has a differing entry (we won't risk clobbering it)."""
    if client.fmt == "toml":
        return _write_toml(client)
    return _write_json(client)


def _write_json(client: Client) -> str:
    client.path.parent.mkdir(parents=True, exist_ok=True)
    data: dict = {}
    if client.path.exists():
        with open(client.path, encoding="utf-8") as f:
            text = f.read().strip()
        data = json.loads(text) if text else {}
    servers = data.setdefault("mcpServers", {})
    existing = servers.get(SERVER_KEY)
    if existing == client.entry:
        return "unchanged"
    servers[SERVER_KEY] = client.entry
    with open(client.path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    return "updated" if existing is not None else "added"


def _write_toml(client: Client) -> str:
    existing = current_entry(client)
    want_args = client.entry["args"]
    if existing is not None:
        if existing.get("command") == client.entry["command"] and existing.get("args") == want_args:
            return "unchanged"
        raise ManualEditRequired(
            f"{client.path} already has a different [mcp_servers.{SERVER_KEY}] entry; "
            "edit it by hand to avoid clobbering your TOML.",
            snippet(client),
        )
    client.path.parent.mkdir(parents=True, exist_ok=True)
    block = snippet(client)
    if client.path.exists():
        prev = client.path.read_text(encoding="utf-8")
        sep = "" if prev.endswith("\n\n") else ("\n" if prev.endswith("\n") else "\n\n")
        client.path.write_text(prev + sep + block, encoding="utf-8")
    else:
        client.path.write_text(block, encoding="utf-8")
    return "added"


def remove_entry(client: Client) -> bool:
    """Remove Youty from this client's config. Returns True if removed."""
    if not client.path.exists():
        return False
    if client.fmt == "toml":
        # stdlib can't rewrite TOML; tell the caller to do it by hand.
        if current_entry(client) is None:
            return False
        raise ManualEditRequired(
            f"Remove the [mcp_servers.{SERVER_KEY}] table from {client.path} by hand "
            "(stdlib can't safely rewrite TOML).",
            "",
        )
    with open(client.path, encoding="utf-8") as f:
        data = json.load(f)
    servers = data.get("mcpServers") or {}
    if SERVER_KEY not in servers:
        return False
    del servers[SERVER_KEY]
    with open(client.path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    return True


def list_text() -> str:
    """A formatted list of supported clients for `--list`."""
    width = max(len(c.key) for c in CLIENTS.values()) + 2
    lines = ["Supported clients (youty-mcp install <client>):", ""]
    for c in CLIENTS.values():
        lines.append(f"  {c.key:<{width}} {c.label}  →  {c.path}")
    return "\n".join(lines)
