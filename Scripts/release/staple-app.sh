#!/bin/bash

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

[[ "$#" -eq 1 ]] || release_die "usage: $0 .release/.../Erylo.app"
release_require_notary_tools
app="$(release_existing_path "$repo_root" "$1")"
"$script_dir/verify-signature.sh" --pre-notarization "$app" >/dev/null
release_xcrun stapler staple "$app"
release_xcrun stapler validate "$app"
release_assert_toolchain full
"$script_dir/verify-signature.sh" --notarized "$app" >/dev/null
printf 'Notarization ticket stapled and validated.\n'
