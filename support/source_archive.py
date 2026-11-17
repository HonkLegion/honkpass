#!/usr/bin/env python3
"""Package the committed project and the source of its actual macOS SDK dependencies."""
import argparse
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import tomllib

from legal import CARGO, CLIENTS, OUTPUT, ROOT, SDK, build_notices, compare_trees, digest, graph, run
from public_source import safe_project_paths, snapshot as public_snapshot, file_inventory


def include_sparkle_source(name):
    # These upstream test archives contain deliberately invalid or unsigned applications.
    # They are not build inputs and prevent notarization when embedded in the source DMG.
    prebuilt = (".zip", ".dmg", ".pkg", ".aar", ".tar", ".tar.gz", ".tar.bz2", ".tar.xz")
    return not (name.startswith("Tests/Resources/") and name.lower().endswith(prebuilt))


def add_bytes(archive, name, data, executable=False):
    info = tarfile.TarInfo("HonkPass-source/" + name)
    info.size = len(data)
    info.mode = 0o755 if executable else 0o644
    info.mtime = 0
    archive.addfile(info, io.BytesIO(data))


def git_snapshot(directory, revision, included):
    paths = run("git", "ls-tree", "-r", "--name-only", "-z", revision, cwd=directory).split("\0")[:-1]
    paths = [name for name in paths if included(name)]
    # Fetch only selected blobs in the sparse reference checkout. Bound the argument size.
    for start in range(0, len(paths), 300):
        raw = subprocess.check_output(["git", "archive", "--format=tar", revision, "--", *paths[start:start + 300]], cwd=directory)
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as snapshot:
            for entry in snapshot:
                if entry.issym() or entry.islnk():
                    raise ValueError(f"Source archive does not follow links: {entry.name}")
                if entry.isfile():
                    yield entry.name, snapshot.extractfile(entry).read(), bool(entry.mode & 0o111)


def create_archive(output):
    if output.exists():
        raise ValueError("The output already exists. Choose a new archive path.")
    if run("git", "status", "--porcelain", "--untracked-files=normal").strip():
        raise ValueError("Commit or isolate the working changes before packaging source.")
    revision = run("git", "rev-parse", "HEAD").strip()
    project_files = list(public_snapshot(ROOT, revision))
    with tempfile.TemporaryDirectory(prefix="honkpass-source-notices-") as temporary:
        staged = Path(temporary) / "Legal"
        inventory = build_notices(staged)
        compare_trees(staged, OUTPUT)
    packages = graph()
    lock = tomllib.loads((SDK / "Cargo.lock").read_text())
    checksums = {(p["name"], p["version"]): p["checksum"] for p in lock["package"] if "checksum" in p}
    source_files = {}
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".source-", suffix=".tar.gz", delete=False) as handle:
        pending = Path(handle.name)
    try:
        with tarfile.open(pending, "w:gz") as archive:
            def put(name, data, executable=False):
                add_bytes(archive, name, data, executable)
                source_files[name] = digest(data)

            for name, data, executable in project_files:
                put("project/" + name, data, executable)

            # The GPL SDK sources are pristine at the pinned revision. The project contains
            # the exact patch applied for the binary. Commercial-only source is excluded.
            sdk_revision = inventory["sdk_revision"]
            for name, data, executable in git_snapshot(SDK, sdk_revision, lambda n: "bitwarden_license" not in Path(n).parts):
                put("third-party/bitwarden-sdk/" + name, data, executable)

            git_sources = {}
            for package in packages:
                source = package.get("source") or ""
                if source.startswith("registry+"):
                    name = f"{package['name']}-{package['version']}.crate"
                    candidates = list((CARGO / "registry/cache").glob("*/" + name))
                    if len(candidates) != 1:
                        raise ValueError(f"Missing or ambiguous dependency source: {name}")
                    data = candidates[0].read_bytes()
                    if digest(data) != checksums[(package["name"], package["version"])]:
                        raise ValueError(f"Dependency source checksum mismatch: {name}")
                    put("third-party/crates/" + name, data)
                elif source.startswith("git+"):
                    base = Path(package["manifest_path"]).parent
                    top = Path(run("git", "rev-parse", "--show-toplevel", cwd=base).strip())
                    commit = source.rsplit("#", 1)[1]
                    if run("git", "rev-parse", "HEAD", cwd=top).strip() != commit or run("git", "diff", "HEAD", cwd=top).strip():
                        raise ValueError("A Git dependency differs from its pinned revision.")
                    git_sources[(str(top), commit)] = source
            for (directory, commit), source in sorted(git_sources.items()):
                for name, data, executable in git_snapshot(Path(directory), commit, lambda _: True):
                    put(f"third-party/git/{commit}/" + name, data, executable)

            sparkle_revision = "ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a"
            for name, data, executable in git_snapshot(ROOT / ".build/checkouts/Sparkle", sparkle_revision, include_sparkle_source):
                put("third-party/sparkle/" + name, data, executable)

            # Preferred source inputs for the generated/converted visual resources.
            prefixes = (
                "libs/components/src/tw-theme.css", "libs/components/src/theme.css",
                "libs/components/src/webfonts/", "libs/angular/src/scss/bwicons/",
                "libs/angular/src/billing/images/cards/", "libs/assets/src/svg/",
                "apps/browser/src/_locales/en/", "apps/browser/src/_locales/cs/",
                "apps/desktop/src/locales/en/", "apps/desktop/src/locales/cs/",
                "apps/desktop/macos/autofill-extension/en.lproj/", "apps/desktop/macos/autofill-extension/cs.lproj/",
                "LICENSE",
            )
            clients_revision = run("git", "rev-parse", "HEAD", cwd=CLIENTS).strip()
            for name, data, executable in git_snapshot(CLIENTS, clients_revision, lambda n: n.startswith(prefixes)):
                put("third-party/bitwarden-clients/" + name, data, executable)

            version = re.search(r"MARKETING_VERSION: (\S+)", (ROOT / "project.yml").read_text())[1]
            build = re.search(r"CURRENT_PROJECT_VERSION: (\S+)", (ROOT / "project.yml").read_text())[1]
            manifest = {"schema": 1, "project_revision": revision, "version": version, "build": build,
                        "public_project_files": file_inventory(project_files),
                        "sdk_revision": sdk_revision, "clients_revision": clients_revision,
                        "sparkle_revision": sparkle_revision,
                        "sparkle_source_note": "Prebuilt test application and installer archives under Tests/Resources are excluded. "
                                               "Source files, build inputs, test code and license notices are retained.",
                        "sdk_patch_sha256": inventory["sdk_patch_sha256"],
                        "inventory_sha256": digest((OUTPUT / "inventory.json").read_bytes()),
                        "git_dependencies": list(git_sources.values()), "files": source_files,
                        "build_instructions": "project/README.md#distribution",
                        "bootstrap_note": "The standard build downloads the full pinned SDK checkout for Cargo workspace metadata. "
                                          "This archive includes its GPL source and excludes unused commercial-only modules. "
                                          "The project supplies the applied SDK patch. Rust and Xcode toolchains are separate prerequisites."}
            add_bytes(archive, "source-manifest.json", (json.dumps(manifest, indent=2) + "\n").encode())
        if run("git", "rev-parse", "HEAD").strip() != revision or run("git", "status", "--porcelain").strip():
            raise ValueError("The project changed during source packaging. The archive was not published.")
        pending.replace(output)
        print(f"OK: source revision {revision}, {len(packages)} SDK/build dependencies, {len(source_files)} files.")
    finally:
        pending.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    create_archive(args.output.resolve())


if __name__ == "__main__":
    main()
