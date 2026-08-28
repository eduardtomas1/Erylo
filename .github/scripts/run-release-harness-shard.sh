#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

shard="${1:-}"
manifest="Tests/ReleaseHarness/shards.tsv"
contract="$(/usr/bin/awk -F '\t' -v shard="$shard" '$1 == shard { print $2 "\t" $3 }' "$manifest")"
[[ -n "$contract" && "$(printf '%s\n' "$contract" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == 1 ]] || {
    printf 'unknown deterministic release-harness shard: %s\n' "$shard" >&2
    exit 64
}
IFS=$'\t' read -r expected_checks timeout_seconds <<< "$contract"
[[ "${2:-$expected_checks}" == "$expected_checks" ]] || {
    printf 'release-harness matrix count drift for %s: workflow=%s manifest=%s\n' \
        "$shard" "${2:-missing}" "$expected_checks" >&2
    exit 65
}
[[ "${3:-$timeout_seconds}" == "$timeout_seconds" ]] || {
    printf 'release-harness matrix timeout drift for %s: workflow=%s manifest=%s\n' \
        "$shard" "${3:-missing}" "$timeout_seconds" >&2
    exit 65
}

state_path="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/erylo-release-harness-${shard}.json"
exec /usr/bin/ruby Tests/ReleaseHarness/process-supervisor.rb run \
    "$state_path" "release-harness-${shard}" "$timeout_seconds" 5 -- \
    /bin/bash Tests/ReleaseHarness/run.sh "$shard"
