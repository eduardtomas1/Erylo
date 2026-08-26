#!/bin/bash

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

[[ "${ERYLO_RELEASE_SNAPSHOT_ACTIVE:-0}" == "1" \
    && "${ERYLO_RELEASE_SUPERVISOR_HANDOFF:-0}" == "1" ]] \
    || release_die "release worker is missing the supervisor snapshot handoff"

# Consume the one-use ordering token without resolving any candidate-root
# executable. Then authenticate the real APFS image, exact Git verifier bytes,
# clean live checkout, and tracked upstream using pinned system tools. Only an
# authenticated source root may supply the filesystem helper used for the lock
# assertion and subsequent release work.
release_assert_worker_capability
source_commit="$(release_source_commit "$repo_root")"
source_tree="$(release_source_tree "$repo_root")"
release_assert_source_snapshot "$repo_root" "$source_commit" "$source_tree"
release_assert_tracked_upstream "$repo_root" "$source_commit"
release_assert_lock "$repo_root"

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
        *) release_die "unknown release worker argument: $1" ;;
    esac
done

[[ -n "$identity" && -n "$keychain_profile" && -n "$appcast_config" && -n "$icon" ]] \
    || release_die "identity, Keychain profile, signed appcast config, and reviewed icon are required"

source_root="${ERYLO_RELEASE_SOURCE_ROOT}"
# Repeat source/upstream admission after parsing and before staging mutation.
release_assert_source_snapshot "$repo_root" "$source_commit" "$source_tree"
release_assert_tracked_upstream "$repo_root" "$source_commit"
metadata_file="$(release_repo_file "$repo_root" "Config/ReleaseVersion.env")"
marketing_version="$(release_metadata_value "$metadata_file" MARKETING_VERSION)"
build_version="$(release_metadata_value "$metadata_file" BUILD_VERSION)"
release_prepare_publishable_artifacts "$repo_root" "$marketing_version" "$build_version"
release_prepare_private_artifacts "$repo_root" "$marketing_version" "$build_version"

release_require_full_xcode
release_assert_toolchain
release_require_reviewed_toolchain "$repo_root" "$source_commit"
appcast_path="$(release_repo_file "$repo_root" "$appcast_config")"
icon_path="$(release_repo_file "$repo_root" "$icon")"
appcast_relative="${appcast_path#"$source_root"/}"
icon_relative="${icon_path#"$source_root"/}"
release_system_git cat-file -e "$source_commit:$appcast_relative" 2>/dev/null \
    || release_die "production appcast metadata must be tracked in the release commit"
release_system_git cat-file -e "$source_commit:$icon_relative" 2>/dev/null \
    || release_die "production icon must be tracked in the release commit"
appcast_config_sha256="$(/usr/bin/shasum -a 256 "$appcast_path" | /usr/bin/awk '{print $1}')"
[[ "$appcast_config_sha256" =~ ^[0-9a-f]{64}$ ]] || release_die "could not hash pinned appcast configuration"
export ERYLO_RELEASE_APPCAST_SHA256="$appcast_config_sha256"

app=".release/stage/Erylo.app"
submission_archive="$(release_submission_archive_path "$marketing_version" "$build_version" "$source_commit")"
final_archive=".release/artifacts/Erylo-${marketing_version}-${build_version}-arm64.zip"
signature_metadata="${final_archive}.sparkle-signature.json"
private_temp="$(release_make_temp_dir "$repo_root" private-publication)"
publication_temp=""
cleanup_release_temporaries() {
    local cleanup_status=0
    if [[ -n "$publication_temp" ]]; then
        release_remove_path "$repo_root" "$publication_temp" || cleanup_status=1
    fi
    release_remove_path "$repo_root" "$private_temp" || cleanup_status=1
    return "$cleanup_status"
}
trap cleanup_release_temporaries EXIT
private_dir="$private_temp/current"
release_make_directory "$repo_root" "$private_dir" >/dev/null
symbols_archive="$private_dir/Erylo-${marketing_version}-${build_version}-${source_commit:0:12}-arm64.dSYM.zip"
symbols_manifest="$private_dir/ReleaseManifest.json"
symbols_checksums="$private_dir/SHA256SUMS"

"$script_dir/build-app.sh"
"$script_dir/archive-symbols.sh" --output "$symbols_archive"
/usr/bin/ruby -rjson -e '
    payload = {
      "archive" => ARGV.fetch(0),
      "marketingVersion" => ARGV.fetch(1),
      "buildVersion" => ARGV.fetch(2),
      "sourceCommit" => ARGV.fetch(3),
      "sourceTree" => ARGV.fetch(4),
      "appcastConfigSHA256" => ARGV.fetch(5),
      "toolchainSHA256" => ARGV.fetch(6)
    }
    File.write(ARGV.fetch(7), JSON.pretty_generate(payload) + "\n", mode: "w", perm: 0o600)
  ' "$(/usr/bin/basename "$symbols_archive")" "$marketing_version" "$build_version" \
    "$source_commit" "$source_tree" "$appcast_config_sha256" \
    "$ERYLO_RELEASE_TOOLCHAIN_SHA256" "$symbols_manifest"
"$script_dir/checksums.sh" --output "$symbols_checksums" "$symbols_archive" "$symbols_manifest"
release_validate_private_artifacts "$repo_root" "$private_dir" \
    "$marketing_version" "$build_version" "$source_commit" "$source_tree" \
    "$appcast_config_sha256" "$ERYLO_RELEASE_TOOLCHAIN_SHA256"
"$script_dir/assemble-app.sh" --appcast-config "$appcast_path" --icon "$icon_path"
"$script_dir/validate-app.sh" --require-updater "$app"
"$script_dir/sign-app.sh" --identity "$identity" --app "$app"
"$script_dir/verify-signature.sh" --pre-notarization "$app"
"$script_dir/archive-app.sh" --app "$app" --output "$submission_archive"
release_seal_file "$repo_root" "$submission_archive" 0400 >/dev/null
"$script_dir/notarize-archive.sh" --archive "$submission_archive" --app "$app" --keychain-profile "$keychain_profile"
"$script_dir/staple-app.sh" "$app"
publication_temp="$(release_make_temp_dir "$repo_root" final-publication)"
publication_dir="$publication_temp/current"
release_make_directory "$repo_root" "$publication_dir" >/dev/null
final_archive="$publication_dir/$(/usr/bin/basename "$final_archive")"
signature_metadata="${final_archive}.sparkle-signature.json"
publication_checksums="$publication_dir/SHA256SUMS"
"$script_dir/archive-app.sh" --post-staple --app "$app" --output "$final_archive"
release_seal_file "$repo_root" "$final_archive" 0400 >/dev/null
"$script_dir/sign-update.sh" \
    --archive "$final_archive" \
    --appcast-config "$appcast_path" \
    --account "$sparkle_account" \
    --output "$signature_metadata"
"$script_dir/checksums.sh" --output "$publication_checksums" "$final_archive" "$signature_metadata"
release_validate_publishable_artifacts \
    "$repo_root" "$marketing_version" "$build_version" complete "$publication_dir" \
    "$source_commit" "$source_tree" "$appcast_config_sha256" "$ERYLO_RELEASE_TOOLCHAIN_SHA256"
"$script_dir/verify-update.sh" --archive "$final_archive" --signature-metadata "$signature_metadata"
final_archive_identity="$(release_file_identity "$repo_root" "$final_archive")"
signature_metadata_identity="$(release_file_identity "$repo_root" "$signature_metadata")"
publication_checksums_identity="$(release_file_identity "$repo_root" "$publication_checksums")"
release_assert_source_snapshot "$repo_root" "$source_commit" "$source_tree"
release_assert_compiler_inputs "$repo_root" "$source_commit" "$source_tree"
release_assert_toolchain full
release_require_reviewed_toolchain "$repo_root" "$source_commit"
release_publish_private_artifacts "$repo_root" "$private_dir" \
    "$marketing_version" "$build_version" "$source_commit" "$source_tree" \
    "$appcast_config_sha256" "$ERYLO_RELEASE_TOOLCHAIN_SHA256"
release_publish_artifact_directory "$repo_root" "$publication_dir" "$marketing_version" "$build_version" none \
    "$source_commit" "$source_tree" "$appcast_config_sha256" "$ERYLO_RELEASE_TOOLCHAIN_SHA256" \
    "$final_archive_identity" "$signature_metadata_identity" "$publication_checksums_identity"

printf 'Release pipeline completed. Publication remains a separate, manual approval gate.\n'
