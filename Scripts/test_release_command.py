"""Exercise local command recovery with simulated external tools; never publish."""
import hashlib
import json
import os
import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


@unittest.skipUnless(sys.platform == 'darwin' and (ROOT / 'Scripts/release.sh').exists(),
                     'Maintainer-only wrapper recovery test requires the local macOS wrapper')
class ReleaseCommand(unittest.TestCase):
    """Run the real shell control flow against isolated fake publication services."""

    def setUp(self):
        """Prepare an interrupted release and command fakes confined to a temporary directory."""
        self.temporary = tempfile.TemporaryDirectory(prefix='youty-release-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for folder in ['Scripts/homebrew', 'Sources', 'CLI', 'youty-mcp', 'release', 'bin',
                       'build/releases/v1.4.8', 'AI/youty-web/.git', 'AI/youty-web/public', 'AI/youty-web/lib']:
            (self.root / folder).mkdir(parents=True)
        for name in ['Scripts/release.sh', 'Scripts/release-check.py', 'Scripts/homebrew/youty.rb',
                     'Sources/Info.plist', 'CLI/main.swift', 'youty-mcp/pyproject.toml', 'youty-mcp/uv.lock',
                     'release/appcast.xml']:
            shutil.copy2(ROOT / name, self.root / name)
        # Pin fixture source versions so future releases do not change this scenario.
        (self.root / 'Sources/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.4.8', 'CFBundleVersion': '15'}))
        (self.root / 'CLI/main.swift').write_text('let version = "1.4.8"')
        (self.root / 'youty-mcp/pyproject.toml').write_text('version = "1.4.8"')
        (self.root / 'youty-mcp/uv.lock').write_text('name = "youty-mcp"\nversion = "1.4.8"')
        self.state = self.root / 'build/releases/v1.4.8'
        for name, value in [('build', '15'), ('notes', 'Test only'), ('models', '0'),
                            ('source.sha', 'a' * 40), ('prepared', '')]:
            (self.state / name).write_text(value)
        dmg = self.root / 'build/Youty-1.4.8.dmg'
        dmg.write_bytes(b'fixture immutable dmg')
        (self.state / 'dmg.sha256').write_text(hashlib.sha256(dmg.read_bytes()).hexdigest() + '  ' + str(dmg) + '\n')
        feed = (self.root / 'release/appcast.xml').read_text()
        entry = ET.fromstring(feed).find('channel/item')
        old_version = entry.findtext('{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString')
        old_build = entry.findtext('{http://www.andymatuschak.org/xml-namespaces/sparkle}version')
        feed = feed.replace(old_version, '1.4.8').replace(f'<sparkle:version>{old_build}</sparkle:version>', '<sparkle:version>15</sparkle:version>')
        feed = feed.replace('length="' + entry.find('enclosure').get('length') + '"', f'length="{dmg.stat().st_size}"')
        formula = (self.root / 'Scripts/homebrew/youty.rb').read_text()
        formula = re.sub(r'archive/refs/tags/v[0-9.]+(?=\.tar\.gz)', 'archive/refs/tags/v1.4.8', formula)
        formula = re.sub(r'(root_url "https://github.com/legetdev/youty/releases/download/)v[0-9.]+', r'\g<1>v1.4.8', formula)
        (self.root / 'Scripts/homebrew/youty.rb').write_text(formula)
        (self.root / 'release/appcast.xml').write_text(feed)
        start = feed.index('<item>', feed.index('</language>'))
        (self.state / 'item.xml').write_text(feed[start:feed.index('</item>', start) + 7])
        (self.root / 'AI/youty-web/public/appcast.xml').write_text(feed)
        (self.root / 'AI/youty-web/lib/site.ts').write_text('version: "v1.4.8", downloadUrl: "https://github.com/legetdev/youty/releases/download/v1.4.8/Youty-1.4.8.dmg"')
        shutil.copy2(self.root / 'Scripts/homebrew/youty.rb', self.root / 'bottled.rb')
        # Intercept only external workflow/public evidence; real version/feed/formula checks still run.
        check = self.root / 'Scripts/release-check.py'
        check.rename(check.with_name('real-check.py'))
        check.write_text('''import os, pathlib, runpy, sys
root = pathlib.Path(os.environ['FIXTURE'])
if sys.argv[1] == 'wait':
    if sys.argv[2] == 'bottle.yml' and not (root / 'repaired').exists():
        sys.exit('simulated failed bottle workflow')
    print('123')
elif sys.argv[1] == 'public':
    if not (root / 'public-ready').exists():
        sys.exit('simulated stale public channel')
else:
    runpy.run_path(str(root / 'Scripts/real-check.py'), run_name='__main__')
''')
        driver = self.root / 'bin/fake-tool'
        driver.write_text('#!' + sys.executable + '\n' + '''import json, os, pathlib, shutil, sys
root = pathlib.Path(os.environ['FIXTURE'])
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with (root / 'calls.jsonl').open('a') as out:
    out.write(json.dumps([name, args]) + '\\n')
if name == 'security':
    print('Developer ID Application: Bent Eisheuer (2X3J8AX87F)')
elif name == 'curl':
    print('source archive bytes')
elif name == 'git':
    directory = pathlib.Path.cwd()
    if args[:1] == ['-C']:
        directory, args = pathlib.Path(args[1]), args[2:]
    if args[:3] == ['remote', 'get-url', '--push']:
        repo = 'youty-web' if directory.name == 'youty-web' else 'homebrew-youty' if directory != root else 'youty'
        print('https://github.com/legetdev/' + repo + '.git')
    elif args[:1] == ['rev-parse']:
        print('main' if '--abbrev-ref' in args else 'a' * 40)
    elif args[:1] == ['clone']:
        dest = pathlib.Path(args[-1]); (dest / '.git').mkdir(); (dest / 'Formula').mkdir()
        shutil.copyfile(root / 'bottled.rb', dest / 'Formula/youty.rb')
    elif args[:1] == ['ls-remote']:
        print('a' * 40 + '\\trefs/tags/v1.4.8')
elif name == 'gh':
    if args[:2] == ['release', 'list']:
        print('1')
    elif args[:2] == ['release', 'view']:
        print('Youty-1.4.8.dmg' if 'assets' in args else '{"isDraft": false, "isPrerelease": false}')
    elif args[:2] == ['release', 'download']:
        shutil.copyfile(root / 'build/Youty-1.4.8.dmg', pathlib.Path(args[args.index('--dir') + 1]) / 'Youty-1.4.8.dmg')
    elif args[:2] == ['run', 'list']:
        print('1' if (root / 'dispatched').exists() else '0')
    elif args[:2] == ['workflow', 'run']:
        (root / 'dispatched').touch()
    elif args[:2] == ['run', 'download']:
        shutil.copyfile(root / 'bottled.rb', pathlib.Path(args[args.index('-D') + 1]) / 'youty.rb')
    elif args[:2] in (['release', 'create'], ['release', 'upload']):
        sys.exit('unexpected duplicate publication')
else:
    sys.exit('unexpected tool execution: ' + name)
''')
        driver.chmod(0o755)
        for name in ['git', 'gh', 'security', 'curl', 'xcodegen', 'uv', 'xcrun', 'codesign', 'spctl']:
            (self.root / 'bin' / name).symlink_to(driver)
        self.env = {**os.environ, 'HOME': str(self.root), 'FIXTURE': str(self.root),
                    'PATH': str(self.root / 'bin') + os.pathsep + os.environ['PATH']}
        self.env.pop('SKIP_NOTARY', None)

    def invoke(self, *args, env=None):
        """Execute only the fixture copy; collect the true command exit and completion text."""
        return subprocess.run(['bash', str(self.root / 'Scripts/release.sh'), 'v1.4.8', *args],
                              input='y\n', text=True, capture_output=True, env=env or self.env,
                              cwd=self.root, timeout=30)

    def test_interrupted_bottle_and_stale_public_channel_resume(self):
        """Two failures must remain incomplete; recovery must reuse artifacts and dispatch once."""
        first = self.invoke('--resume')
        self.assertNotEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertIn('simulated failed bottle', first.stderr)
        self.assertNotIn('all channels verified', first.stdout)
        self.assertFalse((self.state / 'verified').exists())
        (self.root / 'repaired').touch()
        second = self.invoke('--resume')
        self.assertNotEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn('simulated stale public channel', second.stderr)
        self.assertFalse((self.state / 'verified').exists())
        (self.root / 'public-ready').touch()
        third = self.invoke('--resume')
        self.assertEqual(third.returncode, 0, third.stdout + third.stderr)
        self.assertIn('all channels verified', third.stdout)
        self.assertTrue((self.state / 'verified').exists())
        calls = [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]
        self.assertEqual(sum(name == 'gh' and args[:2] == ['workflow', 'run'] for name, args in calls), 1)
        self.assertFalse(any(name == 'gh' and args[:2] in (['release', 'create'], ['release', 'upload']) for name, args in calls))
        self.assertEqual((self.state / 'build').read_text(), '15')

    def test_skip_flags_cannot_create_partial_release(self):
        """Legacy skip options and inherited notarization bypasses fail before publication."""
        self.assertNotEqual(self.invoke('--no-tap').returncode, 0)
        self.assertNotEqual(self.invoke('--resume', env={**self.env, 'SKIP_NOTARY': '1'}).returncode, 0)
        self.assertFalse((self.root / 'calls.jsonl').exists())

    def test_resume_dry_run_does_not_publish_or_mutate_artifact(self):
        """Read-only preview exits before the lock, uploads and state changes."""
        before = {p.name: p.read_bytes() for p in self.state.iterdir()}
        result = self.invoke('--resume', '--dry-run')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.state.iterdir()})
        self.assertFalse((self.root / 'dispatched').exists())
        self.assertFalse((self.root / 'build/.release-running').exists())


if __name__ == '__main__':
    unittest.main()
