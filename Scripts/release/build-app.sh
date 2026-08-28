#!/bin/bash

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

release_require_command git
release_require_command ditto
if [[ -z "${ERYLO_RELEASE_TOOLCHAIN_JSON:-}" ]]; then
    release_capture_toolchain 0
fi
release_assert_toolchain
swift_tool="$(release_developer_tool_path swift)"
swiftc_tool="$(release_developer_tool_path swiftc)"
swift_frontend_tool="$(release_developer_tool_path swift-frontend)"
lipo_tool="$(release_developer_tool_path lipo)"
otool_tool="$(release_developer_tool_path otool)"
dsymutil_tool="$(release_developer_tool_path dsymutil)"

metadata_file="$(release_repo_file "$repo_root" "Config/ReleaseVersion.env")"
source_root="${ERYLO_RELEASE_SOURCE_ROOT:-$repo_root}"
target_architecture="$(release_metadata_value "$metadata_file" TARGET_ARCHITECTURE)"
minimum_system_version="$(release_metadata_value "$metadata_file" MINIMUM_SYSTEM_VERSION)"
[[ "$target_architecture" == "arm64" ]] || release_die "release metadata must select the reviewed arm64 target"
[[ "$minimum_system_version" == "14.0" ]] || release_die "release metadata must select macOS 14.0"

swift_version="$("$swift_tool" --version 2>&1)"
swift_major="$(printf '%s\n' "$swift_version" | /usr/bin/sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | /usr/bin/head -n 1)"
[[ -n "$swift_major" && "$swift_major" -ge 6 ]] || release_die "Swift 6 or newer is required"

scratch_path="$(release_output_path "$repo_root" ".release/swift-build/placeholder")"
scratch_path="$(/usr/bin/dirname "$scratch_path")"
output_path="$(release_output_path "$repo_root" ".release/build/arm64/release/placeholder")"
output_path="$(/usr/bin/dirname "$output_path")"
release_remove_path "$repo_root" "$scratch_path"
temp_dir="$(release_make_temp_dir "$repo_root" build-app)"
trap 'release_remove_path "$repo_root" "$temp_dir"' EXIT

compiler_environment=()
compiler_audit=""
if [[ "${ERYLO_RELEASE_SNAPSHOT_ACTIVE:-0}" == "1" ]]; then
    source_commit="$(release_source_commit "$repo_root")"
    source_tree="$(release_source_tree "$repo_root")"
    verified_swiftc="$(release_repo_file "$repo_root" "Scripts/release/verified-swiftc.rb")"
    compiler_audit_tool="$(release_repo_file "$repo_root" "Scripts/release/compiler-input-audit.rb")"
    release_make_directory "$repo_root" "$temp_dir/compiler-inputs" >/dev/null
    compiler_audit="$temp_dir/compiler-audit.tsv"
    compiler_environment=(
        SWIFT_EXEC="$verified_swiftc"
        ERYLO_RELEASE_REAL_SWIFTC="$swiftc_tool"
        ERYLO_RELEASE_REAL_SWIFT_FRONTEND="$swift_frontend_tool"
        ERYLO_RELEASE_SOURCE_REPOSITORY="$repo_root"
        ERYLO_RELEASE_SOURCE_ROOT="$source_root"
        ERYLO_RELEASE_SOURCE_COMMIT="$source_commit"
        ERYLO_RELEASE_COMPILER_INPUT_DIRECTORY="$temp_dir/compiler-inputs"
        ERYLO_RELEASE_COMPILER_AUDIT="$compiler_audit"
    )
fi

triple="arm64-apple-macosx${minimum_system_version}"
if [[ "${#compiler_environment[@]}" -gt 0 ]]; then
    release_build_swift_product "$swift_tool" "$source_root" "$scratch_path" Erylo "$triple" \
        "${compiler_environment[@]}"
else
    release_build_swift_product "$swift_tool" "$source_root" "$scratch_path" Erylo "$triple"
fi
bin_path="$release_swift_product_bin_path"
binary="$bin_path/Erylo"
[[ -f "$binary" && -x "$binary" && ! -L "$binary" ]] || release_die "SwiftPM did not produce the expected Erylo executable"
[[ "$("$lipo_tool" -archs "$binary")" == "arm64" ]] || release_die "release executable is not arm64-only"
"$otool_tool" -L "$binary" | /usr/bin/grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle' \
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

release_make_directory "$repo_root" "$temp_dir/output/Frameworks" >/dev/null
release_make_directory "$repo_root" "$temp_dir/output/Tools" >/dev/null
release_make_directory "$repo_root" "$temp_dir/output/Symbols" >/dev/null
printf '%s\n' "$ERYLO_RELEASE_TOOLCHAIN_JSON" > "$temp_dir/output/Toolchain.json"
/bin/chmod 0600 "$temp_dir/output/Toolchain.json"
if [[ -n "$compiler_audit" ]]; then
    "$compiler_audit_tool" create "$repo_root" "$source_commit" "$source_tree" \
        "$compiler_audit" "$temp_dir/output/CompilerInputs.json"
fi
/usr/bin/ditto "$binary" "$temp_dir/output/Erylo"
/bin/chmod 0755 "$temp_dir/output/Erylo"
"$dsymutil_tool" "$binary" -o "$temp_dir/output/Symbols/Erylo.app.dSYM"
/usr/bin/ditto "$framework" "$temp_dir/output/Frameworks/Sparkle.framework"
/usr/bin/ditto "$sign_update_tool" "$temp_dir/output/Tools/sign_update"
/usr/bin/ditto "$generate_appcast_tool" "$temp_dir/output/Tools/generate_appcast"
/usr/bin/ditto "$generate_keys_tool" "$temp_dir/output/Tools/generate_keys"
/bin/chmod 0755 \
    "$temp_dir/output/Tools/sign_update" \
    "$temp_dir/output/Tools/generate_appcast" \
    "$temp_dir/output/Tools/generate_keys"

release_publish_directory "$repo_root" "$temp_dir/output" "$output_path"

"$script_dir/validate-symbols.sh" \
    --binary "$output_path/Erylo" \
    --dsym "$output_path/Symbols/Erylo.app.dSYM" >/dev/null
if [[ -n "$compiler_audit" ]]; then
    "$compiler_audit_tool" validate "$repo_root" "$source_commit" "$source_tree" \
        "$output_path/CompilerInputs.json"
fi
release_assert_toolchain full

printf 'Release build staged at %s\n' "$output_path"
