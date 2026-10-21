import importlib.util
import hashlib
import json
import pathlib
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("snapshot", pathlib.Path(__file__).with_name("prepare-public-build.py"))
snapshot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(snapshot)
VERIFY_SPEC = importlib.util.spec_from_file_location("verify_snapshot", pathlib.Path(__file__).with_name("verify-source-snapshot.py"))
verifier = importlib.util.module_from_spec(VERIFY_SPEC)
VERIFY_SPEC.loader.exec_module(verifier)


class SnapshotSafetyTests(unittest.TestCase):
    def test_white_list_excludes_history_builds_and_private_documentation(self):
        files = snapshot.source_files()
        paths = [candidate.relative_to(snapshot.ROOT).as_posix() for candidate in files]
        self.assertIn(".github/workflows/build-ios.yml", paths)
        self.assertIn("Core/Tests/ComfyCoreTests/Fixtures/DualStage4K.json", paths)
        self.assertNotIn("README.md", paths)
        self.assertNotIn("QA.md", paths)
        self.assertTrue(all(".git/" not in name and not name.startswith("build/") and not name.endswith(".ipa") for name in paths))

    def test_checked_source_has_no_unapproved_pattern_matches(self):
        self.assertEqual(snapshot.scan(snapshot.source_files()), [])

    def test_manifest_rejects_tampering_and_unlisted_executable_inputs(self):
        with tempfile.TemporaryDirectory(prefix="comfypocket-integrity-test-") as temporary:
            root = pathlib.Path(temporary).resolve()
            (root / "App").mkdir()
            source = root / "App" / "main.swift"
            source.write_bytes(b"reviewed")
            record = {"path": "App/main.swift", "bytes": 8, "sha256": hashlib.sha256(b"reviewed").hexdigest()}
            (root / "SOURCE-SNAPSHOT.json").write_text(json.dumps({"format": 1, "contains_git_history": False, "files": [record]}), encoding="utf-8")
            self.assertEqual(verifier.verify(root), 1)
            source.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "content mismatch"):
                verifier.verify(root)
            source.write_bytes(b"reviewed")
            (root / "App" / "injected.m").write_bytes(b"unreviewed")
            with self.assertRaisesRegex(ValueError, "Unreviewed extra"):
                verifier.verify(root)

    def test_tokens_credentials_and_private_paths_block_publication(self):
        with tempfile.TemporaryDirectory(prefix="comfypocket-snapshot-test-") as temporary:
            original = snapshot.ROOT
            try:
                snapshot.ROOT = pathlib.Path(temporary).resolve()
                file = snapshot.ROOT / "input.swift"
                file.write_text("ghp_" + "a" * 36 + "\nhttps://" + "real:secret@private.example\n" + "C:" + "\\Users\\Example\\secret", encoding="utf-8")
                categories = {item["category"] for item in snapshot.scan([file])}
                self.assertEqual(categories, {"credential", "credential-url", "personal-path"})
                self.assertTrue(all(set(item) == {"path", "line", "category"} for item in snapshot.scan([file])))
            finally:
                snapshot.ROOT = original


if __name__ == "__main__":
    unittest.main()

