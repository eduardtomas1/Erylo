#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
checker="$repo_root/.github/scripts/check-repository.sh"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/erylo-repository-check.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT

fail() {
    printf 'ERROR: repository-check regression failed (%s).\n' "${1:-unspecified}" >&2
    exit 1
}

initialize_fixture_repository() {
    local directory="$1"

    mkdir -p "$directory"
    git -C "$directory" init -q
    printf 'fixture\n' > "$directory/README.md"
    git -C "$directory" add README.md
}

expect_check_failure() {
    local directory="$1"
    local output_file="$2"

    if (cd "$directory" && "$checker") > "$output_file" 2>&1; then
        fail "scanner accepted fixture"
    fi
}

assert_not_logged() {
    local output_file="$1"
    local forbidden="$2"
    local label="$3"

    if LC_ALL=C grep -Fq -- "$forbidden" "$output_file"; then
        fail "$label"
    fi
}

fine_grained_prefix='github_'
fine_grained_prefix+='pat_'
fine_grained_token="${fine_grained_prefix}$(printf '%082d' 0)"
private_key_marker='-----BEGIN TEST '
private_key_marker+='PRIVATE KEY-----'

binary_repo="$fixture_root/binary"
binary_output="$fixture_root/binary-output"
initialize_fixture_repository "$binary_repo"
printf '\000binary-prefix\000%s\n%s\n' \
    "$fine_grained_token" \
    "$private_key_marker" \
    > "$binary_repo/binary-secret.dat"
git -C "$binary_repo" add binary-secret.dat
expect_check_failure "$binary_repo" "$binary_output"
assert_not_logged "$binary_output" "$fine_grained_token" "binary token leaked"
assert_not_logged "$binary_output" "$private_key_marker" "binary key marker leaked"
assert_not_logged "$binary_output" "binary-prefix" "binary matching line leaked"
LC_ALL=C grep -Fq -- 'FILE: binary-secret.dat' "$binary_output" || fail "binary filename missing"
LC_ALL=C grep -Fq -- 'ERROR: tracked content contains a private-key marker' "$binary_output" \
    || fail "binary key marker not detected"
LC_ALL=C grep -Fq -- 'ERROR: tracked content contains a high-confidence credential pattern' \
    "$binary_output" || fail "binary token not detected"

hostile_repo="$fixture_root/hostile"
hostile_output="$fixture_root/hostile-output"
initialize_fixture_repository "$hostile_repo"
hostile_name=$'hostile\n'
hostile_name+="$fine_grained_token"
hostile_name+=$'\t.txt'
matching_line="credential=$fine_grained_token"
printf '%s\n' "$matching_line" > "$hostile_repo/$hostile_name"
git -C "$hostile_repo" add -- "$hostile_name"
expect_check_failure "$hostile_repo" "$hostile_output"
assert_not_logged "$hostile_output" "$fine_grained_token" "filename token leaked"
assert_not_logged "$hostile_output" "$matching_line" "matching line leaked"
assert_not_logged "$hostile_output" $'\t' "filename tab leaked"
if ruby -e 'exit(File.binread(ARGV.fetch(0)).include?("FILE: hostile\n") ? 0 : 1)' \
    "$hostile_output"; then
    fail "filename newline leaked"
fi
LC_ALL=C grep -Fq -- 'FILE: hostile?[REDACTED]?.txt' "$hostile_output" \
    || fail "hostile filename not sanitized"

error_repo="$fixture_root/error"
error_output="$fixture_root/error-output"
fake_bin="$fixture_root/bin"
real_git="$(command -v git)"
initialize_fixture_repository "$error_repo"
mkdir -p "$fake_bin"
# These variables expand in the generated wrapper, not in this process.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1" == "grep" ]]; then exit 2; fi' \
    'exec "$ERYLO_REAL_GIT" "$@"' \
    > "$fake_bin/git"
chmod +x "$fake_bin/git"
if (cd "$error_repo" && PATH="$fake_bin:$PATH" ERYLO_REAL_GIT="$real_git" "$checker") \
    > "$error_output" 2>&1; then
    fail "scanner error accepted"
fi
LC_ALL=C grep -Fq -- 'ERROR: tracked-content credential scan failed' "$error_output" \
    || fail "scanner error not reported"

printf 'Repository-check regressions passed.\n'
