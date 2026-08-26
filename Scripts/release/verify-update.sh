#!/bin/bash

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

archive_input=""
metadata_input=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --archive|--signature-metadata)
            [[ "$#" -ge 2 && -n "$2" ]] || release_die "missing value for $1"
            if [[ "$1" == "--archive" ]]; then archive_input="$2"; else metadata_input="$2"; fi
            shift 2
            ;;
        --help)
            printf 'Usage: %s --archive .release/.../Erylo.zip --signature-metadata .release/.../signature.json\n' "$0"
            exit 0
            ;;
        *) release_die "unknown argument: $1" ;;
    esac
done

[[ -n "$archive_input" && -n "$metadata_input" ]] \
    || release_die "--archive and --signature-metadata are required"
archive="$(release_existing_path "$repo_root" "$archive_input")"
metadata="$(release_existing_path "$repo_root" "$metadata_input")"
tool="$(release_existing_path "$repo_root" ".release/build/arm64/release/Tools/sign_update")"
[[ -f "$archive" && "$archive" == *.zip && ! -L "$archive" ]] || release_die "update archive is invalid"
[[ -f "$metadata" && ! -L "$metadata" ]] || release_die "update signature metadata is invalid"
[[ -x "$tool" && ! -L "$tool" ]] || release_die "reviewed Sparkle verification tool is unavailable"

archive_identity="$(release_file_identity "$repo_root" "$archive")"
metadata_identity="$(release_file_identity "$repo_root" "$metadata")"
metadata_fields="$({
    /usr/bin/ruby -rbase64 -rjson -e '
      payload = JSON.parse(File.read(ARGV.fetch(0)))
      expected = [
        "appcastConfigSHA256", "archive", "length", "sourceCommit", "sourceTree",
        "sparkleEdSignature", "toolchainSHA256"
      ]
      abort("signature metadata fields are noncanonical") unless payload.keys.sort == expected
      signature = payload.fetch("sparkleEdSignature")
      decoded = Base64.strict_decode64(signature)
      abort("signature is noncanonical") unless decoded.bytesize == 64 && Base64.strict_encode64(decoded) == signature
      abort("archive name mismatch") unless payload.fetch("archive") == File.basename(ARGV.fetch(1))
      abort("archive length mismatch") unless payload.fetch("length") == File.size(ARGV.fetch(1))
      abort("toolchain identity hash is invalid") \
        unless /\A[0-9a-f]{64}\z/.match?(payload.fetch("toolchainSHA256"))
      puts signature
    ' "$metadata" "$archive"
} || true)"
[[ -n "$metadata_fields" ]] || release_die "update signature metadata is invalid"
release_assert_file_identity "$repo_root" "$archive" "$archive_identity"
release_assert_file_identity "$repo_root" "$metadata" "$metadata_identity"

temp_dir="$(release_make_temp_dir "$repo_root" verify-update)"
trap 'release_remove_path "$repo_root" "$temp_dir"' EXIT
if ! "$tool" --verify "$archive" "$metadata_fields" >"$temp_dir/verify.out" 2>"$temp_dir/verify.err"; then
    release_die "Sparkle update signature does not verify against the exact staged archive"
fi
release_assert_file_identity "$repo_root" "$archive" "$archive_identity"
release_assert_file_identity "$repo_root" "$metadata" "$metadata_identity"

printf 'Sparkle update signature verification passed for %s\n' "$archive"
