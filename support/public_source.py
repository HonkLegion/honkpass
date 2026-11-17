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


def export(root, revision, destination, tag):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?", tag):
        raise ValueError("Use a release tag such as v1.2.3.")
    revision = git(root, "rev-parse", "--verify", revision + "^{commit}").decode().strip()
    files = list(snapshot(root, revision))
    spec = next(data for name, data, _ in files if name == "project.yml").decode()
    version = re.search(r"^    MARKETING_VERSION: (\S+)$", spec, re.M)
    build = re.search(r"^    CURRENT_PROJECT_VERSION: (\S+)$", spec, re.M)
    if not version or not build or tag not in {"v" + version[1], "v" + version[1] + "+" + build[1]}:
        raise ValueError("The release tag does not match project.yml.")
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    for name, data, executable in files:
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755 if executable else 0o644)
    metadata = {"schema": 1, "tag": tag, "version": version[1], "build": build[1],
                "source_revision": revision, "files": file_inventory(files)}
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
        if (set(metadata) != {"schema", "tag", "version", "build", "source_revision", "files"}
                or metadata.get("schema") != 1 or metadata.get("files") != file_inventory(files)
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
