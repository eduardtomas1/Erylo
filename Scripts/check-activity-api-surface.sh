#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

bin_path="$(swift build --show-bin-path)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/erylo-activity-api.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

printf '%s\n' \
    'import EryloActivity' \
    'func subscribeSafely(_ broker: ActivityBroker) async throws {' \
    '    _ = try await broker.snapshots()' \
    '}' \
    > "$check_dir/safe-stream.swift"
swiftc -typecheck -swift-version 6 -warnings-as-errors \
    -I "$bin_path/Modules" "$check_dir/safe-stream.swift"

printf '%s\n' \
    'import EryloCore' \
    'func describeLegacyPanelEvent(_ event: PanelEvent) -> Int {' \
    '    switch event {' \
    '    case .show: return 0' \
    '    case .hide: return 1' \
    '    case .hoverBegan: return 2' \
    '    case .hoverEnded: return 3' \
    '    case .primaryAction: return 4' \
    '    case .dragEntered: return 5' \
    '    case .dragExited: return 6' \
    '    case .dropCompleted: return 7' \
    '    case .dismiss: return 8' \
    '    }' \
    '}' \
    > "$check_dir/legacy-panel-event-switch.swift"
swiftc -typecheck -swift-version 6 -warnings-as-errors \
    -I "$bin_path/Modules" "$check_dir/legacy-panel-event-switch.swift"

printf '%s\n' \
    'import EryloCore' \
    'import EryloWindowing' \
    '@MainActor' \
    'func legacyCallsRemainSynchronous(_ coordinator: PanelCoordinator, policy: DisplayPolicy) async {' \
    '    coordinator.start()' \
    '    coordinator.update(policy: policy)' \
    '    coordinator.stop()' \
    '}' \
    '@MainActor' \
    'func explicitPhysicalBarriers(_ coordinator: PanelCoordinator, policy: DisplayPolicy) async {' \
    '    await coordinator.startAndWait()' \
    '    await coordinator.updateAndWait(policy: policy)' \
    '    await coordinator.stopAndWait()' \
    '}' \
    > "$check_dir/coordinator-lifecycle-overloads.swift"
swiftc -typecheck -swift-version 6 -warnings-as-errors \
    -I "$bin_path/Modules" "$check_dir/coordinator-lifecycle-overloads.swift"

printf '%s\n' \
    'import EryloActivity' \
    'import Foundation' \
    'func registerWithExternalIdentity(_ broker: ActivityBroker) async throws {' \
    '    _ = try await broker.snapshots(subscriberID: UUID())' \
    '}' \
    > "$check_dir/explicit-registration.swift"
if swiftc -typecheck -swift-version 6 -warnings-as-errors \
    -I "$bin_path/Modules" "$check_dir/explicit-registration.swift" \
    > /dev/null 2>&1; then
    printf 'ERROR: production clients can register an explicit ActivityBroker subscriber identity.\n' >&2
    exit 1
fi

printf '%s\n' \
    'import EryloActivity' \
    'import Foundation' \
    'func reachPackageRegistration(_ broker: ActivityBroker) async throws {' \
    '    _ = try await broker.snapshotSubscription(subscriberID: UUID())' \
    '}' \
    > "$check_dir/package-registration.swift"
if swiftc -typecheck -swift-version 6 -warnings-as-errors \
    -I "$bin_path/Modules" "$check_dir/package-registration.swift" \
    > /dev/null 2>&1; then
    printf 'ERROR: production clients can reach package ActivityBroker subscription ownership.\n' >&2
    exit 1
fi

printf '%s\n' \
    'import EryloActivity' \
    'import Foundation' \
    'func cancelWithExternalIdentity(_ broker: ActivityBroker) async {' \
    '    await broker.cancelSnapshotSubscription(subscriberID: UUID())' \
    '}' \
    > "$check_dir/explicit-cancellation.swift"
if swiftc -typecheck -swift-version 6 -warnings-as-errors \
    -I "$bin_path/Modules" "$check_dir/explicit-cancellation.swift" \
    > /dev/null 2>&1; then
    printf 'ERROR: production clients can cancel ActivityBroker ownership by UUID alone.\n' >&2
    exit 1
fi

public_probe_dir="$check_dir/public-surface-probe"
arbitrary_checkout_path="$check_dir/activity-surface-source"
mkdir -p "$public_probe_dir/Sources/PublicSurfaceProbe"
ln -s "$repo_root" "$arbitrary_checkout_path"
cp Tests/PublicSurfaceProbe/main.swift \
    "$public_probe_dir/Sources/PublicSurfaceProbe/main.swift"
printf '%s\n' \
    '// swift-tools-version: 6.0' \
    '' \
    'import PackageDescription' \
    '' \
    'let package = Package(' \
    '    name: "PublicSurfaceProbe",' \
    '    platforms: [.macOS(.v14)],' \
    '    dependencies: [.package(name: "Erylo", path: "'"$arbitrary_checkout_path"'")],' \
    '    targets: [' \
    '        .executableTarget(' \
    '            name: "PublicSurfaceProbe",' \
    '            dependencies: [' \
    '                .product(name: "EryloActivity", package: "Erylo"),' \
    '                .product(name: "EryloCore", package: "Erylo"),' \
    '                .product(name: "EryloGlance", package: "Erylo"),' \
    '                .product(name: "EryloIntegrations", package: "Erylo"),' \
    '                .product(name: "EryloSurface", package: "Erylo"),' \
    '                .product(name: "EryloWindowing", package: "Erylo"),' \
    '            ],' \
    '            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]' \
    '        ),' \
    '    ],' \
    '    swiftLanguageModes: [.v6]' \
    ')' \
    > "$public_probe_dir/Package.swift"

run_public_probe() {
    local configuration="$1"
    local scratch_path="$2"
    local bin_path

    swift build --package-path "$public_probe_dir" \
        --scratch-path "$scratch_path" \
        --jobs 2 \
        -c "$configuration" \
        --product PublicSurfaceProbe
    bin_path="$(
        swift build --package-path "$public_probe_dir" \
            --scratch-path "$scratch_path" \
            -c "$configuration" \
            --show-bin-path
    )"
    "$bin_path/PublicSurfaceProbe"
}

run_public_probe debug "$check_dir/public-debug-build"
run_public_probe release "$check_dir/public-release-build"

printf 'Arbitrary-basename dependency identity check passed.\n'
printf 'Activity API surface check passed.\n'
