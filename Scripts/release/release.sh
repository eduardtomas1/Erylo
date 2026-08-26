#!/bin/bash

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

# This is the only public production entry. Never trust caller-declared lock,
# snapshot, supervisor, or worker roles; reject internal state before the lock
# helper scrubs the environment and mints the one-use admission capability.
release_reject_external_snapshot_state
if [[ "$#" -eq 1 && "$1" == "--help" ]]; then
    printf 'Usage: Scripts/release/release.sh --identity "Developer ID Application: ..." --keychain-profile PROFILE --appcast-config PATH --icon PATH [--sparkle-account ACCOUNT]\n'
    exit 0
fi
exec /usr/bin/ruby "$script_dir/fs-helper.rb" run-locked "$repo_root" \
    "$script_dir/release-driver.sh" "$@"
