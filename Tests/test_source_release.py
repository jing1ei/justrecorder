import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
import os
import plistlib
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('source_release', ROOT / 'source-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

class SourceReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for path in release.source_files(ROOT):
            target = self.root / path.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)

    def tearDown(self):
        self.temp.cleanup()

    def test_excludes_local_files_and_preserves_executable_modes(self):
        for name in ['Windows/settings.json', 'Windows/JustRecorder.Windows/bin/debug.cs',
                     'Sources/.env', 'docs/.DS_Store']:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('local data')
        link = self.root / 'Sources/external.swift'
        link.symlink_to(self.root / 'Package.swift')
        archive, _ = release.package(self.root)
        with zipfile.ZipFile(archive) as result:
            names = result.namelist()
            self.assertNotIn('JustRecorder/Windows/settings.json', names)
            self.assertNotIn('JustRecorder/Windows/JustRecorder.Windows/bin/debug.cs', names)
            self.assertNotIn('JustRecorder/Sources/external.swift', names)
            self.assertIn('JustRecorder/.github/RELEASES.md', names)
            self.assertIn('JustRecorder/.github/release.json', names)
            self.assertIn('JustRecorder/.github/scripts/release.py', names)
            self.assertTrue(result.getinfo('JustRecorder/build.sh').external_attr >> 16 & 0o111)
            self.assertIsNone(result.testzip())

    def test_archive_is_reproducible_and_normalizes_modes(self):
        first, _ = release.package(self.root)
        original = first.read_bytes()
        for path in release.source_files(self.root):
            os.utime(path, (1700000000, 1700000000))
            path.chmod(0o600)
        second, _ = release.package(self.root)
        self.assertEqual(original, second.read_bytes())
        with zipfile.ZipFile(second) as archive:
            self.assertEqual(archive.getinfo('JustRecorder/build.sh').external_attr >> 16, 0o100755)
            self.assertEqual(archive.getinfo('JustRecorder/README.md').external_attr >> 16, 0o100644)

    def test_documentation_and_source_have_no_chinese_characters(self):
        for path in release.source_files(ROOT):
            if path.suffix in {'.jpg', '.png', '.ico'}:
                continue
            text = path.read_text()
            self.assertFalse(any(0x3400 <= ord(c) <= 0x9FFF or 0x20000 <= ord(c) <= 0x3134F
                                 for c in text), str(path))

    def test_versions_agree(self):
        version = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
        project = ET.parse(ROOT / 'Windows/JustRecorder.Windows/JustRecorder.Windows.csproj')
        self.assertEqual(project.findtext('.//Version'), version)

    def test_missing_documentation_asset_rejects_release(self):
        (self.root / 'README.md').write_text('[missing](docs/missing.jpg)')
        with self.assertRaises(ValueError):
            release.package(self.root)

if __name__ == '__main__':
    unittest.main()
