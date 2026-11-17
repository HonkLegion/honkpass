#!/usr/bin/env python3
"""Exercise Make and release commands with synthetic tools in an isolated project."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent
FISH = "/opt/homebrew/bin/fish"


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="honkpass-workflow-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("make.fish", "progress.fish", "step-output.py", "archive-developer-id.fish",
                     "notarize-developer-id.fish", "release-check.fish", "source-python.fish"):
            shutil.copyfile(SOURCE / name, scripts / name)
        (scripts / "verify_release.py").write_text("print('OK: synthetic update configuration')\n")
        shutil.copyfile(SOURCE.parent / "Makefile", self.root / "Makefile")
        support = self.root / "support"
        support.mkdir()
        for name in ("source_archive", "release_source"):
            (support / (name + ".py")).write_text('''import json, os, pathlib, sys
name = pathlib.Path(__file__).stem
with open(os.environ["WORKFLOW_TRACE"], "a") as log:
    log.write(json.dumps([name, *sys.argv[1:]]) + "\\n")
if os.environ.get("WORKFLOW_FAIL") == name:
    sys.exit(17)
if name == "source_archive":
    pathlib.Path(sys.argv[sys.argv.index("--output") + 1]).write_text("synthetic source")
''')
        (self.root / "Config").mkdir()
        (self.root / "Config/Local.xcconfig").write_text("// Synthetic configuration\n")
        (self.root / ".local-dependencies/BitwardenSdk/BitwardenFFI.xcframework").mkdir(parents=True)
        self.trace = self.root / "trace.jsonl"
        self.tools = self.root / "tools"
        self.tools.mkdir()
        recorder = '''import json, os, pathlib, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ["WORKFLOW_TRACE"], "a") as log:
    log.write(json.dumps([name, *args]) + "\\n")
if os.environ.get("WORKFLOW_FAIL") == name:
    print("Synthetic command failure")
    sys.exit(int(os.environ.get("WORKFLOW_EXIT", "17")))
if name == "xcodebuild" and "-exportPath" in args:
    pathlib.Path(args[args.index("-exportPath") + 1], "HonkPass.app").mkdir(parents=True)
if name == "codesign" and "--display" in args:
    print("Authority=" + os.environ.get("SIGNING_IDENTITY", "Developer ID Application: Synthetic"))
elif name == "xcrun" and args[:2] == ["notarytool", "submit"]:
    print(json.dumps({"id": "synthetic-id", "status": os.environ.get("NOTARY_STATUS", "Accepted")}))
elif name == "xcrun" and args[:2] == ["notarytool", "log"]:
    pathlib.Path(args[-1]).write_text("{}")
else:
    print(name + " synthetic output")
'''
        for name in ("xcodegen", "xcodebuild", "codesign", "spctl", "xcrun", "ditto"):
            tool = self.tools / name
            tool.write_text(f"#!{sys.executable}\n" + recorder)
            tool.chmod(0o700)
        git = self.tools / "git"
        git.write_text(f"#!{sys.executable}\nimport sys\nif sys.argv[1] == 'rev-parse': print('a' * 40)\n")
        git.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ["PATH"],
                        WORKFLOW_TRACE=str(self.trace), MAKE_PROGRESS="plain", NOTARY_PROFILE="synthetic-profile",
                        CONFIGURATION="Debug", DERIVED_DATA=".build/xcode", DISTRIBUTION_DIR=".build/distribution")

    def run_workflow(self, action, **environment):
        return subprocess.run([FISH, "--no-config", "scripts/make.fish", action], cwd=self.root,
                              env=dict(self.env, **environment), capture_output=True, text=True, timeout=15)

    def calls(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def test_make_preserves_arguments_and_complete_logs(self):
        directory = "build output; touch injected"
        result = subprocess.run(["/usr/bin/make", "build", "DERIVED_DATA=" + directory], cwd=self.root,
                                env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "injected").exists())
        self.assertEqual([c[0] for c in self.calls()], ["xcodegen", "xcodebuild", "codesign"])
        self.assertIn(directory, self.calls()[1])
        self.assertIn(directory + "/Build/Products/Debug/HonkPass.app", self.calls()[2])
        self.assertIn("Generating the Xcode project: OK", result.stdout)
        self.assertIn("Checking the signature: OK", result.stdout)
        self.assertNotIn("\x1b", result.stdout)
        logs = list((self.root / ".build/logs").glob("*/build.log"))
        self.assertEqual(logs[0].read_text(), "xcodebuild synthetic output\n")

    def test_failed_build_stops_and_preserves_exit_code(self):
        result = self.run_workflow("build", WORKFLOW_FAIL="xcodebuild", WORKFLOW_EXIT="23")
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertEqual([c[0] for c in self.calls()], ["xcodegen", "xcodebuild"])
        self.assertIn("FAILED (exit 23)", result.stdout)

    def test_archive_keeps_previous_artifacts_and_uses_current_target(self):
        for _ in range(2):
            result = self.run_workflow("archive")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        exports = list((self.root / ".build/distribution").glob("*/export/HonkPass.app"))
        self.assertEqual(len(exports), 2)
        archive = next(c for c in self.calls() if c[0] == "xcodebuild" and "archive" in c)
        self.assertIn("PassVault.xcodeproj", archive)
        self.assertIn("ARCHS=arm64", archive)
        self.assertIn("HONKPASS_SOURCE_REVISION=" + "a" * 40, archive)
        self.assertTrue(any(c.startswith("HONKPASS_SOURCE_SHA256=") for c in archive))
        self.assertFalse(any(c[0] in ("xcrun", "open") for c in self.calls()))

    def test_failed_archive_keeps_last_successful_export(self):
        self.assertEqual(self.run_workflow("archive").returncode, 0)
        marker = self.root / ".build/distribution/latest-export.txt"
        previous = marker.read_text()
        self.trace.unlink()
        result = self.run_workflow("archive", WORKFLOW_FAIL="xcodebuild", WORKFLOW_EXIT="19")
        self.assertEqual(result.returncode, 19)
        self.assertEqual(marker.read_text(), previous)
        self.assertEqual([c[0] for c in self.calls()], ["source_archive", "xcodegen", "xcodebuild"])

    def prepare_export(self):
        app = self.root / "export/HonkPass.app"
        app.mkdir(parents=True)
        (self.root / "HonkPass-source.tar.gz").write_text("synthetic source")
        distribution = self.root / ".build/distribution"
        distribution.mkdir(parents=True)
        (distribution / "latest-export.txt").write_text(str(app) + "\n")

    def test_notarize_accepted_staples_and_packages(self):
        self.prepare_export()
        result = self.run_workflow("notarize")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([c[:3] for c in self.calls() if c[0] == "xcrun"],
                         [["xcrun", "notarytool", "submit"], ["xcrun", "notarytool", "log"],
                          ["xcrun", "stapler", "staple"], ["xcrun", "stapler", "validate"]])
        self.assertIn("Notarized ZIP:", result.stdout)

    def test_notarize_rejection_is_failed_step_without_stapling(self):
        self.prepare_export()
        result = self.run_workflow("notarize", NOTARY_STATUS="Invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Submitting app to Apple: FAILED", result.stdout)
        self.assertNotIn("Submitting app to Apple: OK", result.stdout)
        self.assertFalse(any(c[:2] == ["xcrun", "stapler"] for c in self.calls()))

    def test_notarize_refuses_development_signature_before_upload(self):
        self.prepare_export()
        result = self.run_workflow("notarize", SIGNING_IDENTITY="Apple Development: Synthetic")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] in ("xcrun", "ditto") for c in self.calls()))

    def test_notarize_refuses_missing_export(self):
        result = self.run_workflow("notarize")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_notarize_refuses_mismatched_source_before_upload(self):
        self.prepare_export()
        result = self.run_workflow("notarize", WORKFLOW_FAIL="release_source")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] in ("xcrun", "ditto") for c in self.calls()))

    def test_archive_refuses_source_failure_before_build(self):
        result = self.run_workflow("archive", WORKFLOW_FAIL="source_archive")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([c[0] for c in self.calls()], ["source_archive"])


if __name__ == "__main__":
    unittest.main()
