#!/usr/bin/env python3
"""Generate and verify HonkPass's single-release Sparkle appcast."""

import base64
import datetime
import pathlib
import plistlib
import re
import sys
import xml.etree.ElementTree as ET


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FEED = "https://update.honklegion.cz/apps/honkpass/appcast.xml"
ARCHIVE_BASE = "https://update.honklegion.cz/apps/honkpass/versions"
BUNDLE_ID = "cz.honklegion.honkpass"
from verify_release import public_key
BUILD_PATTERN = re.compile(
    r"[1-9][0-9]{0,8}(?:\.(?:0|[1-9][0-9]{0,8})){0,3}"
)
ET.register_namespace("sparkle", SPARKLE)


def make_appcast(info: dict, signature: str, length: int) -> bytes:
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ValueError("Unexpected bundle identifier")
    if info.get("SUFeedURL") != FEED:
        raise ValueError("Unexpected appcast URL")
    if info.get("SUPublicEDKey") != public_key():
        raise ValueError("Unexpected Sparkle public key")
    if len(base64.b64decode(public_key(), validate=True)) != 32:
        raise ValueError("Invalid public key")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid archive signature")

    build = info["CFBundleVersion"]
    version = info["CFBundleShortVersionString"]
    if not isinstance(build, str) or BUILD_PATTERN.fullmatch(build) is None:
        raise ValueError("Invalid build version")
    if not isinstance(version, str) or not 0 < len(version) <= 64 or length <= 0:
        raise ValueError("Invalid display version or archive size")

    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "HonkPass"
    ET.SubElement(channel, "link").text = FEED
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"HonkPass {version}"
    ET.SubElement(item, "pubDate").text = datetime.datetime.now(
        datetime.timezone.utc
    ).strftime("%a, %d %b %Y %H:%M:%S %z")
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = info.get(
        "LSMinimumSystemVersion", "26.4"
    )
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": f"{ARCHIVE_BASE}/{build}/HonkPass.dmg",
            "length": str(length),
            "type": "application/octet-stream",
            f"{{{SPARKLE}}}version": build,
            f"{{{SPARKLE}}}shortVersionString": version,
            f"{{{SPARKLE}}}edSignature": signature,
            f"{{{SPARKLE}}}installationType": "application",
        },
    )
    ET.indent(rss)
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True)


def verify_appcast(info: dict, length: int, xml: bytes) -> None:
    actual = ET.fromstring(xml)
    items = actual.findall("channel/item")
    if len(items) != 1:
        raise ValueError("The package appcast must contain exactly one release")
    enclosure = items[0].find("enclosure")
    if enclosure is None:
        raise ValueError("Appcast has no enclosure")
    signature = enclosure.attrib[f"{{{SPARKLE}}}edSignature"]
    expected = ET.fromstring(make_appcast(info, signature, length))
    if enclosure.attrib != expected.find("channel/item/enclosure").attrib:
        raise ValueError("Appcast does not match this build and DMG")
    for path in ("channel/link", f"channel/item/{{{SPARKLE}}}minimumSystemVersion"):
        if actual.findtext(path) != expected.findtext(path):
            raise ValueError("Appcast metadata differs from the signed app")


def load_info(path: str) -> dict:
    with open(path, "rb") as stream:
        return plistlib.load(stream)


def main(arguments: list[str]) -> int:
    if arguments[1:2] == ["--verify"]:
        if len(arguments) != 5:
            raise ValueError(
                "Usage: generate_appcast.py --verify Info.plist HonkPass.dmg appcast.xml"
            )
        info_path, dmg_path, feed_path = arguments[2:]
        info = load_info(info_path)
        actual = ET.parse(feed_path).find("channel/item/enclosure")
        if actual is None:
            raise ValueError("Appcast has no enclosure")
        signature = actual.attrib[f"{{{SPARKLE}}}edSignature"]
        verify_appcast(info, pathlib.Path(dmg_path).stat().st_size, pathlib.Path(feed_path).read_bytes())
        print(info["CFBundleVersion"])
        print(signature)
        return 0

    if len(arguments) != 5:
        raise ValueError(
            "Usage: generate_appcast.py Info.plist HonkPass.dmg signature destination"
        )
    info_path, dmg_path, signature, destination = arguments[1:]
    info = load_info(info_path)
    pathlib.Path(destination).write_bytes(
        make_appcast(info, signature, pathlib.Path(dmg_path).stat().st_size)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
