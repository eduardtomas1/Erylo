#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

repo_root="$(release_repo_root)"
cd "$repo_root"

archive_input=""
app_input=""
post_staple=false
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --archive|--app)
            [[ "$#" -ge 2 && -n "$2" ]] || release_die "missing value for $1"
            if [[ "$1" == "--archive" ]]; then archive_input="$2"; else app_input="$2"; fi
            shift 2
            ;;
        --post-staple)
            post_staple=true
            shift
            ;;
        --help)
            printf 'Usage: %s [--post-staple] --archive .release/.../Erylo.zip --app .release/.../Erylo.app\n' "$0"
            exit 0
            ;;
        *) release_die "unknown argument: $1" ;;
    esac
done
[[ -n "$archive_input" && -n "$app_input" ]] || release_die "--archive and --app are required"

release_require_command ditto
release_require_command zipinfo
archive="$(release_existing_path "$repo_root" "$archive_input")"
app="$(release_existing_path "$repo_root" "$app_input")"
[[ -f "$archive" && "$archive" == *.zip && ! -L "$archive" ]] || release_die "archive input must be a staged ZIP file"
[[ -d "$app" && "$(basename "$app")" == "Erylo.app" && ! -L "$app" ]] || release_die "app input must be a staged Erylo.app"
if [[ "$post_staple" == true ]]; then
    "$script_dir/validate-app.sh" --post-staple "$app" >/dev/null
else
    "$script_dir/validate-app.sh" "$app" >/dev/null
fi

temp_dir="$(release_make_temp_dir "$repo_root" validate-archive)"
trap '/bin/rm -rf -- "$temp_dir"' EXIT
entries_file="$temp_dir/archive-entries.txt"
/usr/bin/zipinfo -1 "$archive" > "$entries_file"
/usr/bin/ruby -e '
    entries = File.readlines(ARGV.fetch(0), chomp: true)
    abort("archive is empty") if entries.empty?
    abort("archive has duplicate entries") unless entries.uniq.length == entries.length
    entries.each do |entry|
      abort("archive entry contains a line break") if entry.match?(/[\r\n]/)
      abort("archive entry escapes root") if entry.start_with?("/") || entry.split("/").include?("..")
      abort("archive entry is outside Erylo.app") unless entry == "Erylo.app" || entry.start_with?("Erylo.app/")
    end
  ' "$entries_file" || release_die "archive entry validation failed"
if /usr/bin/zipinfo -v "$archive" | /usr/bin/grep -Eq 'file security status:[[:space:]]+encrypted$'; then
    release_die "encrypted archives are not accepted"
fi

/bin/mkdir -p "$temp_dir/extracted"
COPYFILE_DISABLE=1 /usr/bin/ditto -x -k "$archive" "$temp_dir/extracted"
extracted_app="$temp_dir/extracted/Erylo.app"
[[ -d "$extracted_app" && ! -L "$extracted_app" ]] || release_die "archive did not extract one Erylo.app"
if [[ "$post_staple" == true ]]; then
    "$script_dir/validate-app.sh" --post-staple "$extracted_app" >/dev/null
else
    "$script_dir/validate-app.sh" "$extracted_app" >/dev/null
fi

/usr/bin/ruby -rdigest -e '
    require "find"

    def manifest(root)
      root = File.realpath(root)
      prefix = root + File::SEPARATOR
      entries = []
      Find.find(root) do |path|
        relative = path == root ? "." : path.delete_prefix(prefix)
        stat = File.lstat(path)
        mode = stat.mode & 0o777
        case stat.ftype
        when "directory"
          entries << [relative, "directory", mode, ""]
        when "file"
          entries << [relative, "file", mode, Digest::SHA256.file(path).hexdigest]
        when "link"
          target = File.readlink(path)
          resolved = File.realpath(path)
          abort("symlink escapes app: #{relative}") unless resolved.start_with?(prefix)
          entries << [relative, "link", mode, target]
        else
          abort("unsupported archive entry type: #{relative}")
        end
      end
      entries.sort
    end

    expected = manifest(ARGV.fetch(0))
    actual = manifest(ARGV.fetch(1))
    abort("archive contents differ from staged app") unless actual == expected
  ' "$app" "$extracted_app" || release_die "archive does not exactly represent the staged app"

printf 'Archive validation passed: %s\n' "$archive"
