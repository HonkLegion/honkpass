#!/usr/bin/env python3
"""Test source pairing and archive boundaries with synthetic files only."""
import io
import json
from pathlib import Path
import plistlib
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "support"))
from legal import digest
from release_source import verify
from source_archive import include_sparkle_source, safe_project_paths
from public_source import POLICY


class SourceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="honkpass-source-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "HonkPass.app"
        self.legal = self.app / "Contents/Resources/Legal"
        (self.legal / "texts").mkdir(parents=True)
        notice = b"Synthetic license notice"
        (self.legal / "texts/notice.txt").write_bytes(notice)
        inventory = {"components": [{"notices": [{"path": "texts/notice.txt", "sha256": digest(notice)}]}]}
        inventory_bytes = json.dumps(inventory).encode()
        (self.legal / "inventory.json").write_bytes(inventory_bytes)
        for name in ("index-en.html", "index-cs.html", "GPL-3.0.txt"):
            (self.legal / name).write_text("Synthetic legal resource")
        self.files = {"project/main.swift": b"// synthetic source\n", "project/App/PassVault/Legal/inventory.json": inventory_bytes}
        for name in ("index-en.html", "index-cs.html", "GPL-3.0.txt"):
            self.files["project/App/PassVault/Legal/" + name] = (self.legal / name).read_bytes()
        self.manifest = {"version": "1.2.3", "build": "4", "project_revision": "a" * 40,
                         "inventory_sha256": digest(inventory_bytes),
                         "files": {name: digest(data) for name, data in self.files.items()}}
        self.source = self.root / "HonkPass-source.tar.gz"
        self.info = {"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "4", "HonkPassSourceRevision": "a" * 40}
        self.write_archive()

    def write_archive(self, extra=None):
        with tarfile.open(self.source, "w:gz") as archive:
            entries = list(self.files.items()) + [("source-manifest.json", json.dumps(self.manifest).encode())]
            if extra:
                entries.append(extra)
            for name, data in entries:
                member = tarfile.TarInfo("HonkPass-source/" + name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        self.info["HonkPassSourceSHA256"] = digest(self.source.read_bytes())
        self.write_info()

    def write_info(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    def test_matching_release(self):
        self.assertEqual(verify(self.app, self.source)["version"], "1.2.3")

    def test_wrong_archive_hash(self):
        self.info["HonkPassSourceSHA256"] = "wrong"
        self.write_info()
        with self.assertRaisesRegex(ValueError, "does not match"):
            verify(self.app, self.source)

    def test_wrong_release_revision_or_version(self):
        for field in ("HonkPassSourceRevision", "CFBundleVersion", "CFBundleShortVersionString"):
            with self.subTest(field=field):
                original = self.info[field]
                self.info[field] = "wrong"
                self.write_info()
                with self.assertRaisesRegex(ValueError, "revision or version"):
                    verify(self.app, self.source)
                self.info[field] = original

    def test_changed_source_payload(self):
        self.files["project/main.swift"] = b"// different source"
        self.write_archive()
        with self.assertRaisesRegex(ValueError, "contents differ"):
            verify(self.app, self.source)

    def test_changed_notice(self):
        (self.legal / "texts/notice.txt").write_text("different notice")
        with self.assertRaisesRegex(ValueError, "notice is missing or changed"):
            verify(self.app, self.source)

    def test_missing_index(self):
        (self.legal / "index-cs.html").unlink()
        with self.assertRaisesRegex(ValueError, "Missing bundled legal resource"):
            verify(self.app, self.source)

    def test_unsafe_member(self):
        self.write_archive(("../outside", b"synthetic"))
        with self.assertRaisesRegex(ValueError, "Invalid source archive member"):
            verify(self.app, self.source)

    def test_duplicate_manifest(self):
        self.write_archive(("source-manifest.json", json.dumps(self.manifest).encode()))
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            verify(self.app, self.source)

    def test_protected_paths_rejected_without_reading(self):
        for name in ("Config/Local.xcconfig", ".env", "sample.p12", "secrets/private.key", "../other", "/private/file", ".ssh/config"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Protected path"):
                safe_project_paths([name])
        safe_project_paths(["Config/Local.example.xcconfig", "Sources/Engine.swift", "LICENSE"])

    def add_public_inventory(self):
        paths = [name.removeprefix("project/") for name in self.files] + [POLICY]
        self.files["project/" + POLICY] = ("\n".join(sorted(paths)) + "\n").encode()
        self.manifest["files"] = {name: digest(data) for name, data in self.files.items()}
        self.manifest["public_project_files"] = {
            name.removeprefix("project/"): {"sha256": digest(data), "executable": False}
            for name, data in self.files.items()}

    def test_filtered_source_inventory_matches_the_archive(self):
        self.add_public_inventory()
        self.write_archive()
        self.assertEqual(verify(self.app, self.source)["version"], "1.2.3")

    def test_private_source_cannot_hide_in_a_matching_manifest(self):
        self.files["project/PLAN.md"] = b"SYNTHETIC-PRIVATE-PLAN"
        self.add_public_inventory()
        self.write_archive()
        with self.assertRaisesRegex(ValueError, "Protected path"):
            verify(self.app, self.source)

    def test_unlisted_source_is_rejected_even_when_its_hash_matches(self):
        self.add_public_inventory()
        self.files["project/notes.md"] = b"SYNTHETIC-INTERNAL-NOTE"
        self.manifest["files"]["project/notes.md"] = digest(self.files["project/notes.md"])
        self.manifest["public_project_files"]["notes.md"] = {"sha256": digest(self.files["project/notes.md"]), "executable": False}
        self.write_archive()
        with self.assertRaisesRegex(ValueError, "unlisted project"):
            verify(self.app, self.source)

    def test_sparkle_prebuilt_fixtures_do_not_enter_the_source_dmg(self):
        for name in ("Tests/Resources/test.pkg", "Tests/Resources/DevSignedApp.zip",
                     "Tests/Resources/SparkleTestCodeSignApp.tar.gz", "Tests/Resources/SparkleTestCodeSignApp.tar.bz2",
                     "Tests/Resources/SparkleTestCodeSignApp.tar.xz", "Tests/Resources/SparkleTestCodeSignApp.tar",
                     "Tests/Resources/SparkleTestCodeSignApp.enc.aar", "Tests/Resources/DevSignedAppVersion2.dmg"):
            with self.subTest(name=name):
                self.assertFalse(include_sparkle_source(name))
        for name in ("LICENSE", "Package.swift", "Sparkle.xcodeproj/project.pbxproj",
                     "Autoupdate/main.m", "Tests/SUUpdateValidatorTest.m", "Tests/Resources/testappcast.xml",
                     "Tests/Resources/test-pubkey.pem", "Tests/Resources/signed-test-file.txt", "Resources/build-input.zip"):
            with self.subTest(name=name):
                self.assertTrue(include_sparkle_source(name))


if __name__ == "__main__":
    unittest.main()
