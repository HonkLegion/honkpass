#!/usr/bin/env python3
"""Select committed public build inputs before reading their contents."""
import hashlib
import argparse
import io
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

POLICY = "support/public-source-files.txt"
METADATA = "public-source.json"
PRIVATE_PARTS = {".git", ".forgejo", ".gitea", ".codex", ".claude", ".aws", ".ssh", ".gnupg",
                 ".build", ".local-dependencies", "internal", "plans", "backups", "exports"}
PRIVATE_NAMES = {"plan.md", "agents.md", ".env", ".envrc", "local.xcconfig"}
PRIVATE_SUFFIXES = {".pem", ".key", ".p8", ".p12", ".pfx", ".mobileprovision", ".provisionprofile",
                    ".keychain", ".keychain-db", ".kdbx", ".sqlite", ".sqlite3", ".db", ".log"}
VERSION = r"(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})"
BUILD = r"[1-9][0-9]{0,8}"


def release_tag(tag):
    match = re.fullmatch(r"v(" + VERSION + r")(?:\+(" + BUILD + r"))?", tag)
    if not match:
        raise ValueError("Use a release tag such as v1.2.3 or v1.2.3+4.")
    return match[1], match[2]


def project_identity(data):
    text = data.decode("utf-8")
    values = []
    for key, pattern in (("MARKETING_VERSION", VERSION), ("CURRENT_PROJECT_VERSION", BUILD)):
        matches = re.findall(r"^    " + key + r": (\S+)$", text, re.M)
        if len(matches) != 1 or not re.fullmatch(pattern, matches[0]):
            raise ValueError("project.yml must contain one valid version and one integer build number.")
        values.append(matches[0])
    return tuple(values)


def git(root, *args, input=None):
    return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", *args], cwd=root, input=input)


def safe_project_paths(paths):
    for name in paths:
        path = PurePosixPath(name)
        parts = {part.lower() for part in path.parts}
        if (not name or path.is_absolute() or ".." in path.parts or str(path) != name
                or "\\" in name or any(ord(c) < 32 for c in name)
                or parts & PRIVATE_PARTS or path.name.lower() in PRIVATE_NAMES
                or path.name.lower().startswith(".env.") or path.suffix.lower() in PRIVATE_SUFFIXES):
            raise ValueError(f"Protected path cannot enter public source: {name}")


def tree(root, revision):
    entries = {}
    for raw in git(root, "ls-tree", "-rz", "--full-tree", revision).split(b"\0"):
        if raw:
            info, name = raw.split(b"\t", 1)
            mode, kind, oid = info.decode("ascii").split()
            entries[name.decode("utf-8")] = (mode, kind, oid)
    return entries


def policy_paths(data):
    paths = [line for line in data.decode("utf-8").splitlines() if line and not line.startswith("#")]
    safe_project_paths(paths)
    if len(set(paths)) != len(paths) or POLICY not in paths:
        raise ValueError("Public source list must contain unique paths and include itself.")
    return set(paths)


def selected_paths(root, revision):
    entries = tree(root, revision)
    if POLICY not in entries or entries[POLICY][:2] != ("100644", "blob"):
        raise ValueError("Missing regular public source list.")
    allowed = policy_paths(git(root, "cat-file", "blob", entries[POLICY][2]))
    if allowed - entries.keys():
        raise ValueError("Public source list contains missing files: " + ", ".join(sorted(allowed - entries.keys())))
    # New build inputs require an explicit publication decision. Never silently omit them.
    unknown = {name for name in entries if name.split("/", 1)[0] in {"App", "Sources", "Tests", "Config"}} - allowed
    if unknown:
        raise ValueError("Review unlisted build inputs: " + ", ".join(sorted(unknown)))
    for name in allowed:
        if entries[name][0] not in {"100644", "100755"} or entries[name][1] != "blob":
            raise ValueError(f"Public source rejects links and submodules: {name}")
    return sorted(allowed)


def snapshot(root, revision):
    """Read reviewed blob IDs only, without Git pathspec expansion or export attributes."""
    paths = selected_paths(root, revision)
    entries = tree(root, revision)
    for start in range(0, len(paths), 250):
        selected = paths[start:start + 250]
        request = "".join(entries[name][2] + "\n" for name in selected).encode()
        response = io.BytesIO(git(root, "cat-file", "--batch", input=request))
        for name in selected:
            oid, kind, size = response.readline().decode("ascii").strip().split()
            data = response.read(int(size))
            if (oid != entries[name][2] or kind != "blob" or len(data) != int(size)
                    or response.read(1) != b"\n"):
                raise ValueError("Unexpected public source blob response.")
            yield name, data, entries[name][0] == "100755"
        if response.read():
            raise ValueError("Unexpected extra public source blob.")


def file_inventory(files):
    return {name: {"sha256": hashlib.sha256(data).hexdigest(), "executable": executable}
            for name, data, executable in files}


def export(root, revision, destination, tag, *, release_build=None):
    version, explicit_build = release_tag(tag)
    revision = git(root, "rev-parse", "--verify", revision + "^{commit}").decode().strip()
    files = list(snapshot(root, revision))
    spec = next(data for name, data, _ in files if name == "project.yml")
    source_version, source_build = project_identity(spec)
    metadata = {"schema": 1, "tag": tag, "version": version, "source_revision": revision}
    if release_build is None:
        build = source_build
        if version != source_version or explicit_build not in (None, build):
            raise ValueError("The release tag does not match project.yml.")
    else:
        build = release_build
        if not isinstance(build, str) or not re.fullmatch(BUILD, build) or explicit_build not in (None, build):
            raise ValueError("The release build is invalid or differs from the tag.")
        text = spec.decode("utf-8")
        for key, value in (("MARKETING_VERSION", version), ("CURRENT_PROJECT_VERSION", build)):
            text = re.sub(r"(^    " + key + r": )\S+$", lambda match: match[1] + value, text, flags=re.M)
        files = [(name, text.encode() if name == "project.yml" else data, executable)
                 for name, data, executable in files]
        metadata.update(schema=2, source_project={"version": source_version, "build": source_build,
                                                  "sha256": hashlib.sha256(spec).hexdigest()})
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    for name, data, executable in files:
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755 if executable else 0o644)
    metadata.update(build=build, files=file_inventory(files))
    (destination / METADATA).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    return metadata


def verify_public_history(root, revision):
    """Refuse development ancestry, including the existing unfiltered GitHub history."""
    for line in git(root, "rev-list", "--parents", revision).decode().splitlines():
        commit, *parents = line.split()
        if len(parents) > 1:
            raise ValueError("Public history must contain release snapshots without merges.")
        entries = tree(root, commit)
        if METADATA not in entries or entries[METADATA][:2] != ("100644", "blob"):
            raise ValueError("Existing history is not a filtered public history. Migrate it separately.")
        metadata = json.loads(git(root, "cat-file", "blob", entries[METADATA][2]))
        files = list(snapshot(root, commit))
        keys = {"schema", "tag", "version", "build", "source_revision", "files"}
        if metadata.get("schema") == 2:
            keys.add("source_project")
            original = metadata.get("source_project")
            if (not isinstance(original, dict) or set(original) != {"version", "build", "sha256"}
                    or not re.fullmatch(VERSION, str(original.get("version")))
                    or not re.fullmatch(BUILD, str(original.get("build")))
                    or not re.fullmatch(r"[0-9a-f]{64}", str(original.get("sha256")))):
                raise ValueError("Public history contains invalid source provenance.")
        version, explicit_build = release_tag(str(metadata.get("tag")))
        spec = next(data for name, data, _ in files if name == "project.yml")
        if (set(metadata) != keys or type(metadata.get("schema")) is not int or metadata["schema"] not in (1, 2)
                or metadata.get("files") != file_inventory(files)
                or project_identity(spec) != (metadata.get("version"), metadata.get("build"))
                or version != metadata.get("version") or explicit_build not in (None, metadata.get("build"))
                or not re.fullmatch(r"[0-9a-f]{40}", metadata.get("source_revision", ""))
                or set(entries) != {name for name, _, _ in files} | {METADATA}):
            raise ValueError("Public history contains unlisted or changed files.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    metadata = export(Path(__file__).resolve().parents[1], args.revision, args.output, args.tag)
    print(f"OK: exported {len(metadata['files'])} public source files.")
