#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

readonly swift_targets=(
    EryloActivityTests
    EryloFoundationTests
    EryloFileHoldTests
    EryloGlanceTests
    EryloMediaTests
    EryloTrustTests
    EryloIntegrationTests
    EryloSurfaceTests
    EryloUpdateTests
    EryloAppRuntimeTests
)

usage() {
    printf 'Usage: %s {build|api-surface|target TARGET|sanitizer SANITIZER}\n' "$0" >&2
    exit 64
}

require_swift_6() {
    local swift_version
    local swift_major

    swift_version="$(swift --version)"
    printf '%s\n' "$swift_version"
    swift_major="$(printf '%s\n' "$swift_version" | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -n 1)"
    if [[ -z "$swift_major" || "$swift_major" -lt 6 ]]; then
        printf 'ERROR: Swift 6 or newer is required.\n' >&2
        exit 1
    fi
}

require_target() {
    local requested="$1"
    local target

    for target in "${swift_targets[@]}"; do
        if [[ "$requested" == "$target" ]]; then
            return 0
        fi
    done

    printf 'ERROR: unsupported CI target.\n' >&2
    exit 64
}

run_harness() {
    local executable="$1"

    # GitHub's shell may inherit runner-control descriptors. The media harness
    # deliberately audits descriptors 3...255, so give every harness the same
    # stdio-only parent contract before it tests descriptors opened by Erylo.
    /bin/bash -c '
        for ((descriptor = 3; descriptor < 256; descriptor++)); do
            eval "exec ${descriptor}>&-"
        done
        exec "$1"
    ' ci-harness "$executable"
}

run_target() {
    local target="$1"
    local bin_path

    require_target "$target"
    swift build --jobs 2 --product "$target" -Xswiftc -warnings-as-errors
    bin_path="$(swift build --show-bin-path)"
    run_harness "$bin_path/$target"
}

run_sanitized_harnesses() {
    local sanitizer="$1"
    local bin_path
    local target
    local swiftc_arguments=(-Xswiftc -warnings-as-errors)

    case "$sanitizer" in
        address|thread) ;;
        *)
            printf 'ERROR: unsupported sanitizer.\n' >&2
            exit 64
            ;;
    esac

    if [[ "$sanitizer" == "thread" ]]; then
        swiftc_arguments+=(-Xswiftc -D -Xswiftc ERYLO_THREAD_SANITIZER)
    fi

    swift build --sanitize "$sanitizer" "${swiftc_arguments[@]}"
    bin_path="$(swift build --sanitize "$sanitizer" --show-bin-path)"
    for target in "${swift_targets[@]}"; do
        printf 'Running %s with %s sanitizer.\n' "$target" "$sanitizer"
        run_harness "$bin_path/$target"
    done
}

[[ $# -ge 1 ]] || usage
require_swift_6

case "$1" in
    build)
        [[ $# -eq 1 ]] || usage
        swift build -Xswiftc -warnings-as-errors
        ;;
    api-surface)
        [[ $# -eq 1 ]] || usage
        swift build --jobs 2 -Xswiftc -warnings-as-errors
        /usr/bin/ruby Scripts/release/validate-compiler-input-policy.rb "$repo_root"
        /usr/bin/ruby Scripts/release/validate-production-permissions.rb repository "$repo_root"
        Scripts/check-activity-api-surface.sh
        Scripts/check-media-api-surface.sh
        Scripts/check-system-glance-api-surface.sh
        ;;
    target)
        [[ $# -eq 2 ]] || usage
        run_target "$2"
        ;;
    sanitizer)
        [[ $# -eq 2 ]] || usage
        run_sanitized_harnesses "$2"
        ;;
    *)
        usage
        ;;
esac
