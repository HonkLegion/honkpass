#!/usr/bin/env fish
# The work behind the Makefile targets. Each run keeps its complete logs.
set -l root (path resolve (path dirname (status filename))/..)
cd "$root"; or exit 1

set -l action $argv[1]
set -q CONFIGURATION[1]; or set -l CONFIGURATION Debug
set -q DERIVED_DATA[1]; or set -l DERIVED_DATA .build/xcode
set -q DEVELOPER_DIR; or set -gx DEVELOPER_DIR /Applications/Xcode.app/Contents/Developer
contains -- "$CONFIGURATION" Debug Release; or begin
    echo 'CONFIGURATION must be Debug or Release.' >&2
    exit 2
end
test -n "$DERIVED_DATA"; or begin
    echo 'DERIVED_DATA must not be empty.' >&2
    exit 2
end
set -l app "$DERIVED_DATA/Build/Products/$CONFIGURATION/HonkPass.app"
set -l compose docker compose -f support/vaultwarden/compose.yaml
set -l server_url http://localhost:8642
# The mark of the start guard of the app (StartGuard.swift), beside its store.
set -l start_guard "$HOME/Library/Application Support/PassVault/start-guard"
mkdir -p .build/logs; or exit $status
set -l logs (mktemp -d "$root/.build/logs/$action-"(date -u +%Y%m%dT%H%M%SZ)"-XXXXXX"); or exit $status
if test "$action" != help
    echo "Logs: $logs"
end

source scripts/progress.fish

function step --argument-names title log
    run_step "$title" "$log" $argv[3..]
end

function require_sdk
    test -e .local-dependencies/BitwardenSdk/BitwardenFFI.xcframework; and return 0
    echo 'The Bitwarden SDK is not built yet. Run: make prepare-sdk' >&2
    return 1
end

# The full check needs the local server. Without it the run stops before it starts, so that a
# run without the server never looks like a pass. OFFLINE=1 allows the run without it.
function require_server --no-scope-shadowing
    curl -fs -o /dev/null --max-time 2 "$server_url/alive"; and return 0
    if test "$OFFLINE" = 1
        echo "The local Vaultwarden does not answer on $server_url: the part of make $argv[1] that needs it is left out (OFFLINE=1)."
        return 0
    end
    echo "The local Vaultwarden does not answer on $server_url: make $argv[1] is not complete without it." >&2
    echo "Start it with 'make server'. To run only the part that needs no server: make $argv[1] OFFLINE=1" >&2
    return 1
end

function build_app --no-scope-shadowing
    require_sdk; or return 1
    test -e Config/Local.xcconfig; or begin
        echo 'Config/Local.xcconfig is missing. Copy Config/Local.example.xcconfig and set your team.' >&2
        return 1
    end
    step 'Generating the Xcode project' $logs/project.log xcodegen generate --quiet; or return $status
    step "Building and signing HonkPass ($CONFIGURATION)" $logs/build.log \
        xcodebuild -project PassVault.xcodeproj -scheme PassVault -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA" -destination platform=macOS build; or return $status
    step 'Checking the signature' $logs/signature.log codesign --verify --strict --deep --verbose=2 "$app"; or return $status
    echo "App: $app"
end

switch "$action"
    case help
        printf '%s\n' \
            'make build         Generate the project, build and sign the Debug app' \
            'make run           Build and open the app' \
            'make test          Run all tests. Needs the local server (make server); OFFLINE=1 runs the part without it' \
            'make smoke         Build, then check the real app: fake backend, then local server. Needs the server; OFFLINE=1 as above' \
            'make check         Run workflow tests, engine tests and the app smoke test' \
            'make test-progress Test terminal output and release workflows with synthetic tools' \
            'make archive       Export a Developer ID app into a new distribution directory' \
            'make notarize      Submit the latest export to Apple, staple it and create a ZIP' \
            'make update-package  Create and sign a notarized Sparkle DMG from the latest notarized app' \
            'make upload-update   Upload the selected DMG as an Admin draft (UPDATER_TOKEN required)' \
            'make test-updates    Test the release API with synthetic inputs and a loopback server' \
            'make licenses      Regenerate offline legal notices from the pinned dependencies' \
            'make check-licenses  Reject stale or incomplete legal notices' \
            'make source-archive  Package source and dependencies from a clean revision' \
            'make public-source RELEASE_TAG=vX.Y.Z  Export reviewed public files from HEAD locally' \
            'make test-publication  Test the private release publisher with synthetic repositories' \
            'make sandbox       Build and open the app on the fake backend: nothing is kept, nothing of the user is touched (NAME=scene)' \
            'make sandbox-server  Legacy local-server scene runner; uses the Bitwarden comparison name (NAME=scene)' \
            'make guard         Turn the start guard on: HonkPass starts only as a test run, never with the stored session' \
            'make guard-off     Turn the start guard off: HonkPass starts as usual' \
            'make prepare-sdk   Download and build the pinned Bitwarden SDK (once, several minutes)' \
            'make server        Start the local Vaultwarden and seed the synthetic account' \
            'make server-https  Add https://localhost:8643 for legacy Bitwarden reference tools' \
            'make server-stop   Stop the local Vaultwarden; its data stays' \
            'make server-reset  Stop the local Vaultwarden and delete its synthetic data' \
            'make two-step-code Print the current authenticator code of the synthetic account with two-step login' \
            'make screenshot NAME=x  Save the HonkPass window as .build/screenshots/x-<light|dark>.png' \
            'make public-suffixes    Regenerate the public suffix rules of VaultModel from the list of the SDK' \
            '' \
            'Legacy maintenance commands (not HonkPass visual acceptance):' \
            'make reference NAME=x   Capture historical Bitwarden reference images (DELAY=5 waits first)' \
            'make reference-session  Record the Bitwarden reference app' \
            'make screenshot-bitwarden NAME=x  Capture the Bitwarden reference app under .build/screenshots/' \
            'make compare NAME=x     Compare against historical Bitwarden images (APPEARANCE=dark|light)' \
            'make reference-source   Fetch pinned Bitwarden source for retained resources and license provenance' \
            'make design-kit         Reimport retained resources; review generated changes before committing' \
            'HonkPass visual baselines and replacement comparison tools remain pending.' \
            '' \
            'Options: CONFIGURATION=Debug|Release DERIVED_DATA=.build/xcode OFFLINE=1 MAKE_PROGRESS=plain' \
            'Release options: DISTRIBUTION_DIR=.build/distribution NOTARY_PROFILE=bckp-notary' \
            'Full logs: .build/logs/<run>/. NO_COLOR removes colors and keeps live output.'
    case prepare-sdk
        step 'Preparing Bitwarden SDK' $logs/sdk.log fish --no-config support/prepare-bitwarden-sdk.fish; or exit $status
    case licenses check-licenses
        set -l mode generate
        test "$action" = check-licenses; and set mode check
        step 'Resolving pinned dependencies' $logs/dependencies.log swift package resolve; or exit $status
        step 'Preparing license notices' $logs/licenses.log python3 support/legal.py $mode; or exit $status
    case source-archive
        step 'Packaging corresponding source' $logs/source.log fish --no-config scripts/source-python.fish support/source_archive.py --output "$logs/HonkPass-source.tar.gz"; or exit $status
        echo "Source archive: $logs/HonkPass-source.tar.gz"
    case public-source
        step 'Exporting public source' $logs/source.log fish --no-config scripts/source-python.fish support/public_source.py \
            --tag "$RELEASE_TAG" --output "$logs/project"; or exit $status
        echo "Public source: $logs/project"
    case test-publication
        test -f .forgejo/scripts/test_publication.py; or begin
            echo 'This target requires the private development checkout.' >&2
            exit 1
        end
        step 'Testing filtered publication' $logs/publication-tests.log fish --no-config scripts/source-python.fish .forgejo/scripts/test_publication.py; or exit $status
        echo 'OK: synthetic publication tests passed.'
    case build
        build_app; or exit $status
    case check
        for workflow in test-progress test-updates test smoke
            fish --no-config scripts/make.fish $workflow; or exit $status
        end
    case test-progress
        step 'Testing terminal output' $logs/output-tests.log python3 scripts/test-step-output.py; or exit $status
        step 'Testing Make workflows' $logs/workflow-tests.log python3 scripts/test-make-workflow.py; or exit $status
        step 'Testing source pairing' $logs/source-tests.log fish --no-config scripts/source-python.fish scripts/test-release-source.py; or exit $status
        step 'Testing public source selection' $logs/public-source-tests.log fish --no-config scripts/source-python.fish scripts/test_public_source.py; or exit $status
        step 'Testing release automation' $logs/ci-release-tests.log fish --no-config scripts/source-python.fish scripts/test_ci_release.py; or exit $status
    case archive
        require_sdk; or exit $status
        test -e Config/Local.xcconfig; or begin
            echo 'Config/Local.xcconfig is missing. Set your signing team before archiving.' >&2
            exit 1
        end
        env HONKPASS_STEP_LOG_DIR="$logs" fish --no-config scripts/archive-developer-id.fish; or exit $status
    case notarize
        env HONKPASS_STEP_LOG_DIR="$logs" fish --no-config scripts/notarize-developer-id.fish; or exit $status
    case update-package
        fish --no-config scripts/package-update.fish; or exit $status
    case upload-update
        test -f scripts/upload_release.py; or begin
            echo 'Production upload requires the private development checkout.' >&2
            exit 1
        end
        set -l notes
        test -n "$NOTES_FILE"; and set notes --notes-file "$NOTES_FILE"
        # Token stays in the environment and is never sourced from a credential file.
        step 'Uploading verified update draft' $logs/upload.log fish --no-config scripts/source-python.fish scripts/upload_release.py $notes; or exit $status
    case test-updates
        step 'Testing updater release flow' $logs/update-tests.log fish --no-config scripts/source-python.fish -m unittest discover -s scripts -p 'test_*update*.py'; or exit $status
        echo 'OK: synthetic updater release tests passed.'
    case guard
        mkdir -p (path dirname $start_guard); and touch $start_guard; or exit 1
        echo 'The start guard is on: HonkPass starts only as a test run (make sandbox, make sandbox-server, make smoke, make compare).'
        echo 'After the run, turn it off: make guard-off'
    case guard-off
        rm -f $start_guard; or exit 1
        echo 'The start guard is off: HonkPass starts as usual.'
    case run
        if test -e $start_guard
            echo 'The start guard is on: HonkPass would not start. Turn it off first: make guard-off' >&2
            exit 1
        end
        build_app; or exit $status
        # The renamed app and older builds share one bundle identifier.
        if pgrep -xq HonkPass; or pgrep -xq PassVault
            echo 'HonkPass or an older build is running. Quit it first; the builds share one bundle identifier.' >&2
            exit 1
        end
        # The system may still run parts of the build before: the launch agent of AutoFill and
        # the extension. They end here, and the system starts the new ones when they are asked for.
        set -l bundle_id (defaults read "$PWD/$app/Contents/Info" CFBundleIdentifier)
        launchctl kill SIGTERM gui/(id -u)/$bundle_id.bridge 2>/dev/null
        pkill -x PassVaultProvider 2>/dev/null
        # The system takes the extension of this build for AutoFill, if the user has turned it on.
        pluginkit -e use -i $bundle_id.provider
        # Of two extensions with one identifier the system takes one, and not by its version: an
        # app in /Applications that has the same identifier wins over this build.
        set -l taken (pluginkit -m -v -i $bundle_id.provider | string match -r '/.*\.appex')
        if test -n "$taken"; and not string match -q "*$app/Contents/PlugIns/*" -- $taken
            echo "AutoFill would start another extension with this identifier: $taken" >&2
            echo "To have the system forget it: pluginkit -r \"$taken\"" >&2
        end
        open "$app"; or exit 1
    case sandbox sandbox-server
        # A run for trying the app by hand, or by an agent that controls the Mac
        # It is a test run: the account lives in memory, so the
        # session, the Keychain, the AutoFill and the shortcuts of the user are not touched,
        # and no field of another app is looked at. The scene opens the app in a known state.
        build_app; or exit $status
        if pgrep -xq HonkPass; or pgrep -xq PassVault
            echo 'HonkPass or the previous PassVault build runs already. Quit it first (Command-Q): one instance at a time.' >&2
            exit 1
        end
        set -l scene $NAME
        test -n "$scene"; or set scene vault-all-items
        set -l options --scene $scene --window-size 1272x828
        test -n "$APPEARANCE"; and set -a options --appearance $APPEARANCE
        # The system starts the app, so it is no child of this script. A terminal that ends the
        # children of a command with the command would end the app too, and a tool that then
        # looks for PassVault would start it as the user does, with the stored session.
        set -l log "$logs/sandbox.log"
        rm -f $log
        set -l launch open -n $app --stdout $log --stderr $log
        if test "$action" = sandbox
            echo "==> HonkPass on the fake backend, scene $scene. Nothing is kept."
            set -a launch --args --fake-backend $options
        else
            curl -fs -o /dev/null --max-time 2 "$server_url/alive"; or begin
                echo "The local Vaultwarden does not answer on $server_url. Run: make server" >&2
                exit 1
            end
            set -l account support/vaultwarden/test-account.json
            echo "==> HonkPass on the local Vaultwarden with the synthetic account, scene $scene."
            echo '    Save, move and delete nothing there: the tests need the account as it is.'
            # The texts say "Bitwarden", as the reference beside it does.
            set -a launch --env PASSVAULT_SMOKE_SERVER=(jq -r .server $account) --env PASSVAULT_SMOKE_EMAIL=(jq -r .email $account) \
                --env PASSVAULT_SMOKE_PASSWORD=(jq -r .masterPassword $account) --args $options --product-name Bitwarden
        end
        $launch; or begin
            echo 'HonkPass did not start.' >&2
            exit 1
        end
        for attempt in (seq 100)
            test -e $log; and grep -q -E 'SCENE (READY|FAILED)' $log; and break
            sleep 0.2
        end
        grep -h 'SCENE' $log; or echo "The scene did not say that it is open. See $logs/sandbox.log" >&2
        if test -e $start_guard
            echo 'The start guard is on: no other start of HonkPass opens the stored session.'
        else
            echo 'The start guard is off: a start of HonkPass by its name opens the stored session. For a run of an agent: make guard'
        end
        # The app goes on when this script ends.
        echo "Quit it with Command-Q in its window, or: kill "(pgrep -n -x HonkPass)
    case smoke
        require_server smoke; or exit 1
        build_app; or exit $status
        step 'Testing app on fake backend' $logs/smoke.log "$app/Contents/MacOS/HonkPass" --smoke-test --fake-backend; or exit $status
        step 'Testing app with two-step login' $logs/smoke-two-step.log "$app/Contents/MacOS/HonkPass" --smoke-test --fake-backend --two-step; or exit $status
        if curl -fs -o /dev/null --max-time 2 "$server_url/alive"
            set -l account support/vaultwarden/test-account.json
            step 'Testing app on local Vaultwarden' $logs/smoke-live.log env PASSVAULT_SMOKE_SERVER=(jq -r .server $account) PASSVAULT_SMOKE_EMAIL=(jq -r .email $account) \
                PASSVAULT_SMOKE_PASSWORD=(jq -r .masterPassword $account) \
                "$app/Contents/MacOS/HonkPass" --smoke-test; or exit $status
            echo 'OK: the smoke test passed on the fake backend, with two-step login and on the local server.'
        else if test "$OFFLINE" = 1
            echo 'PARTIAL: the smoke test passed on the fake backend. The run on the local server was left out (OFFLINE=1): this is not the full check.'
        else
            echo "FAILED: the local Vaultwarden stopped answering on $server_url before the smoke test on it." >&2
            exit 1
        end
    case test
        require_sdk; or exit 1
        require_server test; or exit 1
        step 'Testing engine and local adapters' $logs/test.log swift test; or exit $status
        if not grep -q 'skipped.*Needs the local Vaultwarden' $logs/test.log
            echo 'OK: all tests passed, the tests against the local server among them.'
        else if test "$OFFLINE" = 1
            echo 'PARTIAL: the tests that ran passed. The tests against the local server were left out (OFFLINE=1): this is not the full check.'
        else
            # The server answered before the run and a suite still did not reach it.
            echo "FAILED: tests against the local server were skipped. Full log: $logs/test.log" >&2
            exit 1
        end
    case server server-https
        require_sdk; or exit 1
        set -l profile
        if test "$action" = server-https
            fish --no-config support/vaultwarden/make-certificate.fish; or exit 1
            set profile --profile https
        end
        step 'Starting the local Vaultwarden' $logs/server.log $compose $profile up -d --wait; or exit 1
        for attempt in (seq 30)
            curl -fs -o /dev/null --max-time 2 "$server_url/alive"; and break
            sleep 1
        end
        swift run passvault-seed 2>$logs/seed.log; or begin
            tail -n 20 $logs/seed.log
            exit 1
        end
        echo "Server: $server_url (account: support/vaultwarden/test-account.json)"
        if test "$action" = server-https
            echo 'Server for the official Bitwarden app: https://localhost:8643'
            echo 'The app must trust the local development CA at .local-dependencies/dev-tls/ca.pem.'
        end
    case two-step-code
        require_sdk; or exit 1
        swift run passvault-seed authenticator-code 2>$logs/seed.log; or begin
            tail -n 20 $logs/seed.log
            exit 1
        end
    case server-stop
        $compose --profile https stop; or exit 1
    case server-reset
        # Deletes only the synthetic data of the development server.
        $compose --profile https down --volumes; or exit 1
    case reference
        fish --no-config scripts/capture-window.fish reference "$NAME"; or exit 1
    case reference-session
        fish --no-config scripts/record-window.fish; or exit 1
    case reference-source
        fish --no-config support/fetch-reference-source.fish; or exit 1
    case public-suffixes
        python3 -I support/generate-public-suffixes.py; or exit 1
    case design-kit
        fish --no-config support/fetch-reference-source.fish; or exit 1
        python3 -I support/generate-design-kit.py; or exit 1
    case compare
        build_app; or exit $status
        fish --no-config scripts/compare-screen.fish "$NAME" $APPEARANCE; or exit 1
    case screenshot
        fish --no-config scripts/capture-window.fish passvault "$NAME"; or exit 1
    case screenshot-bitwarden
        fish --no-config scripts/capture-window.fish bitwarden "$NAME"; or exit 1
    case '*'
        echo 'Unknown target. Run: make help' >&2
        exit 2
end
