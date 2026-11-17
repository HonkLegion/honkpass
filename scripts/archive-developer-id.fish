#!/usr/bin/env fish
# Adapted from the original HonkPass. Each export uses a new directory.
set -l root (path resolve (path dirname (status filename))/..)
cd "$root"; or exit $status
source scripts/progress.fish
set -q DEVELOPER_DIR; or set -gx DEVELOPER_DIR /Applications/Xcode.app/Contents/Developer
set -l logs "$HONKPASS_STEP_LOG_DIR"
if test -z "$logs"
    mkdir -p .build/logs; or exit $status
    set logs (mktemp -d "$root/.build/logs/archive-XXXXXX"); or exit $status
    echo "Logs: $logs"
end
run_step 'Checking update configuration' "$logs/update-config.log" fish --no-config scripts/source-python.fish scripts/verify_release.py; or exit $status
set -l distribution .build/distribution
set -q DISTRIBUTION_DIR[1]; and set distribution "$DISTRIBUTION_DIR"
test -n "$distribution"; or begin
    echo 'DISTRIBUTION_DIR must not be empty.' >&2
    exit 2
end
mkdir -p "$distribution"; or exit $status
set distribution (path resolve "$distribution")
set -l output (mktemp -d "$distribution/archive-"(date -u +%Y%m%dT%H%M%SZ)'-XXXXXX'); or exit $status
set -l archive "$output/HonkPass.xcarchive"
set -l export_path "$output/export"
set -l source_archive "$output/HonkPass-source.tar.gz"
set -l provisioning_options -allowProvisioningUpdates
set -l signing_options
set -l export_options App/ExportOptions-DeveloperID.plist
if set -q HONKPASS_CI_SIGNING_IDENTITY
    string match -rq '^[0-9A-Fa-f]{40}$' -- "$HONKPASS_CI_SIGNING_IDENTITY"; and test -s "$HONKPASS_CI_EXPORT_OPTIONS"; or begin
        echo 'CI signing requires a certificate fingerprint and an export configuration.' >&2
        exit 2
    end
    set provisioning_options
    set signing_options CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$HONKPASS_CI_SIGNING_IDENTITY"
    set export_options "$HONKPASS_CI_EXPORT_OPTIONS"
end
run_step 'Packaging corresponding source' "$logs/source.log" fish --no-config scripts/source-python.fish support/source_archive.py --output "$source_archive"; or exit $status
set -l source_revision (git rev-parse HEAD); or exit $status
set -l source_hash (shasum -a 256 "$source_archive" | string split ' ')[1]; or exit $status
run_step 'Generating Xcode project' "$logs/project.log" xcodegen generate --quiet; or exit $status
run_step 'Archiving app' "$logs/archive.log" xcodebuild \
    -project PassVault.xcodeproj -scheme PassVault -configuration Release \
    -derivedDataPath "$output/DerivedData" -destination platform=macOS \
    -archivePath "$archive" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    HONKPASS_SOURCE_REVISION="$source_revision" HONKPASS_SOURCE_SHA256="$source_hash" $signing_options $provisioning_options archive
or exit $status
run_step 'Exporting Developer ID app' "$logs/export.log" xcodebuild -exportArchive \
    -archivePath "$archive" -exportOptionsPlist "$export_options" \
    -exportPath "$export_path" $provisioning_options
or exit $status
set -l app "$export_path/HonkPass.app"
test -d "$app"; or begin
    echo 'Export produced no application bundle.' >&2
    exit 1
end
run_step 'Checking app signature' "$logs/signature.log" codesign --verify --strict --deep --verbose=2 "$app"; or exit $status
run_step 'Checking Developer ID identity' "$logs/identity.log" fish --no-config scripts/release-check.fish identity "$app"; or exit $status
run_step 'Checking source and licenses' "$logs/source-check.log" fish --no-config scripts/source-python.fish support/release_source.py "$app" "$source_archive"; or exit $status
test (git rev-parse HEAD) = "$source_revision"; and test -z "$(git status --porcelain)"; or begin
    echo 'The project changed during archiving. The previous successful export remains selected.' >&2
    exit 1
end
# Keep the last successful export. Failed builds leave this pointer unchanged.
set -l marker (mktemp "$distribution/.latest-export-XXXXXX"); or exit $status
printf '%s\n' "$app" > "$marker"; or exit $status
mv "$marker" "$distribution/latest-export.txt"; or exit $status
echo "Developer ID export: $app (not notarized, not installed, not launched)"
echo "Corresponding source: $source_archive"
