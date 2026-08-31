#!/bin/bash

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"
source_root="$(release_validated_source_root "$repo_root")"

signed_mode=false
if [[ "${1:-}" == "--signed" ]]; then
    signed_mode=true
    shift
fi
[[ "$#" -eq 1 ]] || release_die "usage: $0 [--signed] ENTITLEMENTS.plist"

entitlements="$1"
[[ -f "$entitlements" && ! -L "$entitlements" ]] || release_die "entitlements input must be a regular file"
validator="$(release_repo_file "$repo_root" "Scripts/release/validate-production-permissions.rb")"
/usr/bin/ruby "$validator" entitlements "$source_root" "$entitlements" "$signed_mode" >/dev/null \
    || release_die "entitlements failed minimality validation"

printf 'Entitlements passed minimality validation.\n'
