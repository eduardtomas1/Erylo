#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

test_root="$repo_root/.release/tests"
/bin/rm -rf -- "$test_root"
/bin/mkdir -p "$test_root/logs"
external_test_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/erylo-release-harness.XXXXXX")"
trap '/bin/rm -rf -- "$external_test_root"' EXIT

check_count=0
failure_count=0

check() {
    local message="$1"
    shift
    check_count=$((check_count + 1))
    if "$@"; then
        return 0
    fi
    printf 'FAIL: %s\n' "$message" >&2
    failure_count=$((failure_count + 1))
    return 0
}

expect_failure() {
    local message="$1"
    local log_name="$2"
    shift 2
    check_count=$((check_count + 1))
    if "$@" >"$test_root/logs/$log_name.out" 2>"$test_root/logs/$log_name.err"; then
        printf 'FAIL: %s\n' "$message" >&2
        failure_count=$((failure_count + 1))
    fi
}

Scripts/release/build-app.sh
check "Sparkle public-key lookup tool is staged but never shipped" \
    test -x "$repo_root/.release/build/arm64/release/Tools/generate_keys"
staged_binary="$repo_root/.release/build/arm64/release/Erylo"
staged_dsym="$repo_root/.release/build/arm64/release/Symbols/Erylo.app.dSYM"
check "Release build generates a separate dSYM" test -f "$staged_dsym/Contents/Resources/DWARF/Erylo"
check "Release dSYM UUIDs match the executable" \
    Scripts/release/validate-symbols.sh --binary "$staged_binary" --dsym "$staged_dsym"
expect_failure "missing dSYM validation fails closed" missing-dsym \
    Scripts/release/validate-symbols.sh --binary "$staged_binary" --dsym "$test_root/missing/Erylo.app.dSYM"
mismatch_binary="$test_root/mismatch/Erylo"
/bin/mkdir -p "$(dirname "$mismatch_binary")"
/usr/bin/lipo .release/build/arm64/release/Tools/sign_update -thin arm64 -output "$mismatch_binary"
/bin/chmod 0755 "$mismatch_binary"
expect_failure "mismatched dSYM UUID validation fails closed" mismatched-dsym \
    Scripts/release/validate-symbols.sh --binary "$mismatch_binary" --dsym "$staged_dsym"

symbols_one="$repo_root/.release/private/Erylo-0.1.0-1-arm64.dSYM.zip"
symbols_two="$test_root/symbols-two/Erylo.dSYM.zip"
Scripts/release/archive-symbols.sh --output "$symbols_one" --source-date-epoch 1700000000
Scripts/release/archive-symbols.sh --output "$symbols_two" --source-date-epoch 1700000000
symbols_hash_one="$(shasum -a 256 "$symbols_one" | awk '{print $1}')"
symbols_hash_two="$(shasum -a 256 "$symbols_two" | awk '{print $1}')"
check "private dSYM archives are reproducible for identical input and epoch" \
    test "$symbols_hash_one" = "$symbols_hash_two"
symbols_manifest="$repo_root/.release/private/SHA256SUMS"
Scripts/release/checksums.sh --output "$symbols_manifest" "$symbols_one"
check "private symbol checksum manifest includes the retained dSYM archive" \
    /usr/bin/grep -Fq "$symbols_hash_one  Erylo-0.1.0-1-arm64.dSYM.zip" "$symbols_manifest"

default_app="$test_root/default/Erylo.app"
Scripts/release/assemble-app.sh --output "$default_app"
check "default bundle passes deterministic validation" Scripts/release/validate-app.sh "$default_app"
expect_failure "default bundle must not pass the production updater gate" missing-updater \
    Scripts/release/validate-app.sh --require-updater "$default_app"

plist="$default_app/Contents/Info.plist"
check "bundle identifier matches release metadata" test "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" = "com.erylo.Erylo"
check "bundle is an agent application" test "$(plutil -extract LSUIElement raw -o - "$plist")" = "true"
check "automatic Sparkle checks are disabled" test "$(plutil -extract SUEnableAutomaticChecks raw -o - "$plist")" = "false"
check "missing optional plist keys produce no diagnostic payload" bash -c '
    source Scripts/release/lib.sh
    value="$(release_plist_value "$1" SUFeedURL || true)"
    [[ -z "$value" ]]
  ' _ "$plist"
check "placeholder icon metadata is absent" bash -c '! plutil -extract CFBundleIconFile raw -o - "$1" >/dev/null 2>&1' _ "$plist"
check "main executable is arm64-only" test "$(lipo -archs "$default_app/Contents/MacOS/Erylo")" = "arm64"
check "reviewed Sparkle and external notices are bundled exactly" \
    /usr/bin/cmp -s Resources/App/ThirdPartyNotices.txt "$default_app/Contents/Resources/ThirdPartyNotices.txt"
check "repository Apache license is bundled exactly" \
    /usr/bin/cmp -s LICENSE "$default_app/Contents/Resources/Erylo-License.txt"
check "reviewed notices retain Sparkle binary-redistribution content" bash -c '
    for text in \
      "Sparkle 2.9.6" \
      "Copyright (c) 2006-2013 Andy Matuschak." \
      "EXTERNAL LICENSES" \
      "bspatch.c and bsdiff.c, from bsdiff 4.3" \
      "sais.c and sais.h, from sais-lite" \
      "Portable C implementation of Ed25519" \
      "SUSignatureVerifier.m:"; do
        /usr/bin/grep -Fq "$text" "$1" || exit 1
    done
  ' _ Resources/App/ThirdPartyNotices.txt
check "dSYM is not embedded in the application bundle" bash -c '
    ! /usr/bin/find "$1" -name "*.dSYM" -print | /usr/bin/grep -q .
  ' _ "$default_app"

missing_notice_app="$test_root/missing-notice/Erylo.app"
/usr/bin/ditto "$default_app" "$missing_notice_app"
/bin/rm -f -- "$missing_notice_app/Contents/Resources/ThirdPartyNotices.txt"
expect_failure "bundle validation rejects a missing third-party notice" missing-third-party-notice \
    Scripts/release/validate-app.sh "$missing_notice_app"
tampered_notice_app="$test_root/tampered-notice/Erylo.app"
/usr/bin/ditto "$default_app" "$tampered_notice_app"
printf '\nmodified\n' >> "$tampered_notice_app/Contents/Resources/ThirdPartyNotices.txt"
expect_failure "bundle validation rejects a modified third-party notice" tampered-third-party-notice \
    Scripts/release/validate-app.sh "$tampered_notice_app"

ticket_app="$test_root/post-staple/Erylo.app"
/usr/bin/ditto "$default_app" "$ticket_app"
printf 'structural ticket fixture; not notarization evidence\n' > "$ticket_app/Contents/CodeResources"
expect_failure "pre-staple bundle validation rejects Contents/CodeResources" pre-staple-ticket \
    Scripts/release/validate-app.sh "$ticket_app"
check "post-staple structure permits exactly one regular ticket file" \
    Scripts/release/validate-app.sh --post-staple "$ticket_app"
symlink_ticket_app="$test_root/symlink-ticket/Erylo.app"
/usr/bin/ditto "$default_app" "$symlink_ticket_app"
/bin/ln -s PkgInfo "$symlink_ticket_app/Contents/CodeResources"
expect_failure "post-staple validation rejects a symlink ticket" symlink-ticket \
    Scripts/release/validate-app.sh --post-staple "$symlink_ticket_app"
directory_ticket_app="$test_root/directory-ticket/Erylo.app"
/usr/bin/ditto "$default_app" "$directory_ticket_app"
/bin/mkdir "$directory_ticket_app/Contents/CodeResources"
expect_failure "post-staple validation rejects a directory ticket" directory-ticket \
    Scripts/release/validate-app.sh --post-staple "$directory_ticket_app"
extra_ticket_app="$test_root/extra-ticket/Erylo.app"
/usr/bin/ditto "$ticket_app" "$extra_ticket_app"
printf 'unexpected\n' > "$extra_ticket_app/Contents/Unexpected.txt"
expect_failure "post-staple validation still rejects extra Contents entries" post-staple-extra \
    Scripts/release/validate-app.sh --post-staple "$extra_ticket_app"

test_appcast="$test_root/appcast.plist"
/bin/cp Config/Appcast.example.plist "$test_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test/appcast.xml" "$test_appcast"
test_public_key="$(/usr/bin/ruby -rbase64 -e 'print Base64.strict_encode64("x" * 32)')"
/usr/bin/plutil -replace SUPublicEDKey -string "$test_public_key" "$test_appcast"
updater_app="$test_root/updater/Erylo.app"
Scripts/release/assemble-app.sh --appcast-config "$test_appcast" --output "$updater_app"
check "explicit signed appcast metadata passes the production gate" \
    Scripts/release/validate-app.sh --require-updater "$updater_app"
expect_failure "tracked example appcast placeholders are rejected" placeholder-appcast \
    Scripts/release/assemble-app.sh --appcast-config Config/Appcast.example.plist --output "$test_root/rejected/Erylo.app"

credential_appcast="$test_root/credential-appcast.plist"
/bin/cp "$test_appcast" "$credential_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://user:password@updates.erylo.test/appcast.xml" "$credential_appcast"
expect_failure "appcast URL credentials are rejected before Info.plist assembly" credential-appcast \
    Scripts/release/assemble-app.sh --appcast-config "$credential_appcast" --output "$test_root/credential/Erylo.app"
credential_bundle="$test_root/credential-bundle/Erylo.app"
/usr/bin/ditto "$updater_app" "$credential_bundle"
/usr/bin/plutil -replace SUFeedURL -string "https://user:password@updates.erylo.test/appcast.xml" \
    "$credential_bundle/Contents/Info.plist"
expect_failure "bundle validation rejects injected appcast URL credentials" credential-bundle \
    Scripts/release/validate-app.sh --require-updater "$credential_bundle"

empty_userinfo_appcast="$test_root/empty-userinfo-appcast.plist"
/bin/cp "$test_appcast" "$empty_userinfo_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://@updates.erylo.test/appcast.xml" "$empty_userinfo_appcast"
expect_failure "empty appcast URL userinfo is rejected before Info.plist assembly" empty-userinfo-appcast \
    Scripts/release/assemble-app.sh --appcast-config "$empty_userinfo_appcast" --output "$test_root/empty-userinfo/Erylo.app"
empty_userinfo_bundle="$test_root/empty-userinfo-bundle/Erylo.app"
/usr/bin/ditto "$updater_app" "$empty_userinfo_bundle"
/usr/bin/plutil -replace SUFeedURL -string "https://@updates.erylo.test/appcast.xml" \
    "$empty_userinfo_bundle/Contents/Info.plist"
expect_failure "bundle validation rejects injected empty appcast userinfo" empty-userinfo-bundle \
    Scripts/release/validate-app.sh --require-updater "$empty_userinfo_bundle"

default_port_appcast="$test_root/default-port-appcast.plist"
/bin/cp "$test_appcast" "$default_port_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test:443/appcast.xml" "$default_port_appcast"
expect_failure "explicit default appcast ports are rejected" default-port-appcast \
    Scripts/release/assemble-app.sh --appcast-config "$default_port_appcast" --output "$test_root/default-port/Erylo.app"
default_port_bundle="$test_root/default-port-bundle/Erylo.app"
/usr/bin/ditto "$updater_app" "$default_port_bundle"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test:443/appcast.xml" \
    "$default_port_bundle/Contents/Info.plist"
expect_failure "bundle validation rejects an injected explicit default port" default-port-bundle \
    Scripts/release/validate-app.sh --require-updater "$default_port_bundle"

custom_port_appcast="$test_root/custom-port-appcast.plist"
/bin/cp "$test_appcast" "$custom_port_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test:8443/appcast.xml" "$custom_port_appcast"
expect_failure "nondefault appcast ports are rejected" custom-port-appcast \
    Scripts/release/assemble-app.sh --appcast-config "$custom_port_appcast" --output "$test_root/custom-port/Erylo.app"

uppercase_scheme_appcast="$test_root/uppercase-scheme-appcast.plist"
/bin/cp "$test_appcast" "$uppercase_scheme_appcast"
/usr/bin/plutil -replace SUFeedURL -string "HTTPS://updates.erylo.test/appcast.xml" "$uppercase_scheme_appcast"
expect_failure "noncanonical appcast scheme spelling is rejected" uppercase-scheme-appcast \
    Scripts/release/assemble-app.sh --appcast-config "$uppercase_scheme_appcast" --output "$test_root/uppercase-scheme/Erylo.app"

query_appcast="$test_root/query-appcast.plist"
/bin/cp "$test_appcast" "$query_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test/appcast.xml?channel=stable" "$query_appcast"
expect_failure "noncanonical appcast URL queries are rejected" query-appcast \
    Scripts/release/assemble-app.sh --appcast-config "$query_appcast" --output "$test_root/query/Erylo.app"
query_bundle="$test_root/query-bundle/Erylo.app"
/usr/bin/ditto "$updater_app" "$query_bundle"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test/appcast.xml?channel=stable" \
    "$query_bundle/Contents/Info.plist"
expect_failure "bundle validation rejects injected appcast URL queries" query-bundle \
    Scripts/release/validate-app.sh --require-updater "$query_bundle"

fragment_appcast="$test_root/fragment-appcast.plist"
/bin/cp "$test_appcast" "$fragment_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test/appcast.xml#latest" "$fragment_appcast"
expect_failure "noncanonical appcast URL fragments are rejected" fragment-appcast \
    Scripts/release/assemble-app.sh --appcast-config "$fragment_appcast" --output "$test_root/fragment/Erylo.app"
fragment_bundle="$test_root/fragment-bundle/Erylo.app"
/usr/bin/ditto "$updater_app" "$fragment_bundle"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test/appcast.xml#latest" \
    "$fragment_bundle/Contents/Info.plist"
expect_failure "bundle validation rejects injected appcast URL fragments" fragment-bundle \
    Scripts/release/validate-app.sh --require-updater "$fragment_bundle"

bad_entitlements="$test_root/bad.entitlements"
/bin/cp Resources/App/Erylo.entitlements "$bad_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.network.server bool true' "$bad_entitlements"
expect_failure "entitlement denylist rejects network server capability" bad-entitlements \
    Scripts/release/validate-entitlements.sh "$bad_entitlements"
check "reviewed entitlements remain minimal" Scripts/release/validate-entitlements.sh Resources/App/Erylo.entitlements

secret_app="$test_root/secret/Erylo.app"
/usr/bin/ditto "$default_app" "$secret_app"
printf '%s%s\n' '-----BEGIN TEST ' 'PRIVATE KEY-----' > "$secret_app/Contents/Resources/secret-fixture.txt"
expect_failure "bundle validation rejects private-key markers" private-key-marker \
    Scripts/release/validate-app.sh "$secret_app"

escape_path="$repo_root/release-harness-escape/Erylo.app"
expect_failure "assembler rejects path traversal outside release staging" assemble-traversal \
    Scripts/release/assemble-app.sh --output ".release/../release-harness-escape/Erylo.app"
check "path traversal attempt creates no external output" test ! -e "$escape_path"
expect_failure "archiver rejects output traversal" archive-traversal \
    Scripts/release/archive-app.sh --app "$default_app" --output ".release/../release-harness-escape.zip"

/bin/mkdir -p "$test_root/real-parent"
/bin/ln -s "$test_root/real-parent" "$test_root/symlink-parent"
expect_failure "release output refuses symlink parents" symlink-parent \
    Scripts/release/assemble-app.sh --output "$test_root/symlink-parent/Erylo.app"
external_output_target="$external_test_root/output-target.txt"
printf 'external-output-sentinel\n' > "$external_output_target"
final_symlink="$test_root/final-output-link"
/bin/ln -s "$external_output_target" "$final_symlink"
expect_failure "release output refuses a symlink at the final component" final-output-symlink \
    bash -c 'source Scripts/release/lib.sh; release_output_path "$1" "$2"' _ "$repo_root" "$final_symlink"
check "final output symlink rejection leaves its external target unchanged" \
    /usr/bin/grep -Fxq external-output-sentinel "$external_output_target"
/bin/rm -f -- "$final_symlink"
fifo_output="$test_root/fifo-output"
/usr/bin/mkfifo "$fifo_output"
expect_failure "release output refuses special files at the final component" final-output-fifo \
    bash -c 'source Scripts/release/lib.sh; release_output_path "$1" "$2"' _ "$repo_root" "$fifo_output"

archive_one="$test_root/archive-one/Erylo.zip"
archive_two="$test_root/archive-two/Erylo.zip"
Scripts/release/archive-app.sh --app "$default_app" --output "$archive_one" --source-date-epoch 1700000000
Scripts/release/archive-app.sh --app "$default_app" --output "$archive_two" --source-date-epoch 1700000000
hash_one="$(shasum -a 256 "$archive_one" | awk '{print $1}')"
hash_two="$(shasum -a 256 "$archive_two" | awk '{print $1}')"
check "archives are reproducible for identical input and epoch" test "$hash_one" = "$hash_two"
check "dSYM is not embedded in the public update archive" bash -c '
    ! /usr/bin/zipinfo -1 "$1" | /usr/bin/grep -Fq ".dSYM"
  ' _ "$archive_one"
checksum_file="$test_root/checksums/SHA256SUMS"
Scripts/release/checksums.sh --output "$checksum_file" "$archive_one"
check "checksum manifest records the archive digest" /usr/bin/grep -Fq "$hash_one  Erylo.zip" "$checksum_file"
expect_failure "archive creation rejects an app missing third-party notices" archive-missing-notice \
    Scripts/release/archive-app.sh --app "$missing_notice_app" --output "$test_root/missing-notice.zip"

ticket_archive_root="$test_root/post-staple-archive/root"
ticket_archive="$test_root/post-staple-archive/Erylo.zip"
/bin/mkdir -p "$ticket_archive_root"
COPYFILE_DISABLE=1 /usr/bin/ditto "$ticket_app" "$ticket_archive_root/Erylo.app"
(
    cd "$ticket_archive_root"
    /usr/bin/find Erylo.app -print | LC_ALL=C /usr/bin/sort | \
        TZ=UTC COPYFILE_DISABLE=1 /usr/bin/zip -X -y -9 -q "$ticket_archive" -@
)
expect_failure "pre-staple archive validation rejects Contents/CodeResources" pre-staple-ticket-archive \
    Scripts/release/validate-archive.sh --archive "$ticket_archive" --app "$ticket_app"
check "post-staple archive validation permits the one regular ticket file" \
    Scripts/release/validate-archive.sh --post-staple --archive "$ticket_archive" --app "$ticket_app"

archive_entries_external="$external_test_root/archive-entries-target.txt"
printf 'archive-entries-sentinel\n' > "$archive_entries_external"
archive_entries_path_record="$test_root/archive-entries-path.txt"
check "archive validation ignores a planted predictable final symlink" bash -c '
    planted=".release/tmp/archive-entries.$$.txt"
    /bin/ln -s "$3" "$planted"
    printf "%s\n" "$planted" > "$4"
    set -- --archive "$1" --app "$2"
    source Scripts/release/validate-archive.sh >/dev/null
  ' _ "$archive_one" "$default_app" "$archive_entries_external" "$archive_entries_path_record"
check "archive entry validation leaves the external symlink target unchanged" \
    /usr/bin/grep -Fxq archive-entries-sentinel "$archive_entries_external"
planted_entries_path="$(<"$archive_entries_path_record")"
/bin/rm -f -- "$planted_entries_path"

fake_notary_external="$external_test_root/notary-target.json"
printf 'external-notary-sentinel\n' > "$fake_notary_external"
fake_notary_source="$test_root/fake-notary/submission.json"
fake_notary_result="$repo_root/.release/notarization/$(basename "$archive_one").submission.json"
/bin/mkdir -p "$(dirname "$fake_notary_source")" "$(dirname "$fake_notary_result")"
printf '{"status":"Accepted","fixture":true}\n' > "$fake_notary_source"
/bin/rm -f -- "$fake_notary_result"
/bin/ln -s "$fake_notary_external" "$fake_notary_result"
check "fake notary publication safely replaces only the in-root result leaf" bash -c '
    source Scripts/release/lib.sh
    release_publish_file "$1" "$2" "$3"
  ' _ "$repo_root" "$fake_notary_source" "$fake_notary_result"
check "fake notary publication leaves the external symlink target unchanged" \
    /usr/bin/grep -Fxq external-notary-sentinel "$fake_notary_external"
check "fake notary publication produces a regular reviewed in-root result" bash -c '
    [[ -f "$1" && ! -L "$1" ]] && /usr/bin/grep -Fq "\"fixture\":true" "$1"
  ' _ "$fake_notary_result"

submission_relative="$(bash -c '
    source Scripts/release/lib.sh
    release_submission_archive_path 0.1.0 1
  ')"
check "notarization submission ZIP routes outside publishable artifacts" \
    test "$submission_relative" = ".release/notarization/submissions/Erylo-0.1.0-1-arm64-submission.zip"

legacy_submission="$repo_root/.release/artifacts/Erylo-0.1.0-1-arm64-submission.zip"
/bin/mkdir -p "$(dirname "$legacy_submission")"
printf 'legacy submission fixture\n' > "$legacy_submission"
expect_failure "failed release preparation removes a legacy publishable submission ZIP" release-cleans-submission \
    Scripts/release/release.sh \
        --identity "Developer ID Application: Release Harness (AAAAAAAAAA)" \
        --keychain-profile RELEASE_HARNESS \
        --appcast-config Config/Appcast.example.plist \
        --icon Resources/App/Missing.icns
check "no regular submission ZIP remains after a failed release attempt" test ! -e "$legacy_submission"

legacy_submission_external="$external_test_root/legacy-submission-target.zip"
printf 'external-submission-sentinel\n' > "$legacy_submission_external"
/bin/ln -s "$legacy_submission_external" "$legacy_submission"
expect_failure "resumed release preparation removes a legacy submission symlink safely" release-cleans-submission-symlink \
    Scripts/release/release.sh \
        --identity "Developer ID Application: Release Harness (AAAAAAAAAA)" \
        --keychain-profile RELEASE_HARNESS \
        --appcast-config Config/Appcast.example.plist \
        --icon Resources/App/Missing.icns
check "resume cleanup removes only the in-root submission symlink" test ! -e "$legacy_submission"
check "resume cleanup leaves the external symlink target unchanged" \
    /usr/bin/grep -Fxq external-submission-sentinel "$legacy_submission_external"
check "publishable artifacts contain no submission ZIP after failure or resume" bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_artifacts "$1"
  ' _ "$repo_root"

expect_failure "Sparkle signing rejects empty userinfo before tool or credential gates" signing-empty-userinfo \
    Scripts/release/sign-update.sh --archive "$archive_one" --appcast-config "$empty_userinfo_appcast"
check "Sparkle signing failure identifies the shared appcast URL gate" \
    /usr/bin/grep -Fq "appcast feed URL is invalid" "$test_root/logs/signing-empty-userinfo.err"

fake_bin="$test_root/fake-bin"
/bin/mkdir -p "$fake_bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" /Library/Developer/CommandLineTools' > "$fake_bin/xcode-select"
/bin/chmod 0755 "$fake_bin/xcode-select"
expect_failure "signing fails closed without full Xcode" missing-full-xcode \
    /usr/bin/env PATH="$fake_bin:/usr/bin:/bin" Scripts/release/sign-app.sh \
        --identity "Developer ID Application: Release Harness (AAAAAAAAAA)" --app "$default_app"
expect_failure "signing refuses an absent identity argument" missing-identity Scripts/release/sign-app.sh --app "$default_app"
expect_failure "notarization refuses an absent Keychain profile" missing-notary-profile \
    Scripts/release/notarize-archive.sh --archive "$archive_one" --app "$default_app"
expect_failure "Sparkle signing refuses an absent public appcast config" missing-signing-appcast \
    Scripts/release/sign-update.sh --archive "$archive_one"

check "Sparkle dependency is pinned exactly in Package.resolved" /usr/bin/ruby -rjson -e '
    data = JSON.parse(File.read(ARGV.fetch(0)))
    pins = data.fetch("pins")
    sparkle = pins.find { |pin| pin.fetch("identity") == "sparkle" }
    abort unless sparkle && sparkle.fetch("state").fetch("version") == "2.9.6"
  ' Package.resolved

Scripts/release/build-app.sh
check "a subsequent build retains the private dSYM archive" test -f "$symbols_one"
check "a subsequent build retains the private dSYM checksum evidence" test -f "$symbols_manifest"

if [[ "$failure_count" -ne 0 ]]; then
    printf 'Release harness failed %d of %d checks.\n' "$failure_count" "$check_count" >&2
    exit 1
fi

printf 'Release harness passed %d checks.\n' "$check_count"
