#!/usr/bin/env fish
# Fetches the source of the reference: bitwarden/clients at the tag of Bitwarden desktop 2026.10.4.
# DesignKit retains attributed colors, Inter, translations and selected illustrations from it.
# HonkPass controls and SF Symbols follow the product direction in AGENTS.md.
# Output: .local-dependencies/bitwarden-clients. Nothing from it is tracked except what
# support/generate-design-kit.py writes into Sources/DesignKit.
set -l root (path resolve (path dirname (status filename))/..)
set -l source "$root/.local-dependencies/bitwarden-clients"
set -l tag desktop-v2026.10.4
set -gx GIT_CONFIG_GLOBAL /dev/null
set -gx GIT_CONFIG_SYSTEM /dev/null
set -gx GIT_TERMINAL_PROMPT 0

# Desktop and browser translations plus shared resources supply the retained attributed assets.
set -l parts apps/desktop apps/browser libs
if test -d "$source/.git"
    # An older checkout lacks the browser extension: the same revision, more of its files.
    if not test -d "$source/apps/browser"
        git -C "$source" sparse-checkout set --cone $parts; or exit 1
    end
    # A checkout of an older reference moves to the tag of this one.
    set -l wanted (git -C "$source" rev-parse --quiet --verify "refs/tags/ref-$tag^{commit}" 2>/dev/null)
    if test -z "$wanted"
        git -C "$source" fetch --quiet --depth 1 --filter=blob:none origin "refs/tags/$tag"; or exit 1
        git -C "$source" tag -f "ref-$tag" FETCH_HEAD >/dev/null; or exit 1
        set wanted (git -C "$source" rev-parse "refs/tags/ref-$tag^{commit}")
    end
    if test (git -C "$source" rev-parse HEAD) != "$wanted"
        git -C "$source" checkout --quiet --detach "$wanted"; or exit 1
        echo "Reference source $tag is in $source"
        exit 0
    end
    echo "The reference source exists in $source"
    exit 0
end
mkdir -p "$source"; or exit 1
git -C "$source" init --quiet; or exit 1
git -C "$source" remote add origin https://github.com/bitwarden/clients.git; or exit 1
# Only these parts, and only the files of this one revision.
git -C "$source" sparse-checkout set --cone $parts; or exit 1
git -C "$source" fetch --quiet --depth 1 --filter=blob:none origin "refs/tags/$tag"; or exit 1
git -C "$source" checkout --quiet --detach FETCH_HEAD; or exit 1
echo "Reference source $tag is in $source"
