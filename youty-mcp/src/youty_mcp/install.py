"""`youty-mcp install` — wire Youty into your MCP clients automatically.

The Youty Mac app is sandboxed, so it can't write other apps' config files or
run their CLIs. This (non-sandboxed) Python package can — so the one-command
auto-wiring lives here. A bare `install` detects every MCP client on the Mac and
merges a `youty` entry into each: no hand-edited JSON, idempotent, and reversible
with `youty-mcp uninstall`. Existing settings in each config are preserved.
"""

from __future__ import annotations

import shutil
import sys

from . import clients


def dispatch(args: list[str]) -> None:
    """Route a `youty-mcp <subcommand>` invocation. Called by cli.main."""
    cmd, rest = args[0], args[1:]
    if cmd == "install":
        _install(rest)
    elif cmd == "uninstall":
        _uninstall(rest)
    elif cmd in ("list", "--list"):
        print(clients.list_text())
    elif cmd in ("help", "--help", "-h"):
        _help()
    elif cmd in ("version", "--version", "-v"):
        print(f"youty-mcp {_pkg_version()}")
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        _help()
        sys.exit(1)


def _pkg_version() -> str:
    from importlib.metadata import PackageNotFoundError, version
    try:
        return version("youty-mcp")
    except PackageNotFoundError:
        return "unknown"


def _indent(text: str, pad: str = "      ") -> str:
    return "\n".join(pad + line for line in text.splitlines())


# --- install -------------------------------------------------------------
def _install(rest: list[str]) -> None:
    if "--list" in rest:
        print(clients.list_text())
        return
    if sys.platform != "darwin":
        print("Youty is macOS-only. Detected: " + sys.platform, file=sys.stderr)
        sys.exit(1)

    key = next((a for a in rest if not a.startswith("-")), None)
    if key and "--all" not in rest:
        client = clients.get(key)
        if client is None:
            print(f"Unknown client: {key}\n", file=sys.stderr)
            print(clients.list_text(), file=sys.stderr)
            sys.exit(1)
        targets = [client]
    else:
        # Default (and --all): every supported client detected on this Mac.
        targets = [c for c in clients.CLIENTS.values() if clients.is_present(c)]
        if not targets:
            print("No supported MCP clients detected on this Mac.")
            print("Install one (Claude Code, Cursor, Codex, Gemini CLI, …) and re-run,")
            print("or target one explicitly: youty-mcp install <client>  (see --list).")
            return

    print("youty-mcp install")
    print("=================\n")
    _check_uvx()
    print()

    configured = [c for c in targets if _configure_client(c)]
    print()

    if configured:
        print("Wired: " + ", ".join(c.label for c in configured))
        for c in configured:
            print(f"  • {c.note}")
        print()
        print('Then ask your AI to search your vault — e.g. "search my saved videos for X".')


def _check_uvx() -> None:
    """Clients launch Youty via `uvx`; warn (don't fail) if it isn't installed."""
    if shutil.which("uvx"):
        print("  ✓ uvx found — clients will run youty-mcp@latest on demand.")
    else:
        print("  ⚠ uvx not found on PATH. Clients launch Youty with uvx, so install uv:")
        print("      brew install uv")
        print("    Configs are still written below; install uv before using them.")


def _configure_client(client) -> bool:
    """Merge Youty into one client's config. Prompts before replacing a *different*
    existing youty entry (EOF/non-interactive → keep it, never clobber). Returns
    True if the client is left configured."""
    try:
        existing = clients.current_entry(client)
    except Exception as e:
        print(f"  ✗ Could not read {client.path}: {e}")
        print("    Fix the file, or add this manually:")
        print(_indent(clients.snippet(client)))
        return False

    if existing is not None and existing != client.entry:
        print(f"  Found a different youty entry in {client.path}.")
        try:
            ans = input("  Replace it with the canonical uvx entry? [y/N] ").strip().lower()
        except EOFError:
            ans = ""  # non-interactive: never clobber a hand-edited entry
        if ans not in ("y", "yes"):
            print("  Left the existing entry unchanged.")
            return True

    try:
        action = clients.write_entry(client)
    except clients.ManualEditRequired as e:
        print(f"  ⚠ {e}")
        print("    Add this block yourself:")
        print(_indent(e.snippet))
        return False
    except Exception as e:
        print(f"  ✗ Could not write {client.path}: {e}")
        print("    Add this manually instead:")
        print(_indent(clients.snippet(client)))
        return False

    msg = {
        "added": f"✓ Added Youty to {client.label}  ({client.path})",
        "updated": f"✓ Updated Youty in {client.label}  ({client.path})",
        "unchanged": f"✓ Youty already configured in {client.label}",
    }[action]
    print(f"  {msg}")
    return True


# --- uninstall -----------------------------------------------------------
def _uninstall(rest: list[str]) -> None:
    key = next((a for a in rest if not a.startswith("-")), None)
    if key:
        client = clients.get(key)
        if client is None:
            print(f"Unknown client: {key}\n", file=sys.stderr)
            print(clients.list_text(), file=sys.stderr)
            sys.exit(1)
        targets = [client]
    else:
        targets = [c for c in clients.CLIENTS.values() if clients.is_present(c)]

    removed = False
    for c in targets:
        try:
            if clients.remove_entry(c):
                print(f"  ✓ Removed Youty from {c.label} ({c.path})")
                removed = True
        except clients.ManualEditRequired as e:
            print(f"  ⚠ {e}")
    if not removed:
        print("Youty was not configured in any detected client.")


def _help() -> None:
    print(__doc__.strip())
    print()
    print("Usage:")
    print("  youty-mcp install             wire every MCP client detected on this Mac")
    print("  youty-mcp install <client>    wire just one (see --list for names)")
    print("  youty-mcp install --list      list supported clients + config paths")
    print("  youty-mcp uninstall [client]  remove Youty from one client, or all detected")
    print("  youty-mcp version             print version")
    print()
    print("With no arguments, `youty-mcp` runs the MCP server over stdio — that's")
    print("what MCP clients launch. The subcommands above are for humans.")
