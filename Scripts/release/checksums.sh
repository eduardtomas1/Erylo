#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

output_input=".release/artifacts/SHA256SUMS"
if [[ "${1:-}" == "--output" ]]; then
    [[ "$#" -ge 3 && -n "$2" ]] || release_die "--output requires a path and at least one input"
    output_input="$2"
    shift 2
fi
[[ "$#" -ge 1 ]] || release_die "usage: $0 [--output .release/.../SHA256SUMS] .release/.../FILE [...]"

release_require_command shasum
output="$(release_output_path "$repo_root" "$output_input")"
temp_dir="$(release_make_temp_dir "$repo_root" checksums)"
trap '/bin/rm -rf -- "$temp_dir"' EXIT

inputs_file="$temp_dir/inputs"
: > "$inputs_file"
for input in "$@"; do
    resolved="$(release_existing_path "$repo_root" "$input")"
    [[ -f "$resolved" && ! -L "$resolved" ]] || release_die "checksum input must be a regular staged file"
    [[ "$resolved" != "$output" ]] || release_die "checksum output cannot also be an input"
    basename_value="$(basename "$resolved")"
    [[ "$basename_value" =~ ^[A-Za-z0-9._-]+$ ]] || release_die "checksum input filename is unsafe"
    printf '%s\t%s\n' "$basename_value" "$resolved" >> "$inputs_file"
done

duplicate_name="$(/usr/bin/cut -f1 "$inputs_file" | /usr/bin/sort | /usr/bin/uniq -d | /usr/bin/head -n 1)"
[[ -z "$duplicate_name" ]] || release_die "checksum inputs contain duplicate basenames"

checksum_temp="$temp_dir/SHA256SUMS"
while IFS=$'\t' read -r basename_value resolved; do
    hash="$(/usr/bin/shasum -a 256 "$resolved" | /usr/bin/awk '{print $1}')"
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || release_die "could not calculate SHA-256"
    printf '%s  %s\n' "$hash" "$basename_value" >> "$checksum_temp"
done < <(LC_ALL=C /usr/bin/sort "$inputs_file")

release_remove_path "$repo_root" "$output"
/bin/mv "$checksum_temp" "$output"
printf 'Checksums written to %s\n' "$output"
