#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

archive_input=""
app_input=".release/stage/Erylo.app"
keychain_profile=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --archive|--app|--keychain-profile)
            [[ "$#" -ge 2 && -n "$2" ]] || release_die "missing value for $1"
            case "$1" in
                --archive) archive_input="$2" ;;
                --app) app_input="$2" ;;
                --keychain-profile) keychain_profile="$2" ;;
            esac
            shift 2
            ;;
        --help)
            printf 'Usage: %s --archive .release/.../Erylo.zip --keychain-profile PROFILE [--app .release/.../Erylo.app]\n' "$0"
            exit 0
            ;;
        *) release_die "unknown argument: $1" ;;
    esac
done

[[ -n "$archive_input" ]] || release_die "--archive is required"
profile_pattern='^[A-Za-z0-9._ -]{1,128}$'
[[ "$keychain_profile" =~ $profile_pattern ]] || release_die "a valid notarytool Keychain profile is required"
release_require_notary_tools

archive="$(release_existing_path "$repo_root" "$archive_input")"
app="$(release_existing_path "$repo_root" "$app_input")"
[[ -f "$archive" && "$archive" == *.zip && ! -L "$archive" ]] || release_die "notarization input must be a staged ZIP archive"
"$script_dir/verify-signature.sh" --pre-notarization "$app" >/dev/null
"$script_dir/validate-archive.sh" --archive "$archive" --app "$app" >/dev/null

temp_dir="$(release_make_temp_dir "$repo_root" notarize)"
trap '/bin/rm -rf -- "$temp_dir"' EXIT
if ! /usr/bin/xcrun notarytool history --keychain-profile "$keychain_profile" --output-format json \
    >"$temp_dir/profile-check.json" 2>"$temp_dir/profile-check.err"; then
    release_die "notarytool Keychain profile is unavailable or cannot authenticate noninteractively"
fi

result_path=".release/notarization/$(basename "$archive").submission.json"
if ! /usr/bin/xcrun notarytool submit "$archive" --keychain-profile "$keychain_profile" \
    --wait --timeout 30m --output-format json >"$temp_dir/submission.json" 2>"$temp_dir/submission.err"; then
    if [[ -s "$temp_dir/submission.json" ]]; then
        release_publish_file "$repo_root" "$temp_dir/submission.json" "$result_path"
    fi
    release_die "notary submission failed; no notarization is claimed"
fi

status="$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("status", "")' "$temp_dir/submission.json")"
release_publish_file "$repo_root" "$temp_dir/submission.json" "$result_path"
[[ "$status" == "Accepted" ]] || release_die "notary service did not accept the archive; inspect staged submission metadata"

printf 'Notary service accepted the archive; submission metadata is at %s\n' \
    "$(release_existing_path "$repo_root" "$result_path")"
