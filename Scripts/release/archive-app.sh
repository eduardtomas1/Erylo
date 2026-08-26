#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

app_input=".release/stage/Erylo.app"
output_input=""
source_date_epoch="${SOURCE_DATE_EPOCH:-}"
post_staple=false
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --app|--output|--source-date-epoch)
            [[ "$#" -ge 2 && -n "$2" ]] || release_die "missing value for $1"
            case "$1" in
                --app) app_input="$2" ;;
                --output) output_input="$2" ;;
                --source-date-epoch) source_date_epoch="$2" ;;
            esac
            shift 2
            ;;
        --post-staple)
            post_staple=true
            shift
            ;;
        --help)
            printf 'Usage: %s [--post-staple] [--app .release/.../Erylo.app] [--output .release/.../Erylo.zip] [--source-date-epoch SECONDS]\n' "$0"
            exit 0
            ;;
        *) release_die "unknown argument: $1" ;;
    esac
done

release_require_command ditto
release_require_command git
release_require_command zip
release_require_command zipinfo

app="$(release_existing_path "$repo_root" "$app_input")"
if [[ "$post_staple" == true ]]; then
    "$script_dir/verify-signature.sh" --notarized "$app" >/dev/null
else
    "$script_dir/validate-app.sh" "$app" >/dev/null
fi
metadata_file="$(release_repo_file "$repo_root" "Config/ReleaseVersion.env")"
if [[ -z "$output_input" ]]; then
    marketing_version="$(release_metadata_value "$metadata_file" MARKETING_VERSION)"
    build_version="$(release_metadata_value "$metadata_file" BUILD_VERSION)"
    output_input=".release/artifacts/Erylo-${marketing_version}-${build_version}-arm64.zip"
fi
output="$(release_output_path "$repo_root" "$output_input")"
[[ "$output" == *.zip ]] || release_die "archive output must use the .zip extension"

if [[ -z "$source_date_epoch" ]]; then
    source_date_epoch="$(git show -s --format=%ct HEAD)"
fi
[[ "$source_date_epoch" =~ ^[0-9]{9,12}$ && "$source_date_epoch" -ge 315532800 ]] \
    || release_die "SOURCE_DATE_EPOCH must be a valid post-1980 Unix timestamp"

temp_dir="$(release_make_temp_dir "$repo_root" archive-app)"
trap '/bin/rm -rf -- "$temp_dir"' EXIT
/bin/mkdir -p "$temp_dir/root"
COPYFILE_DISABLE=1 /usr/bin/ditto "$app" "$temp_dir/root/Erylo.app"

/usr/bin/ruby -e '
    require "find"
    root = ARGV.fetch(0)
    timestamp = Integer(ARGV.fetch(1))
    time = Time.at(timestamp).utc
    Find.find(root).to_a.reverse_each do |path|
      if File.symlink?(path)
        File.lutime(time, time, path)
      else
        File.utime(time, time, path)
      end
    end
  ' "$temp_dir/root/Erylo.app" "$source_date_epoch" || release_die "could not normalize archive timestamps"

archive_temp="$temp_dir/Erylo.zip"
(
    cd "$temp_dir/root"
    /usr/bin/find Erylo.app -print | LC_ALL=C /usr/bin/sort | \
        TZ=UTC COPYFILE_DISABLE=1 /usr/bin/zip -X -y -9 -q "$archive_temp" -@
)

validate_archive_arguments=(--archive "$archive_temp" --app "$app")
if [[ "$post_staple" == true ]]; then
    validate_archive_arguments=(--post-staple "${validate_archive_arguments[@]}")
fi
"$script_dir/validate-archive.sh" "${validate_archive_arguments[@]}" >/dev/null

release_remove_path "$repo_root" "$output"
/bin/mv "$archive_temp" "$output"
printf 'Deterministic ZIP archive created at %s\n' "$output"
