#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

identity=""
keychain_profile=""
appcast_config=""
icon=""
sparkle_account="ed25519"
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --identity|--keychain-profile|--appcast-config|--icon|--sparkle-account)
            [[ "$#" -ge 2 && -n "$2" ]] || release_die "missing value for $1"
            case "$1" in
                --identity) identity="$2" ;;
                --keychain-profile) keychain_profile="$2" ;;
                --appcast-config) appcast_config="$2" ;;
                --icon) icon="$2" ;;
                --sparkle-account) sparkle_account="$2" ;;
            esac
            shift 2
            ;;
        --help)
            printf 'Usage: %s --identity "Developer ID Application: ..." --keychain-profile PROFILE --appcast-config PATH --icon PATH [--sparkle-account ACCOUNT]\n' "$0"
            exit 0
            ;;
        *) release_die "unknown argument: $1" ;;
    esac
done

[[ -n "$identity" && -n "$keychain_profile" && -n "$appcast_config" && -n "$icon" ]] \
    || release_die "identity, Keychain profile, signed appcast config, and reviewed icon are required"
metadata_file="$(release_repo_file "$repo_root" "Config/ReleaseVersion.env")"
marketing_version="$(release_metadata_value "$metadata_file" MARKETING_VERSION)"
build_version="$(release_metadata_value "$metadata_file" BUILD_VERSION)"
legacy_submission_archive=".release/artifacts/Erylo-${marketing_version}-${build_version}-arm64-submission.zip"
release_remove_path "$repo_root" "$legacy_submission_archive"
release_validate_publishable_artifacts "$repo_root"

release_require_full_xcode
[[ -z "$(git status --porcelain=v1 --untracked-files=normal)" ]] \
    || release_die "production releases require a clean worktree"
appcast_path="$(release_repo_file "$repo_root" "$appcast_config")"
icon_path="$(release_repo_file "$repo_root" "$icon")"
appcast_relative="${appcast_path#"$repo_root"/}"
icon_relative="${icon_path#"$repo_root"/}"
git ls-files --error-unmatch -- "$appcast_relative" >/dev/null 2>&1 \
    || release_die "production appcast metadata must be tracked in the release commit"
git ls-files --error-unmatch -- "$icon_relative" >/dev/null 2>&1 \
    || release_die "production icon must be tracked in the release commit"

app=".release/stage/Erylo.app"
submission_archive="$(release_submission_archive_path "$marketing_version" "$build_version")"
final_archive=".release/artifacts/Erylo-${marketing_version}-${build_version}-arm64.zip"
signature_metadata="${final_archive}.sparkle-signature.json"
symbols_archive=".release/private/Erylo-${marketing_version}-${build_version}-arm64.dSYM.zip"
symbols_checksums=".release/private/SHA256SUMS"

"$script_dir/build-app.sh"
"$script_dir/archive-symbols.sh" --output "$symbols_archive"
"$script_dir/checksums.sh" --output "$symbols_checksums" "$symbols_archive"
"$script_dir/assemble-app.sh" --appcast-config "$appcast_path" --icon "$icon_path"
"$script_dir/validate-app.sh" --require-updater "$app"
"$script_dir/sign-app.sh" --identity "$identity" --app "$app"
"$script_dir/verify-signature.sh" --pre-notarization "$app"
"$script_dir/archive-app.sh" --app "$app" --output "$submission_archive"
"$script_dir/notarize-archive.sh" --archive "$submission_archive" --app "$app" --keychain-profile "$keychain_profile"
"$script_dir/staple-app.sh" "$app"
"$script_dir/archive-app.sh" --post-staple --app "$app" --output "$final_archive"
"$script_dir/sign-update.sh" \
    --archive "$final_archive" \
    --appcast-config "$appcast_path" \
    --account "$sparkle_account" \
    --output "$signature_metadata"
"$script_dir/checksums.sh" "$final_archive" "$signature_metadata"
release_validate_publishable_artifacts "$repo_root"

printf 'Release pipeline completed. Publication remains a separate, manual approval gate.\n'
