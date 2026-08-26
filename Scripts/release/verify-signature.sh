#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

mode="final"
if [[ "${1:-}" == "--pre-notarization" ]]; then
    mode="pre-notarization"
    shift
elif [[ "${1:-}" == "--notarized" ]]; then
    mode="notarized"
    shift
fi
[[ "$#" -eq 1 ]] || release_die "usage: $0 [--pre-notarization|--notarized] .release/.../Erylo.app"

release_require_command codesign
app="$(release_existing_path "$repo_root" "$1")"
if [[ "$mode" == "notarized" ]]; then
    "$script_dir/validate-app.sh" --post-staple "$app" >/dev/null
else
    "$script_dir/validate-app.sh" "$app" >/dev/null
fi

framework="$app/Contents/Frameworks/Sparkle.framework"
updater="$framework/Versions/B/Updater.app"
autoupdate="$framework/Versions/B/Autoupdate"

/usr/bin/codesign --verify --strict "$autoupdate"
/usr/bin/codesign --verify --strict "$updater"
/usr/bin/codesign --verify --strict "$framework"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

temp_dir="$(release_make_temp_dir "$repo_root" verify-signature)"
trap '/bin/rm -rf -- "$temp_dir"' EXIT
/usr/bin/codesign --display --verbose=4 "$app" >"$temp_dir/details.out" 2>"$temp_dir/details.err"
/usr/bin/grep -Eq '^Authority=Developer ID Application:' "$temp_dir/details.err" \
    || release_die "application is not signed with a Developer ID Application identity"
/usr/bin/grep -Eq '^flags=.*runtime' "$temp_dir/details.err" \
    || release_die "application signature does not enable Hardened Runtime"

/usr/bin/codesign --display --entitlements :- "$app" >"$temp_dir/entitlements.plist" 2>"$temp_dir/entitlements.err"
[[ -s "$temp_dir/entitlements.plist" ]] || release_die "signed entitlements could not be extracted"
"$script_dir/validate-entitlements.sh" --signed "$temp_dir/entitlements.plist" >/dev/null

if [[ "$mode" != "pre-notarization" ]]; then
    release_require_command spctl
    if ! /usr/sbin/spctl --assess --type execute --verbose=4 "$app" >"$temp_dir/spctl.out" 2>"$temp_dir/spctl.err"; then
        release_die "Gatekeeper assessment failed"
    fi
fi

if [[ "$mode" == "notarized" ]]; then
    release_require_notary_tools
    /usr/bin/xcrun stapler validate "$app" >/dev/null
fi

printf 'Signature verification passed (%s).\n' "$mode"
