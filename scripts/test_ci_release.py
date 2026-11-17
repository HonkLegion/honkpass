#!/usr/bin/env python3
"""Exercise release boundaries with synthetic credentials and artifacts."""
import base64
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ci_release
import ci_signing
import upload_release
from test_public_source import PublicSourceFixture
from public_source import export, git


class ReleaseIdentityTests(PublicSourceFixture):
    def test_only_a_clean_matching_public_tag_can_build(self):
        public = self.base / "public"
        export(self.source, "HEAD", public, "v1.2.4", release_build="5")
        git(public, "init", "--initial-branch=main")
        git(public, "add", "--all")
        git(public, "-c", "user.name=Synthetic", "-c", "user.email=ci@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-m", "Synthetic public release")
        git(public, "-c", "tag.gpgsign=false", "tag", "v1.2.4")
        identity = ci_release.identity(public, "v1.2.4")
        self.assertEqual((identity["version"], identity["build"]), ("1.2.4", "5"))
        (public / "Sources/main.swift").write_text("// modified\n")
        with self.assertRaisesRegex(ValueError, "differs"):
            ci_release.identity(public, "v1.2.4")
        git(self.source, "-c", "tag.gpgsign=false", "tag", "v1.2.3")
        with self.assertRaisesRegex(ValueError, "not a filtered"):
            ci_release.identity(self.source, "v1.2.3")


class ReleaseAssetTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)
        self.identity = {"tag": "v1.2.4", "version": "1.2.4", "build": "5", "source_revision": "a" * 40}
        for name in ci_release.ASSETS:
            (self.directory / name).write_bytes(("synthetic-" + name).encode())
        self.manifest = dict(self.identity, files={name: {"sha256": ci_release.digest(self.directory / name),
                                                        "size": (self.directory / name).stat().st_size}
                                                  for name in ci_release.ASSETS})
        (self.directory / ci_release.MANIFEST).write_text(json.dumps(self.manifest))
        self.files = ci_release.validate_assets(self.directory, self.manifest)

    def remote(self, draft=True):
        return {"tag_name": self.identity["tag"], "draft": draft,
                "assets": [{"name": name, "size": info["size"], "digest": "sha256:" + info["sha256"]}
                           for name, info in self.files.items()]}

    def test_missing_extra_changed_and_linked_assets_are_rejected(self):
        extra = self.directory / "credentials.p12"
        extra.write_text("synthetic")
        with self.assertRaisesRegex(ValueError, "unexpected"):
            ci_release.validate_assets(self.directory, self.manifest)
        extra.unlink()
        target = self.directory / "HonkPass.dmg"
        target.write_text("changed")
        with self.assertRaisesRegex(ValueError, "changed"):
            ci_release.validate_assets(self.directory, self.manifest)
        target.unlink()
        target.symlink_to(self.directory / "appcast.xml")
        with self.assertRaisesRegex(ValueError, "regular"):
            ci_release.validate_assets(self.directory, self.manifest)

    def test_remote_digest_mismatch_never_overwrites_a_draft(self):
        remote = self.remote()
        remote["assets"][0]["digest"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ValueError, "immutable"):
            ci_release.missing_assets(remote, self.files, self.identity["tag"])

    def test_published_release_requires_all_original_assets(self):
        remote = self.remote(draft=False)
        self.assertEqual(ci_release.missing_assets(remote, self.files, self.identity["tag"]), [])
        remote["assets"].pop()
        with self.assertRaisesRegex(ValueError, "published release is incomplete"):
            ci_release.missing_assets(remote, self.files, self.identity["tag"])

    def test_new_github_release_is_a_draft_and_upload_never_clobbers(self):
        remote = None
        calls = []
        def gh(*args, **kwargs):
            nonlocal remote
            calls.append(args)
            if args[0] == "api":
                return json.dumps(remote).encode() if remote is not None else None
            if args[:2] == ("release", "create"):
                self.assertIn("--draft", args)
                self.assertIn("--verify-tag", args)
                remote = {"tag_name": self.identity["tag"], "draft": True, "assets": []}
            elif args[:2] == ("release", "upload"):
                self.assertNotIn("--clobber", args)
                remote = self.remote()
            return b""
        with patch("ci_release.identity", return_value=self.identity), patch("ci_release.gh", side_effect=gh):
            ci_release.draft(self.directory, self.identity["tag"], self.directory)
        self.assertEqual(len([call for call in calls if call[:2] == ("release", "upload")]), 1)

    def test_collect_uses_only_paired_assets_and_rejects_another_source_revision(self):
        root = self.directory / "checkout"
        distribution = root / ".build/distribution"
        update = distribution / "update"
        notarized = root / ".build/logs/notarized"
        update.mkdir(parents=True)
        notarized.mkdir(parents=True)
        (distribution / "latest-notarized.txt").write_text(str(notarized))
        for name in ci_release.ASSETS - {"release-manifest.json"}:
            destination = notarized if name == "HonkPass-notarized.zip" else update
            (destination / name).write_bytes(("synthetic-" + name).encode())
        (update / "credentials.p12").write_text("must not be copied")
        record = dict(self.identity, binary_sha256=ci_release.digest(notarized / "HonkPass-notarized.zip"),
                      source_sha256=ci_release.digest(update / "HonkPass-source.tar.gz"))
        (notarized / "release-manifest.json").write_text(json.dumps(record))
        prepared = ({}, self.identity, {"sha256": ci_release.digest(update / "HonkPass.dmg")})
        with patch("ci_release.identity", return_value=self.identity), \
                patch("ci_release.upload_release.prepare", return_value=prepared), \
                patch("ci_release.upload_release.expected_release_paths", return_value=(update / "HonkPass.app", update / "HonkPass.dmg")), \
                patch.dict(os.environ, {"DISTRIBUTION_DIR": str(distribution)}):
            output = root / ".build/github-release"
            ci_release.collect(root, self.identity["tag"], output)
            self.assertEqual({path.name for path in output.iterdir()}, ci_release.ASSETS | {ci_release.MANIFEST})
            record["source_revision"] = "b" * 40
            (notarized / "release-manifest.json").write_text(json.dumps(record))
            with self.assertRaisesRegex(ValueError, "same release"):
                ci_release.collect(root, self.identity["tag"], root / ".build/rejected")
            self.assertFalse((root / ".build/rejected").exists())


class SigningTests(unittest.TestCase):
    def profile(self, **changes):
        profile = {"UUID": "00000000-0000-0000-0000-000000000001", "TeamIdentifier": ["ABCDEFGHIJ"],
                   "ExpirationDate": datetime.now() + timedelta(days=1),
                   "Entitlements": {"com.apple.application-identifier": "ABCDEFGHIJ.cz.honklegion.honkpass"}}
        profile.update(changes)
        return plistlib.dumps(profile)

    def test_profile_must_match_team_bundle_and_expiration(self):
        self.assertEqual(ci_signing.profile_identity(self.profile(), "ABCDEFGHIJ", "cz.honklegion.honkpass"),
                         "00000000-0000-0000-0000-000000000001")
        for data, team, bundle in ((self.profile(), "ZZZZZZZZZZ", "cz.honklegion.honkpass"),
                                   (self.profile(), "ABCDEFGHIJ", "cz.honklegion.honkpass.provider"),
                                   (self.profile(ExpirationDate=datetime(2000, 1, 1)), "ABCDEFGHIJ", "cz.honklegion.honkpass")):
            with self.assertRaises(ci_signing.SigningError):
                ci_signing.profile_identity(data, team, bundle)
        identifier = "AAAAAAAA-0000-0000-0000-000000000001"
        self.assertEqual(ci_signing.profile_identity(self.profile(UUID=identifier), "ABCDEFGHIJ", "cz.honklegion.honkpass"),
                         identifier)

    def test_runner_setup_and_cleanup_keep_secrets_outside_the_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "checkout"
            (root / "Config").mkdir(parents=True)
            (root / "Config/Sparkle.xcconfig").write_text("HONKPASS_SPARKLE_PUBLIC_KEY = synthetic-public-key\n")
            directory = Path(temporary) / "runner-signing"
            environment_file = Path(temporary) / "environment"
            secrets = {name: base64.b64encode(b"synthetic-credential").decode() for name in ci_signing.SECRET_NAMES}
            secrets.update(APPLE_TEAM_ID="ABCDEFGHIJ", APPLE_NOTARY_KEY_ID="1234567890",
                           APPLE_NOTARY_ISSUER_ID="00000000-0000-0000-0000-000000000001",
                           SPARKLE_PRIVATE_KEY=base64.b64encode(bytes(32)).decode(), GITHUB_ENV=str(environment_file))
            calls = []
            def run(*args):
                calls.append(args)
                if args[0:2] == ("security", "default-keychain") and "-s" not in args:
                    return b'"/synthetic/login.keychain-db"'
                if args[0:2] == ("security", "list-keychains") and "-s" not in args:
                    return b'"/synthetic/login.keychain-db"'
                if args[0:2] == ("security", "create-keychain"):
                    Path(args[-1]).touch()
                if args[0:2] == ("security", "find-identity"):
                    return ('1) ' + 'A' * 40 + ' "Developer ID Application: Synthetic (ABCDEFGHIJ)"').encode()
                if args[0:2] == ("security", "cms"):
                    provider = "PROVIDER" in args[-1]
                    return self.profile(UUID="00000000-0000-0000-0000-00000000000" + ("2" if provider else "1"),
                                        Entitlements={"com.apple.application-identifier":
                                                      "ABCDEFGHIJ.cz.honklegion.honkpass" + (".provider" if provider else "")})
                if args[0] == "fish":
                    return b"/synthetic/Sparkle"
                if args[0].endswith("generate_keys") and "-p" in args:
                    return b"synthetic-public-key"
                return b""
            with patch("ci_signing.ROOT", root), patch("ci_signing.runner_directory", return_value=directory), \
                    patch("ci_signing.Path.home", return_value=Path(temporary) / "home"), \
                    patch("ci_signing.run", side_effect=run), patch.dict(os.environ, secrets):
                ci_signing.setup()
                key = directory / "sparkle-key"
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
                self.assertIn("HONKPASS_SPARKLE_KEY_FILE=" + str(key), environment_file.read_text())
                self.assertNotIn(secrets["SPARKLE_PRIVATE_KEY"], environment_file.read_text())
                self.assertFalse((directory / "certificate.p12").exists())
                self.assertFalse((directory / "notary.p8").exists())
                profiles = json.loads((directory / "state.json").read_text())["profiles"]
                self.assertTrue(all(Path(path).exists() for path in profiles))
                ci_signing.cleanup()
                self.assertFalse(directory.exists())
                self.assertFalse((root / "Config/Local.xcconfig").exists())
                self.assertTrue(all(not Path(path).exists() for path in profiles))
                self.assertIn(("security", "default-keychain", "-d", "user", "-s", "/synthetic/login.keychain-db"), calls)

    def test_explicit_sparkle_file_never_falls_back_to_keychain(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(upload_release.sparkle_signing_options(), ["--account", "cz.honklegion.honkpass.sparkle"])
            for path in ("", "/nonexistent-synthetic-key"):
                os.environ["HONKPASS_SPARKLE_KEY_FILE"] = path
                with self.assertRaises(upload_release.UploadError):
                    upload_release.sparkle_signing_options()
            with tempfile.NamedTemporaryFile() as synthetic:
                os.environ["HONKPASS_SPARKLE_KEY_FILE"] = synthetic.name
                self.assertEqual(upload_release.sparkle_signing_options(), ["--ed-key-file", synthetic.name])

    def test_credentials_are_not_forwarded_to_commands_or_errors(self):
        with patch.dict(os.environ, {name: "synthetic-private-value" for name in ci_signing.SECRET_NAMES}), \
                patch("ci_signing.subprocess.run", return_value=subprocess.CompletedProcess([], 1, b"synthetic-private-value", b"synthetic-private-value")) as runner:
            with self.assertRaises(ci_signing.SigningError) as error:
                ci_signing.run("security", "synthetic")
            self.assertNotIn("synthetic-private-value", str(error.exception))
            self.assertFalse(ci_signing.SECRET_NAMES & runner.call_args.kwargs["env"].keys())

    def test_setup_refuses_a_developer_machine(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}):
            with self.assertRaisesRegex(ci_signing.SigningError, "GitHub-hosted"):
                ci_signing.runner_directory()

    def test_invalid_encoded_key_never_enters_an_error(self):
        with patch.dict(os.environ, {"SPARKLE_PRIVATE_KEY": "SYNTHETIC-INVALID-SECRET!"}):
            with self.assertRaises(ci_signing.SigningError) as error:
                ci_signing.secret_bytes("SPARKLE_PRIVATE_KEY")
            self.assertNotIn("SYNTHETIC-INVALID-SECRET", str(error.exception))


if __name__ == "__main__":
    unittest.main()
