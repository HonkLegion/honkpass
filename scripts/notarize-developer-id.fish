#!/usr/bin/env fish
# Submit only an existing Developer ID export. This is never part of build or archive.
set -l root (path resolve (path dirname (status filename))/..)
cd "$root"; or exit $status
source scripts/progress.fish
set -l logs "$HONKPASS_STEP_LOG_DIR"
if test -z "$logs"
    mkdir -p .build/logs; or exit $status
    set logs (mktemp -d "$root/.build/logs/notarize-XXXXXX"); or exit $status
    echo "Logs: $logs"
end
set -l distribution .build/distribution
set -q DISTRIBUTION_DIR[1]; and set distribution "$DISTRIBUTION_DIR"
test -n "$distribution"; or exit 2
set -l profile "$NOTARY_PROFILE"
test -n "$profile"; or begin
    echo 'Set NOTARY_PROFILE to an existing notarytool Keychain profile.' >&2
    exit 2
end
test -f "$distribution/latest-export.txt"; or begin
    echo 'Exported app is missing. Run make archive first.' >&2
    exit 1
end
set -l app (string collect < "$distribution/latest-export.txt")
test -d "$app"; or begin
    echo 'The latest exported app is missing. Run make archive again.' >&2
    exit 1
end
run_step 'Checking app signature' "$logs/signature.log" codesign --verify --strict --deep --verbose=2 "$app"; or exit $status
run_step 'Checking Developer ID identity' "$logs/identity.log" fish --no-config scripts/release-check.fish identity "$app"; or exit $status
set -l source_archive (path dirname (path dirname "$app"))/HonkPass-source.tar.gz
run_step 'Checking source and licenses' "$logs/source-check.log" fish --no-config scripts/source-python.fish support/release_source.py "$app" "$source_archive"; or exit $status
set -l zip "$logs/HonkPass-for-notarization.zip"
run_step 'Packaging app' "$logs/package.log" ditto -c -k --keepParent "$app" "$zip"; or exit $status
echo "Submitting to Apple: $app"
run_step 'Submitting app to Apple' "$logs/submit.log" fish --no-config scripts/release-check.fish submit \
    "$zip" "$profile" "$logs/submission.json" "$logs/notary.json"
or exit $status
run_step 'Stapling app ticket' "$logs/staple.log" xcrun stapler staple "$app"; or exit $status
run_step 'Validating app ticket' "$logs/validate.log" xcrun stapler validate "$app"; or exit $status
run_step 'Checking Gatekeeper' "$logs/gatekeeper.log" spctl --assess --type execute --verbose=2 "$app"; or exit $status
set -l final_zip "$logs/HonkPass-notarized.zip"
run_step 'Packaging notarized app' "$logs/final-package.log" ditto -c -k --keepParent "$app" "$final_zip"; or exit $status
cp "$source_archive" "$logs/HonkPass-source.tar.gz"; or exit $status
run_step 'Recording release hashes' "$logs/release-record.log" fish --no-config scripts/source-python.fish support/release_source.py "$app" "$logs/HonkPass-source.tar.gz" \
    --binary-zip "$final_zip" --record "$logs/release-manifest.json"; or exit $status
printf '%s\n' "$app" > "$logs/notarized-app.txt"; or exit $status
set -l marker (mktemp "$distribution/.latest-notarized-XXXXXX"); or exit $status
printf '%s\n' "$logs" > "$marker"; or exit $status
mv "$marker" "$distribution/latest-notarized.txt"; or exit $status
echo "Notarized app: $app"
echo "Notarized ZIP: $final_zip"
echo "Corresponding source: $logs/HonkPass-source.tar.gz"
