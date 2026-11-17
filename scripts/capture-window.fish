#!/usr/bin/env fish
# Saves a picture of one app window, named after the screen and the current appearance.
#   fish scripts/capture-window.fish reference <screen>    Bitwarden -> docs/reference/<screen>-<light|dark>.png
#   fish scripts/capture-window.fish passvault <screen>    PassVault -> .build/screenshots/<screen>-<light|dark>.png
#   fish scripts/capture-window.fish bitwarden <screen>    Bitwarden -> .build/screenshots/<screen>-<light|dark>.png
# DELAY=<seconds> in the environment waits before the picture, to open a menu in the app first.
# The terminal needs the Screen Recording permission. Reference pictures are tracked in Git:
# take them only while Bitwarden shows the synthetic test account.
set -l root (path resolve (path dirname (status filename))/..)
cd "$root"; or exit 1

set -l kind $argv[1]
set -l screen $argv[2]
if not string match -rq '^[a-z0-9]+(-[a-z0-9]+)*$' -- "$screen"
    echo 'Name the screen with lower-case words and hyphens, for example: vault-login-item' >&2
    exit 2
end
set -l app
set -l directory
switch "$kind"
    case reference
        set app Bitwarden
        set directory docs/reference
    case passvault
        set app HonkPass
        set directory .build/screenshots
    case bitwarden
        # A picture for a look, not a reference picture: it stays out of docs/reference.
        set app Bitwarden
        set directory .build/screenshots
    case '*'
        echo 'Usage: fish scripts/capture-window.fish reference|passvault|bitwarden <screen>' >&2
        exit 2
end

if set -q DELAY[1]; and test -n "$DELAY"
    string match -rq '^[0-9]+$' -- "$DELAY"; or begin
        echo 'DELAY is a whole number of seconds.' >&2
        exit 2
    end
    echo "Picture in $DELAY seconds."
    sleep $DELAY
end
set -l window (swift scripts/window-id.swift $app); or exit 1
set -l appearance light
if test "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" = Dark
    set appearance dark
end
mkdir -p $directory; or exit 1
set -l file "$directory/$screen-$appearance.png"
screencapture -x -o -l $window "$file"; or exit 1
echo "Saved $file"
