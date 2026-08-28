#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

status=0

report_failure() {
    printf 'ERROR: %s\n' "$1" >&2
    status=1
}

sanitize_path() {
    local path="$1"

    path="${path//$'\n'/?}"
    path="${path//$'\r'/?}"
    path="${path//$'\t'/?}"
    LC_ALL=C sed -E \
        -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
        -e 's/gh[pousr]_[A-Za-z0-9_]{30,}/[REDACTED]/g' \
        -e 's/github_pat_[A-Za-z0-9_]{30,}/[REDACTED]/g' \
        -e 's/[^[:print:]]/?/g' \
        <<< "$path"
}

report_path() {
    local sanitized

    sanitized="$(sanitize_path "$1")"
    printf 'FILE: %s\n' "$sanitized" >&2
}

tracked_ignored_found=0
while IFS= read -r -d '' path; do
    report_path "$path"
    tracked_ignored_found=1
done < <(git ls-files -ciz --exclude-standard)
if [[ "$tracked_ignored_found" -ne 0 ]]; then
    report_failure "tracked files are matched by .gitignore"
fi

sensitive_path_found=0
while IFS= read -r -d '' path; do
    if [[ "$path" =~ (^|/)(\.env($|\.)|AuthKey_[^/]*\.p8$|[^/]*\.(p12|pfx|mobileprovision|provisionprofile|keychain|keychain-db)$) ]] \
        && [[ ! "$path" =~ (^|/)\.env\.(example|sample|template)$ ]]; then
        report_path "$path"
        sensitive_path_found=1
    fi
done < <(git ls-files -z)
if [[ "$sensitive_path_found" -ne 0 ]]; then
    report_failure "tracked filenames look like credentials or private signing material"
fi

scan_tracked_content() {
    local pattern="$1"
    local message="$2"
    local grep_status
    local match_found=0
    local path
    local result_file

    result_file="$(mktemp "${TMPDIR:-/tmp}/erylo-secret-scan.XXXXXX")"

    # -l and -z expose only NUL-delimited filenames. Do not use -I: tracked
    # binary blobs must be scanned too. Suppress grep diagnostics so malformed
    # paths or content cannot reach logs, and treat every status except the
    # documented match/no-match statuses as a closed scanner failure.
    if git grep -lzE -e "$pattern" -- . > "$result_file" 2>/dev/null; then
        grep_status=0
    else
        grep_status=$?
    fi

    if [[ "$grep_status" -gt 1 ]]; then
        rm -f -- "$result_file"
        report_failure "tracked-content credential scan failed"
        return
    fi

    while IFS= read -r -d '' path; do
        report_path "$path"
        match_found=1
    done < "$result_file"
    rm -f -- "$result_file"

    if [[ "$match_found" -ne 0 ]]; then
        report_failure "$message"
    elif [[ "$grep_status" -eq 0 ]]; then
        report_failure "tracked-content credential scan returned invalid output"
    fi
}

scan_tracked_content \
    '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' \
    "tracked content contains a private-key marker"
scan_tracked_content \
    '(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{30,})' \
    "tracked content contains a high-confidence credential pattern"

while IFS= read -r -d '' script; do
    bash -n "$script"
done < <(git ls-files -z '*.sh')

if [[ -d .github ]]; then
    ruby -e '
        require "yaml"
        files = Dir[".github/**/*.{yml,yaml}"].sort
        files.each do |file|
          YAML.safe_load(File.read(file), aliases: true)
          puts "YAML OK: #{file}"
        end
    '
fi

unpinned_action_found=0
for workflow in .github/workflows/*.yml .github/workflows/*.yaml; do
    [[ -f "$workflow" ]] || continue
    if ! ruby - "$workflow" <<'RUBY'
require "yaml"

references = []
walk = lambda do |value|
  case value
  when Hash
    value.each do |key, child|
      references << child if key.to_s == "uses"
      walk.call(child)
    end
  when Array
    value.each { |child| walk.call(child) }
  end
end

walk.call(YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true))
invalid = references.any? do |reference|
  next false if reference.is_a?(String) && reference.start_with?("./")
  !reference.is_a?(String) || !reference.match?(/\A[^@\s]+@[0-9a-f]{40}\z/)
end
exit(invalid ? 1 : 0)
RUBY
    then
        report_path "$workflow"
        unpinned_action_found=1
    fi
done
if [[ "$unpinned_action_found" -ne 0 ]]; then
    report_failure "third-party GitHub Actions must use full commit SHAs"
fi

if [[ "$status" -ne 0 ]]; then
    exit "$status"
fi

printf 'Repository checks passed.\n'
