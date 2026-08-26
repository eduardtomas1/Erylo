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

swift build
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
