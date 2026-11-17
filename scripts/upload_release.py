#!/usr/bin/env python3
"""Upload an immutable notarized HonkPass build as a draft, never publish it.

Only the standard library and system curl are used. Authorization is supplied
through stdin, never argv, curlrc or a temporary file.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

from generate_appcast import BUILD_PATTERN, BUNDLE_ID, FEED, SPARKLE, make_appcast, verify_appcast
from verify_release import verify, public_key


BASE = "https://update.honklegion.cz/api/v1"
MAX_FILE = 536_870_912
MAX_RESPONSE = 1024 * 1024
ATTEMPTS = 3
DISPLAY_VERSION_PATTERN = re.compile(r"[0-9A-Za-z][0-9A-Za-z._-]{0,63}")


class UploadError(Exception):
    """Messages must be local literals, never raw server output or credentials."""


class ApiError(UploadError):
    def __init__(self, status: int):
        self.status = status
        self.retryable = status in (502, 503, 504)
        super().__init__(
            f"Updater returned HTTP {status}; no automatic publication was attempted."
        )


class TransportError(UploadError):
    def __init__(self, retryable: bool = True):
        self.retryable = retryable
        super().__init__(
            "Updater transport failed; rerun the same build and notes to reconcile."
        )


def canonical(value) -> bytes:
    return json.dumps(
        value, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    ).encode()


def identifier(value) -> int:
    if type(value) is not int or not 1 <= value <= 999_999_999:
        raise UploadError("Invalid numeric ID or revision in API response.")
    return value


def load_token() -> str:
    token = os.environ.get("UPDATER_TOKEN")
    if not isinstance(token, str) or not re.fullmatch(
        r"[A-Za-z0-9._~+/=-]{8,4096}", token
    ):
        raise UploadError("Set a valid UPDATER_TOKEN environment variable.")
    return token


def child_environment() -> dict[str, str]:
    return {key: value for key, value in os.environ.items() if key != "UPDATER_TOKEN"}


def checked(args: list[str]) -> bytes:
    result = subprocess.run(
        args,
        env=child_environment(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=120,
        check=False,
    )
    if result.returncode:
        raise UploadError(
            f"Local verification failed: {Path(args[0]).name}. Rebuild and notarize."
        )
    return result.stdout


def checked_details(args: list[str]) -> bytes:
    result = subprocess.run(
        args,
        env=child_environment(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=120,
        check=False,
    )
    if result.returncode:
        raise UploadError(
            f"Local verification failed: {Path(args[0]).name}. Rebuild and notarize."
        )
    return result.stdout


class CurlAPI:
    def __init__(self, token: str):
        self.token = token

    def request(
        self,
        method: str,
        route: str,
        *,
        metadata=None,
        key=None,
        artifact=None,
        revision=None,
    ):
        allowed = (
            method == "GET"
            and re.fullmatch(
                r"/apps(?:/[1-9][0-9]*(?:/releases/[1-9][0-9]*)?)?", route
            )
        ) or (
            method == "POST"
            and re.fullmatch(
                r"/apps/[1-9][0-9]*/releases(?:/[1-9][0-9]*/artifact)?", route
            )
        )
        if not allowed:
            raise UploadError("Forbidden updater operation.")

        args = [
            "/usr/bin/curl",
            "-q",
            "--silent",
            "--show-error",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--connect-timeout",
            "10",
            "--max-time",
            "300",
            "--max-filesize",
            str(MAX_RESPONSE),
            "--request",
            method,
            "--header",
            "@-",
            "--header",
            "Accept: application/json",
            "--write-out",
            "\n%{http_code}",
            BASE + route,
        ]
        # Redirects are deliberately not followed.
        if metadata is not None:
            args += [
                "--header",
                "Content-Type: application/json",
                "--header",
                "Idempotency-Key: " + key,
                "--data-binary",
                canonical(metadata).decode(),
            ]
        if artifact is not None:
            path = str(artifact["path"])
            if any(char in path for char in '\";\r\n'):
                raise UploadError("Unsupported temporary file path.")
            args += [
                "--form",
                f'file=@"{path}";filename=HonkPass.dmg',
                "--form-string",
                "signature=" + artifact["signature"],
                "--form-string",
                "revision=" + str(identifier(revision)),
            ]
        try:
            result = subprocess.run(
                args,
                input=f"Authorization: Bearer {self.token}\n".encode(),
                env=child_environment(),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=310,
                check=False,
            )
        except subprocess.TimeoutExpired:
            raise TransportError() from None
        if result.returncode:
            raise TransportError(
                result.returncode in (5, 6, 7, 18, 28, 52, 55, 56)
            )
        if len(result.stdout) > MAX_RESPONSE + 4:
            raise UploadError("Updater response exceeded the size limit.")
        try:
            body, status = result.stdout.rsplit(b"\n", 1)
            status = int(status)
        except (ValueError, TypeError):
            raise TransportError(False) from None
        expected = 201 if method == "POST" and artifact is None else 200
        if status != expected:
            raise ApiError(status)
        try:
            envelope = json.loads(body)
            return envelope["data"]
        except (ValueError, TypeError, KeyError):
            raise TransportError() from None


def retry(call, sleep):
    for attempt in range(ATTEMPTS):
        try:
            return call()
        except (TransportError, ApiError) as error:
            if not error.retryable or attempt == ATTEMPTS - 1:
                raise
            sleep(attempt + 1)
    raise TransportError(False)


def validate_app(app, info: dict, size: int) -> None:
    if not isinstance(app, dict):
        raise UploadError("Invalid application response.")
    identifier(app.get("id"))
    expected = {
        "bundle_id": info["CFBundleIdentifier"],
        "public_key": info["SUPublicEDKey"],
        "feed_url": info["SUFeedURL"],
    }
    if any(app.get(key) != value for key, value in expected.items()):
        raise UploadError(
            "Token application, Sparkle public key or feed does not match this build."
        )
    if app.get("publication_pending") is not False:
        raise UploadError("Publication is pending; resolve it in the admin first.")
    limit = app.get("upload_max_bytes")
    if type(limit) is not int or not 0 < limit <= MAX_FILE or size > limit:
        raise UploadError("Artifact exceeds the server upload limit.")


def select_app(apps, info: dict, size: int) -> dict:
    if not isinstance(apps, list):
        raise UploadError("Invalid application list response.")
    matches = [
        app
        for app in apps
        if isinstance(app, dict)
        and app.get("bundle_id") == info["CFBundleIdentifier"]
        and app.get("public_key") == info["SUPublicEDKey"]
        and app.get("feed_url") == info["SUFeedURL"]
    ]
    if len(matches) != 1:
        raise UploadError(
            "Token must expose exactly one application matching this signed build."
        )
    validate_app(matches[0], info, size)
    return matches[0]


def validate_release(release, app_id: int, metadata: dict, artifact: dict, release_id=None) -> bool:
    if not isinstance(release, dict):
        raise UploadError("Invalid release response.")
    release_identifier = identifier(release.get("id"))
    identifier(release.get("revision"))
    if release_id is not None and release_identifier != release_id:
        raise UploadError("Release ID changed; manual resolution required.")
    if release.get("application_id") != app_id or any(
        release.get(key) != value for key, value in metadata.items()
    ):
        raise UploadError("Release metadata changed; refusing to overwrite it.")
    state = release.get("state")
    if state not in ("draft", "published"):
        raise UploadError("Release state requires manual resolution.")
    if "artifact" not in release:
        raise UploadError("Missing artifact state in API response.")
    remote = release["artifact"]
    if remote is None:
        if state == "published":
            raise UploadError("Published release is missing its verified artifact.")
        return False
    # The Go updater normalizes stored filenames to lowercase. The older API
    # preserves the submitted name. Both identify the same immutable bytes.
    names = (artifact["original_name"], artifact["original_name"].lower())
    fields = ("type", "size", "sha256", "signature")
    if not isinstance(remote, dict) or remote.get("original_name") not in names or any(
        remote.get(key) != artifact[key] for key in fields
    ):
        raise UploadError("Release contains a different artifact.")
    if not isinstance(remote.get("verified_at"), str) or not remote[
        "verified_at"
    ].strip():
        raise UploadError("Server did not confirm artifact signature verification.")
    return True


def upload(api, info: dict, metadata: dict, artifact: dict, sleep=time.sleep):
    apps = retry(lambda: api.request("GET", "/apps"), sleep)
    app = select_app(apps, info, artifact["size"])
    app_id = app["id"]
    key = "honkpass-" + hashlib.sha256(
        canonical(
            {"app": app_id, "metadata": metadata, "sha256": artifact["sha256"]}
        )
    ).hexdigest()
    base = f"/apps/{app_id}"
    release = retry(
        lambda: api.request(
            "POST", base + "/releases", metadata=metadata, key=key
        ),
        sleep,
    )
    validate_release(release, app_id, metadata, artifact)
    release_id = release["id"]
    route = base + f"/releases/{release_id}"

    def current():
        value = retry(lambda: api.request("GET", route), sleep)
        validate_release(value, app_id, metadata, artifact, release_id)
        return value

    release = current()
    for attempt in range(ATTEMPTS):
        if validate_release(release, app_id, metadata, artifact, release_id):
            return app_id, release
        fresh_app = retry(lambda: api.request("GET", base), sleep)
        validate_app(fresh_app, info, artifact["size"])
        if fresh_app["id"] != app_id:
            raise UploadError("Application ID changed.")
        try:
            response = api.request(
                "POST",
                route + "/artifact",
                artifact=artifact,
                revision=release["revision"],
            )
        except (TransportError, ApiError) as error:
            if isinstance(error, ApiError) and error.status in (409, 422):
                release = current()
                if validate_release(
                    release, app_id, metadata, artifact, release_id
                ):
                    return app_id, release
                raise UploadError(
                    "Upload conflict; inspect the draft before retrying."
                ) from None
            if not error.retryable:
                raise
            sleep(attempt + 1)
            release = current()
            if validate_release(release, app_id, metadata, artifact, release_id):
                return app_id, release
            if attempt == ATTEMPTS - 1:
                raise error
        else:
            if not validate_release(
                response, app_id, metadata, artifact, release_id
            ):
                raise UploadError("Upload response lacks a verified artifact.")
            final = current()
            if not validate_release(final, app_id, metadata, artifact, release_id):
                raise UploadError("Artifact disappeared after upload.")
            return app_id, final
    raise UploadError("Upload attempts exhausted.")


def expected_release_paths(root: Path) -> tuple[Path, Path]:
    distribution = Path(os.environ.get("DISTRIBUTION_DIR", root / ".build/distribution"))
    if not distribution.is_absolute():
        distribution = root / distribution
    directory = Path((distribution / "latest-update.txt").read_text().strip()).resolve()
    if not directory.is_relative_to(distribution.resolve()) or directory == distribution.resolve():
        raise UploadError("Update package must belong to the distribution directory.")
    return directory / "HonkPass.app", directory / "HonkPass.dmg"


def sparkle_signing_options():
    if "HONKPASS_SPARKLE_KEY_FILE" not in os.environ:
        return ["--account", "cz.honklegion.honkpass.sparkle"]
    key_file = os.environ["HONKPASS_SPARKLE_KEY_FILE"]
    if not key_file or not Path(key_file).is_file():
        raise UploadError("The configured Sparkle key file is missing.")
    return ["--ed-key-file", key_file]


def prepare(root: Path, directory: Path, notes_file: str):
    app, source = expected_release_paths(root)
    feed = source.parent / "appcast.xml"
    verify(root, app)
    manifest = json.loads((source.parent / "update-manifest.json").read_text())
    for name in ("HonkPass.dmg", "HonkPass-source.tar.gz"):
        with (source.parent / name).open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != manifest[name]:
                raise UploadError("Update package changed after signing.")
    checked(["fish", "--no-config", str(root / "scripts/source-python.fish"),
             str(root / "support/release_source.py"), str(app), str(source.parent / "HonkPass-source.tar.gz")])
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    notes = Path(notes_file).read_text(encoding="utf-8").strip() if notes_file else ""
    metadata = {
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "minimum_macos": info["LSMinimumSystemVersion"],
        "notes": notes,
    }
    if (
        len(notes.encode()) > 50_000
        or len(canonical(metadata)) > 65_536
        or not 0 < len(metadata["version"]) <= 64
        or BUILD_PATTERN.fullmatch(metadata["build"]) is None
    ):
        raise UploadError("Release metadata is invalid or exceeds API limits.")
    if not 0 < source.stat().st_size <= MAX_FILE:
        raise UploadError("DMG exceeds the supported size limit.")

    snapshot = directory / "HonkPass.dmg"
    shutil.copyfile(source, snapshot)
    size = snapshot.stat().st_size
    with snapshot.open("rb") as stream:
        sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    verify_appcast(info, size, feed.read_bytes())
    actual = ET.parse(feed).find("channel/item/enclosure")
    if actual is None:
        raise UploadError("Appcast has no enclosure.")
    signature = actual.attrib[f"{{{SPARKLE}}}edSignature"]
    expected = ET.fromstring(make_appcast(info, signature, size)).find(
        "channel/item/enclosure"
    )
    if expected is None or actual.attrib != expected.attrib:
        raise UploadError("Appcast does not match this build.")

    checked(["codesign", "--verify", "--deep", "--strict", str(app)])
    checked(["codesign", "--verify", "--strict", str(snapshot)])
    details = checked_details(["codesign", "-dv", "--verbose=4", str(app)])
    if b"Authority=Developer ID Application:" not in details or not re.search(
        rb"flags=.*\bruntime\b", details
    ):
        raise UploadError("HonkPass lacks Developer ID or Hardened Runtime.")
    checked(["xcrun", "stapler", "validate", str(app)])
    checked(["xcrun", "stapler", "validate", str(snapshot)])
    checked(["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)])
    sparkle = checked(["fish", str(root / "scripts/sparkle-tools.fish")]).decode().strip()
    signing_options = sparkle_signing_options()
    if info.get("SURequireSignedFeed") is True:
        checked(
            [
                str(Path(sparkle) / "bin/sign_update"),
                *signing_options,
                "--verify",
                str(feed),
            ]
        )
    checked(
        [
            str(Path(sparkle) / "bin/sign_update"),
            *signing_options,
            "--verify",
            str(snapshot),
            signature,
        ]
    )
    if info["CFBundleIdentifier"] != BUNDLE_ID or info["SUFeedURL"] != FEED:
        raise UploadError("Unexpected signed application identity.")
    if info["SUPublicEDKey"] != public_key(root):
        raise UploadError("Unexpected signed Sparkle public key.")
    return info, metadata, {
        "path": snapshot,
        "original_name": "HonkPass.dmg",
        "type": "dmg",
        "size": size,
        "sha256": sha256,
        "signature": signature,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Upload a verified draft; publish manually in HonkLegion Admin."
    )
    parser.add_argument(
        "--notes-file", default="", help="Markdown notes; omitted means empty notes."
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        with tempfile.TemporaryDirectory(prefix="honkpass-upload-") as temp:
            info, metadata, artifact = prepare(root, Path(temp), args.notes_file)
            app_id, release = upload(
                CurlAPI(load_token()), info, metadata, artifact
            )
            print(
                f"HonkPass {metadata['version']} (build {metadata['build']}), "
                f"release ID {release['id']}."
            )
            if release["state"] == "published":
                print("This exact release is already published; nothing changed.")
            else:
                print("Verified draft uploaded. Publication remains MANUAL.")
            print(f"https://admin.honklegion.cz/manage/updates?id={app_id}")
    except UploadError as error:
        print(f"Upload stopped: {error}", file=sys.stderr)
        return 1
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        ET.ParseError,
        subprocess.SubprocessError,
    ):
        print(
            "Upload stopped: invalid local input or verification failure.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
