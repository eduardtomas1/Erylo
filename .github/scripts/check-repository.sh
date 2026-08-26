#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

status=0

report_failure() {
    printf 'ERROR: %s\n' "$1" >&2
    status=1
}

tracked_ignored="$(git ls-files -ci --exclude-standard)"
if [[ -n "$tracked_ignored" ]]; then
    printf '%s\n' "$tracked_ignored" >&2
    report_failure "tracked files are matched by .gitignore"
fi

sensitive_paths="$(
    git ls-files |
        grep -E '(^|/)(\.env($|\.)|AuthKey_[^/]*\.p8$|[^/]*\.(p12|pfx|mobileprovision|provisionprofile|keychain|keychain-db)$)' |
        grep -Ev '(^|/)\.env\.(example|sample|template)$' || true
)"
if [[ -n "$sensitive_paths" ]]; then
    printf '%s\n' "$sensitive_paths" >&2
    report_failure "tracked filenames look like credentials or private signing material"
fi

private_key_marker='-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'
if git grep -nIE -e "$private_key_marker" -- .; then
    report_failure "tracked content contains a private-key marker"
fi

credential_marker='(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{30,})'
if git grep -nIE -e "$credential_marker" -- .; then
    report_failure "tracked content contains a high-confidence credential pattern"
fi

while IFS= read -r script; do
    bash -n "$script"
done < <(git ls-files '*.sh')

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

if [[ "$status" -ne 0 ]]; then
    exit "$status"
fi

printf 'Repository checks passed.\n'
