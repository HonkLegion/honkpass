"""Synthetic release identity and appcast drift tests."""
import base64
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

from generate_appcast import make_appcast, verify_appcast, SPARKLE
from verify_release import public_key, verify, BUNDLE_ID, FEED

KEY = base64.b64encode(bytes(range(32))).decode()
SIGNATURE = base64.b64encode(bytes(range(64))).decode()

class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Config").mkdir()
        (self.root / "Config/Sparkle.xcconfig").write_text("HONKPASS_SPARKLE_PUBLIC_KEY = " + KEY + "\n")
        (self.root / "project.yml").write_text("    MARKETING_VERSION: 1.0\n    CURRENT_PROJECT_VERSION: 9\n")
        self.app = self.root / "HonkPass.app"
        (self.app / "Contents").mkdir(parents=True)
        self.info = {"CFBundleIdentifier": BUNDLE_ID, "SUFeedURL": FEED, "SUPublicEDKey": KEY,
                     "CFBundleShortVersionString": "1.0", "CFBundleVersion": "9",
                     "LSMinimumSystemVersion": "26.4", "SUVerifyUpdateBeforeExtraction": True,
                     "SUAllowsAutomaticUpdates": False, "SUAutomaticallyUpdate": False,
                     "SUEnableAutomaticChecks": True, "SUEnableSystemProfiling": False}
        self.write_info()

    def write_info(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    def test_missing_signing_key_stops_distribution(self):
        for key in ("", "not-a-key", base64.b64encode(bytes(32)).decode()):
            (self.root / "Config/Sparkle.xcconfig").write_text("HONKPASS_SPARKLE_PUBLIC_KEY = " + key + "\n")
            with self.assertRaises(ValueError):
                public_key(self.root)

    def test_rejects_stale_build_and_silent_install_policy(self):
        verify(self.root, self.app)
        for key, value in (("CFBundleVersion", "8"), ("SUAllowsAutomaticUpdates", True),
                           ("SUFeedURL", "https://example.test/appcast.xml")):
            original = self.info[key]
            self.info[key] = value
            self.write_info()
            with self.assertRaises(ValueError):
                verify(self.root, self.app)
            self.info[key] = original

    def test_appcast_rejects_changed_size_minimum_os_and_download(self):
        with patch("generate_appcast.public_key", return_value=KEY):
            xml = make_appcast(self.info, SIGNATURE, 123)
            verify_appcast(self.info, 123, xml)
            for old, new in ((b'length="123"', b'length="124"'),
                             (b">26.4<", b">12.0<"),
                             (b"/versions/9/", b"/versions/8/")):
                with self.assertRaises(ValueError):
                    verify_appcast(self.info, 123, xml.replace(old, new))
            for signature in ("invalid", base64.b64encode(bytes(32)).decode()):
                with self.assertRaises(ValueError):
                    make_appcast(self.info, signature, 123)

if __name__ == "__main__":
    unittest.main()
