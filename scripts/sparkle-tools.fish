#!/usr/bin/env fish
set -l root (path resolve (path dirname (status filename))/..)
cd "$root"; or exit 1
# SwiftPM checks the pinned archive checksum before it extracts these tools.
if not test -x .build/artifacts/sparkle/Sparkle/bin/sign_update
    swift package resolve >&2; or exit 1
end
test -x .build/artifacts/sparkle/Sparkle/bin/sign_update; or exit 1
echo "$root/.build/artifacts/sparkle/Sparkle"
