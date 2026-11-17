#!/usr/bin/env python3
"""Collect offline notices from the exact SDK graph and retained visual resources."""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SDK = ROOT / ".local-dependencies/bitwarden-sdk-source"
CARGO = ROOT / ".local-dependencies/bitwarden-cargo"
CLIENTS = ROOT / ".local-dependencies/bitwarden-clients"
OUTPUT = ROOT / "App/PassVault/Legal"
SUPPLEMENTS = ROOT / "support/legal-supplements"
TARGET = "aarch64-apple-darwin"
NOTICE = re.compile(r"(?i)^(licen[sc]e|copying|copyright|notice|authors)([._-]|$)")


def run(*args, cwd=ROOT):
    env = dict(os.environ, CARGO_HOME=str(CARGO), CARGO_NET_OFFLINE="true")
    return subprocess.check_output(args, cwd=cwd, env=env, text=True)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def graph():
    metadata = json.loads(run("cargo", "metadata", "--locked", "--offline", "--format-version", "1",
                              "--filter-platform", TARGET, cwd=SDK))
    selected = set()
    for package in ("bitwarden-uniffi", "uniffi-bindgen"):
        tree = run("cargo", "tree", "--locked", "--offline", "--target", TARGET, "-p", package,
                   "--edges", "normal,build", "--prefix", "none", "--format", "{p}", cwd=SDK)
        selected.update(re.findall(r"^([^ ]+) v([^ \n]+)", tree, re.M))
    packages = [p for p in metadata["packages"] if (p["name"], p["version"]) in selected]
    if len(packages) != len(selected):
        raise ValueError("The dependency graph contains ambiguous or missing package identities.")
    for p in packages:
        if "/bitwarden_license/" in p["manifest_path"] or not p["license"]:
            raise ValueError(f"Unreviewed or commercial dependency: {p['name']}")
    return sorted(packages, key=lambda p: (p["name"], p["version"]))


def notice_files(package):
    base = Path(package["manifest_path"]).parent
    if base.is_relative_to(SDK):
        return [SDK / "LICENSE", SDK / "LICENSE_GPL.txt"]
    files = {f for f in base.rglob("*") if f.is_file() and NOTICE.match(f.name)}
    if package.get("license_file"):
        files.add(base / package["license_file"])
    if (package.get("source") or "").startswith("git+"):
        top = Path(run("git", "rev-parse", "--show-toplevel", cwd=base).strip())
        files.update(f for f in top.iterdir() if f.is_file() and NOTICE.match(f.name))
    if package["name"].startswith("uniffi"):
        files.add(SUPPLEMENTS / "MPL-2.0.txt")
    fallback = {
        "blake2b_simd": "blake2b_simd-MIT.txt",
        "credential-exchange-format": "credential-exchange-format-MIT.txt",
        "block-modes": "Apache-2.0.txt",
        "pretty-lint": "MIT.txt",
    }
    if package["name"] in fallback:
        files.add(SUPPLEMENTS / fallback[package["name"]])
    if not files:
        raise ValueError(f"No license text for {package['name']} {package['version']}")
    return sorted(files)


def build_notices(destination):
    packages = graph()
    destination.mkdir(parents=True, exist_ok=True)
    texts = destination / "texts"
    texts.mkdir()
    origins = json.loads((SUPPLEMENTS / "sources.json").read_text())
    for name, origin in origins.items():
        if digest((SUPPLEMENTS / name).read_bytes()) != origin["sha256"]:
            raise ValueError(f"Supplement changed without provenance: {name}")

    def copy_notice(path):
        data = path.read_bytes()
        # Retain the original bytes, including copyright and nested third-party notices.
        name = digest(data) + (".html" if path.suffix == ".html" else ".txt")
        (texts / name).write_bytes(data)
        return {"name": path.name, "path": "texts/" + name, "sha256": digest(data)}

    components = []
    for p in packages:
        notices = [copy_notice(f) for f in notice_files(p)]
        component = {k: p[k] for k in ("name", "version", "license", "authors", "repository", "source")}
        component["notices"] = list({n["path"]: n for n in notices}.values())
        if Path(p["manifest_path"]).is_relative_to(SDK):
            component["selected_license"] = "GPL-3.0-only"
            component["note"] = ("HonkPass applies support/patches/bitwarden-sdk-macos.patch, introduced on 2026-11-12. "
                                 "The patch adds macOS vault bindings and disables SDK HTTP redirects. "
                                 "The source archive includes the original SDK and the exact patch.")
        if p["name"] == "pretty-lint":
            component["note"] = ("Upstream declares MIT and author tamasfe in Cargo.toml, but supplies no license file or copyright notice. "
                                 "The linked MIT text is the standard SPDX template, not an invented upstream copyright statement.")
        if p["name"] == "block-modes":
            component["selected_license"] = "Apache-2.0"
        components.append(component)

    sdk_revision = run("git", "rev-parse", "HEAD", cwd=SDK).strip()
    expected = re.search(r"set -l revision ([0-9a-f]{40})", (ROOT / "support/prepare-bitwarden-sdk.fish").read_text())[1]
    if sdk_revision != expected:
        raise ValueError("SDK source revision differs from the build script.")
    sdk_diff = run("git", "diff", "--no-ext-diff", cwd=SDK)
    if sdk_diff != (ROOT / "support/patches/bitwarden-sdk-macos.patch").read_text():
        raise ValueError("SDK source differs from the reviewed patch.")

    rust_root = Path(run("rustc", "--print", "sysroot", cwd=SDK).strip())
    rust_notice = rust_root / "share/doc/rust/COPYRIGHT-library.html"
    extras = [
        {"name": "HonkPass", "license": "GPL-3.0-only", "authors": ["HonkPass contributors"],
         "note": "Copyright 2026 HonkPass contributors. The goose-key artwork originated in the original HonkPass project, as confirmed by its owner on 2026-11-15.",
         "notices": [copy_notice(ROOT / "LICENSE")]},
        {"name": "Bitwarden client resources", "version": run("git", "rev-parse", "HEAD", cwd=CLIENTS).strip(),
         "license": "GPL-3.0-only", "authors": ["Bitwarden Inc. and contributors"],
         "repository": "https://github.com/bitwarden/clients", "notices": [copy_notice(CLIENTS / "LICENSE.txt"), copy_notice(CLIENTS / "LICENSE_GPL.txt")],
         "note": "From desktop-v2026.10.4. HonkPass adapts colors, icons, illustrations, localization and interface components. "
                 "Interface icons use macOS SF Symbols. The legacy icon font is not bundled. "
                 "Generators and source references describe the changes. Modifications date from 2026-11-12 onward. "
                 "Trademarks remain with their respective owners. HonkPass is not affiliated with Bitwarden Inc."},
        {"name": "Inter", "license": "OFL-1.1", "authors": ["The Inter Project Authors"],
         "notices": [copy_notice(ROOT / "Sources/DesignKit/Resources/Fonts/Inter-LICENSE.txt")]},
        {"name": "Public Suffix List", "license": "MPL-2.0", "repository": "https://publicsuffix.org/list/",
         "note": "Version 2025-04-26_17-35-43_UTC. HonkPass removes comments and normalizes rules with support/generate-public-suffixes.py. "
                 "The modified list remains available under MPL-2.0 and additionally under GPL-3.0-only as part of this combined work.",
         "notices": [copy_notice(SUPPLEMENTS / "MPL-2.0.txt")]},
        {"name": "Rust standard library", "version": run("rustc", "--version", cwd=SDK).strip(),
         "license": "MIT OR Apache-2.0; bundled third-party exceptions in the notice", "notices": [copy_notice(rust_notice)]},
    ]
    sparkle = ROOT / ".build/checkouts/Sparkle"
    sparkle_revision = run("git", "rev-parse", "HEAD", cwd=sparkle).strip()
    if sparkle_revision != "ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a":
        raise ValueError("Sparkle differs from its pinned revision. Run swift package resolve.")
    extras.append({"name": "Sparkle", "version": "2.9.6",
                   "license": "MIT; bundled BSD and zlib notices",
                   "repository": "https://github.com/sparkle-project/Sparkle",
                   "source": "git+https://github.com/sparkle-project/Sparkle#" + sparkle_revision,
                   "notices": [copy_notice(sparkle / "LICENSE")],
                   "note": "The official Swift Package Manager archive has SHA-256 "
                           "8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606. "
                           "Sparkle performs update signature validation. HonkPass implements no update cryptography."})
    asset_hashes = {}
    for directory in ("Sources/DesignKit/Resources", "Sources/VaultModel/Resources", "App/PassVault/AppIcon.icon"):
        for path in sorted((ROOT / directory).rglob("*")):
            if path.is_file() and path.name != ".DS_Store":
                asset_hashes[str(path.relative_to(ROOT))] = digest(path.read_bytes())
    inventory = {"schema": 1, "target": TARGET, "sdk_revision": sdk_revision,
                 "sdk_patch_sha256": digest(sdk_diff.encode()), "cargo_lock_sha256": digest((SDK / "Cargo.lock").read_bytes()),
                 "supplement_sources": origins, "asset_sha256": asset_hashes, "components": extras + components}
    (destination / "inventory.json").write_text(json.dumps(inventory, indent=2, ensure_ascii=False) + "\n")
    (destination / "GPL-3.0.txt").write_bytes((ROOT / "LICENSE").read_bytes())
    for language in ("en", "cs"):
        write_index(destination, inventory, language)
    return inventory


def write_index(destination, inventory, language):
    title = "Licence a zdrojové kódy" if language == "cs" else "Licenses and source code"
    intro = ("HonkPass je svobodný software pod GPLv3. Můžete jej upravovat a dále šířit podle této licence. "
             "Aplikace se poskytuje bez záruky v rozsahu dovoleném zákonem. HonkPass není produktem společnosti Bitwarden Inc. ani s ní není spojen."
             if language == "cs" else
             "HonkPass is free software under GPLv3. You can modify and redistribute it under that license. "
             "The app comes without warranty to the extent permitted by law. HonkPass is not affiliated with Bitwarden Inc.")
    source = ("Odpovídající zdrojové kódy, závislosti, patche a postup sestavení patří ke stejnému vydání jako aplikace. "
              "Při stažení veřejného vydání najdete archiv zdrojů vedle instalačního balíčku. Původní licenční texty níže zůstávají v angličtině."
              if language == "cs" else
              "The corresponding source, dependencies, patches and build instructions belong to the same release as the app. "
              "Public releases provide the source archive beside the app download. Original license texts appear below.")
    # No scripts, remote styles, images, or automatic network requests.
    parts = [f'<!doctype html><html lang="{language}"><meta charset="utf-8"><meta name="color-scheme" content="light dark">',
             f'<title>HonkPass — {title}</title>',
             '<style>body{font:16px system-ui;max-width:880px;margin:40px auto;padding:0 24px;line-height:1.5}details{margin:12px 0}summary{cursor:pointer}li{margin:6px 0}small{overflow-wrap:anywhere}</style>',
             f'<h1>{title}</h1><p>{html.escape(intro)}</p><p>{html.escape(source)}</p>',
             '<p><a href="GPL-3.0.txt">GNU General Public License v3.0</a> · <a href="inventory.json">Dependency inventory</a></p>']
    for c in inventory["components"]:
        label = c["name"] + (" " + c["version"] if c.get("version") else "")
        parts.append(f'<details><summary>{html.escape(label)}</summary><p>{html.escape(c["license"])}</p>')
        if c.get("authors"):
            parts.append('<p>' + html.escape(", ".join(c["authors"])) + '</p>')
        if c.get("note"):
            parts.append('<p>' + html.escape(c["note"]) + '</p>')
        if c.get("source") or c.get("repository"):
            parts.append('<small>' + html.escape(c.get("source") or c["repository"]) + '</small>')
        parts.append('<ul>')
        for notice in c["notices"]:
            parts.append(f'<li><a href="{notice["path"]}">{html.escape(notice["name"])}</a></li>')
        parts.append('</ul></details>')
    parts.append('</html>')
    (destination / f"index-{language}.html").write_text("\n".join(parts) + "\n")


def compare_trees(expected, actual):
    def files(root):
        return {str(p.relative_to(root)): digest(p.read_bytes()) for p in root.rglob("*") if p.is_file()}
    if files(expected) != files(actual):
        raise ValueError("License resources are stale. Run make licenses and review the changes.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["generate", "check"])
    args = parser.parse_args()
    # Generate into a fresh directory so failures leave the current notices intact.
    with tempfile.TemporaryDirectory(prefix="honkpass-licenses-") as temporary:
        staging = Path(temporary) / "Legal"
        inventory = build_notices(staging)
        if args.action == "check":
            compare_trees(staging, OUTPUT)
        else:
            import shutil
            OUTPUT.mkdir(parents=True, exist_ok=True)
            for p in staging.rglob("*"):
                if p.is_file():
                    target = OUTPUT / p.relative_to(staging)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(p, target)
            # Remove only obsolete generated notice files, never user assets.
            valid = {p.name for p in (staging / "texts").iterdir()}
            for p in (OUTPUT / "texts").iterdir():
                if re.fullmatch(r"[0-9a-f]{64}\.(txt|html)", p.name) and p.name not in valid:
                    p.unlink()
        print(f"OK: {len(inventory['components'])} components with offline license notices.")


if __name__ == "__main__":
    main()
