#!/usr/bin/env fish
# Keep machine-readable responses separate from the progress log.
switch "$argv[1]"
    case identity
        set -l identity (codesign --display --verbose=4 "$argv[2]" 2>&1)
        set -l result $status
        printf '%s\n' $identity
        test $result -eq 0; or exit $result
        string match -rq '^Authority=Developer ID Application:' -- $identity; or begin
            echo 'The app is not signed with a Developer ID Application identity.' >&2
            exit 1
        end
    case submit
        # The profile name is an argument, never a credential or shell source.
        xcrun notarytool submit "$argv[2]" --keychain-profile "$argv[3]" --wait --output-format json > "$argv[4]"
        or exit $status
        set -l submission (jq -er '.id | strings | select(length > 0)' "$argv[4]"); or exit $status
        xcrun notarytool log "$submission" --keychain-profile "$argv[3]" "$argv[5]"; or exit $status
        jq -e '.status == "Accepted"' "$argv[4]" >/dev/null; or begin
            echo "Notarization was not accepted. Read $argv[4] and $argv[5]." >&2
            exit 1
        end
        echo 'Notarization accepted.'
    case '*'
        echo 'Unknown release check.' >&2
        exit 2
end
