#!/usr/bin/env python3
"""Fail the release gate if Sparkle's narrow sandbox integration regresses."""
import plistlib
import subprocess
import sys
from pathlib import Path


def verify(app=None):
    """Check generated source settings, or the actual signed app when supplied."""
    root = Path(__file__).resolve().parents[1]
    info_path = app / "Contents/Info.plist" if app else root / "Sources/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    if app:
        entitlements = plistlib.loads(subprocess.check_output(
            ["codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL,
        ))
        bundle_id = info["CFBundleIdentifier"]
        helper = app / "Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Installer.xpc"
        assert helper.is_dir(), "Sparkle installer service is missing"
        subprocess.run(["codesign", "--verify", "--strict", str(helper)], check=True)
    else:
        entitlements = plistlib.loads((root / "Sources/youty.entitlements").read_bytes())
        bundle_id = "dev.leget.youty"
    assert info.get("SUEnableInstallerLauncherService") is True, "Sandboxed updater installer must be enabled"
    assert not info.get("SUEnableDownloaderService"), "Existing network entitlement makes the downloader service unnecessary"
    assert info["SUFeedURL"].startswith("https://"), "Update feed must use HTTPS"
    assert info.get("SUPublicEDKey"), "Signed updates must remain required"
    assert entitlements.get("com.apple.security.app-sandbox") is True, "App Sandbox must stay enabled"
    assert entitlements.get("com.apple.security.network.client") is True
    names = entitlements.get("com.apple.security.temporary-exception.mach-lookup.global-name", [])
    assert sorted(names) == sorted([bundle_id + "-spks", bundle_id + "-spki"]), "Allow only this app's two updater services"
    assert not entitlements.get("com.apple.security.get-task-allow"), "Do not ship debugger access"
    print("Updater gate passed: sandbox retained, installer enabled, two scoped service names")


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None)
