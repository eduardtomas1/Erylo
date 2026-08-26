#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

bin_path="$(swift build --show-bin-path)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/erylo-media-api.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT

printf '%s\n' \
    'import EryloIntegrations' \
    'func acceptsValidatedBoundary(_ value: ProcessMediaScriptExecutor, _ request: MediaScriptRequest) {}' \
    > "$check_dir/validated.swift"
swiftc -typecheck -I "$bin_path/Modules" "$check_dir/validated.swift"

printf '%s\n' \
    'import EryloIntegrations' \
    'let rawRunner: FoundationMediaScriptProcessRunner? = nil' \
    > "$check_dir/raw-runner.swift"
if swiftc -typecheck -I "$bin_path/Modules" "$check_dir/raw-runner.swift" \
    > /dev/null 2>&1; then
    printf 'ERROR: production clients can reach the raw media process runner.\n' >&2
    exit 1
fi

printf '%s\n' \
    'import EryloIntegrations' \
    'let rawProtocol: (any MediaScriptProcessRunning)? = nil' \
    > "$check_dir/raw-protocol.swift"
if swiftc -typecheck -I "$bin_path/Modules" "$check_dir/raw-protocol.swift" \
    > /dev/null 2>&1; then
    printf 'ERROR: production clients can reach the arbitrary-argv process protocol.\n' >&2
    exit 1
fi

printf 'Media API surface check passed.\n'
