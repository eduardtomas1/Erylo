#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

binary_input=".release/build/arm64/release/Erylo"
dsym_input=".release/build/arm64/release/Symbols/Erylo.app.dSYM"
output_input=""
source_date_epoch="${SOURCE_DATE_EPOCH:-}"
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --binary|--dsym|--output|--source-date-epoch)
            [[ "$#" -ge 2 && -n "$2" ]] || release_die "missing value for $1"
            case "$1" in
                --binary) binary_input="$2" ;;
                --dsym) dsym_input="$2" ;;
                --output) output_input="$2" ;;
                --source-date-epoch) source_date_epoch="$2" ;;
            esac
            shift 2
            ;;
        --help)
            printf 'Usage: %s [--binary PATH] [--dsym PATH] [--output .release/.../Erylo.dSYM.zip] [--source-date-epoch SECONDS]\n' "$0"
            exit 0
            ;;
        *) release_die "unknown argument: $1" ;;
    esac
done

release_require_command ditto
release_require_command git
release_require_command zip
release_require_command zipinfo
binary="$(release_existing_path "$repo_root" "$binary_input")"
dsym="$(release_existing_path "$repo_root" "$dsym_input")"
"$script_dir/validate-symbols.sh" --binary "$binary" --dsym "$dsym" >/dev/null

metadata_file="$(release_repo_file "$repo_root" "Config/ReleaseVersion.env")"
if [[ -z "$output_input" ]]; then
    marketing_version="$(release_metadata_value "$metadata_file" MARKETING_VERSION)"
    build_version="$(release_metadata_value "$metadata_file" BUILD_VERSION)"
    output_input=".release/private/Erylo-${marketing_version}-${build_version}-arm64.dSYM.zip"
fi
output="$(release_output_path "$repo_root" "$output_input")"
[[ "$output" == *.dSYM.zip ]] || release_die "symbol archive output must end in .dSYM.zip"

if [[ -z "$source_date_epoch" ]]; then
    source_date_epoch="$(git show -s --format=%ct HEAD)"
fi
[[ "$source_date_epoch" =~ ^[0-9]{9,12}$ && "$source_date_epoch" -ge 315532800 ]] \
    || release_die "SOURCE_DATE_EPOCH must be a valid post-1980 Unix timestamp"

temp_dir="$(release_make_temp_dir "$repo_root" archive-symbols)"
trap '/bin/rm -rf -- "$temp_dir"' EXIT
/bin/mkdir -p "$temp_dir/root" "$temp_dir/extracted"
COPYFILE_DISABLE=1 /usr/bin/ditto "$dsym" "$temp_dir/root/Erylo.app.dSYM"
/usr/bin/ruby -e '
    require "find"
    time = Time.at(Integer(ARGV.fetch(1))).utc
    Find.find(ARGV.fetch(0)).to_a.reverse_each do |path|
      File.symlink?(path) ? File.lutime(time, time, path) : File.utime(time, time, path)
    end
  ' "$temp_dir/root/Erylo.app.dSYM" "$source_date_epoch" || release_die "could not normalize dSYM timestamps"

archive_temp="$temp_dir/Erylo.dSYM.zip"
(
    cd "$temp_dir/root"
    /usr/bin/find Erylo.app.dSYM -print | LC_ALL=C /usr/bin/sort | \
        TZ=UTC COPYFILE_DISABLE=1 /usr/bin/zip -X -y -9 -q "$archive_temp" -@
)
/usr/bin/zipinfo -1 "$archive_temp" > "$temp_dir/entries"
/usr/bin/ruby -e '
    entries = File.readlines(ARGV.fetch(0), chomp: true)
    abort("symbol archive is empty") if entries.empty?
    abort("symbol archive has duplicate entries") unless entries.uniq.length == entries.length
    entries.each do |entry|
      abort("unsafe symbol archive entry") if entry.start_with?("/") || entry.split("/").include?("..")
      abort("entry is outside Erylo.app.dSYM") unless entry == "Erylo.app.dSYM" || entry.start_with?("Erylo.app.dSYM/")
    end
  ' "$temp_dir/entries" || release_die "symbol archive entry validation failed"
COPYFILE_DISABLE=1 /usr/bin/ditto -x -k "$archive_temp" "$temp_dir/extracted"
"$script_dir/validate-symbols.sh" --binary "$binary" --dsym "$temp_dir/extracted/Erylo.app.dSYM" >/dev/null

release_remove_path "$repo_root" "$output"
/bin/mv "$archive_temp" "$output"
printf 'Private dSYM archive created at %s\n' "$output"
