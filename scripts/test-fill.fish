#!/usr/bin/env fish
# Synthetic AppKit and WebKit integration tests. The app must already be built and
# allowed in Accessibility. Never launch alongside the installed HonkPass.
set -l root (path resolve (path dirname (status filename))/..)
cd "$root"; or exit 1
if pgrep -x HonkPass >/dev/null
    echo 'Quit HonkPass before running the synthetic fill tests.' >&2
    exit 1
end
set -q DERIVED_DATA; or set DERIVED_DATA .build/xcode
set -l app "$DERIVED_DATA/Build/Products/Debug/HonkPass.app/Contents/MacOS/HonkPass"
test -x "$app"; or begin
    echo 'Build HonkPass with make build first.' >&2
    exit 1
end
swiftc -o .build/PassVaultFillFixture support/fill-fixture/main.swift; or exit 1
set -l logs (mktemp -d .build/fill-check-XXXXXX); or exit 1
echo "Logs: $logs"
set -l scenarios native native-password native-nowhere web web-password web-nowhere web-code web-code-only web-long web-replace web-redirect web-duplicate-code web-foreign-code web-microsoft-code web-ambiguous-code
for scenario in $scenarios
    set -l app_args --fake-backend --fill-check
    set -l fixture_args check
    if string match -q 'web*' $scenario
        set -a fixture_args web controlled
    end
    switch $scenario
        case '*-password'
            set -a fixture_args password
            set -a app_args --fill-check-password
        case '*-nowhere'
            set -a fixture_args nowhere
            set -a app_args --fill-check-nowhere
        case web-code
            set -a fixture_args code
            set -a app_args --fill-check-code
        case web-code-only
            set -a fixture_args code-only
            set -a app_args --fill-check-code-only
        case web-microsoft-code
            set -a fixture_args code-only microsoft-code
            set -a app_args --fill-check-code-only
        case web-ambiguous-code
            set -a fixture_args code-only ambiguous-code
            set -a app_args --fill-check-ambiguous-code
        case web-long
            set -a fixture_args long
            set -a app_args --fill-check-long
        case web-replace
            set -a fixture_args replace
        case web-redirect
            set -a fixture_args long redirect
            set -a app_args --fill-check-long --fill-check-interrupted
        case web-duplicate-code
            set -a fixture_args code duplicate-code
            set -a app_args --fill-check-code
        case web-foreign-code
            set -a fixture_args code foreign-code
            set -a app_args --fill-check-code
    end
    set -l app_log $logs/$scenario-app.log
    set -l fixture_log $logs/$scenario-fixture.log
    $app $app_args >$app_log 2>&1 &
    set -l app_pid $last_pid
    for attempt in (seq 1 100)
        if rg -q 'FILL CHECK (WAITS|FAILED)' $app_log
            break
        end
        sleep 0.05
    end
    .build/PassVaultFillFixture $fixture_args >$fixture_log 2>&1 &
    set -l fixture_pid $last_pid
    wait $app_pid
    wait $fixture_pid
    # Fish wait does not return each child's exit status. Both programs emit their
    # success marker only after their independent assertions pass.
    if not rg -q 'FILL CHECK DONE' $app_log; or not rg -q 'FILL FIXTURE OK' $fixture_log
        rg 'FILL CHECK|FILL FIXTURE' $app_log $fixture_log
        echo "$scenario: FAILED" >&2
        exit 1
    end
    echo "$scenario: OK"
end
echo "OK: "(count $scenarios)' synthetic fill scenarios passed.'
