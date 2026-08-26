#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

binary_input=".release/build/arm64/release/Erylo"
dsym_input=".release/build/arm64/release/Symbols/Erylo.app.dSYM"
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --binary|--dsym)
            [[ "$#" -ge 2 && -n "$2" ]] || release_die "missing value for $1"
            if [[ "$1" == "--binary" ]]; then binary_input="$2"; else dsym_input="$2"; fi
            shift 2
            ;;
        --help)
            printf 'Usage: %s [--binary .release/.../Erylo] [--dsym .release/.../Erylo.app.dSYM]\n' "$0"
            exit 0
            ;;
        *) release_die "unknown argument: $1" ;;
    esac
done

release_require_command dwarfdump
release_require_command lipo
binary="$(release_existing_path "$repo_root" "$binary_input")"
dsym="$(release_existing_path "$repo_root" "$dsym_input")"
[[ -f "$binary" && -x "$binary" && ! -L "$binary" ]] || release_die "symbol binary must be a regular executable"
[[ -d "$dsym" && "$(basename "$dsym")" == "Erylo.app.dSYM" && ! -L "$dsym" ]] \
    || release_die "dSYM input must be a staged Erylo.app.dSYM directory"
[[ -f "$dsym/Contents/Info.plist" && ! -L "$dsym/Contents/Info.plist" ]] \
    || release_die "dSYM Info.plist is missing or unsafe"
[[ -z "$(/usr/bin/find "$dsym" -type l -print -quit)" ]] || release_die "dSYM may not contain symlinks"

dwarf="$dsym/Contents/Resources/DWARF/Erylo"
[[ -f "$dwarf" && ! -L "$dwarf" ]] || release_die "dSYM contains no regular Erylo DWARF image"
[[ "$(/usr/bin/find "$dsym/Contents/Resources/DWARF" -type f -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "1" ]] \
    || release_die "dSYM must contain exactly one DWARF image"
[[ "$(/usr/bin/lipo -archs "$binary")" == "arm64" ]] || release_die "symbol binary must be arm64-only"
[[ "$(/usr/bin/lipo -archs "$dwarf")" == "arm64" ]] || release_die "dSYM DWARF image must be arm64-only"

temp_dir="$(release_make_temp_dir "$repo_root" validate-symbols)"
trap '/bin/rm -rf -- "$temp_dir"' EXIT
/usr/bin/dwarfdump --uuid "$binary" > "$temp_dir/binary-uuids"
/usr/bin/dwarfdump --uuid "$dsym" > "$temp_dir/dsym-uuids"
/usr/bin/ruby -e '
    pattern = /\AUUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\) /
    sets = ARGV.map do |path|
      lines = File.readlines(path, chomp: true)
      parsed = lines.map { |line| pattern.match(line)&.captures }.compact
      abort("UUID output is missing or malformed") if parsed.empty? || parsed.length != lines.length
      parsed.map { |uuid, arch| [uuid.downcase, arch] }.sort
    end
    abort("dSYM UUIDs do not exactly match executable UUIDs") unless sets[0] == sets[1]
  ' "$temp_dir/binary-uuids" "$temp_dir/dsym-uuids" || release_die "dSYM UUID validation failed"

printf 'dSYM validation passed: %s\n' "$dsym"
