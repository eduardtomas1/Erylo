#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

release_require_command swift
release_require_command git
release_require_command lipo
release_require_command otool
release_require_command ditto
release_require_command dsymutil

metadata_file="$(release_repo_file "$repo_root" "Config/ReleaseVersion.env")"
target_architecture="$(release_metadata_value "$metadata_file" TARGET_ARCHITECTURE)"
minimum_system_version="$(release_metadata_value "$metadata_file" MINIMUM_SYSTEM_VERSION)"
[[ "$target_architecture" == "arm64" ]] || release_die "release metadata must select the reviewed arm64 target"
[[ "$minimum_system_version" == "14.0" ]] || release_die "release metadata must select macOS 14.0"

swift_version="$(swift --version)"
swift_major="$(printf '%s\n' "$swift_version" | /usr/bin/sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | /usr/bin/head -n 1)"
[[ -n "$swift_major" && "$swift_major" -ge 6 ]] || release_die "Swift 6 or newer is required"

scratch_path="$(release_output_path "$repo_root" ".release/swift-build/placeholder")"
scratch_path="$(dirname "$scratch_path")"
output_path="$(release_output_path "$repo_root" ".release/build/arm64/release/placeholder")"
output_path="$(dirname "$output_path")"
release_remove_path "$repo_root" "$scratch_path"
temp_dir="$(release_make_temp_dir "$repo_root" build-app)"
trap '/bin/rm -rf -- "$temp_dir"' EXIT

triple="arm64-apple-macosx${minimum_system_version}"
build_arguments=(
    --package-path "$repo_root"
    --scratch-path "$scratch_path"
    --configuration release
    --product Erylo
    --triple "$triple"
    --disable-index-store
    -Xswiftc -warnings-as-errors
)

swift build "${build_arguments[@]}"
bin_path="$(swift build "${build_arguments[@]}" --show-bin-path)"
binary="$bin_path/Erylo"
[[ -f "$binary" && -x "$binary" && ! -L "$binary" ]] || release_die "SwiftPM did not produce the expected Erylo executable"
[[ "$(lipo -archs "$binary")" == "arm64" ]] || release_die "release executable is not arm64-only"
otool -L "$binary" | /usr/bin/grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle' \
    || release_die "release executable is not linked to the reviewed Sparkle framework"

framework=""
framework_count=0
while IFS= read -r candidate; do
    framework="$candidate"
    framework_count=$((framework_count + 1))
done < <(/usr/bin/find "$scratch_path/artifacts" -type d -name Sparkle.framework -print 2>/dev/null)
[[ "$framework_count" -eq 1 && -n "$framework" ]] || release_die "expected exactly one resolved Sparkle.framework artifact"
sparkle_artifact_root="${framework%%/Sparkle.xcframework/*}"
sign_update_tool="$sparkle_artifact_root/bin/sign_update"
generate_appcast_tool="$sparkle_artifact_root/bin/generate_appcast"
generate_keys_tool="$sparkle_artifact_root/bin/generate_keys"
[[ -f "$sign_update_tool" && -x "$sign_update_tool" ]] || release_die "resolved Sparkle sign_update tool is missing"
[[ -f "$generate_appcast_tool" && -x "$generate_appcast_tool" ]] || release_die "resolved Sparkle generate_appcast tool is missing"
[[ -f "$generate_keys_tool" && -x "$generate_keys_tool" ]] || release_die "resolved Sparkle generate_keys tool is missing"

/bin/mkdir -p "$temp_dir/output/Frameworks" "$temp_dir/output/Tools" "$temp_dir/output/Symbols"
/usr/bin/ditto "$binary" "$temp_dir/output/Erylo"
/bin/chmod 0755 "$temp_dir/output/Erylo"
/usr/bin/dsymutil "$binary" -o "$temp_dir/output/Symbols/Erylo.app.dSYM"
/usr/bin/ditto "$framework" "$temp_dir/output/Frameworks/Sparkle.framework"
/usr/bin/ditto "$sign_update_tool" "$temp_dir/output/Tools/sign_update"
/usr/bin/ditto "$generate_appcast_tool" "$temp_dir/output/Tools/generate_appcast"
/usr/bin/ditto "$generate_keys_tool" "$temp_dir/output/Tools/generate_keys"
/bin/chmod 0755 \
    "$temp_dir/output/Tools/sign_update" \
    "$temp_dir/output/Tools/generate_appcast" \
    "$temp_dir/output/Tools/generate_keys"

release_remove_path "$repo_root" "$output_path"
/bin/mv "$temp_dir/output" "$output_path"

"$script_dir/validate-symbols.sh" \
    --binary "$output_path/Erylo" \
    --dsym "$output_path/Symbols/Erylo.app.dSYM" >/dev/null

printf 'Release build staged at %s\n' "$output_path"
