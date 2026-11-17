#!/usr/bin/env fish
# Create a new signed DMG from the last successful notarization. Never publish it.
set -l root (path resolve (path dirname (status filename))/..)
cd "$root"; or exit 1
source scripts/progress.fish
set -q DEVELOPER_DIR; or set -gx DEVELOPER_DIR /Applications/Xcode.app/Contents/Developer
set -l distribution .build/distribution
set -q DISTRIBUTION_DIR[1]; and set distribution "$DISTRIBUTION_DIR"
set -l profile "$NOTARY_PROFILE"
test -n "$distribution"; and test -n "$profile"; or exit 2
set distribution (path resolve "$distribution")
test -f "$distribution/latest-notarized.txt"; or begin
    echo 'Run make archive and make notarize before make update-package.' >&2
    exit 1
end
set -l notarized (string collect < "$distribution/latest-notarized.txt")
set -l original (string collect < "$notarized/notarized-app.txt"); or exit 1
test -d "$original"; or exit 1
set -l output (mktemp -d "$distribution/update-"(date -u +%Y%m%dT%H%M%SZ)"-XXXXXX"); or exit 1
set -l logs "$output/logs"
mkdir -p "$logs" "$output/image"; or exit 1
echo "Logs: $logs"
set -l app "$output/HonkPass.app"
set -l dmg "$output/HonkPass.dmg"
run_step 'Copying notarized app' "$logs/copy.log" ditto "$original" "$app"; or exit $status
cp "$notarized/HonkPass-source.tar.gz" "$output/HonkPass-source.tar.gz"; or exit 1
run_step 'Checking release identity' "$logs/identity.log" fish --no-config scripts/source-python.fish scripts/verify_release.py "$app"; or exit $status
run_step 'Checking paired source' "$logs/source.log" fish --no-config scripts/source-python.fish support/release_source.py "$app" "$output/HonkPass-source.tar.gz"; or exit $status
run_step 'Checking code signature' "$logs/signature.log" codesign --verify --deep --strict "$app"; or exit $status
run_step 'Checking app notarization' "$logs/app-ticket.log" xcrun stapler validate "$app"; or exit $status
run_step 'Checking Gatekeeper' "$logs/gatekeeper.log" spctl --assess --type execute "$app"; or exit $status
set -l identity (codesign -dv --verbose=4 "$app" 2>&1 | string match -r '^Authority=Developer ID Application:.*' | string replace 'Authority=' '')
test (count $identity) -eq 1; or begin
    echo 'The app needs a Developer ID Application signature.' >&2
    exit 1
end
# Select the exact public signing certificate. Passing its display name to codesign can
# misdecode accented characters even though the identity exists in Keychain.
run_step 'Reading public signing certificate' "$logs/certificate.log" codesign --display --extract-certificates="$logs/signer-" "$app"; or exit $status
test -s "$logs/signer-0"; or exit 1
set identity (shasum -a 1 "$logs/signer-0" | string split ' ')[1]
string match -rq '^[0-9a-f]{40}$' -- "$identity"; or exit 1
run_step 'Preparing disk image' "$logs/image-source.log" ditto "$app" "$output/image/HonkPass.app"; or exit $status
# Publish the paired source archive beside the DMG as a separate download.
ln -s /Applications "$output/image/Applications"; or exit 1
run_step 'Creating disk image' "$logs/image.log" hdiutil create -volname HonkPass -srcfolder "$output/image" -format UDZO -ov "$dmg"; or exit $status
run_step 'Signing disk image' "$logs/dmg-sign.log" codesign --force --timestamp --sign "$identity" "$dmg"; or exit $status
run_step 'Notarizing disk image' "$logs/notary.log" fish --no-config scripts/release-check.fish submit "$dmg" "$profile" "$logs/submission.json" "$logs/notary.json"; or exit $status
run_step 'Stapling disk image' "$logs/staple.log" xcrun stapler staple "$dmg"; or exit $status
run_step 'Checking disk image ticket' "$logs/dmg-ticket.log" xcrun stapler validate "$dmg"; or exit $status
run_step 'Checking disk image signature' "$logs/dmg-signature.log" codesign --verify --strict "$dmg"; or exit $status
set -l sparkle (fish --no-config scripts/sparkle-tools.fish); or exit 1
set -l account cz.honklegion.honkpass.sparkle
set -l public_key ("$sparkle/bin/generate_keys" --account "$account" -p); or exit 1
set -l bundled_key (/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist"); or exit 1
test "$public_key" = "$bundled_key"; or begin
    echo 'The Keychain signing account does not match the public key in HonkPass.' >&2
    exit 1
end
set -l signing_options --account "$account"
if set -q HONKPASS_SPARKLE_KEY_FILE
    test -s "$HONKPASS_SPARKLE_KEY_FILE"; or exit 2
    set signing_options --ed-key-file "$HONKPASS_SPARKLE_KEY_FILE"
end
set -l signature ("$sparkle/bin/sign_update" $signing_options -p "$dmg"); or exit 1
"$sparkle/bin/sign_update" $signing_options --verify "$dmg" "$signature"; or exit 1
fish --no-config scripts/source-python.fish scripts/generate_appcast.py "$app/Contents/Info.plist" "$dmg" "$signature" "$output/appcast.xml"; or exit 1
fish --no-config scripts/source-python.fish scripts/generate_appcast.py --verify "$app/Contents/Info.plist" "$dmg" "$output/appcast.xml" >/dev/null; or exit 1
python3 -c 'import hashlib,json,pathlib,sys; p=pathlib.Path(sys.argv[1]); (p/"update-manifest.json").write_text(json.dumps({n:hashlib.sha256((p/n).read_bytes()).hexdigest() for n in ("HonkPass.dmg","HonkPass-source.tar.gz")},indent=2)+"\n")' "$output"; or exit 1
# A failed packaging run leaves the previous successful update selected.
set -l marker (mktemp "$distribution/.latest-update-XXXXXX"); or exit 1
printf '%s\n' "$output" > "$marker"; or exit 1
mv "$marker" "$distribution/latest-update.txt"; or exit 1
echo "OK: signed update package: $output"
echo 'Use make upload-update to create a draft in HonkLegion Admin.'
