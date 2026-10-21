import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


class VerifyIPATests(unittest.TestCase):
    def setUp(self):
        base = ROOT / "build" / "validator-test-temp"
        base.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="fixture-", dir=base)
        self.directory = pathlib.Path(self.temporary.name).resolve()
        assert self.directory.is_relative_to(base.resolve())
        self.addCleanup(self.temporary.cleanup)

    def rejected(self, file, expected):
        result = subprocess.run([sys.executable, str(ROOT / "scripts" / "verify-ipa.py"), str(file)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(expected, result.stderr)

    def fixture(self, info):
        file = self.directory / "synthetic-invalid-fixture.zip"
        with zipfile.ZipFile(file, "w") as archive:
            archive.writestr("Payload/ComfyPocket.app/Info.plist", plistlib.dumps(info))
        return file

    def test_missing_file(self):
        self.rejected(self.directory / "missing.zip", "file missing")

    def test_plain_text_is_not_an_ipa(self):
        file = self.directory / "source-only.zip"
        file.write_text("This is not an iOS executable", encoding="utf-8")
        self.rejected(file, "IPA verification failed")

    def test_source_zip_is_rejected(self):
        file = self.directory / "source.zip"
        with zipfile.ZipFile(file, "w") as archive:
            archive.writestr("App/Source.swift", "import SwiftUI")
        self.rejected(file, "expected exactly one app")

    def test_path_traversal_is_rejected(self):
        file = self.directory / "unsafe.zip"
        with zipfile.ZipFile(file, "w") as archive:
            archive.writestr("../outside", "invalid")
        self.rejected(file, "unsafe ZIP path")

    def test_simulator_build_is_rejected(self):
        file = self.fixture({"CFBundleIdentifier": "com.ray.comfypocket", "MinimumOSVersion": "15.0", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]})
        self.rejected(file, "simulator build is not installable")

    def test_wrong_minimum_version_is_rejected(self):
        file = self.fixture({"CFBundleIdentifier": "com.ray.comfypocket", "MinimumOSVersion": "16.0"})
        self.rejected(file, "deployment target must be 15.0")


if __name__ == "__main__":
    unittest.main()
