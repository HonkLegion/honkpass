#!/usr/bin/env fish
# Build the pinned Bitwarden SDK (bitwarden/sdk-internal) for macOS on Apple Silicon.
# Output: .local-dependencies/BitwardenSdk, a local Swift package that only EngineLive imports.
# Nothing from this build is committed. The script never rebuilds an existing framework.
set -l root (path resolve (path dirname (status filename))/..)
set -l source "$root/.local-dependencies/bitwarden-sdk-source"
set -l package "$root/.local-dependencies/BitwardenSdk"
set -l revision ca53f727655ae58acc278fa8bea3894636445286
set -l target aarch64-apple-darwin
set -l patch "$root/support/patches/bitwarden-sdk-macos.patch"

# Keep the build independent of the user's Git and Cargo configuration.
set -gx GIT_CONFIG_GLOBAL /dev/null
set -gx GIT_CONFIG_SYSTEM /dev/null
set -gx GIT_TERMINAL_PROMPT 0
set -gx CARGO_HOME "$root/.local-dependencies/bitwarden-cargo"
set -gx CARGO_TARGET_DIR "$root/.local-dependencies/bitwarden-target"
set -gx MACOSX_DEPLOYMENT_TARGET 26.4
# The build fails if a crate under the Bitwarden commercial licence gets linked.
set -gx RUSTFLAGS '--cfg bitwarden_ensure_non_commercial'
set -q DEVELOPER_DIR; or set -gx DEVELOPER_DIR /Applications/Xcode.app/Contents/Developer

if test -e "$package/BitwardenFFI.xcframework"
    echo 'The SDK framework exists. Remove .local-dependencies/BitwardenSdk to rebuild it.' >&2
    exit 1
end
for tool in git cargo xcodebuild
    command -q $tool; or begin
        echo "$tool is required." >&2
        exit 1
    end
end

if not test -d "$source/.git"
    if test -e "$source"
        echo 'The SDK source path exists but is not a checkout. Nothing was changed.' >&2
        exit 1
    end
    mkdir -p "$source"; or exit 1
    git -C "$source" init --quiet; or exit 1
    git -C "$source" remote add origin https://github.com/bitwarden/sdk-internal.git; or exit 1
end
if not git -C "$source" cat-file -e "$revision^{commit}" 2>/dev/null
    git -C "$source" fetch --depth 1 origin "$revision"; or exit 1
end
if not git -C "$source" rev-parse --verify HEAD >/dev/null 2>&1
    git -C "$source" checkout --quiet --detach "$revision"; or exit 1
end
if test (git -C "$source" rev-parse HEAD) != "$revision"
    echo 'The SDK source is not at the pinned revision.' >&2
    exit 1
end

if not git -C "$source" apply --reverse --check "$patch" 2>/dev/null
    git -C "$source" apply --check "$patch"; or exit 1
    git -C "$source" apply "$patch"; or exit 1
end
git -C "$source" diff --no-ext-diff | cmp -s "$patch" -; or begin
    echo 'The SDK source has changes beyond the PassVault patch.' >&2
    exit 1
end
if test -n "$(git -C "$source" ls-files --others --exclude-standard)"
    echo 'The SDK source has unexpected untracked files.' >&2
    exit 1
end

cd "$source"; or exit 1
# Release profile: key derivation in a debug build is too slow to use.
cargo build --locked --release --package bitwarden-uniffi --target $target; or exit 1
cargo build --locked --package uniffi-bindgen; or exit 1

set -l products "$CARGO_TARGET_DIR/$target/release"
mkdir -p "$package/Sources/BitwardenSdk" "$package/Sources/BitwardenSdkSupport" "$package/Headers" "$package/Bindings"; or exit 1
"$CARGO_TARGET_DIR/debug/uniffi-bindgen" generate "$products/libbitwarden_uniffi.dylib" \
    --language swift --no-format --out-dir "$package/Bindings"; or exit 1
cp "$package/Bindings/"*.swift "$package/Sources/BitwardenSdk/"; or exit 1
cp "$package/Bindings/"*.h "$package/Headers/"; or exit 1
cat "$package/Bindings/"*.modulemap > "$package/Headers/module.modulemap"; or exit 1
cp crates/bitwarden-uniffi/swift/Sources/BitwardenSdkSupport/*.swift "$package/Sources/BitwardenSdkSupport/"; or exit 1
cp "$root/support/bitwarden-sdk-package.swift" "$package/Package.swift"; or exit 1
xcodebuild -create-xcframework -library "$products/libbitwarden_uniffi.a" -headers "$package/Headers" \
    -output "$package/BitwardenFFI.xcframework"; or exit 1
echo "Bitwarden SDK $revision prepared for $target."
