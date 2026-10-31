"""Client config changes must preserve unrelated settings and survive failures."""

import json
import stat
import tomllib

import pytest

from youty_mcp import clients


@pytest.mark.parametrize("fmt", ["json", "toml"])
def test_install_preserves_settings_and_permissions(tmp_path, fmt):
    """Both config formats keep unrelated content and remain idempotent."""
    path = tmp_path / f"config.{fmt}"
    path.write_text('{"theme": "dark"}\n' if fmt == "json" else 'theme = "dark"\n')
    path.chmod(0o600)
    client = clients.Client("test", "Test", path, fmt)
    assert clients.write_entry(client) == "added"
    assert clients.write_entry(client) == "unchanged"
    data = json.loads(path.read_text()) if fmt == "json" else tomllib.loads(path.read_text())
    assert data["theme"] == "dark"
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


@pytest.mark.parametrize("operation", ["install", "uninstall"])
def test_failed_config_replace_keeps_original(tmp_path, monkeypatch, operation):
    """An interrupted replacement never truncates the user's existing config."""
    path = tmp_path / "config.json"
    original = '{"theme":"dark","mcpServers":{"youty":{"command":"custom"}}}\n'
    path.write_text(original)
    client = clients.Client("test", "Test", path, "json")

    def fail_replace(*args):
        """Simulate a filesystem failure immediately before publication."""
        raise OSError("replacement failed")

    monkeypatch.setattr(clients.os, "replace", fail_replace)
    with pytest.raises(OSError, match="replacement failed"):
        (clients.write_entry if operation == "install" else clients.remove_entry)(client)
    assert path.read_text() == original
    assert list(tmp_path.iterdir()) == [path]


def test_symlink_config_keeps_link_and_updates_target(tmp_path):
    """Managed dotfile symlinks must keep pointing at their original target."""
    target = tmp_path / "managed.json"
    target.write_text('{"theme":"dark"}')
    path = tmp_path / "config.json"
    path.symlink_to(target)
    client = clients.Client("test", "Test", path, "json")
    clients.write_entry(client)
    assert path.is_symlink()
    assert json.loads(target.read_text())["mcpServers"]["youty"] == client.entry


def test_installer_skips_clients_that_already_have_youty(tmp_path, monkeypatch):
    """The plugin or desktop extension already provides Youty; no duplicate entry."""
    monkeypatch.setenv("HOME", str(tmp_path))
    claude = clients.CLIENTS["claude"]
    desktop = clients.CLIENTS["claude-desktop"]
    assert clients.plugin_provides(claude) is None
    plugins = tmp_path / ".claude/plugins"
    plugins.mkdir(parents=True)
    (plugins / "installed_plugins.json").write_text('{"version": 2, "plugins": {"youty@youty": []}}')
    assert "plugin" in clients.plugin_provides(claude)
    extensions = tmp_path / "Library/Application Support/Claude/Claude Extensions"
    (extensions / "local.mcpb.bent-eisheuer.youty").mkdir(parents=True)
    assert "extension" in clients.plugin_provides(desktop)


@pytest.mark.parametrize("args", [["install", "--help"], ["install", "-h"], ["uninstall", "--help"],
                                  ["install", "cursor", "--help"]])
def test_help_never_changes_a_config(tmp_path, monkeypatch, capsys, args):
    from youty_mcp import install

    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(clients, "write_entry", lambda *a, **k: pytest.fail("wrote a config"))
    monkeypatch.setattr(clients, "remove_entry", lambda *a, **k: pytest.fail("removed a config"))
    install.dispatch(args)
    assert "Usage:" in capsys.readouterr().out


@pytest.mark.parametrize("args", [["install", "--dry-run"], ["uninstall", "--all"]])
def test_unknown_options_are_refused(tmp_path, monkeypatch, capsys, args):
    from youty_mcp import install

    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(clients, "write_entry", lambda *a, **k: pytest.fail("wrote a config"))
    monkeypatch.setattr(clients, "remove_entry", lambda *a, **k: pytest.fail("removed a config"))
    with pytest.raises(SystemExit) as exit_:
        install.dispatch(args)
    assert exit_.value.code == 2 and "Unknown option" in capsys.readouterr().err
