#!/bin/bash

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

archive_input=""
output_input=""
account="ed25519"
appcast_input=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --archive|--output|--account|--appcast-config)
            [[ "$#" -ge 2 && -n "$2" ]] || release_die "missing value for $1"
            case "$1" in
                --archive) archive_input="$2" ;;
                --output) output_input="$2" ;;
                --account) account="$2" ;;
                --appcast-config) appcast_input="$2" ;;
            esac
            shift 2
            ;;
        --help)
            printf 'Usage: %s --archive .release/.../Erylo.zip --appcast-config PATH [--account KEYCHAIN_ACCOUNT] [--output .release/.../signature.json]\n' "$0"
            exit 0
            ;;
        *) release_die "unknown argument: $1" ;;
    esac
done

[[ -n "$archive_input" && -n "$appcast_input" ]] || release_die "--archive and --appcast-config are required"
[[ "$account" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || release_die "invalid Sparkle Keychain account name"

archive="$(release_existing_path "$repo_root" "$archive_input")"
[[ -f "$archive" && "$archive" == *.zip && ! -L "$archive" ]] || release_die "update archive must be a staged ZIP file"
archive_identity="$(release_file_identity "$repo_root" "$archive")"
tool="$(release_existing_path "$repo_root" ".release/build/arm64/release/Tools/sign_update")"
generate_keys_tool="$(release_existing_path "$repo_root" ".release/build/arm64/release/Tools/generate_keys")"
toolchain_manifest="$(release_existing_path "$repo_root" ".release/build/arm64/release/Toolchain.json")"
[[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || release_die "reviewed Sparkle sign_update tool is unavailable"
[[ -f "$generate_keys_tool" && -x "$generate_keys_tool" && ! -L "$generate_keys_tool" ]] \
    || release_die "reviewed Sparkle generate_keys tool is unavailable"
[[ -f "$toolchain_manifest" && ! -L "$toolchain_manifest" ]] \
    || release_die "build toolchain provenance is unavailable"
toolchain_sha256="$(/usr/bin/shasum -a 256 "$toolchain_manifest" | /usr/bin/awk '{print $1}')"
[[ "$toolchain_sha256" =~ ^[0-9a-f]{64}$ ]] || release_die "build toolchain provenance hash is invalid"
if [[ -n "${ERYLO_RELEASE_TOOLCHAIN_SHA256:-}" ]]; then
    [[ "$toolchain_sha256" == "$ERYLO_RELEASE_TOOLCHAIN_SHA256" \
        && "$(/bin/cat "$toolchain_manifest")" == "$ERYLO_RELEASE_TOOLCHAIN_JSON" ]] \
        || release_die "build toolchain provenance differs from the pinned release toolchain"
fi
appcast_file="$(release_repo_file "$repo_root" "$appcast_input")"
source_commit="$(release_source_commit "$repo_root")"
source_tree="$(release_source_tree "$repo_root")"
appcast_config_sha256="$(/usr/bin/shasum -a 256 "$appcast_file" | /usr/bin/awk '{print $1}')"
[[ "$appcast_config_sha256" =~ ^[0-9a-f]{64}$ ]] || release_die "could not hash appcast configuration"
if [[ -n "${ERYLO_RELEASE_APPCAST_SHA256:-}" ]]; then
    [[ "$appcast_config_sha256" == "$ERYLO_RELEASE_APPCAST_SHA256" ]] \
        || release_die "appcast configuration differs from the pinned release snapshot"
fi
feed_url="$(release_plist_value "$appcast_file" SUFeedURL)" || release_die "appcast config is missing SUFeedURL"
configured_public_key="$(release_plist_value "$appcast_file" SUPublicEDKey)" \
    || release_die "appcast config is missing SUPublicEDKey"
signed_feed="$(release_plist_value "$appcast_file" SURequireSignedFeed)" \
    || release_die "appcast config is missing SURequireSignedFeed"
verify_before_extraction="$(release_plist_value "$appcast_file" SUVerifyUpdateBeforeExtraction)" \
    || release_die "appcast config is missing SUVerifyUpdateBeforeExtraction"
[[ "$signed_feed" == "true" && "$verify_before_extraction" == "true" ]] \
    || release_die "appcast config must require a signed feed and pre-extraction verification"
release_validate_feed_url "$feed_url" || release_die "appcast feed URL is invalid"
release_validate_public_key "$configured_public_key" || release_die "appcast public key is invalid or noncanonical"
release_require_full_xcode
if [[ -z "$output_input" ]]; then
    output_input="${archive}.sparkle-signature.json"
fi
output="$(release_output_path "$repo_root" "$output_input")"

temp_dir="$(release_make_temp_dir "$repo_root" sign-update)"
trap 'release_remove_path "$repo_root" "$temp_dir"' EXIT
if ! "$generate_keys_tool" --account "$account" -p >"$temp_dir/public-key" 2>"$temp_dir/key-lookup.err"; then
    release_die "Sparkle Keychain account is unavailable; no key was generated"
fi
keychain_public_key="$(/usr/bin/tr -d '\r\n' < "$temp_dir/public-key")"
[[ "$keychain_public_key" == "$configured_public_key" ]] \
    || release_die "Sparkle Keychain account does not match the configured public EdDSA key"
release_assert_file_identity "$repo_root" "$archive" "$archive_identity"
if ! "$tool" --account "$account" -p "$archive" >"$temp_dir/signature" 2>"$temp_dir/signing.err"; then
    release_die "Sparkle signing key is unavailable or update signing failed"
fi
release_assert_file_identity "$repo_root" "$archive" "$archive_identity"
signature="$(/usr/bin/tr -d '\r\n' < "$temp_dir/signature")"
/usr/bin/ruby -rbase64 -e '
    signature = ARGV.fetch(0)
    decoded = Base64.strict_decode64(signature)
    abort unless decoded.bytesize == 64 && Base64.strict_encode64(decoded) == signature
  ' "$signature" || release_die "Sparkle sign_update returned an invalid EdDSA signature"

release_assert_file_identity "$repo_root" "$archive" "$archive_identity"
if ! "$tool" --account "$account" --verify "$archive" "$signature" >"$temp_dir/verify.out" 2>"$temp_dir/verify.err"; then
    release_die "Sparkle update signature verification failed"
fi
release_assert_file_identity "$repo_root" "$archive" "$archive_identity"

archive_name="$(/usr/bin/basename "$archive")"
archive_size="$(/usr/bin/stat -f '%z' "$archive")"
release_assert_file_identity "$repo_root" "$archive" "$archive_identity"
/usr/bin/ruby -rjson -e '
    payload = {
      "archive" => ARGV.fetch(0),
      "length" => Integer(ARGV.fetch(1)),
      "sparkleEdSignature" => ARGV.fetch(2),
      "sourceCommit" => ARGV.fetch(3),
      "sourceTree" => ARGV.fetch(4),
      "appcastConfigSHA256" => ARGV.fetch(5),
      "toolchainSHA256" => ARGV.fetch(6)
    }
    File.write(ARGV.fetch(7), JSON.pretty_generate(payload) + "\n")
  ' "$archive_name" "$archive_size" "$signature" \
    "$source_commit" "$source_tree" "$appcast_config_sha256" "$toolchain_sha256" \
    "$temp_dir/signature.json"

release_publish_file "$repo_root" "$temp_dir/signature.json" "$output"
printf 'Sparkle update signature metadata written to %s\n' "$output"
