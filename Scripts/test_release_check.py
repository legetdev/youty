"""Offline regressions for release gates, stale channels, and interrupted publication."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('release_check', Path(__file__).with_name('release-check.py'))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseChecks(unittest.TestCase):
    """Exercise failure boundaries without uploading or modifying a real release."""

    def setUp(self):
        """Use a real prior public feed as the fixture, independent of the generator."""
        self.feed = (Path(__file__).resolve().parent.parent / 'release/appcast.xml').read_text()
        self.entry = release.item(self.feed)
        self.version = self.entry.findtext(release.SPARKLE + 'shortVersionString')
        self.build = self.entry.findtext(release.SPARKLE + 'version')
        self.size = int(self.entry.find('enclosure').get('length'))
        start = self.feed.index('<item>', self.feed.index('</language>'))
        self.fragment = self.feed[start:self.feed.index('</item>', start) + len('</item>')]

    def test_valid_published_item(self):
        """Accept matching fields from the actual checked-in appcast."""
        release.validate_item(self.feed, self.version, self.build, self.size)

    def test_stale_and_malformed_feed_rejected(self):
        """A valid HTTP response cannot hide old or unsigned update metadata."""
        cases = [('99.0.0', self.build, self.size), (self.version, '99999', self.size),
                 (self.version, self.build, self.size + 1)]
        for version, build, size in cases:
            with self.subTest(version=version, build=build, size=size), self.assertRaises(ValueError):
                release.validate_item(self.feed, version, build, size)
        for xml in (self.feed.replace('sparkle:edSignature=', 'unsigned='),
                    self.feed.replace(release.dmg_url(self.version), 'https://example.com/other.dmg')):
            with self.assertRaises(ValueError):
                release.validate_item(xml, self.version, self.build, self.size)

    def test_feed_retry_is_idempotent(self):
        """Retry after a successful write must not create a second update entry."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'appcast.xml'
            path.write_text(self.feed.replace(self.fragment, '', 1))
            release.splice(path, self.fragment)
            once = path.read_bytes()
            release.splice(path, self.fragment)
            self.assertEqual(once, path.read_bytes())

    def test_feed_conflict_does_not_overwrite(self):
        """An existing version with different bytes must stop recovery."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'appcast.xml'
            path.write_text(self.feed)
            with self.assertRaises(ValueError):
                release.splice(path, self.fragment.replace('<title>', '<title>conflict '))
            self.assertEqual(path.read_text(), self.feed)

    def test_feed_cannot_roll_back_newer_release(self):
        """A retry cannot promote an older release above a newer one."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'appcast.xml'
            newer = self.fragment.replace(self.version, '99.0.0')
            path.write_text(self.feed.replace(self.fragment, newer + '\n' + self.fragment, 1))
            with self.assertRaises(ValueError):
                release.splice(path, self.fragment)

    def test_website_partial_update_rejected(self):
        """A new link alone cannot hide an old displayed version or a second stale button."""
        html = f'<a href="{release.dmg_url(self.version)}">Download</a><span>v{self.version}</span>'
        release.validate_website(html, self.version)
        with self.assertRaises(ValueError):
            release.validate_website(html.replace(f'>v{self.version}<', '>v0.0.1<'), self.version)
        with self.assertRaises(ValueError):
            release.validate_website(html + f'<a href="{release.dmg_url("0.0.1")}">Old</a>', self.version)

    def test_stale_bottle_and_wrong_checksum_rejected(self):
        """Source version alone is insufficient when the bottle still points backwards."""
        formula = (f'url "https://github.com/legetdev/youty/archive/refs/tags/v{self.version}.tar.gz"\n'
                   f'sha256 "{"a" * 64}"\n'
                   f'root_url "https://github.com/legetdev/youty/releases/download/v{self.version}"\n'
                   f'sha256 arm64_tahoe: "{"b" * 64}"')
        release.validate_formula(formula, self.version)
        with self.assertRaises(ValueError):
            release.validate_formula(formula.replace(f'download/v{self.version}"', 'download/v0.0.1"'), self.version)
        with self.assertRaises(ValueError):
            release.validate_formula(formula, self.version, '0' * 64)

    def test_unrelated_workflow_success_cannot_satisfy_gate(self):
        """Wait for both the selected commit and version-specific bottle title."""
        unrelated = dict(databaseId=10, displayTitle='Bottle v0.0.1', headSha='abc', status='completed', conclusion='success')
        correct = dict(unrelated, databaseId=11, displayTitle='Bottle v1.2.3')
        with patch.object(release, 'run', side_effect=[json.dumps([unrelated]), json.dumps([correct])]), \
                patch.object(release.time, 'sleep') as sleep:
            self.assertEqual(release.wait_run('repo', 'bottle.yml', 'abc', 'Bottle v1.2.3'), '11')
            sleep.assert_called_once()

    def test_failed_workflow_stops_then_rerun_recovers(self):
        """The same release may continue after its failed workflow is repaired."""
        entry = dict(databaseId=12, displayTitle='Bottle v1.2.3', headSha='abc', status='completed', conclusion='failure')
        with patch.object(release, 'run', return_value=json.dumps([entry])):
            with self.assertRaisesRegex(ValueError, 'repair and rerun'):
                release.wait_run('repo', 'bottle.yml', 'abc', 'Bottle v1.2.3')
        entry['conclusion'] = 'success'
        with patch.object(release, 'run', return_value=json.dumps([entry])):
            self.assertEqual(release.wait_run('repo', 'bottle.yml', 'abc', 'Bottle v1.2.3'), '12')

    def test_missing_workflow_times_out(self):
        """Missing workflow evidence is incomplete, never implicit success."""
        with patch.object(release.time, 'monotonic', side_effect=[0, 2]):
            with self.assertRaisesRegex(ValueError, 'Timed out'):
                release.wait_run('repo', 'ci.yml', 'abc', timeout=1)

    def test_http_failure_propagates(self):
        """HTTP errors must reach the caller even when the response has a body."""
        with patch.object(release.subprocess, 'check_output', side_effect=subprocess.CalledProcessError(22, 'curl')):
            with self.assertRaises(subprocess.CalledProcessError):
                release.fetch('https://example.com/missing')


if __name__ == '__main__':
    unittest.main()
