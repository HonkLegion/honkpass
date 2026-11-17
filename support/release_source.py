#!/usr/bin/env python3
"""Bind a signed app to its exact source archive and record release artifact hashes."""
import argparse
import json
from pathlib import Path
import plistlib
import tarfile

from legal import digest
from public_source import POLICY, policy_paths


def verify(app, source):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    source_hash = digest(source.read_bytes())
    if info.get("HonkPassSourceSHA256") != source_hash:
        raise ValueError("The signed app does not match this source archive.")
    with tarfile.open(source, "r:gz") as archive:
        manifest = json.load(archive.extractfile("HonkPass-source/source-manifest.json"))
        if (info.get("HonkPassSourceRevision") != manifest["project_revision"]
                or info["CFBundleShortVersionString"] != manifest["version"]
                or info["CFBundleVersion"] != manifest["build"]):
            raise ValueError("Source revision or version differs from the signed app.")
        actual = {}
        project_files = {}
        seen = set()
        for member in archive:
            if member.isdir():
                continue
            if not member.isfile() or not member.name.startswith("HonkPass-source/") or ".." in Path(member.name).parts:
                raise ValueError("Invalid source archive member.")
            name = member.name.removeprefix("HonkPass-source/")
            if name in seen:
                raise ValueError("Duplicate source archive member.")
            seen.add(name)
            if name == "source-manifest.json":
                continue
            actual[name] = digest(archive.extractfile(member).read())
            if name.startswith("project/"):
                project_files[name.removeprefix("project/")] = {
                    "sha256": actual[name], "executable": bool(member.mode & 0o111)}
        if actual != manifest["files"]:
            raise ValueError("Source archive contents differ from its manifest.")
        if "public_project_files" in manifest:
            if project_files != manifest["public_project_files"]:
                raise ValueError("Source archive differs from the public project inventory.")
            try:
                policy = archive.extractfile("HonkPass-source/project/" + POLICY).read()
            except KeyError:
                raise ValueError("Source archive is missing the public source list.") from None
            if set(project_files) != policy_paths(policy):
                raise ValueError("Source archive contains unlisted project files.")
    legal = app / "Contents/Resources/Legal"
    if digest((legal / "inventory.json").read_bytes()) != manifest["inventory_sha256"]:
        raise ValueError("The app license inventory differs from the source inventory.")
    inventory = json.loads((legal / "inventory.json").read_text())
    for component in inventory["components"]:
        for notice in component["notices"]:
            relative = Path(notice["path"])
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Invalid notice path.")
            if digest((legal / relative).read_bytes()) != notice["sha256"]:
                raise ValueError("A bundled license notice is missing or changed.")
    for required in ("index-en.html", "index-cs.html", "GPL-3.0.txt"):
        if not (legal / required).is_file():
            raise ValueError(f"Missing bundled legal resource: {required}")
        expected = manifest["files"].get("project/App/PassVault/Legal/" + required)
        if digest((legal / required).read_bytes()) != expected:
            raise ValueError(f"Bundled legal resource differs from source: {required}")
    return {"version": manifest["version"], "build": manifest["build"],
            "source_revision": manifest["project_revision"], "source_sha256": source_hash}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("--binary-zip", type=Path)
    parser.add_argument("--record", type=Path)
    args = parser.parse_args()
    result = verify(args.app, args.source)
    if args.record:
        if not args.binary_zip:
            parser.error("--record requires --binary-zip")
        result.update(source_file=args.source.name, binary_file=args.binary_zip.name,
                      binary_sha256=digest(args.binary_zip.read_bytes()))
        args.record.write_text(json.dumps(result, indent=2) + "\n")
    print("OK: signed app, licenses and corresponding source agree.")


if __name__ == "__main__":
    main()
