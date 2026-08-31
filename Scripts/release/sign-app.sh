#!/bin/bash

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

identity=""
app_input=".release/stage/Erylo.app"
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --identity|--app)
            [[ "$#" -ge 2 && -n "$2" ]] || release_die "missing value for $1"
            if [[ "$1" == "--identity" ]]; then identity="$2"; else app_input="$2"; fi
            shift 2
            ;;
        --help)
            printf 'Usage: %s --identity "Developer ID Application: ..." [--app .release/.../Erylo.app]\n' "$0"
            exit 0
            ;;
        *) release_die "unknown argument: $1" ;;
    esac
done

[[ -n "$identity" ]] || release_die "a Developer ID Application identity is required"
identity_team_id="$(release_developer_id_team_id "$identity")"
if [[ "${ERYLO_RELEASE_EXPECTED_TEAM_ID+x}" == x ]]; then
    expected_team_id="$ERYLO_RELEASE_EXPECTED_TEAM_ID"
    [[ "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]] \
        || release_die "expected Developer ID team identifier is invalid"
    [[ "$identity_team_id" == "$expected_team_id" ]] \
        || release_die "selected Developer ID identity does not match the expected team"
fi

release_require_full_xcode
release_require_command codesign
release_require_command security

app="$(release_existing_path "$repo_root" "$app_input")"
"$script_dir/validate-app.sh" "$app" >/dev/null

if ! /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -Fq -- "\"$identity\""; then
    release_die "requested Developer ID identity is unavailable in the current keychain"
fi

framework="$app/Contents/Frameworks/Sparkle.framework"
updater="$framework/Versions/B/Updater.app"
autoupdate="$framework/Versions/B/Autoupdate"
entitlements="$(release_repo_file "$repo_root" "Resources/App/Erylo.entitlements")"

# Sparkle's documented non-Xcode signing order. XPC services are intentionally
# absent for this non-sandboxed app, and --deep is intentionally never used to sign.
/usr/bin/codesign --force --sign "$identity" --options runtime --timestamp "$autoupdate"
/usr/bin/codesign --force --sign "$identity" --options runtime --timestamp "$updater"
/usr/bin/codesign --force --sign "$identity" --options runtime --timestamp "$framework"
/usr/bin/codesign --force --sign "$identity" --options runtime --timestamp --entitlements "$entitlements" "$app"

/usr/bin/codesign --verify --strict "$autoupdate"
/usr/bin/codesign --verify --strict "$updater"
/usr/bin/codesign --verify --strict "$framework"
/usr/bin/codesign --verify --deep --strict "$app"

signature_details="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)" \
    || release_die "signed application identity is unreadable"
actual_team_id="$(printf '%s\n' "$signature_details" | \
    /usr/bin/sed -nE 's/^TeamIdentifier=([A-Z0-9]{10})$/\1/p')"
[[ "$actual_team_id" =~ ^[A-Z0-9]{10}$ ]] \
    || release_die "signed application TeamIdentifier is missing or invalid"
[[ "$actual_team_id" == "$identity_team_id" ]] \
    || release_die "signed application TeamIdentifier does not match the selected identity"

printf 'Developer ID signing completed and passed codesign verification.\n'
