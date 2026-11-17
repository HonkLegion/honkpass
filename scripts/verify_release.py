#!/usr/bin/env python3
"""Validate the public identity of a release before signing or upload."""
import base64
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "cz.honklegion.honkpass"
FEED = "https://update.honklegion.cz/apps/honkpass/appcast.xml"
ACCOUNT = "cz.honklegion.honkpass.sparkle"

def public_key(root=ROOT):
    text = (root / "Config/Sparkle.xcconfig").read_text()
    match = re.search(r"^HONKPASS_SPARKLE_PUBLIC_KEY = *([^\n]*)$", text, re.M)
    key = match[1].strip() if match else ""
    data = base64.b64decode(key, validate=True)
    if len(data) != 32 or not any(data):
        raise ValueError("Set the public Sparkle key in Config/Sparkle.xcconfig before distribution.")
    return key

def versions(root):
    project = (root / "project.yml").read_text()
    return tuple(re.search(r"^    " + name + r": (\S+)$", project, re.M)[1]
                 for name in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"))

def verify(root, app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version, build = versions(root)
    expected = {"CFBundleIdentifier": BUNDLE_ID, "SUFeedURL": FEED,
                "SUPublicEDKey": public_key(root), "CFBundleShortVersionString": version,
                "CFBundleVersion": build, "SUVerifyUpdateBeforeExtraction": True,
                "SUAllowsAutomaticUpdates": False, "SUAutomaticallyUpdate": False,
                "SUEnableAutomaticChecks": True, "SUEnableSystemProfiling": False}
    if any(info.get(k) != v for k, v in expected.items()):
        raise ValueError("The signed release identity or update policy differs from the source.")
    return info

if __name__ == "__main__":
    try:
        if len(sys.argv) == 2:
            verify(ROOT, Path(sys.argv[1]))
        else:
            public_key()
        print("OK: public update configuration.")
    except (ValueError, OSError, KeyError, TypeError):
        sys.exit("Release configuration is missing or differs from the source. Set the public Sparkle key first.")
