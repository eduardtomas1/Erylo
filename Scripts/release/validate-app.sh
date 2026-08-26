#!/bin/bash

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

require_updater=false
post_staple=false
while [[ "$#" -gt 0 && "$1" == --* ]]; do
    case "$1" in
        --require-updater) require_updater=true ;;
        --post-staple) post_staple=true ;;
        *) release_die "usage: $0 [--require-updater] [--post-staple] .release/.../Erylo.app" ;;
    esac
    shift
done
[[ "$#" -eq 1 ]] || release_die "usage: $0 [--require-updater] [--post-staple] .release/.../Erylo.app"
app_input="$1"
[[ ! -L "$app_input" ]] || release_die "application bundle input may not be a symlink"
app="$(release_existing_path "$repo_root" "$app_input")"
[[ -d "$app" && "$(/usr/bin/basename "$app")" == "Erylo.app" ]] || release_die "input is not a staged Erylo.app bundle"

release_require_command file
release_require_command git
release_require_command plutil
release_configure_developer_dir 0
if [[ -n "${ERYLO_RELEASE_TOOLCHAIN_JSON:-}" ]]; then
    release_assert_toolchain
fi
lipo_tool="$(release_developer_tool_path lipo)"
otool_tool="$(release_developer_tool_path otool)"

metadata_file="$(release_repo_file "$repo_root" "Config/ReleaseVersion.env")"
entitlements_file="$(release_repo_file "$repo_root" "Resources/App/Erylo.entitlements")"
erylo_license="$(release_repo_file "$repo_root" "LICENSE")"
third_party_notices="$(release_repo_file "$repo_root" "Resources/App/ThirdPartyNotices.txt")"
plist="$app/Contents/Info.plist"
executable_name="$(release_metadata_value "$metadata_file" EXECUTABLE_NAME)"
binary="$app/Contents/MacOS/$executable_name"
framework="$app/Contents/Frameworks/Sparkle.framework"
toolchain_manifest="$app/Contents/Resources/Toolchain.json"

[[ -f "$plist" && ! -L "$plist" ]] || release_die "Info.plist is missing or unsafe"
[[ -f "$binary" && -x "$binary" && ! -L "$binary" ]] || release_die "main executable is missing or unsafe"
[[ -d "$app/Contents/Resources" && ! -L "$app/Contents/Resources" ]] || release_die "Resources directory is missing or unsafe"
[[ -d "$framework" && ! -L "$framework" ]] || release_die "Sparkle framework is missing or unsafe"
[[ -f "$toolchain_manifest" && ! -L "$toolchain_manifest" ]] \
    || release_die "toolchain provenance manifest is missing or unsafe"
[[ -f "$app/Contents/PkgInfo" && "$(<"$app/Contents/PkgInfo")" == "APPL????" ]] || release_die "PkgInfo is invalid"

/usr/bin/ruby -e '
    app = File.realpath(ARGV.fetch(0))
    expected_outer = ["Contents"]
    post_staple = ARGV.fetch(1) == "true"
    expected_contents = ["Frameworks", "Info.plist", "MacOS", "PkgInfo", "Resources", "_CodeSignature"]
    expected_contents << "CodeResources" if post_staple
    outer = Dir.children(app).sort
    abort("unexpected app-bundle root layout: #{outer.inspect}") unless outer == expected_outer
    contents = Dir.children(File.join(app, "Contents"))
    unexpected = contents - expected_contents
    required = ["Frameworks", "Info.plist", "MacOS", "PkgInfo", "Resources"]
    missing = required - contents
    abort("unexpected Contents entries: #{unexpected.sort.inspect}") unless unexpected.empty?
    abort("missing Contents entries: #{missing.sort.inspect}") unless missing.empty?

    require "find"
    prefix = app + File::SEPARATOR
    Find.find(app) do |path|
      relative = path.delete_prefix(prefix)
      abort("unsafe path component") if relative.split(File::SEPARATOR).include?("..") || relative.include?("\n")
      next unless File.symlink?(path)
      target = File.realpath(path)
      abort("bundle symlink escapes application: #{relative}") unless target.start_with?(prefix)
    end
  ' "$app" "$post_staple" || release_die "bundle structure or symlink validation failed"

if [[ "$post_staple" == true ]]; then
    [[ -f "$app/Contents/CodeResources" && ! -L "$app/Contents/CodeResources" ]] \
        || release_die "post-staple validation requires one regular Contents/CodeResources ticket"
fi

bundled_erylo_license="$app/Contents/Resources/Erylo-License.txt"
bundled_third_party_notices="$app/Contents/Resources/ThirdPartyNotices.txt"
[[ -f "$bundled_erylo_license" && ! -L "$bundled_erylo_license" ]] \
    || release_die "bundled Erylo license is missing or unsafe"
[[ -f "$bundled_third_party_notices" && ! -L "$bundled_third_party_notices" ]] \
    || release_die "bundled third-party notices are missing or unsafe"
/usr/bin/cmp -s "$erylo_license" "$bundled_erylo_license" \
    || release_die "bundled Erylo license differs from the reviewed repository license"
/usr/bin/cmp -s "$third_party_notices" "$bundled_third_party_notices" \
    || release_die "bundled third-party notices differ from the reviewed release notice"
sparkle_version="$(release_metadata_value "$metadata_file" SPARKLE_VERSION)"
required_notice_lines=(
    "Sparkle $sparkle_version"
    "Copyright (c) 2006-2013 Andy Matuschak."
    "EXTERNAL LICENSES"
    "bspatch.c and bsdiff.c, from bsdiff 4.3"
    "sais.c and sais.h, from sais-lite"
    "Portable C implementation of Ed25519"
    "SUSignatureVerifier.m:"
)
for required_notice_line in "${required_notice_lines[@]}"; do
    /usr/bin/grep -Fq "$required_notice_line" "$bundled_third_party_notices" \
        || release_die "bundled third-party notices omit required Sparkle content"
done

/usr/bin/plutil -lint "$plist" >/dev/null || release_die "Info.plist is invalid"
toolchain_sha256="$(/usr/bin/shasum -a 256 "$toolchain_manifest" | /usr/bin/awk '{print $1}')"
/usr/bin/ruby -rjson -e '
    payload = JSON.parse(File.read(ARGV.fetch(0)))
    expected = [
      "kind", "macOSSDKBuildVersion", "macOSSDKPath", "macOSSDKVersion",
      "swiftCompilerVersion", "tools", "xcodeBuildVersion", "xcodeVersion"
    ]
    abort("toolchain provenance fields are noncanonical") unless payload.keys.sort == expected
    abort("toolchain kind is invalid") unless ["Xcode", "CommandLineTools"].include?(payload.fetch("kind"))
    %w[macOSSDKBuildVersion macOSSDKPath macOSSDKVersion swiftCompilerVersion xcodeBuildVersion xcodeVersion].each do |key|
      value = payload.fetch(key)
      abort("toolchain provenance value is invalid: #{key}") \
        unless value.is_a?(String) && !value.empty? && value.ascii_only? && !value.include?("\0")
    end
    expected_tools = %w[dsymutil dwarfdump install_name_tool lipo notarytool otool stapler swift swift-frontend swiftc]
    tools = payload.fetch("tools")
    abort("toolchain provenance tool set is noncanonical") unless tools.is_a?(Hash) && tools.keys.sort == expected_tools
    tools.each do |name, metadata|
      abort("toolchain provenance tool fields are noncanonical: #{name}") \
        unless metadata.is_a?(Hash) && metadata.keys.sort == %w[path sha256]
      path = metadata.fetch("path")
      hash = metadata.fetch("sha256")
      abort("toolchain provenance path is invalid: #{name}") \
        unless path.is_a?(String) && !path.empty? && !path.start_with?("/") && !path.split("/").include?("..")
      abort("toolchain provenance hash is invalid: #{name}") \
        unless hash.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(hash)
    end
  ' "$toolchain_manifest" || release_die "toolchain provenance manifest is invalid"
if [[ -n "${ERYLO_RELEASE_TOOLCHAIN_JSON:-}" ]]; then
    [[ "$(/bin/cat "$toolchain_manifest")" == "$ERYLO_RELEASE_TOOLCHAIN_JSON" \
        && "$toolchain_sha256" == "$ERYLO_RELEASE_TOOLCHAIN_SHA256" ]] \
        || release_die "bundle toolchain provenance differs from the pinned release toolchain"
fi

assert_plist_equals() {
    local key="$1"
    local expected="$2"
    local actual
    actual="$(release_plist_value "$plist" "$key")" || release_die "Info.plist is missing $key"
    [[ "$actual" == "$expected" ]] || release_die "Info.plist value mismatch for $key"
}

assert_plist_absent() {
    local key="$1"
    if release_plist_value "$plist" "$key" >/dev/null 2>&1; then
        release_die "Info.plist contains forbidden Sparkle metadata: $key"
    fi
}

assert_plist_equals CFBundleDisplayName "$(release_metadata_value "$metadata_file" PRODUCT_NAME)"
assert_plist_equals CFBundleExecutable "$executable_name"
assert_plist_equals CFBundleIdentifier "$(release_metadata_value "$metadata_file" BUNDLE_IDENTIFIER)"
assert_plist_equals CFBundlePackageType APPL
assert_plist_equals CFBundleShortVersionString "$(release_metadata_value "$metadata_file" MARKETING_VERSION)"
assert_plist_equals CFBundleVersion "$(release_metadata_value "$metadata_file" BUILD_VERSION)"
assert_plist_equals EryloReleaseArchitecture "$(release_metadata_value "$metadata_file" TARGET_ARCHITECTURE)"
assert_plist_equals EryloSourceCommit "$(release_source_commit "$repo_root")"
assert_plist_equals EryloSparkleVersion "$sparkle_version"
assert_plist_equals EryloToolchainSHA256 "$toolchain_sha256"
assert_plist_equals LSApplicationCategoryType public.app-category.utilities
assert_plist_equals LSMinimumSystemVersion "$(release_metadata_value "$metadata_file" MINIMUM_SYSTEM_VERSION)"
assert_plist_equals LSUIElement true
assert_plist_equals NSAppleEventsUsageDescription "Erylo reads current playback and now-playing details when you refresh media, and sends playback commands only when you use media controls."
assert_plist_equals NSCalendarsFullAccessUsageDescription "Erylo reads upcoming events only when Next Meeting is enabled so it can show your next event."
assert_plist_equals SUAllowsAutomaticUpdates false
assert_plist_equals SUAutomaticallyUpdate false
assert_plist_equals SUEnableAutomaticChecks false
assert_plist_equals SUEnableDownloaderService false
assert_plist_equals SUEnableInstallerLauncherService false
assert_plist_equals SUEnableSystemProfiling false
assert_plist_absent SUDefaultsDomain
assert_plist_absent SUSendProfileInfo

[[ "$("$lipo_tool" -archs "$binary")" == "arm64" ]] || release_die "main executable is not arm64-only"
minos="$("$otool_tool" -l "$binary" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
[[ "$minos" == "14.0" ]] || release_die "main executable minimum OS does not match release metadata"
"$otool_tool" -L "$binary" | /usr/bin/grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle' \
    || release_die "main executable does not link embedded Sparkle"
"$otool_tool" -l "$binary" | /usr/bin/grep -Fq '@executable_path/../Frameworks' \
    || release_die "main executable lacks the app-relative framework rpath"

[[ -f "$framework/Versions/B/Sparkle" && -x "$framework/Versions/B/Sparkle" ]] || release_die "Sparkle framework binary is missing"
[[ -f "$framework/Versions/B/Autoupdate" && -x "$framework/Versions/B/Autoupdate" ]] || release_die "Sparkle Autoupdate helper is missing"
[[ -d "$framework/Versions/B/Updater.app" ]] || release_die "Sparkle Updater helper is missing"
[[ ! -e "$framework/XPCServices" && ! -L "$framework/XPCServices" ]] || release_die "unused Sparkle XPCServices link is present"
[[ ! -e "$framework/Versions/B/XPCServices" ]] || release_die "unused Sparkle XPC services are present"
framework_version="$(release_plist_value "$framework/Resources/Info.plist" CFBundleShortVersionString)" \
    || release_die "Sparkle framework version is unreadable"
[[ "$framework_version" == "$sparkle_version" ]] \
    || release_die "embedded Sparkle version is inconsistent"
"$lipo_tool" -archs "$framework/Versions/B/Sparkle" | /usr/bin/tr ' ' '\n' | /usr/bin/grep -Fxq arm64 \
    || release_die "embedded Sparkle framework does not support arm64"

"$script_dir/validate-entitlements.sh" "$entitlements_file" >/dev/null

feed_url="$(release_plist_value "$plist" SUFeedURL || true)"
public_key="$(release_plist_value "$plist" SUPublicEDKey || true)"
if [[ -n "$feed_url" || -n "$public_key" ]]; then
    [[ -n "$feed_url" && -n "$public_key" ]] || release_die "Sparkle feed metadata is incomplete"
    assert_plist_equals SURequireSignedFeed true
    assert_plist_equals SUVerifyUpdateBeforeExtraction true
    release_validate_feed_url "$feed_url" || release_die "Sparkle feed URL is invalid"
    release_validate_public_key "$public_key" || release_die "Sparkle public key metadata is invalid"
    appcast_config_sha256="$(release_plist_value "$plist" EryloReleaseConfigSHA256 || true)"
    [[ "$appcast_config_sha256" =~ ^[0-9a-f]{64}$ ]] \
        || release_die "signed appcast configuration hash is missing or invalid"
    if [[ -n "${ERYLO_RELEASE_APPCAST_SHA256:-}" ]]; then
        [[ "$appcast_config_sha256" == "$ERYLO_RELEASE_APPCAST_SHA256" ]] \
            || release_die "bundle appcast configuration hash differs from the pinned snapshot"
    fi
elif [[ "$require_updater" == true ]]; then
    release_die "production validation requires explicit signed appcast metadata"
fi

icon_name="$(release_plist_value "$plist" CFBundleIconFile || true)"
if [[ -n "$icon_name" ]]; then
    [[ "$icon_name" == "AppIcon" && -s "$app/Contents/Resources/AppIcon.icns" ]] \
        || release_die "icon metadata does not route to a real AppIcon.icns"
    /usr/bin/file -b "$app/Contents/Resources/AppIcon.icns" | /usr/bin/grep -Fq 'Mac OS X icon' \
        || release_die "bundled AppIcon.icns is invalid"
elif [[ -e "$app/Contents/Resources/AppIcon.icns" ]]; then
    release_die "AppIcon.icns exists without CFBundleIconFile metadata"
fi

/usr/bin/ruby -e '
    require "find"
    roots = [ARGV.fetch(0), ARGV.fetch(1)]
    patterns = [
      /REPLACE[_-]?ME/i,
      /YOUR[_-](?:KEY|TOKEN|SECRET|VALUE)/i,
      /example\.invalid/i,
      /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/,
      /AKIA[0-9A-Z]{16}/,
      /gh[pousr]_[A-Za-z0-9_]{30,}/
    ]
    roots.each do |root|
      next unless File.exist?(root)
      Find.find(root) do |path|
        next unless File.file?(path) && !File.symlink?(path)
        data = File.binread(path)
        abort("placeholder or secret marker in #{path}") if patterns.any? { |pattern| data.match?(pattern) }
      end
    end
  ' "$plist" "$app/Contents/Resources" || release_die "placeholder or secret-marker validation failed"

printf 'Application bundle validation passed: %s\n' "$app"
