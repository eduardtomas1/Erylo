#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
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
tool="$(release_existing_path "$repo_root" ".release/build/arm64/release/Tools/sign_update")"
generate_keys_tool="$(release_existing_path "$repo_root" ".release/build/arm64/release/Tools/generate_keys")"
[[ -f "$tool" && -x "$tool" && ! -L "$tool" ]] || release_die "reviewed Sparkle sign_update tool is unavailable"
[[ -f "$generate_keys_tool" && -x "$generate_keys_tool" && ! -L "$generate_keys_tool" ]] \
    || release_die "reviewed Sparkle generate_keys tool is unavailable"
appcast_file="$(release_repo_file "$repo_root" "$appcast_input")"
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
/usr/bin/ruby -rbase64 -e '
    abort unless Base64.strict_decode64(ARGV.fetch(0)).bytesize == 32
  ' "$configured_public_key" || release_die "appcast public key is invalid"
release_require_full_xcode
if [[ -z "$output_input" ]]; then
    output_input="${archive}.sparkle-signature.json"
fi
output="$(release_output_path "$repo_root" "$output_input")"

temp_dir="$(release_make_temp_dir "$repo_root" sign-update)"
trap '/bin/rm -rf -- "$temp_dir"' EXIT
if ! "$generate_keys_tool" --account "$account" -p >"$temp_dir/public-key" 2>"$temp_dir/key-lookup.err"; then
    release_die "Sparkle Keychain account is unavailable; no key was generated"
fi
keychain_public_key="$(/usr/bin/tr -d '\r\n' < "$temp_dir/public-key")"
[[ "$keychain_public_key" == "$configured_public_key" ]] \
    || release_die "Sparkle Keychain account does not match the configured public EdDSA key"
if ! "$tool" --account "$account" -p "$archive" >"$temp_dir/signature" 2>"$temp_dir/signing.err"; then
    release_die "Sparkle signing key is unavailable or update signing failed"
fi
signature="$(/usr/bin/tr -d '\r\n' < "$temp_dir/signature")"
/usr/bin/ruby -rbase64 -e '
    signature = ARGV.fetch(0)
    abort unless Base64.strict_decode64(signature).bytesize == 64
  ' "$signature" || release_die "Sparkle sign_update returned an invalid EdDSA signature"

if ! "$tool" --account "$account" --verify "$archive" "$signature" >"$temp_dir/verify.out" 2>"$temp_dir/verify.err"; then
    release_die "Sparkle update signature verification failed"
fi

archive_name="$(basename "$archive")"
archive_size="$(/usr/bin/stat -f '%z' "$archive")"
/usr/bin/ruby -rjson -e '
    payload = {
      "archive" => ARGV.fetch(0),
      "length" => Integer(ARGV.fetch(1)),
      "sparkleEdSignature" => ARGV.fetch(2)
    }
    File.write(ARGV.fetch(3), JSON.pretty_generate(payload) + "\n")
  ' "$archive_name" "$archive_size" "$signature" "$temp_dir/signature.json"

release_remove_path "$repo_root" "$output"
/bin/mv "$temp_dir/signature.json" "$output"
printf 'Sparkle update signature metadata written to %s\n' "$output"
