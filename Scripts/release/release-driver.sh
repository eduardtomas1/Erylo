#!/bin/bash

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"
release_reject_outer_driver_state
release_assert_outer_capability
release_assert_lock "$repo_root"
original_arguments=("$@")

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
        *) release_die "unknown argument: $1" ;;
    esac
done

[[ -n "$identity" && -n "$keychain_profile" && -n "$appcast_config" && -n "$icon" ]] \
    || release_die "identity, Keychain profile, signed appcast config, and reviewed icon are required"
release_recover_temporaries "$repo_root"
release_require_command git
release_require_command tar
release_require_command hdiutil
source_commit="$(release_system_git rev-parse --verify HEAD)"
marketing_version="$(release_git_metadata_value "$repo_root" "$source_commit" MARKETING_VERSION)"
build_version="$(release_git_metadata_value "$repo_root" "$source_commit" BUILD_VERSION)"
release_prepare_publishable_artifacts "$repo_root" "$marketing_version" "$build_version"
release_prepare_private_artifacts "$repo_root" "$marketing_version" "$build_version"
[[ -z "$(release_system_git status --porcelain=v1 --untracked-files=normal)" ]] \
    || release_die "production releases require a clean worktree"
source_tree="$(release_system_git rev-parse --verify HEAD^{tree})"
source_epoch="$(release_system_git show -s --format=%ct "$source_commit")"
release_assert_tracked_upstream "$repo_root" "$source_commit"
release_capture_toolchain 1
release_require_reviewed_toolchain "$repo_root" "$source_commit"
snapshot_temp="$(release_make_temp_dir "$repo_root" source-snapshot)"
snapshot_staging="$snapshot_temp/staging"
snapshot_root="$snapshot_temp/mount"
snapshot_image="$snapshot_temp/source.dmg"
snapshot_attached=0
snapshot_attached_device=""
cleanup_source_snapshot() {
    local cleanup_status=$?
    local authenticated_device=""
    set +e
    if [[ "$snapshot_attached" == "1" ]]; then
        authenticated_device="$(release_authenticate_source_mount \
            "$repo_root" "$source_commit" "$snapshot_root")"
        if [[ "$?" -ne 0 || "$authenticated_device" != "$snapshot_attached_device" ]]; then
            cleanup_status=1
        else
            /usr/bin/hdiutil detach -quiet "$authenticated_device"
            [[ "$?" -eq 0 ]] || cleanup_status=1
        fi
    fi
    release_remove_path "$repo_root" "$snapshot_temp"
    [[ "$?" -eq 0 ]] || cleanup_status=1
    return "$cleanup_status"
}
trap cleanup_source_snapshot EXIT
release_make_directory "$repo_root" "$snapshot_staging" >/dev/null
release_make_directory "$repo_root" "$snapshot_root" >/dev/null
release_system_git archive --format=tar "$source_commit" | /usr/bin/tar -x -C "$snapshot_staging"
/bin/chmod -R a-w "$snapshot_staging"
/usr/bin/hdiutil create -quiet -fs APFS -format UDRO \
    -volname EryloReleaseSource -srcfolder "$snapshot_staging" "$snapshot_image"
/bin/chmod 0400 "$snapshot_image"
snapshot_image_sha256="$(/usr/bin/shasum -a 256 "$snapshot_image" | /usr/bin/awk '{print $1}')"
/usr/bin/ruby -rjson -e '
        payload = {
          "image" => "source.dmg",
          "imageSHA256" => ARGV.fetch(0),
          "mount" => "mount",
          "sourceCommit" => ARGV.fetch(1)
        }
        File.open(ARGV.fetch(2), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
          output.write(JSON.generate(payload) + "\n")
          output.flush
          output.fsync
        end
  ' "$snapshot_image_sha256" "$source_commit" "$snapshot_temp/SourceImage.json"
release_seal_file "$repo_root" "$snapshot_temp/SourceImage.json" 0400 >/dev/null
if [[ "${ERYLO_RELEASE_TESTING:-0}" == "1" \
    && "${ERYLO_RELEASE_TEST_PAUSE_STAGE:-}" == "before-source-attach" ]]; then
    /bin/kill -STOP "$$"
fi
/usr/bin/hdiutil attach -quiet -readonly -nobrowse \
    -mountpoint "$snapshot_root" "$snapshot_image"
snapshot_attached=1
snapshot_attached_device="$(release_authenticate_source_mount \
    "$repo_root" "$source_commit" "$snapshot_root")" \
    || release_die "could not authenticate the attached source image identity"
if [[ "${ERYLO_RELEASE_TESTING:-0}" == "1" \
    && "${ERYLO_RELEASE_TEST_PAUSE_STAGE:-}" == "after-source-attach" ]]; then
    /bin/kill -STOP "$$"
fi
snapshot_device="$(/usr/bin/stat -f '%d' "$snapshot_root")"
snapshot_manifest_sha256="$(release_verify_source_tree \
    "$repo_root" "$source_commit" "$snapshot_root")" \
    || release_die "could not bind the read-only source image to the release commit"
[[ "$snapshot_manifest_sha256" =~ ^[0-9a-f]{64}$ ]] \
    || release_die "read-only source image manifest is invalid"
release_remove_path "$repo_root" "$snapshot_staging"

export ERYLO_RELEASE_SNAPSHOT_ACTIVE=1
export ERYLO_RELEASE_SOURCE_ROOT="$snapshot_root"
export ERYLO_RELEASE_SOURCE_COMMIT="$source_commit"
export ERYLO_RELEASE_SOURCE_TREE="$source_tree"
export ERYLO_RELEASE_SOURCE_EPOCH="$source_epoch"
export ERYLO_RELEASE_SOURCE_DEVICE="$snapshot_device"
export ERYLO_RELEASE_SOURCE_IMAGE="$snapshot_image"
export ERYLO_RELEASE_SOURCE_IMAGE_SHA256="$snapshot_image_sha256"
export ERYLO_RELEASE_SOURCE_DISK_DEVICE="$snapshot_attached_device"
export ERYLO_RELEASE_SNAPSHOT_TEMP="$snapshot_temp"
export ERYLO_RELEASE_SNAPSHOT_MANIFEST_SHA256="$snapshot_manifest_sha256"
release_pinned_supervisor exec \
    "$repo_root" "$source_commit" "$snapshot_temp" "$snapshot_root" \
    "$snapshot_root/Scripts/release/release-worker.sh" "${original_arguments[@]}"
release_die "release worker supervisor returned unexpectedly"
