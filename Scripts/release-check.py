#!/usr/bin/env python3
"""Validate coordinated releases using the standard library and existing vendor CLIs."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
REPO = 'legetdev/youty'
SITE = 'https://youtyapp.vercel.app'


def require(condition, message):
    """Reject missing evidence instead of treating it as a successful check."""
    if not condition:
        raise ValueError(message)


def run(*args):
    """Run a vendor CLI without a shell; every failure propagates."""
    return subprocess.check_output(args, text=True).strip()


def fetch(url):
    """Retrieve public evidence with HTTP failures and bounded network waits."""
    return subprocess.check_output(['curl', '--fail', '--silent', '--show-error',
                                    '--location', '--max-time', '60', url])


def sha256(path):
    """Hash large artifacts without loading them into memory."""
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def item(xml):
    """Read the newest feed item or a standalone namespaced item fragment."""
    if xml.lstrip().startswith('<item>'):
        result = ET.fromstring(f'<root xmlns:sparkle="{SPARKLE[1:-1]}">{xml}</root>').find('item')
    else:
        result = ET.fromstring(xml).find('channel/item')
    require(result is not None, 'Appcast has no release item')
    return result


def validate_item(xml, version, build, size):
    """Require the exact version, build, download URL, length and signature."""
    release = item(xml)
    require(release.findtext(SPARKLE + 'shortVersionString') == version, 'Appcast version mismatch')
    require(release.findtext(SPARKLE + 'version') == str(build), 'Appcast build mismatch')
    enclosure = release.find('enclosure')
    require(enclosure is not None, 'Missing appcast enclosure')
    require(enclosure.get('url') == dmg_url(version), 'Appcast download URL mismatch')
    require(enclosure.get('length') == str(size), 'Appcast download size mismatch')
    require(bool(enclosure.get(SPARKLE + 'edSignature')), 'Missing Sparkle signature')
    return enclosure.attrib


def dmg_url(version):
    """Return the canonical immutable download URL for this release."""
    return f'https://github.com/{REPO}/releases/download/v{version}/Youty-{version}.dmg'


def validate_website(html, version):
    """Require the visible version and every Youty DMG link to be current."""
    links = re.findall(r'href="(https://github.com/legetdev/youty/releases/download/[^" ]+\.dmg)"', html)
    require(links and all(link == dmg_url(version) for link in links), 'Website download is stale')
    require(re.search(r'>\s*v' + re.escape(version) + r'\s*<', html), 'Website displayed version is stale')


def validate_formula(text, version, source_sha=None):
    """Check source and bottle pins independently of unchanged model weights."""
    require(f'archive/refs/tags/v{version}.tar.gz"' in text, 'Homebrew source version mismatch')
    require(f'root_url "https://github.com/{REPO}/releases/download/v{version}"' in text,
            'Homebrew bottle version mismatch')
    require(re.search(r'arm64_tahoe: "[a-f0-9]{64}"', text), 'Missing arm64 Tahoe bottle checksum')
    if source_sha:
        match = re.search(r'archive/refs/tags/[^\n]+\n\s*sha256 "([a-f0-9]{64})"', text)
        require(match and match[1] == source_sha, 'Homebrew source checksum mismatch')


def splice(path, fragment):
    """Insert once; retries accept an identical entry and reject conflicting releases."""
    path = Path(path)
    text = path.read_text()
    candidate = item(fragment)
    version = candidate.findtext(SPARKLE + 'shortVersionString')
    root = ET.fromstring(text)
    existing = [entry for entry in root.findall('channel/item')
                if entry.findtext(SPARKLE + 'shortVersionString') == version]
    if existing:
        require(len(existing) == 1, 'Duplicate release entries already exist')
        require(ET.tostring(existing[0]).strip() == ET.tostring(candidate).strip(),
                'Existing appcast entry conflicts with prepared release')
        require(root.find('channel/item') is existing[0], 'A newer appcast release exists; refuse rollback')
        return
    marker = '</language>'
    require(marker in text, 'Missing appcast insertion point')
    updated = text.replace(marker, marker + '\n' + fragment.rstrip() + '\n', 1)
    ET.fromstring(updated)
    path.write_text(updated)


def wait_run(repo, workflow, sha, title=None, timeout=3600):
    """Wait for the specific commit and optional dispatch title, never the latest unrelated run."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        runs = json.loads(run('gh', 'run', 'list', '--repo', repo, '--workflow', workflow,
                              '--commit', sha, '--limit', '100', '--json',
                              'databaseId,displayTitle,status,conclusion,headSha'))
        matches = [entry for entry in runs if entry['headSha'] == sha
                   and (title is None or entry['displayTitle'] == title)]
        if matches:
            chosen = matches[0]
            if chosen['status'] == 'completed':
                require(chosen['conclusion'] == 'success',
                        f'{workflow} run {chosen["databaseId"]}: {chosen["conclusion"]}; '
                        'repair and rerun that workflow, then resume the release')
                return str(chosen['databaseId'])
        print(f'Waiting for {workflow} at {sha[:8]}…', file=sys.stderr, flush=True)
        time.sleep(20)
    raise ValueError(f'Timed out waiting for {workflow}; release remains incomplete')


def check_source(root, version):
    """Check app, CLI, package and lock versions before any release uploads."""
    plist = plistlib.loads((root / 'Sources/Info.plist').read_bytes())
    require(plist['CFBundleShortVersionString'] == version, 'App source version mismatch')
    require(f'let version = "{version}"' in (root / 'CLI/main.swift').read_text(), 'CLI version mismatch')
    require(re.search(r'^version = "' + re.escape(version) + r'"$',
                      (root / 'youty-mcp/pyproject.toml').read_text(), re.M), 'MCP version mismatch')
    require(re.search(r'name = "youty-mcp"\nversion = "' + re.escape(version) + r'"',
                      (root / 'youty-mcp/uv.lock').read_text()), 'MCP lock version mismatch')
    return plist['CFBundleVersion']


def verify_public(root, version, timeout):
    """Verify public bytes, Apple trust, all distribution versions and deployment convergence."""
    build = check_source(root, version)
    local = root / f'build/Youty-{version}.dmg'
    expected = validate_item((root / 'release/appcast.xml').read_text(), version, build, local.stat().st_size)
    latest = json.loads(run('gh', 'api', f'repos/{REPO}/releases/latest'))
    require(latest['tag_name'] == f'v{version}' and not latest['draft'] and not latest['prerelease'],
            'GitHub latest release is not this stable version')
    require(run('git', 'rev-parse', 'HEAD') == run('git', 'ls-remote', 'origin', 'refs/heads/main').split()[0],
            'Source main is not pushed')
    tag_sha = run('git', 'rev-parse', f'v{version}^{{commit}}')
    remote_tag = run('git', 'ls-remote', 'origin', f'refs/tags/v{version}').split()[0]
    require(tag_sha == remote_tag, 'Published tag differs from local lightweight tag')
    run('git', 'merge-base', '--is-ancestor', tag_sha, 'HEAD')
    run('git', 'diff', '--exit-code', tag_sha, 'HEAD', '--', '.',
        ':!release/appcast.xml', ':!Scripts/homebrew/youty.rb')
    with tempfile.TemporaryDirectory(prefix='youty-release-verify-') as directory:
        public = Path(directory) / local.name
        run('curl', '--fail', '--silent', '--show-error', '--location', '--max-time', '600',
            '--output', str(public), dmg_url(version))
        require(sha256(public) == sha256(local), 'Published DMG differs from the prepared artifact')
        run('codesign', '--verify', '--verbose=2', str(public))
        run('xcrun', 'stapler', 'validate', str(public))
        run('spctl', '-a', '-t', 'open', '--context', 'context:primary-signature', str(public))
        mount = Path(directory) / 'mount'
        mount.mkdir()
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(public))
        try:
            app = mount / 'youty.app'
            plist = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            require(plist['CFBundleShortVersionString'] == version and plist['CFBundleVersion'] == str(build),
                    'Public app version/build mismatch')
            run('codesign', '--verify', '--deep', '--strict', str(app))
            run('xcrun', 'stapler', 'validate', str(app))
            run('spctl', '-a', '-t', 'execute', str(app))
        finally:
            run('hdiutil', 'detach', str(mount))
        source = Path(directory) / 'source.tar.gz'
        run('curl', '--fail', '--silent', '--show-error', '--location', '--max-time', '600',
            '--output', str(source), f'https://github.com/{REPO}/archive/refs/tags/v{version}.tar.gz')
        formula = (root / 'Scripts/homebrew/youty.rb').read_text()
        validate_formula(formula, version, sha256(source))
        tap = json.loads(run('gh', 'api', 'repos/legetdev/homebrew-youty/contents/Formula/youty.rb?ref=main'))
        import base64
        require(base64.b64decode(tap['content']).decode() == formula, 'Public tap differs from verified formula')
        bottle = Path(directory) / 'bottle.tar.gz'
        run('curl', '--fail', '--silent', '--show-error', '--location', '--max-time', '600',
            '--output', str(bottle), f'https://github.com/{REPO}/releases/download/v{version}/youty-{version}.arm64_tahoe.bottle.tar.gz')
        require(sha256(bottle) == re.search(r'arm64_tahoe: "([a-f0-9]{64})"', formula)[1],
                'Published bottle checksum mismatch')
    deadline = time.monotonic() + timeout
    while True:
        try:
            require(validate_item(fetch(SITE + '/appcast.xml').decode(), version, build, local.stat().st_size)
                    == expected, 'Live feed differs from signed reference')
            validate_website(fetch(SITE).decode(), version)
            metadata = json.loads(fetch('https://pypi.org/pypi/youty-mcp/json'))
            require(metadata['info']['version'] == version, 'PyPI latest version is stale')
            require(metadata['urls'] and all(not asset['yanked'] for asset in metadata['urls']),
                    'PyPI release is empty or yanked')
            break
        except (ValueError, subprocess.CalledProcessError) as error:
            if time.monotonic() >= deadline:
                raise ValueError(f'Public channels did not converge: {error}') from error
            print(f'Waiting for website/PyPI: {error}', file=sys.stderr, flush=True)
            time.sleep(20)
    run('uv', 'run', '--isolated', '--no-project', '--refresh-package', 'youty-mcp',
        '--with', f'youty-mcp=={version}', 'python', '-c',
        'import importlib.metadata; from youty_mcp import server; '
        f'assert importlib.metadata.version("youty-mcp") == "{version}"')
    print(f'All public channels verified at {version}.')


def main():
    """Expose focused checks to the local orchestrator and offline regression suite."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['source', 'item', 'splice', 'formula', 'wait', 'public'])
    parser.add_argument('value')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--file', type=Path)
    parser.add_argument('--sha')
    parser.add_argument('--title')
    parser.add_argument('--timeout', type=int, default=900)
    args = parser.parse_args()
    if args.command == 'source':
        print(check_source(args.root, args.value))
    elif args.command == 'item':
        build = check_source(args.root, args.value)
        validate_item(args.file.read_text(), args.value, build,
                      (args.root / f'build/Youty-{args.value}.dmg').stat().st_size)
    elif args.command == 'splice':
        splice(args.file, Path(args.value).read_text())
    elif args.command == 'formula':
        validate_formula(args.file.read_text(), args.value)
    elif args.command == 'wait':
        print(wait_run(REPO, args.value, args.sha, args.title, args.timeout))
    else:
        verify_public(args.root, args.value, args.timeout)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, ET.ParseError) as error:
        sys.exit(f'Release incomplete: {error}')
