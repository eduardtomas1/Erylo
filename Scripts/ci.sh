#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

swift_version="$(swift --version)"
printf '%s\n' "$swift_version"
swift_major="$(printf '%s\n' "$swift_version" | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -n 1)"
if [[ -z "$swift_major" || "$swift_major" -lt 6 ]]; then
    printf 'ERROR: Swift 6 or newer is required.\n' >&2
    exit 1
fi

swift build -Xswiftc -warnings-as-errors
Scripts/check-activity-api-surface.sh
Scripts/check-media-api-surface.sh
swift run EryloActivityTests
swift run EryloFoundationTests
swift run EryloFileHoldTests
swift run EryloGlanceTests
swift run EryloMediaTests
swift run EryloTrustTests
swift run EryloIntegrationTests
swift run EryloSurfaceTests
swift run EryloUpdateTests
swift run EryloAppRuntimeTests
bash Tests/ReleaseHarness/run.sh

if command -v shellcheck >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    shellcheck $(git ls-files '*.sh')
else
    printf 'shellcheck is unavailable; bash -n validation remains enforced by repository controls.\n'
fi
