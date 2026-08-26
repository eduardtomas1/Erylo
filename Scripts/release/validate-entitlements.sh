#!/bin/bash

set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

script_dir="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=Scripts/release/lib.sh
source "$script_dir/lib.sh"

signed_mode=false
if [[ "${1:-}" == "--signed" ]]; then
    signed_mode=true
    shift
fi
[[ "$#" -eq 1 ]] || release_die "usage: $0 [--signed] ENTITLEMENTS.plist"

entitlements="$1"
[[ -f "$entitlements" && ! -L "$entitlements" ]] || release_die "entitlements input must be a regular file"
release_require_command plutil

json="$(/usr/bin/plutil -convert json -o - "$entitlements")" || release_die "entitlements are not a valid plist"
/usr/bin/ruby -rjson -e '
    values = JSON.parse(ARGV.fetch(0))
    signed_mode = ARGV.fetch(1) == "true"
    abort("entitlements root must be a dictionary") unless values.is_a?(Hash)

    allowed = {"com.apple.security.automation.apple-events" => true}
    if signed_mode
      allowed["com.apple.application-identifier"] = String
      allowed["com.apple.developer.team-identifier"] = String
    end

    denied = %w[
      com.apple.security.app-sandbox
      com.apple.security.network.server
      com.apple.security.files.user-selected.read-write
      com.apple.security.files.downloads.read-write
      com.apple.security.files.all
      com.apple.security.personal-information.addressbook
      com.apple.security.device.camera
      com.apple.security.device.microphone
      com.apple.security.get-task-allow
      com.apple.security.cs.allow-jit
      com.apple.security.cs.allow-unsigned-executable-memory
      com.apple.security.cs.disable-library-validation
    ]
    present_denied = values.keys & denied
    abort("denied entitlement present: #{present_denied.sort.join(", ")}") unless present_denied.empty?

    unknown = values.keys - allowed.keys
    abort("unreviewed entitlement present: #{unknown.sort.join(", ")}") unless unknown.empty?
    abort("Apple Events automation entitlement must be true") unless values["com.apple.security.automation.apple-events"] == true

    allowed.each do |key, expected|
      next unless values.key?(key)
      next if expected == true && values[key] == true
      next if expected == String && values[key].is_a?(String) && !values[key].empty?
      abort("invalid entitlement value: #{key}")
    end
  ' "$json" "$signed_mode" || release_die "entitlements failed minimality validation"

printf 'Entitlements passed minimality validation.\n'
