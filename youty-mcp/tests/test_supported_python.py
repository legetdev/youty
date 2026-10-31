"""Every launch entry must start the server on a Python with coremltools wheels:
uvx ignores Requires-Python, and on another Python search drops to keywords."""

from __future__ import annotations

import json
import sys
import tomllib
from pathlib import Path

import pytest

from youty_mcp import cli, clients, install

REPO = Path(__file__).resolve().parents[2]
EARLIER = {"command": "/opt/homebrew/bin/uvx", "args": ["youty-mcp@latest"]}


def test_the_range_matches_the_package_and_every_shipped_entry():
    project = tomllib.loads((REPO / "youty-mcp/pyproject.toml").read_text())["project"]
    assert project["requires-python"].replace(" ", "") == clients.PYTHON_RANGE
    want = ["--python", clients.PYTHON_RANGE, "youty-mcp@latest"]
    assert clients.LAUNCH_ENTRY["args"] == want
    plugin = json.loads((REPO / "plugins/youty/.mcp.json").read_text())
    assert plugin["mcpServers"]["youty"]["args"] == want
    extension = json.loads((REPO / "youty-mcp/mcpb/manifest.json").read_text())
    assert extension["server"]["mcp_config"]["args"] == ["tool", "run", *want]
    onboarding = (REPO / "Sources/OnboardingView.swift").read_text()
    assert onboarding.count(json.dumps(want, separators=(",", ":"))) == 2  # Cursor and VS Code links


def json_client(tmp_path, entry) -> clients.Client:
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"theme": "dark", "mcpServers": {"other": {"command": "x"}, "youty": entry}}))
    return clients.Client("test", "Test", path, "json")


@pytest.mark.parametrize("entry", [EARLIER, {"type": "stdio", **EARLIER},
                                   {"name": "youty", "transport": "stdio", **EARLIER}])
def test_an_earlier_entry_is_upgraded_without_asking(tmp_path, monkeypatch, entry):
    client = json_client(tmp_path, entry)
    monkeypatch.setattr("builtins.input", lambda *_: pytest.fail("asked before replacing our own entry"))

    assert install._configure_client(client)
    data = json.loads(client.path.read_text())
    assert data["mcpServers"]["youty"] == client.entry
    assert data["theme"] == "dark" and data["mcpServers"]["other"] == {"command": "x"}


@pytest.mark.parametrize("entry", [{"command": "uvx", "args": ["youty-mcp==1.0"]},
                                   {"command": "/usr/bin/python3", "args": ["-m", "youty_mcp"]},
                                   {**EARLIER, "env": {"YOUTY_VAULT": "/v"}}])
def test_a_hand_edited_entry_is_kept_unless_the_user_agrees(tmp_path, monkeypatch, entry):
    client = json_client(tmp_path, entry)
    monkeypatch.setattr("builtins.input", lambda *_: "")

    assert install._configure_client(client)
    assert json.loads(client.path.read_text())["mcpServers"]["youty"] == entry


CODEX = '''model = "o4"  # keep this comment

[mcp_servers.youty]
command = "/opt/homebrew/bin/uvx"
args = ["youty-mcp@latest"]

[mcp_servers.other]
command = "x"

[projects."/a"]
trust_level = "trusted"
'''


def test_an_earlier_codex_entry_is_replaced_and_nothing_else_changes(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text(CODEX)
    client = clients.Client("codex", "Codex", path, "toml")

    assert clients.write_entry(client) == "updated"
    text = path.read_text()
    old_table = '[mcp_servers.youty]\ncommand = "/opt/homebrew/bin/uvx"\nargs = ["youty-mcp@latest"]\n'
    assert text == CODEX.replace(old_table, clients.snippet(client))
    assert tomllib.loads(text)["mcp_servers"]["youty"]["args"] == client.entry["args"]
    assert clients.write_entry(client) == "unchanged"


def test_a_codex_entry_with_extra_settings_is_never_rewritten(tmp_path):
    path = tmp_path / "config.toml"
    original = CODEX.replace('args = ["youty-mcp@latest"]\n', 'args = ["youty-mcp@latest"]\nenv = { A = "1" }\n')
    path.write_text(original)
    client = clients.Client("codex", "Codex", path, "toml")

    with pytest.raises(clients.ManualEditRequired):
        clients.write_entry(client)
    assert path.read_text() == original


@pytest.fixture()
def relaunch(monkeypatch):
    calls = []
    monkeypatch.setattr(cli.os, "execve", lambda path, argv, env: calls.append((path, argv, env)))
    monkeypatch.setattr(cli.sys, "platform", "darwin")
    monkeypatch.setattr(cli.sys, "argv", ["youty-mcp"])
    monkeypatch.setattr(cli, "_python_version", lambda: (3, 14))
    monkeypatch.setenv("UV", "/opt/homebrew/bin/uv")
    monkeypatch.delenv("YOUTY_RELAUNCHED", raising=False)
    monkeypatch.setattr("youty_mcp.__version__", "2.0.6", raising=False)
    return calls


def test_an_unsupported_python_restarts_the_server_on_a_supported_one(relaunch):
    cli._relaunch_on_supported_python()
    [(path, argv, env)] = relaunch
    assert path == "/opt/homebrew/bin/uv"
    assert argv == ["/opt/homebrew/bin/uv", "tool", "run", "--python", clients.PYTHON_RANGE, "youty-mcp==2.0.6"]
    assert env["YOUTY_RELAUNCHED"] == "1"


def test_falls_back_to_uvx_on_the_path(relaunch, monkeypatch):
    monkeypatch.delenv("UV")
    monkeypatch.setattr(cli, "_which", lambda name: "/usr/local/bin/uvx")
    cli._relaunch_on_supported_python()
    assert relaunch[0][1][:3] == ["/usr/local/bin/uvx", "--python", clients.PYTHON_RANGE]


@pytest.mark.parametrize("case", ["supported", "already relaunched", "no uv", "linux"])
def test_otherwise_the_server_starts_where_it_is(relaunch, monkeypatch, case):
    if case == "supported":
        monkeypatch.setattr(cli, "_python_version", lambda: (3, 13))
    elif case == "already relaunched":
        monkeypatch.setenv("YOUTY_RELAUNCHED", "1")
    elif case == "no uv":
        monkeypatch.delenv("UV")
        monkeypatch.setattr(cli, "_which", lambda name: None)
    else:
        monkeypatch.setattr(cli.sys, "platform", "linux")
    cli._relaunch_on_supported_python()
    assert relaunch == []


def test_a_failed_restart_keeps_the_server_running(relaunch, monkeypatch):
    def fail(*args):
        raise OSError("no such file")
    monkeypatch.setattr(cli.os, "execve", fail)
    cli._relaunch_on_supported_python()  # returns instead of raising


def test_this_interpreter_is_supported():
    low, high = clients.SUPPORTED_PYTHON
    assert low <= sys.version_info[:2] < high
