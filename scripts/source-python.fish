#!/usr/bin/env fish
# Xcode can put Python 3.9 before Homebrew in PATH. Source packaging needs tomllib.
for candidate in python3 python3.14 python3.13 python3.12 python3.11
    if command -sq $candidate
        command $candidate -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null
        if test $status -eq 0
            command $candidate $argv
            exit $status
        end
    end
end
echo 'Source packaging requires Python 3.11 or later in PATH.' >&2
exit 1
