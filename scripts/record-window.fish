#!/usr/bin/env fish
# Records the Bitwarden window while you click through the app: one picture for every change.
# The pictures go to .build/reference-session/<time>-<light|dark>/ and are not tracked.
# Keep reviewed captures local under .build/ with their screen names.
# Stop with Ctrl-C. The recording also stops after 20 minutes or 400 pictures.
#
# Record only while Bitwarden shows the synthetic test account.
set -l root (path resolve (path dirname (status filename))/..)
cd "$root"; or exit 1

set -l app Bitwarden
set -l window (swift scripts/window-id.swift $app); or exit 1
set -l appearance light
if test "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" = Dark
    set appearance dark
end
set -g directory .build/reference-session/(date +%Y%m%d-%H%M%S)-$appearance
mkdir -p $directory; or exit 1
set -g count 0

function finish --on-signal INT --on-signal TERM
    rm -f $directory/frame.png
    echo "Stopped with $count pictures in $directory"
    exit 0
end
echo "Recording the $app window into $directory"
echo 'Click through the app and stay about two seconds on each screen. Stop with Ctrl-C.'

set -l last ''
set -l started (date +%s)
while test $count -lt 400; and test (math (date +%s) - $started) -lt 1200
    if not screencapture -x -o -l $window $directory/frame.png 2>/dev/null
        # The window was closed and opened again: find it once more.
        sleep 1
        set window (swift scripts/window-id.swift $app 2>/dev/null); or continue
        continue
    end
    set -l hash (shasum -a 256 $directory/frame.png | string split ' ')[1]
    if test "$hash" != "$last"
        set count (math $count + 1)
        mv $directory/frame.png (printf '%s/%03d.png' $directory $count)
        set last $hash
        echo "picture $count"
    end
    sleep 0.5
end
finish
