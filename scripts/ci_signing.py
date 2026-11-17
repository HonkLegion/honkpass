#!/usr/bin/env python3
"""Install release credentials only on an ephemeral GitHub macOS runner."""
import argparse
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
SECRET_NAMES = {"APPLE_CERTIFICATE_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_APP_PROFILE_BASE64",
                "APPLE_PROVIDER_PROFILE_BASE64", "APPLE_NOTARY_KEY_BASE64", "APPLE_NOTARY_KEY_ID",
                "APPLE_NOTARY_ISSUER_ID", "SPARKLE_PRIVATE_KEY", "UPDATER_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"}


class SigningError(Exception):
    pass


def run(*args):
    environment = {key: value for key, value in os.environ.items() if key not in SECRET_NAMES}
    result = subprocess.run(args, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    if result.returncode:
        raise SigningError(f"Credential setup failed in {Path(args[0]).name}. Credential output was suppressed.")
    return result.stdout


def runner_directory():
    if (os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or sys.platform != "darwin" or os.environ.get("RUNNER_ARCH") != "ARM64"):
        raise SigningError("Credential setup requires a GitHub-hosted Apple Silicon runner.")
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    return temporary / "honkpass-signing"


def secret_bytes(name):
    value = os.environ.get(name, "")
    try:
        data = base64.b64decode(value, validate=True)
    except ValueError:
        raise SigningError(f"{name} must contain valid Base64 data.") from None
    if not 0 < len(data) <= 1024 * 1024:
        raise SigningError(f"{name} is empty or exceeds the size limit.")
    return data


def profile_identity(data, team, bundle):
    profile = plistlib.loads(data)
    identifier = profile["UUID"]
    if str(uuid.UUID(identifier)) != identifier.lower():
        raise SigningError("A provisioning profile has an invalid identifier.")
    if profile.get("TeamIdentifier") != [team]:
        raise SigningError("A provisioning profile belongs to a different team.")
    entitlements = profile["Entitlements"]
    if entitlements.get("com.apple.application-identifier", entitlements.get("application-identifier")) != team + "." + bundle:
        raise SigningError("A provisioning profile does not match the application identifier.")
    expiration = profile["ExpirationDate"].replace(tzinfo=timezone.utc)
    if expiration <= datetime.now(timezone.utc):
        raise SigningError("A provisioning profile expired.")
    return identifier


def write_private(path, data):
    with path.open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)


def setup():
    directory = runner_directory()
    missing = sorted(name for name in SECRET_NAMES - {"UPDATER_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"}
                     if not os.environ.get(name))
    if missing:
        raise SigningError("Missing GitHub secrets: " + ", ".join(missing))
    team = os.environ.get("APPLE_TEAM_ID", "")
    key_id = os.environ["APPLE_NOTARY_KEY_ID"]
    issuer = os.environ["APPLE_NOTARY_ISSUER_ID"]
    if not re.fullmatch(r"[A-Z0-9]{10}", team) or not re.fullmatch(r"[A-Za-z0-9]{10,32}", key_id):
        raise SigningError("The Apple team or notary key identifier is invalid.")
    uuid.UUID(issuer)
    sparkle_secret = secret_bytes("SPARKLE_PRIVATE_KEY")
    if len(sparkle_secret) not in (32, 96):
        raise SigningError("SPARKLE_PRIVATE_KEY must contain the existing exported Sparkle key.")
    # All local mutations use fresh runner-owned paths. Never use the developer's Keychain.
    directory.mkdir(mode=0o700)
    keychain = directory / "release.keychain-db"
    state = {"default_keychain": shlex.split(run("security", "default-keychain", "-d", "user").decode())[0],
             "search_list": shlex.split(run("security", "list-keychains", "-d", "user").decode()), "profiles": []}
    state_path = directory / "state.json"
    write_private(state_path, json.dumps(state).encode())
    password = secrets.token_urlsafe(40)
    certificate = directory / "certificate.p12"
    write_private(certificate, secret_bytes("APPLE_CERTIFICATE_BASE64"))
    run("security", "create-keychain", "-p", password, str(keychain))
    run("security", "set-keychain-settings", "-lut", "21600", str(keychain))
    run("security", "unlock-keychain", "-p", password, str(keychain))
    run("security", "import", str(certificate), "-P", os.environ["APPLE_CERTIFICATE_PASSWORD"], "-t", "cert", "-f", "pkcs12",
        "-k", str(keychain), "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain))
    run("security", "list-keychains", "-d", "user", "-s", str(keychain), *state["search_list"])
    run("security", "default-keychain", "-d", "user", "-s", str(keychain))
    identities = run("security", "find-identity", "-v", "-p", "codesigning", str(keychain)).decode()
    matches = re.findall(r'([0-9A-F]{40}) "Developer ID Application: [^\n"]+ \(' + team + r'\)"', identities)
    if len(matches) != 1:
        raise SigningError("The certificate must provide one Developer ID Application identity for the configured team.")
    profiles = {}
    for secret, bundle in (("APPLE_APP_PROFILE_BASE64", "cz.honklegion.honkpass"),
                           ("APPLE_PROVIDER_PROFILE_BASE64", "cz.honklegion.honkpass.provider")):
        source = directory / (secret + ".provisionprofile")
        write_private(source, secret_bytes(secret))
        identifier = profile_identity(run("security", "cms", "-D", "-i", str(source)), team, bundle)
        profiles[bundle] = identifier
        for base in (Path.home() / "Library/MobileDevice/Provisioning Profiles",
                     Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"):
            base.mkdir(parents=True, exist_ok=True)
            target = base / (identifier + ".provisionprofile")
            write_private(target, source.read_bytes())
            state["profiles"].append(str(target))
            state_path.write_text(json.dumps(state))
    local = ROOT / "Config/Local.xcconfig"
    write_private(local, (f"DEVELOPMENT_TEAM = {team}\n"
                         f"HONKPASS_APP_PROFILE = {profiles['cz.honklegion.honkpass']}\n"
                         f"HONKPASS_PROVIDER_PROFILE = {profiles['cz.honklegion.honkpass.provider']}\n").encode())
    state["local_configuration"] = True
    state_path.write_text(json.dumps(state))
    options = directory / "ExportOptions.plist"
    write_private(options, plistlib.dumps({"method": "developer-id", "signingStyle": "manual", "teamID": team,
                                          "signingCertificate": matches[0], "provisioningProfiles": profiles}))
    notary_key = directory / "notary.p8"
    write_private(notary_key, secret_bytes("APPLE_NOTARY_KEY_BASE64"))
    run("xcrun", "notarytool", "store-credentials", "honkpass-ci", "--key", str(notary_key),
        "--key-id", key_id, "--issuer", issuer, "--keychain", str(keychain), "--no-validate")
    sparkle = Path(run("fish", "--no-config", str(ROOT / "scripts/sparkle-tools.fish")).decode().strip())
    private_key = directory / "sparkle-key"
    write_private(private_key, base64.b64encode(sparkle_secret))
    run(str(sparkle / "bin/generate_keys"), "--account", "cz.honklegion.honkpass.sparkle", "-f", str(private_key))
    actual = run(str(sparkle / "bin/generate_keys"), "--account", "cz.honklegion.honkpass.sparkle", "-p").decode().strip()
    public = re.search(r"^HONKPASS_SPARKLE_PUBLIC_KEY = (\S+)$", (ROOT / "Config/Sparkle.xcconfig").read_text(), re.M)[1]
    if actual != public:
        raise SigningError("The Sparkle private key does not match the existing application. Do not generate a replacement key.")
    # sign_update uses the file directly to avoid a Keychain access prompt for a different executable.
    for path in (certificate, notary_key):
        path.unlink()
    with Path(os.environ["GITHUB_ENV"]).open("a") as stream:
        stream.write(f"HONKPASS_CI_SIGNING_IDENTITY={matches[0]}\nHONKPASS_CI_EXPORT_OPTIONS={options}\n"
                     f"HONKPASS_SPARKLE_KEY_FILE={private_key}\nNOTARY_PROFILE=honkpass-ci\n")
    print("OK: ephemeral signing credentials are ready.")


def cleanup():
    directory = runner_directory()
    if not directory.exists():
        return
    state_path = directory / "state.json"
    if state_path.exists():
        state = json.loads(state_path.read_text())
        run("security", "default-keychain", "-d", "user", "-s", state["default_keychain"])
        run("security", "list-keychains", "-d", "user", "-s", *state["search_list"])
        keychain = directory / "release.keychain-db"
        if keychain.exists():
            run("security", "delete-keychain", str(keychain))
        for path in state["profiles"]:
            Path(path).unlink(missing_ok=True)
        if state.get("local_configuration"):
            (ROOT / "Config/Local.xcconfig").unlink(missing_ok=True)
    shutil.rmtree(directory)
    print("OK: ephemeral signing credentials were removed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("setup", "cleanup"))
    action = parser.parse_args().action
    try:
        setup() if action == "setup" else cleanup()
    except SigningError as error:
        sys.exit(str(error))
    except Exception:
        sys.exit("Credential setup or cleanup failed. Credential details were suppressed.")
