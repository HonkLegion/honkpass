#!/usr/bin/env python3
"""Prepare explicit release assets and create an immutable GitHub draft."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "support"))
from public_source import git, project_identity, release_tag, verify_public_history
import upload_release

REPOSITORY = "HonkLegion/honkpass"
ASSETS = {"HonkPass.dmg", "HonkPass-notarized.zip", "HonkPass-source.tar.gz", "appcast.xml",
          "release-manifest.json", "update-manifest.json"}
MANIFEST = "github-release.json"


def digest(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Release assets must be regular files.")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def identity(root, tag):
    version, explicit_build = release_tag(tag)
    revision = git(root, "rev-parse", "HEAD").decode().strip()
    if git(root, "rev-parse", "refs/tags/" + tag + "^{commit}").decode().strip() != revision:
        raise ValueError("The requested tag does not identify this checkout.")
    verify_public_history(root, revision)
    metadata = json.loads((root / "public-source.json").read_text())
    if (metadata["tag"] != tag or metadata["version"] != version
            or explicit_build not in (None, metadata["build"])
            or project_identity((root / "project.yml").read_bytes()) != (version, metadata["build"])
            or git(root, "status", "--porcelain").strip()):
        raise ValueError("The release checkout differs from its published tag or metadata.")
    return {"tag": tag, "version": version, "build": metadata["build"], "source_revision": revision}


def collect(root, tag, destination):
    expected = identity(root, tag)
    distribution = Path(os.environ.get("DISTRIBUTION_DIR", str(root / ".build/distribution"))).resolve()
    with tempfile.TemporaryDirectory(prefix="honkpass-ci-verification-") as temporary:
        # Use the same notarization, signature and source checks as the existing updater.
        _, metadata, artifact = upload_release.prepare(root, Path(temporary), "")
        if (metadata["version"], metadata["build"]) != (expected["version"], expected["build"]):
            raise ValueError("The signed package differs from the release tag.")
        _, dmg = upload_release.expected_release_paths(root)
        notarized = Path((distribution / "latest-notarized.txt").read_text().strip()).resolve()
        # Notarization logs can live under .build/logs rather than DISTRIBUTION_DIR.
        if not notarized.is_relative_to((root / ".build").resolve()):
            raise ValueError("The notarization output is outside the build directory.")
        record = json.loads((notarized / "release-manifest.json").read_text())
        if (record["source_revision"] != expected["source_revision"]
                or record["version"] != expected["version"] or record["build"] != expected["build"]
                or record["binary_sha256"] != digest(notarized / "HonkPass-notarized.zip")
                or record["source_sha256"] != digest(dmg.parent / "HonkPass-source.tar.gz")
                or artifact["sha256"] != digest(dmg)):
            raise ValueError("The ZIP, DMG and source archive do not describe the same release.")
        destination.mkdir(parents=True, exist_ok=False)
        for name in sorted(ASSETS):
            source = notarized / name if name in {"HonkPass-notarized.zip", "release-manifest.json"} else dmg.parent / name
            digest(source)
            shutil.copyfile(source, destination / name)
    expected["files"] = {name: {"sha256": digest(destination / name), "size": (destination / name).stat().st_size}
                         for name in sorted(ASSETS)}
    (destination / MANIFEST).write_text(json.dumps(expected, indent=2) + "\n")
    validate_assets(destination, expected)
    print("OK: the release directory contains only the verified distribution assets.")


def validate_assets(directory, expected):
    names = {path.name for path in directory.iterdir()}
    if names != ASSETS | {MANIFEST} or set(expected.get("files", {})) != ASSETS:
        raise ValueError("The release directory contains missing or unexpected files.")
    for name, details in expected["files"].items():
        path = directory / name
        if details != {"sha256": digest(path), "size": path.stat().st_size}:
            raise ValueError("A release asset changed after verification.")
    return {name: {"sha256": digest(directory / name), "size": (directory / name).stat().st_size} for name in names}


def gh(*args):
    result = subprocess.run(["gh", *args], env=dict(os.environ, GH_HOST="github.com"),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    if result.returncode:
        raise ValueError("GitHub rejected the release operation. No existing asset was replaced.")
    return result.stdout


def missing_assets(remote, files, tag):
    if remote.get("tag_name") != tag:
        raise ValueError("GitHub returned a different release tag.")
    assets = remote.get("assets", [])
    by_name = {asset["name"]: asset for asset in assets}
    if len(by_name) != len(assets) or set(by_name) - files.keys():
        raise ValueError("The GitHub release contains unexpected assets.")
    for name, asset in by_name.items():
        if asset.get("size") != files[name]["size"] or asset.get("digest") != "sha256:" + files[name]["sha256"]:
            raise ValueError("The GitHub release contains different bytes. Existing assets are immutable.")
    missing = files.keys() - by_name.keys()
    if missing and remote.get("draft") is not True:
        raise ValueError("A published release is incomplete. Automatic changes are not permitted.")
    return sorted(missing)


def draft(root, tag, directory):
    expected = identity(root, tag)
    digest(directory / MANIFEST)
    manifest = json.loads((directory / MANIFEST).read_text())
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise ValueError("Downloaded assets belong to another release.")
    files = validate_assets(directory, manifest)
    route = f"repos/{REPOSITORY}/releases"
    pages = json.loads(gh("api", "--paginate", "--slurp", route + "?per_page=100"))
    matches = [release for page in pages for release in page if release["tag_name"] == tag]
    if len(matches) > 1:
        raise ValueError("Multiple GitHub releases use this tag.")
    if matches:
        remote = matches[0]
    else:
        notes = ("Native macOS client for Vaultwarden.\n\n"
                 "Download the DMG or ZIP to install HonkPass. "
                 "HonkPass-source.tar.gz contains the corresponding source and dependency notices. "
                 "The manifests record the source revision and artifact hashes.")
        gh("api", f"repos/{REPOSITORY}/git/ref/tags/{tag}")
        remote = json.loads(gh("api", "--method", "POST", route, "-f", f"tag_name={tag}",
                               "-F", "draft=true", "-f", f"name=HonkPass {expected['version']} ({expected['build']})",
                               "-f", f"body={notes}"))
    release_id = remote.get("id")
    if type(release_id) is not int or release_id <= 0:
        raise ValueError("GitHub did not return a valid release ID.")
    missing = missing_assets(remote, files, tag)
    for name in missing:
        gh("api", "--method", "POST", f"https://uploads.github.com/{route}/{release_id}/assets?name={name}",
           "--header", "Content-Type: application/octet-stream", "--input", str(directory / name))
    remote = json.loads(gh("api", f"{route}/{release_id}"))
    if missing_assets(remote, files, tag):
        raise ValueError("GitHub did not retain every release asset.")
    print("OK: verified GitHub release assets. Publication remains manual.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("preflight", "collect", "draft"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--directory", type=Path, default=ROOT / ".build/github-release")
    args = parser.parse_args()
    try:
        if os.environ.get("GITHUB_REPOSITORY", "").lower() != REPOSITORY.lower():
            raise ValueError("The release workflow is restricted to HonkLegion/honkpass.")
        if args.action == "preflight":
            print("OK: release identity " + json.dumps(identity(ROOT, args.tag)))
        elif args.action == "collect":
            collect(ROOT, args.tag, args.directory)
        else:
            draft(ROOT, args.tag, args.directory)
    except (ValueError, upload_release.UploadError) as error:
        sys.exit(str(error))
    except Exception:
        sys.exit("Release preparation failed. No credentials or command output were logged.")
