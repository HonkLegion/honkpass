#!/usr/bin/env python3
"""Exercise the public source boundary with synthetic private documents."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "support"))
from public_source import POLICY, export, git, project_identity, selected_paths, snapshot


class PublicSourceFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="honkpass-public-test-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.source = self.base / "private"
        self.source.mkdir()
        git(self.source, "init", "--initial-branch=main")
        git(self.source, "config", "user.name", "Synthetic Author")
        git(self.source, "config", "user.email", "author@example.invalid")
        self.paths = [POLICY, "project.yml", "Sources/main.swift", "scripts/build.fish", "LICENSE"]
        self.write("Sources/main.swift", "// synthetic public source\n")
        self.write("scripts/build.fish", "echo synthetic\n")
        (self.source / "scripts/build.fish").chmod(0o755)
        self.write("LICENSE", "Synthetic license notice\n")
        self.version("1.2.3", "4")
        self.write("PLAN.md", "SYNTHETIC-PRIVATE-PLAN\n")
        self.write("internal/notes.md", "SYNTHETIC-INTERNAL-NOTES\n")
        self.write(".forgejo/workflows/private.yml", "SYNTHETIC-WORKFLOW\n")
        self.write("AGENTS.md", "SYNTHETIC-AGENT-RULES\n")
        self.write(".env", "SYNTHETIC-ENVIRONMENT\n")
        self.policy()
        self.commit()

    def write(self, path, data):
        destination = self.source / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(data)

    def version(self, version, build):
        self.write("project.yml", f"settings:\n  base:\n    MARKETING_VERSION: {version}\n    CURRENT_PROJECT_VERSION: {build}\n")

    def policy(self):
        self.write(POLICY, "\n".join(sorted(self.paths)) + "\n")

    def commit(self):
        git(self.source, "add", "--all")
        git(self.source, "-c", "commit.gpgsign=false", "commit", "-m", "Synthetic change")
        return git(self.source, "rev-parse", "HEAD").decode().strip()


class PublicSourceTests(PublicSourceFixture):
    def test_only_selected_committed_files_are_read_and_exported(self):
        self.write("Sources/main.swift", "UNCOMMITTED-MARKER\n")
        files = list(snapshot(self.source, "HEAD"))
        self.assertEqual({name for name, _, _ in files}, set(self.paths))
        payload = b"".join(data for _, data, _ in files)
        for marker in (b"SYNTHETIC-PRIVATE", b"SYNTHETIC-INTERNAL", b"SYNTHETIC-WORKFLOW", b"SYNTHETIC-ENVIRONMENT", b"UNCOMMITTED"):
            self.assertNotIn(marker, payload)
        destination = self.base / "export"
        metadata = export(self.source, "HEAD", destination, "v1.2.3")
        self.assertEqual(set(metadata["files"]), set(self.paths))
        self.assertTrue((destination / "scripts/build.fish").stat().st_mode & 0o111)
        self.assertEqual(metadata["source_revision"], git(self.source, "rev-parse", "HEAD").decode().strip())

    def test_new_build_input_requires_a_publication_decision(self):
        self.write("Sources/new.swift", "// synthetic\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "unlisted build inputs"):
            list(snapshot(self.source, "HEAD"))

    def test_links_and_submodules_are_rejected(self):
        (self.source / "Sources/main.swift").unlink()
        (self.source / "Sources/main.swift").symlink_to("../PLAN.md")
        self.commit()
        with self.assertRaisesRegex(ValueError, "links and submodules"):
            list(snapshot(self.source, "HEAD"))
        (self.source / "Sources/main.swift").unlink()
        git(self.source, "update-index", "--cacheinfo", "160000," + git(self.source, "rev-parse", "HEAD").decode().strip() + ",Sources/main.swift")
        git(self.source, "-c", "commit.gpgsign=false", "commit", "-m", "Synthetic submodule")
        with self.assertRaisesRegex(ValueError, "links and submodules"):
            selected_paths(self.source, "HEAD")

    def test_private_paths_cannot_be_added_to_the_policy(self):
        for name in ("PLAN.md", "AGENTS.md", ".env", ".forgejo/workflows/private.yml", "internal/notes.md", "../outside"):
            with self.subTest(name=name):
                self.paths.append(name)
                self.policy()
                self.commit()
                with self.assertRaisesRegex(ValueError, "Protected path"):
                    selected_paths(self.source, "HEAD")
                self.paths.pop()

    def test_missing_inputs_fail_and_export_attributes_cannot_change_content(self):
        self.paths.append("missing.swift")
        self.policy()
        self.commit()
        with self.assertRaisesRegex(ValueError, "missing files"):
            selected_paths(self.source, "HEAD")
        self.paths.pop()
        self.policy()
        self.write(".gitattributes", "Sources/main.swift export-ignore\n")
        self.commit()
        self.assertIn("Sources/main.swift", {name for name, _, _ in snapshot(self.source, "HEAD")})

    def test_literal_names_cannot_select_other_files(self):
        self.paths.append("notes/[x].txt")
        self.write("notes/[x].txt", "SYNTHETIC-PUBLIC-LITERAL\n")
        self.write("notes/x.txt", "SYNTHETIC-PRIVATE-OTHER\n")
        self.policy()
        self.commit()
        files = list(snapshot(self.source, "HEAD"))
        payload = b"".join(data for _, data, _ in files)
        self.assertIn(b"SYNTHETIC-PUBLIC-LITERAL", payload)
        self.assertNotIn(b"SYNTHETIC-PRIVATE-OTHER", payload)

    def test_tag_must_match_version_and_output_must_be_new(self):
        for tag in ("v9.9.9", "v1.2.3+5", "v1.2.3;echo injected", "../v1.2.3"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                export(self.source, "HEAD", self.base / "not-created", tag)
        destination = self.base / "export"
        export(self.source, "HEAD", destination, "v1.2.3+4")
        with self.assertRaises(FileExistsError):
            export(self.source, "HEAD", destination, "v1.2.3")

    def test_release_metadata_changes_only_the_exported_project_version(self):
        before = dict((name, data) for name, data, _ in snapshot(self.source, "HEAD"))
        destination = self.base / "release"
        metadata = export(self.source, "HEAD", destination, "v1.2.4", release_build="5")
        self.assertEqual(metadata["schema"], 2)
        self.assertEqual((metadata["version"], metadata["build"]), ("1.2.4", "5"))
        self.assertEqual(metadata["source_project"]["version"], "1.2.3")
        self.assertEqual(metadata["source_project"]["build"], "4")
        self.assertEqual(project_identity((destination / "project.yml").read_bytes()), ("1.2.4", "5"))
        for name, content in before.items():
            if name != "project.yml":
                self.assertEqual((destination / name).read_bytes(), content)
        self.assertEqual((self.source / "project.yml").read_bytes(), before["project.yml"])
        self.assertEqual(git(self.source, "status", "--porcelain"), b"")
        self.assertEqual(set(metadata["files"]), set(self.paths))

    def test_generated_release_rejects_bad_or_ambiguous_versions(self):
        for tag, build in (("v1.2.4", "0"), ("v1.2.4", "5\ninjected"), ("v1.2.4", "1000000000"),
                           ("v1.2.4+6", "5"), ("v01.2.4", "5"), ("v1.2.4-beta", "5")):
            with self.subTest(tag=tag, build=build), self.assertRaises(ValueError):
                export(self.source, "HEAD", self.base / "bad", tag, release_build=build)
        self.write("project.yml", (self.source / "project.yml").read_text() + "    MARKETING_VERSION: 1.2.3\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "one valid version"):
            export(self.source, "HEAD", self.base / "bad", "v1.2.4", release_build="5")


if __name__ == "__main__":
    unittest.main()
