#!/usr/bin/env fish
# Compares one PassVault screen with its reference picture.
#   fish scripts/compare-screen.fish <screen> [dark|light]
# It starts the built app in the scene of that screen, at the size and in the appearance of
# the reference picture, takes a picture of its window and writes
#   .build/screenshots/<screen>-<appearance>.png   the PassVault window
#   .build/compare/<screen>-<appearance>.png       reference | PassVault | difference
# The app runs on the local development server (make server). Build first: make build.
set -l root (path resolve (path dirname (status filename))/..)
cd "$root"; or exit 1

set -l screen $argv[1]
set -l appearances $argv[2]
test -n "$appearances"; or set appearances dark light
set -l app .build/xcode/Build/Products/Debug/HonkPass.app/Contents/MacOS/HonkPass
test -x $app; or begin
    echo 'The app is not built. Run: make build' >&2
    exit 1
end
test -x .build/image-tool; or swiftc -O scripts/image-tool.swift -o .build/image-tool; or exit 1
set -l account support/vaultwarden/test-account.json
mkdir -p .build/screenshots .build/compare .build/logs; or exit 1

set -l result 0
for appearance in $appearances
    set -l reference docs/reference/$screen-$appearance.png
    test -e $reference; or begin
        echo "There is no reference picture $reference" >&2
        exit 1
    end
    # The window gets the size of the reference picture, which has two pixels to a point.
    set -l size (string match -r '(\d+) x (\d+)' (.build/image-tool size $reference))
    set -l points (math $size[2] / 2)x(math $size[3] / 2)
    set -l log .build/logs/scene-$screen-$appearance.log
    env PASSVAULT_SMOKE_SERVER=(jq -r .server $account) PASSVAULT_SMOKE_EMAIL=(jq -r .email $account) \
        PASSVAULT_SMOKE_PASSWORD=(jq -r .masterPassword $account) \
        $app --scene $screen --appearance $appearance --window-size $points --language cs --product-name Bitwarden >$log 2>&1 &
    set -l pid $last_pid
    set -l ready no
    for attempt in (seq 100)
        if grep -q 'SCENE READY' $log
            set ready yes
            break
        end
        grep -q 'SCENE FAILED' $log; and break
        sleep 0.2
    end
    if test $ready = yes
        set -l picture .build/screenshots/$screen-$appearance.png
        # An older picture must not stand in for the one that could not be taken.
        rm -f $picture .build/compare/$screen-$appearance.png
        screencapture -x -o -l (swift scripts/window-id.swift HonkPass $pid) $picture
        if test -s $picture
            printf '%s %s: ' $screen $appearance
            .build/image-tool compare $reference $picture .build/compare/$screen-$appearance.png 80; or set result 1
        else
            echo "$screen $appearance: NOT COMPARED, the window could not be captured. Unlock the screen and give the terminal the Screen Recording permission." >&2
            set result 1
        end
    else
        echo "$screen $appearance: the scene did not open. See $log" >&2
        set result 1
    end
    kill $pid 2>/dev/null
    wait $pid 2>/dev/null
end
exit $result
