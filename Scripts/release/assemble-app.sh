#!/bin/bash

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

binary_input=".release/build/arm64/release/Erylo"
framework_input=".release/build/arm64/release/Frameworks/Sparkle.framework"
toolchain_input=".release/build/arm64/release/Toolchain.json"
output_input=".release/stage/Erylo.app"
metadata_input="Config/ReleaseVersion.env"
appcast_input=""
icon_input=""

usage() {
    printf 'Usage: %s [--binary PATH] [--framework PATH] [--output .release/.../Erylo.app] [--metadata PATH] [--appcast-config PATH] [--icon PATH]\n' "$0"
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --binary|--framework|--toolchain|--output|--metadata|--appcast-config|--icon)
            [[ "$#" -ge 2 && -n "$2" ]] || release_die "missing value for $1"
            case "$1" in
                --binary) binary_input="$2" ;;
                --framework) framework_input="$2" ;;
                --toolchain) toolchain_input="$2" ;;
                --output) output_input="$2" ;;
                --metadata) metadata_input="$2" ;;
                --appcast-config) appcast_input="$2" ;;
                --icon) icon_input="$2" ;;
            esac
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            release_die "unknown argument: $1"
            ;;
    esac
done

output="$(release_output_path "$repo_root" "$output_input")"
[[ "$output" == *.app && "$(/usr/bin/basename "$output")" == "Erylo.app" ]] \
    || release_die "assembled output must be a release-staged Erylo.app"

release_require_command git
release_require_command ditto
release_require_command plutil
appcast_file=""
feed_url=""
public_key=""
appcast_config_sha256=""
if [[ -n "$appcast_input" ]]; then
    appcast_file="$(release_repo_file "$repo_root" "$appcast_input")"
    /usr/bin/plutil -lint "$appcast_file" >/dev/null || release_die "appcast config is not a valid plist"
    feed_url="$(release_plist_value "$appcast_file" SUFeedURL)" \
        || release_die "appcast config is missing SUFeedURL"
    public_key="$(release_plist_value "$appcast_file" SUPublicEDKey)" \
        || release_die "appcast config is missing SUPublicEDKey"
    signed_feed="$(release_plist_value "$appcast_file" SURequireSignedFeed)" \
        || release_die "appcast config is missing SURequireSignedFeed"
    verify_before_extraction="$(release_plist_value "$appcast_file" SUVerifyUpdateBeforeExtraction)" \
        || release_die "appcast config is missing SUVerifyUpdateBeforeExtraction"
    release_validate_signed_appcast_metadata \
        "$feed_url" "$public_key" "$signed_feed" "$verify_before_extraction"
    appcast_config_sha256="$(/usr/bin/shasum -a 256 "$appcast_file" | /usr/bin/awk '{print $1}')"
    [[ "$appcast_config_sha256" =~ ^[0-9a-f]{64}$ ]] \
        || release_die "could not hash signed appcast configuration"
    if [[ -n "${ERYLO_RELEASE_APPCAST_SHA256:-}" ]]; then
        [[ "$appcast_config_sha256" == "$ERYLO_RELEASE_APPCAST_SHA256" ]] \
            || release_die "appcast configuration differs from the pinned release snapshot"
    fi
fi
if [[ -z "${ERYLO_RELEASE_TOOLCHAIN_JSON:-}" ]]; then
    release_capture_toolchain 0
fi
release_assert_toolchain
lipo_tool="$(release_developer_tool_path lipo)"
otool_tool="$(release_developer_tool_path otool)"
install_name_tool="$(release_developer_tool_path install_name_tool)"

binary="$(release_existing_path "$repo_root" "$binary_input")"
framework="$(release_existing_path "$repo_root" "$framework_input")"
toolchain="$(release_existing_path "$repo_root" "$toolchain_input")"
metadata_file="$(release_repo_file "$repo_root" "$metadata_input")"
template="$(release_repo_file "$repo_root" "Resources/App/Info.plist.in")"
erylo_license="$(release_repo_file "$repo_root" "LICENSE")"
third_party_notices="$(release_repo_file "$repo_root" "Resources/App/ThirdPartyNotices.txt")"

[[ -f "$binary" && -x "$binary" && ! -L "$binary" ]] || release_die "binary input must be a regular executable"
[[ -d "$framework" && ! -L "$framework" ]] || release_die "framework input must be a real directory"
[[ -f "$toolchain" && ! -L "$toolchain" ]] || release_die "toolchain provenance input is missing"
toolchain_json="$(/bin/cat "$toolchain")"
[[ "$toolchain_json" == "$ERYLO_RELEASE_TOOLCHAIN_JSON" ]] \
    || release_die "build toolchain provenance differs from the selected toolchain"
toolchain_sha256="$(/usr/bin/shasum -a 256 "$toolchain" | /usr/bin/awk '{print $1}')"
[[ "$toolchain_sha256" == "$ERYLO_RELEASE_TOOLCHAIN_SHA256" ]] \
    || release_die "build toolchain provenance hash is inconsistent"
[[ "$("$lipo_tool" -archs "$binary")" == "arm64" ]] || release_die "binary input must be arm64-only"
"$otool_tool" -L "$binary" | /usr/bin/grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle' \
    || release_die "binary input does not link Sparkle through an app-relative rpath"

product_name="$(release_metadata_value "$metadata_file" PRODUCT_NAME)"
executable_name="$(release_metadata_value "$metadata_file" EXECUTABLE_NAME)"
bundle_identifier="$(release_metadata_value "$metadata_file" BUNDLE_IDENTIFIER)"
marketing_version="$(release_metadata_value "$metadata_file" MARKETING_VERSION)"
build_version="$(release_metadata_value "$metadata_file" BUILD_VERSION)"
minimum_system_version="$(release_metadata_value "$metadata_file" MINIMUM_SYSTEM_VERSION)"
target_architecture="$(release_metadata_value "$metadata_file" TARGET_ARCHITECTURE)"
sparkle_version="$(release_metadata_value "$metadata_file" SPARKLE_VERSION)"
source_commit="$(release_source_commit "$repo_root")"

[[ "$product_name" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ ]] || release_die "invalid product name metadata"
[[ "$executable_name" =~ ^[A-Za-z][A-Za-z0-9._-]{0,63}$ ]] || release_die "invalid executable name metadata"
[[ "$bundle_identifier" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$ && "$bundle_identifier" == *.* ]] \
    || release_die "invalid bundle identifier metadata"
[[ "$marketing_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || release_die "invalid marketing version metadata"
[[ "$build_version" =~ ^[1-9][0-9]{0,17}$ ]] || release_die "invalid build version metadata"
[[ "$minimum_system_version" == "14.0" ]] || release_die "minimum system version must remain 14.0"
[[ "$target_architecture" == "arm64" ]] || release_die "target architecture must remain arm64"
[[ "$sparkle_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || release_die "invalid Sparkle version metadata"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || release_die "invalid source commit"

framework_plist="$framework/Resources/Info.plist"
[[ -f "$framework_plist" ]] || release_die "Sparkle framework Info.plist is missing"
resolved_sparkle_version="$(release_plist_value "$framework_plist" CFBundleShortVersionString)" \
    || release_die "Sparkle framework version is unreadable"
[[ "$resolved_sparkle_version" == "$sparkle_version" ]] || release_die "Sparkle framework version does not match release metadata"

temp_dir="$(release_make_temp_dir "$repo_root" assemble-app)"
trap 'release_remove_path "$repo_root" "$temp_dir"' EXIT
temp_app="$temp_dir/Erylo.app"
release_make_directory "$repo_root" "$temp_app/Contents/MacOS" >/dev/null
release_make_directory "$repo_root" "$temp_app/Contents/Resources" >/dev/null
release_make_directory "$repo_root" "$temp_app/Contents/Frameworks" >/dev/null

/usr/bin/ditto "$binary" "$temp_app/Contents/MacOS/$executable_name"
/bin/chmod 0755 "$temp_app/Contents/MacOS/$executable_name"
/usr/bin/ditto "$framework" "$temp_app/Contents/Frameworks/Sparkle.framework"
/usr/bin/ditto "$erylo_license" "$temp_app/Contents/Resources/Erylo-License.txt"
/usr/bin/ditto "$third_party_notices" "$temp_app/Contents/Resources/ThirdPartyNotices.txt"
/usr/bin/ditto "$toolchain" "$temp_app/Contents/Resources/Toolchain.json"
/bin/chmod 0644 \
    "$temp_app/Contents/Resources/Erylo-License.txt" \
    "$temp_app/Contents/Resources/ThirdPartyNotices.txt" \
    "$temp_app/Contents/Resources/Toolchain.json"

sparkle_destination="$temp_app/Contents/Frameworks/Sparkle.framework"
if [[ -L "$sparkle_destination/XPCServices" ]]; then
    release_remove_path "$repo_root" "$sparkle_destination/XPCServices" file
fi
if [[ -d "$sparkle_destination/Versions/B/XPCServices" ]]; then
    release_remove_path "$repo_root" "$sparkle_destination/Versions/B/XPCServices"
fi
if [[ -d "$sparkle_destination/Versions/B/_CodeSignature" ]]; then
    release_remove_path "$repo_root" "$sparkle_destination/Versions/B/_CodeSignature"
fi

app_binary="$temp_app/Contents/MacOS/$executable_name"
if ! "$otool_tool" -l "$app_binary" | /usr/bin/grep -Fq '@executable_path/../Frameworks'; then
    "$install_name_tool" -add_rpath '@executable_path/../Frameworks' "$app_binary"
fi

/bin/cp "$template" "$temp_app/Contents/Info.plist"
plist="$temp_app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "$product_name" "$plist"
/usr/bin/plutil -replace CFBundleExecutable -string "$executable_name" "$plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_identifier" "$plist"
/usr/bin/plutil -replace CFBundleName -string "$product_name" "$plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$marketing_version" "$plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_version" "$plist"
/usr/bin/plutil -replace EryloReleaseArchitecture -string "$target_architecture" "$plist"
/usr/bin/plutil -replace EryloSourceCommit -string "$source_commit" "$plist"
/usr/bin/plutil -replace EryloSparkleVersion -string "$sparkle_version" "$plist"
/usr/bin/plutil -replace EryloToolchainSHA256 -string "$toolchain_sha256" "$plist"
/usr/bin/plutil -replace LSMinimumSystemVersion -string "$minimum_system_version" "$plist"

if [[ -n "$appcast_input" ]]; then
    /usr/bin/plutil -insert SUFeedURL -string "$feed_url" "$plist"
    /usr/bin/plutil -insert SUPublicEDKey -string "$public_key" "$plist"
    /usr/bin/plutil -insert SURequireSignedFeed -bool true "$plist"
    /usr/bin/plutil -insert SUVerifyUpdateBeforeExtraction -bool true "$plist"
    /usr/bin/plutil -insert EryloReleaseConfigSHA256 -string "$appcast_config_sha256" "$plist"
fi

if [[ -n "$icon_input" ]]; then
    icon_file="$(release_repo_file "$repo_root" "$icon_input")"
    [[ "$icon_file" == *.icns && -s "$icon_file" ]] || release_die "icon input must be a non-empty .icns file"
    /usr/bin/file -b "$icon_file" | /usr/bin/grep -Fq 'Mac OS X icon' || release_die "icon input is not an ICNS resource"
    /usr/bin/ditto "$icon_file" "$temp_app/Contents/Resources/AppIcon.icns"
    /usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$plist"
fi

/usr/bin/plutil -lint "$plist" >/dev/null || release_die "assembled Info.plist is invalid"
printf 'APPL????' > "$temp_app/Contents/PkgInfo"

release_publish_directory "$repo_root" "$temp_app" "$output"
release_assert_toolchain full

printf 'Application bundle assembled at %s\n' "$output"
