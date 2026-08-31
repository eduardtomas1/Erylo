#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

bin_path="$(swift build --show-bin-path)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/erylo-system-glance-api.XXXXXX")"
trap 'rm -rf -- "$check_dir"' EXIT

cat > "$check_dir/public-contract.swift" <<'SWIFT'
import EryloActivity
import EryloGlance

actor OriginalShapeBroker: GlanceActivityBroker {
    func submit(_ request: ActivityRequest) async throws -> ActivityBrokerSnapshot {
        _ = request
        fatalError("type-check only")
    }

    func cancel(_ identity: ActivityIdentity) async -> Bool {
        _ = identity
        return false
    }
}

func describe(_ capability: GlanceProviderCapability) -> Int {
    switch capability {
    case .unknownWhileDisabled: 0
    case .available: 1
    case .unavailable: 2
    case .permissionRequired: 3
    case .permissionDenied: 4
    case .restricted: 5
    }
}

func volumeSnapshotCompatibility() throws {
    _ = try VolumeSnapshot(deviceID: 1, scalar: 0.5, isMuted: false)
    _ = try VolumeSnapshot(
        deviceID: 1,
        scalar: 0.5,
        isMuted: false,
        outputDisplayName: "Public output"
    )
}
SWIFT
swiftc -typecheck -swift-version 6 -warnings-as-errors \
    -I "$bin_path/Modules" -F "$bin_path" "$check_dir/public-contract.swift"

probe_package_symbol() {
    local module="$1"
    local symbol="$2"
    local type_reference="${3:-$module.$symbol}"
    local expected_error
    if [[ $# -ge 4 ]]; then
        expected_error="$4"
    else
        expected_error="no type named '${symbol}' in module '${module}'"
    fi
    local probe="$check_dir/package-$module-$symbol.swift"
    local access_error="$check_dir/package-$module-$symbol.stderr"

    printf '%s\n' \
        "import $module" \
        "let packageOnlyValue: $type_reference? = nil" \
        > "$probe"

    # Prove the declaration exists for another target in this package.
    swiftc -typecheck -swift-version 6 -warnings-as-errors \
        -package-name erylo -I "$bin_path/Modules" -F "$bin_path" "$probe"

    # Prove an external client is rejected for this exact declaration, rather
    # than accepting an unrelated compiler or dependency failure as success.
    if swiftc -typecheck -swift-version 6 -warnings-as-errors \
        -I "$bin_path/Modules" -F "$bin_path" "$probe" \
        > /dev/null 2> "$access_error"; then
        printf 'ERROR: package-only %s leaked into public API.\n' "$symbol" >&2
        exit 1
    fi
    if ! grep -Fq "$expected_error" \
        "$access_error"; then
        printf 'ERROR: %s probe did not fail for the expected package access boundary.\n' \
            "$symbol" >&2
        sed -n '1,12p' "$access_error" >&2
        exit 1
    fi
}

probe_package_symbol EryloAppRuntime SystemGlanceRuntimeError
probe_package_symbol EryloAppRuntime SystemGlanceModuleProviderFactory
probe_package_symbol EryloAppRuntime PowerGlanceLifecycleAdapter
probe_package_symbol EryloAppRuntime VolumeGlanceLifecycleAdapter
probe_package_symbol \
    EryloGlance \
    GlanceActivationEventRelay \
    'GlanceActivationEventRelay<Int>' \
    "cannot find type 'GlanceActivationEventRelay' in scope"

control_source="Sources/EryloAppRuntime/ApplicationControlPlane.swift"
composition_source="Sources/EryloAppRuntime/ApplicationRuntime.swift"
volume_source="Sources/EryloGlance/GlanceEventSources.swift"
app_runtime_sources=(Sources/EryloAppRuntime/*.swift)

count_occurrences() {
    local needle="$1"
    awk -v needle="$needle" '
        {
            remainder = $0
            while ((position = index(remainder, needle)) != 0) {
                count += 1
                remainder = substr(remainder, position + length(needle))
            }
        }
        END { print count + 0 }
    ' "${app_runtime_sources[@]}"
}

assert_occurrence_count() {
    local needle="$1"
    local expected="$2"
    local actual

    actual="$(count_occurrences "$needle")"
    if [[ "$actual" -ne "$expected" ]]; then
        printf 'ERROR: expected %s occurrence(s) of %s across EryloAppRuntime; found %s.\n' \
            "$expected" "$needle" "$actual" >&2
        return 1
    fi
}

assert_source_contains() {
    local source="$1"
    local expected="$2"

    if ! grep -Fq "$expected" "$source"; then
        printf 'ERROR: %s is missing required composition: %s\n' \
            "$source" "$expected" >&2
        return 1
    fi
}

expect_assertion_failure() {
    local label="$1"
    shift

    if "$@" > /dev/null 2>&1; then
        printf 'ERROR: negative regression did not reject perturbed %s assertion.\n' \
            "$label" >&2
        exit 1
    fi
}

assert_occurrence_count 'PowerGlanceProvider(' 1 || exit 1
assert_occurrence_count 'VolumeGlanceProvider(' 1 || exit 1
assert_occurrence_count 'CountdownGlanceProvider(' 1 || exit 1
assert_occurrence_count 'CalendarGlanceProvider(' 0 || exit 1
assert_occurrence_count 'EventKitCalendarEventSource(' 0 || exit 1
assert_occurrence_count 'IOPowerEventSource(' 1 || exit 1
assert_occurrence_count 'CoreAudioVolumeEventSource(' 1 || exit 1

expect_assertion_failure PowerGlanceProvider \
    assert_occurrence_count 'PowerGlanceProvider(' 2
expect_assertion_failure VolumeGlanceProvider \
    assert_occurrence_count 'VolumeGlanceProvider(' 2
expect_assertion_failure CountdownGlanceProvider \
    assert_occurrence_count 'CountdownGlanceProvider(' 2
expect_assertion_failure CalendarGlanceProvider \
    assert_occurrence_count 'CalendarGlanceProvider(' 1
expect_assertion_failure EventKitCalendarEventSource \
    assert_occurrence_count 'EventKitCalendarEventSource(' 1
expect_assertion_failure IOPowerEventSource \
    assert_occurrence_count 'IOPowerEventSource(' 2
expect_assertion_failure CoreAudioVolumeEventSource \
    assert_occurrence_count 'CoreAudioVolumeEventSource(' 2

mounted_providers="$({
    grep -hEo '[A-Za-z_][A-Za-z0-9_]*GlanceProvider\(' \
        "${app_runtime_sources[@]}" || true
} | LC_ALL=C sort)"
expected_providers="$(printf '%s\n' \
    'CountdownGlanceProvider(' \
    'PowerGlanceProvider(' \
    'VolumeGlanceProvider(' \
    | LC_ALL=C sort)"
assert_provider_allowlist() {
    local observed="$1"
    local expected="$2"

    if [[ "$observed" != "$expected" ]]; then
        printf 'ERROR: EryloAppRuntime mounted Glance provider set is not closed.\n' >&2
        printf 'Observed:\n%s\n' "$observed" >&2
        return 1
    fi
}

assert_provider_allowlist "$mounted_providers" "$expected_providers" || exit 1
expect_assertion_failure providerAllowlist \
    assert_provider_allowlist \
        "$mounted_providers"$'\nCalendarGlanceProvider(' \
        "$expected_providers"

assert_source_contains \
    "$control_source" \
    'availableModules: [.battery, .volume]' \
    || exit 1
assert_source_contains \
    "$composition_source" \
    'ApplicationControlPlane.production(activityBroker: activityBroker)' \
    || exit 1
expect_assertion_failure availableModules \
    assert_source_contains "$control_source" 'availableModules: [.battery]'
expect_assertion_failure sharedActivityBroker \
    assert_source_contains "$composition_source" \
        'ApplicationControlPlane.production(activityBroker: ActivityBroker())'

assert_source_contains \
    "$volume_source" \
    'mSelector: kAudioObjectPropertyName' \
    || exit 1

output_name_sources="$({
    git grep -l --fixed-strings 'outputDisplayName' -- 'Sources/**/*.swift' || true
} | LC_ALL=C sort)"
expected_output_name_sources="$(printf '%s\n' \
    'Sources/EryloGlance/GlanceDomain.swift' \
    'Sources/EryloGlance/GlanceEventSources.swift' \
    | LC_ALL=C sort)"
if [[ "$output_name_sources" != "$expected_output_name_sources" ]]; then
    printf 'ERROR: default-output display names escaped their nonpersistent Glance boundary.\n' >&2
    printf 'Observed:\n%s\n' "$output_name_sources" >&2
    exit 1
fi

printf 'System Glance API and production-mount checks passed.\n'
