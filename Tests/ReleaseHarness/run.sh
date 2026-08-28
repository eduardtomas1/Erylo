#!/usr/bin/env bash

# The sourced process library publishes owned-helper state in these globals.
# shellcheck disable=SC2154

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
# shellcheck source=Scripts/release/lib.sh
source Scripts/release/lib.sh
release_capture_toolchain 0

release_harness_shard="${1:-all}"
release_harness_manifest="Tests/ReleaseHarness/shards.tsv"
if [[ "$release_harness_shard" == all ]]; then
    release_harness_expected_checks=548
else
    release_harness_expected_checks="$(/usr/bin/awk -F '\t' -v shard="$release_harness_shard" \
        '$1 == shard { print $2 }' "$release_harness_manifest")"
    if [[ -z "$release_harness_expected_checks" \
        || "$(printf '%s\n' "$release_harness_expected_checks" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" != 1 ]]; then
        printf 'Usage: %s [all|SHARD-FROM-%s]\n' "$0" "$release_harness_manifest" >&2
        exit 64
    fi
fi
release_harness_started_seconds=$SECONDS

test_root="$repo_root/.release/tests"
release_remove_path "$repo_root" "$test_root"
harness_private_commit="1111111111111111111111111111111111111111"
release_remove_path "$repo_root" ".release/private/$harness_private_commit"
logs_placeholder="$(release_output_path "$repo_root" "$test_root/logs/placeholder")"
test_root="$(dirname "$(dirname "$logs_placeholder")")"
external_temp_repo="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/erylo-release-harness.XXXXXX")"
/usr/bin/ruby "$repo_root/Scripts/release/fs-helper.rb" make-directory \
    "$external_temp_repo" .release/fixtures >/dev/null
external_test_root="$external_temp_repo/.release/fixtures"
source_image_mount=""
source_image_temp=""
unrelated_mount_path=""
unrelated_mount_temp=""
cleanup_external_test_root() {
    if [[ -n "$source_image_mount" ]]; then
        /usr/bin/hdiutil detach -quiet "$source_image_mount" >/dev/null 2>&1 || true
    fi
    if [[ -n "$unrelated_mount_path" ]]; then
        /usr/bin/hdiutil detach -quiet "$unrelated_mount_path" >/dev/null 2>&1 || true
    fi
    release_recover_temporaries "$repo_root" >/dev/null 2>&1 || true
    if [[ -n "${snapshot_fixture_repo:-}" \
        && -f "$snapshot_fixture_repo/Scripts/release/lib.sh" ]]; then
        bash -c 'source "$1/Scripts/release/lib.sh"; release_recover_temporaries "$1"' \
            _ "$snapshot_fixture_repo" >/dev/null 2>&1 || true
    fi
    if [[ -n "$source_image_temp" && -e "$source_image_temp" ]]; then
        /usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" remove \
            "$snapshot_fixture_repo" "$source_image_temp" any >/dev/null 2>&1 || true
    fi
    if [[ -n "$unrelated_mount_temp" && -e "$unrelated_mount_temp" ]]; then
        release_remove_path "$repo_root" "$unrelated_mount_temp" >/dev/null 2>&1 || true
    fi
    if [[ -d "$external_temp_repo" && ! -L "$external_temp_repo" ]]; then
        /usr/bin/ruby "$repo_root/Scripts/release/fs-helper.rb" remove \
            "$external_temp_repo" .release/fixtures
        /bin/rmdir "$external_temp_repo/.release"
        /bin/rmdir "$external_temp_repo"
    fi
}

# shellcheck source=Tests/ReleaseHarness/processes.sh
source Tests/ReleaseHarness/processes.sh

cleanup_release_harness() {
    cleanup_release_harness_processes
    cleanup_external_test_root
}
trap cleanup_release_harness EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

expect_failure_with_stderr() {
    local message="$1"
    local log_name="$2"
    local expected="$3"
    shift 3
    check_count=$((check_count + 1))
    if "$@" >"$test_root/logs/$log_name.out" 2>"$test_root/logs/$log_name.err"; then
        printf 'FAIL: %s\n' "$message" >&2
        failure_count=$((failure_count + 1))
    elif ! /usr/bin/grep -Fq "$expected" "$test_root/logs/$log_name.err"; then
        printf 'FAIL: %s (unexpected failure boundary)\n' "$message" >&2
        failure_count=$((failure_count + 1))
    fi
}

release_set_digest() {
    /usr/bin/ruby -rdigest -e '
      root = ARGV.fetch(0)
      digest = Digest::SHA256.new
      Dir.children(root).sort.each do |name|
        path = File.join(root, name)
        stat = File.lstat(path)
        abort "unexpected non-file in release set: #{name}" unless stat.file?
        digest << name << "\0" << File.binread(path) << "\0"
      end
      print digest.hexdigest
    ' "$1"
}

release_harness_runs() {
    [[ "$release_harness_shard" == all || "$release_harness_shard" == "$1" ]]
}

release_harness_phase() {
    printf 'HARNESS_PHASE phase=%s shard=%s checks=%d elapsed=%ds\n' \
        "$1" "$release_harness_shard" "$check_count" \
        "$((SECONDS - release_harness_started_seconds))"
}

private_fixture_commit="$harness_private_commit"
private_fixture_tree="2222222222222222222222222222222222222222"
private_fixture_appcast_hash="$(shasum -a 256 Config/Appcast.example.plist | awk '{print $1}')"

prepare_compiled_release_fixture() {
    local metadata_file
    local minimum_system_version
    local target_architecture
    local triple
    local swift_tool
    local scratch_path
    local bin_path

    metadata_file="$(release_repo_file "$repo_root" "Config/ReleaseVersion.env")"
    target_architecture="$(release_metadata_value "$metadata_file" TARGET_ARCHITECTURE)"
    minimum_system_version="$(release_metadata_value "$metadata_file" MINIMUM_SYSTEM_VERSION)"
    [[ "$target_architecture" == arm64 && "$minimum_system_version" == 14.0 ]] \
        || release_die "compiled harness fixture must match release architecture and deployment"
    triple="${target_architecture}-apple-macosx${minimum_system_version}"
    swift_tool="$(release_developer_tool_path swift)"
    scratch_path="$(release_output_path "$repo_root" ".release/harness-swift-build/placeholder")"
    scratch_path="$(/usr/bin/dirname "$scratch_path")"
    release_remove_path "$repo_root" "$scratch_path"
    release_build_swift_product "$swift_tool" "$repo_root" "$scratch_path" Erylo "$triple"
    bin_path="$release_swift_product_bin_path"
    fixture_binary="$bin_path/Erylo"
    fixture_framework="$bin_path/Sparkle.framework"
    [[ -f "$fixture_binary" && -x "$fixture_binary" && ! -L "$fixture_binary" ]] \
        || release_die "compiled harness fixture has no regular Erylo executable"
    [[ -d "$fixture_framework" && ! -L "$fixture_framework" ]] \
        || release_die "compiled harness fixture has no real Sparkle framework"
    fixture_toolchain="$test_root/compiled-release/Toolchain.json"
    release_make_directory "$repo_root" "$(/usr/bin/dirname "$fixture_toolchain")" >/dev/null
    printf '%s\n' "$ERYLO_RELEASE_TOOLCHAIN_JSON" > "$fixture_toolchain"
    /bin/chmod 0600 "$fixture_toolchain"
    fixture_toolchain_hash="$(/usr/bin/shasum -a 256 "$fixture_toolchain" | /usr/bin/awk '{print $1}')"
    [[ "$fixture_toolchain_hash" == "$ERYLO_RELEASE_TOOLCHAIN_SHA256" ]] \
        || release_die "compiled harness fixture toolchain binding is inconsistent"
}

assemble_compiled_fixture() {
    Scripts/release/assemble-app.sh \
        --binary "$fixture_binary" \
        --framework "$fixture_framework" \
        --toolchain "$fixture_toolchain" \
        "$@"
}

prepare_compiled_symbol_fixture() {
    local dsymutil_tool

    prepare_compiled_release_fixture
    staged_binary="$fixture_binary"
    staged_dsym="$test_root/compiled-symbols/Erylo.app.dSYM"
    release_make_directory "$repo_root" "$(/usr/bin/dirname "$staged_dsym")" >/dev/null
    dsymutil_tool="$(release_developer_tool_path dsymutil)"
    "$dsymutil_tool" "$staged_binary" -o "$staged_dsym"
}

prepare_hostile_path_fixture() {
    hostile_path="$test_root/hostile-path/bin"
    hostile_path_marker="$test_root/hostile-path/executed"
    /bin/mkdir -p "$hostile_path"
    for shadow_tool in bash git ruby swift swiftc xcrun lipo otool dsymutil dwarfdump ditto; do
        printf '#!/bin/bash\nprintf "%%s\\n" "$0" >> %q\nexit 97\n' "$hostile_path_marker" \
            > "$hostile_path/$shadow_tool"
        /bin/chmod 0755 "$hostile_path/$shadow_tool"
    done
}

prepare_private_evidence_fixture() {
    fixture_toolchain_hash="$ERYLO_RELEASE_TOOLCHAIN_SHA256"
    symbols_one="$test_root/private-evidence/Erylo-0.1.0-1-arm64.dSYM.zip"
    release_make_directory "$repo_root" "$(/usr/bin/dirname "$symbols_one")" >/dev/null
    printf 'structural private-symbol archive fixture\n' > "$symbols_one"
}

prepare_default_bundle_fixture() {
    prepare_compiled_release_fixture
    default_app="$test_root/default/Erylo.app"
    assemble_compiled_fixture --output "$default_app"
    plist="$default_app/Contents/Info.plist"
    missing_notice_app="$test_root/missing-notice/Erylo.app"
    /usr/bin/ditto "$default_app" "$missing_notice_app"
    /bin/rm -f -- "$missing_notice_app/Contents/Resources/ThirdPartyNotices.txt"
}

prepare_ticket_fixture() {
    ticket_app="$test_root/post-staple/Erylo.app"
    /usr/bin/ditto "$default_app" "$ticket_app"
    printf 'structural ticket fixture; not notarization evidence\n' \
        > "$ticket_app/Contents/CodeResources"
}

prepare_appcast_fixture() {
    test_appcast="$test_root/appcast.plist"
    /bin/cp Config/Appcast.example.plist "$test_appcast"
    /usr/bin/plutil -replace SUFeedURL -string \
        "https://updates.erylo.test/appcast.xml" "$test_appcast"
    test_public_key="$(/usr/bin/ruby -rbase64 -e 'print Base64.strict_encode64("x" * 32)')"
    /usr/bin/plutil -replace SUPublicEDKey -string "$test_public_key" "$test_appcast"
}

prepare_bundle_fixtures() {
    prepare_default_bundle_fixture
    prepare_ticket_fixture
    prepare_appcast_fixture
    updater_app="$test_root/updater/Erylo.app"
    assemble_compiled_fixture --appcast-config "$test_appcast" --output "$updater_app"
    empty_userinfo_appcast="$test_root/empty-userinfo-appcast.plist"
    /bin/cp "$test_appcast" "$empty_userinfo_appcast"
    /usr/bin/plutil -replace SUFeedURL -string \
        "https://@updates.erylo.test/appcast.xml" "$empty_userinfo_appcast"
}

prepare_update_vector_fixtures() {
    prepare_compiled_release_fixture
    prepare_appcast_fixture
    updater_app="$test_root/updater/Erylo.app"
    archive_one="$test_root/signing-fixture/Erylo.zip"
    /bin/mkdir -p "$(dirname "$archive_one")"
    printf 'structural signing archive fixture\n' > "$archive_one"
    non_xcode_developer_dir="$test_root/fake-command-line-tools"
    /bin/mkdir -p "$non_xcode_developer_dir"
}

prepare_evidence_metadata_fixtures() {
    fixture_toolchain_hash="$ERYLO_RELEASE_TOOLCHAIN_SHA256"
    archive_one="$test_root/evidence-metadata/Erylo.zip"
    release_make_directory "$repo_root" "$(/usr/bin/dirname "$archive_one")" >/dev/null
    printf 'structural evidence archive fixture\n' > "$archive_one"
    hash_one="$(shasum -a 256 "$archive_one" | awk '{print $1}')"
    verify_update_tool="$repo_root/.release/build/arm64/release/Tools/sign_update"
    release_make_directory "$repo_root" "$(/usr/bin/dirname "$verify_update_tool")" >/dev/null
    printf '#!/bin/bash\nexit 1\n' > "$verify_update_tool"
    /bin/chmod 0755 "$verify_update_tool"
}

prepare_archive_evidence_fixtures() {
    prepare_default_bundle_fixture
    prepare_ticket_fixture
    archive_one="$test_root/archive-one/Erylo.zip"
    Scripts/release/archive-app.sh --app "$default_app" --output "$archive_one" \
        --source-date-epoch 1700000000
    hash_one="$(shasum -a 256 "$archive_one" | awk '{print $1}')"
}

prepare_release_cleanup_fixture() {
    archive_one="$test_root/release-cleanup/Erylo.zip"
    release_make_directory "$repo_root" "$(/usr/bin/dirname "$archive_one")" >/dev/null
    printf 'structural cleanup archive fixture\n' > "$archive_one"
}

prepare_publication_fixtures() {
    fixture_toolchain_hash="$ERYLO_RELEASE_TOOLCHAIN_SHA256"
    publication_build_root="$repo_root/.release/build/arm64/release"
    release_make_directory "$repo_root" "$publication_build_root/Tools" >/dev/null
    printf '%s\n' "$ERYLO_RELEASE_TOOLCHAIN_JSON" > "$publication_build_root/Toolchain.json"
    /bin/chmod 0600 "$publication_build_root/Toolchain.json"
    for publication_tool in sign_update generate_keys; do
        printf '#!/bin/bash\nexit 1\n' > "$publication_build_root/Tools/$publication_tool"
        /bin/chmod 0755 "$publication_build_root/Tools/$publication_tool"
    done
    prepare_appcast_fixture
    empty_userinfo_appcast="$test_root/empty-userinfo-appcast.plist"
    /bin/cp "$test_appcast" "$empty_userinfo_appcast"
    /usr/bin/plutil -replace SUFeedURL -string \
        "https://@updates.erylo.test/appcast.xml" "$empty_userinfo_appcast"
    publishable_fixture="$test_root/publishable-boundary"
    publishable_final="$publishable_fixture/Erylo-0.1.0-1-arm64.zip"
    publishable_signature="${publishable_final}.sparkle-signature.json"
    publishable_checksums="$publishable_fixture/SHA256SUMS"
    /bin/mkdir -p "$publishable_fixture"
    archive_one="$test_root/publication-archive/Erylo.zip"
    /bin/mkdir -p "$(dirname "$archive_one")"
    printf 'structural publication archive fixture\n' > "$archive_one"
    /bin/cp "$archive_one" "$publishable_final"
    publishable_length="$(/usr/bin/stat -f '%z' "$publishable_final")"
    fixture_signature="$(/usr/bin/ruby -rbase64 -e \
        'print Base64.strict_encode64("structural fixture".ljust(64, "!"))')"
    fixture_source_commit="$private_fixture_commit"
    fixture_source_tree="$private_fixture_tree"
    fixture_appcast_hash="$private_fixture_appcast_hash"
    printf '{"archive":"Erylo-0.1.0-1-arm64.zip","length":%s,"sparkleEdSignature":"%s","sourceCommit":"%s","sourceTree":"%s","appcastConfigSHA256":"%s","toolchainSHA256":"%s"}\n' \
        "$publishable_length" "$fixture_signature" "$fixture_source_commit" \
        "$fixture_source_tree" "$fixture_appcast_hash" "$fixture_toolchain_hash" \
        > "$publishable_signature"
    Scripts/release/checksums.sh --output "$publishable_checksums" \
        "$publishable_final" "$publishable_signature"

    private_fixture_name="Erylo-0.1.0-1-${private_fixture_commit:0:12}-arm64.dSYM.zip"
    private_fixture_dir="$test_root/private-transaction/publication-setup"
    release_make_directory "$repo_root" "$private_fixture_dir" >/dev/null
    printf 'structural private-symbol fixture\n' > "$private_fixture_dir/$private_fixture_name"
    /usr/bin/ruby -rjson -e '
      payload = {
        "archive" => ARGV.fetch(0), "marketingVersion" => "0.1.0", "buildVersion" => "1",
        "sourceCommit" => ARGV.fetch(1), "sourceTree" => ARGV.fetch(2),
        "appcastConfigSHA256" => ARGV.fetch(3), "toolchainSHA256" => ARGV.fetch(4)
      }
      File.write(ARGV.fetch(5), JSON.pretty_generate(payload) + "\n")
    ' "$private_fixture_name" "$private_fixture_commit" "$private_fixture_tree" \
        "$private_fixture_appcast_hash" "$fixture_toolchain_hash" \
        "$private_fixture_dir/ReleaseManifest.json"
    Scripts/release/checksums.sh --output "$private_fixture_dir/SHA256SUMS" \
        "$private_fixture_dir/$private_fixture_name" "$private_fixture_dir/ReleaseManifest.json"
    release_publish_private_artifacts "$repo_root" "$private_fixture_dir" \
        0.1.0 1 "$private_fixture_commit" "$private_fixture_tree" \
        "$private_fixture_appcast_hash" "$fixture_toolchain_hash"
    private_published_dir="$repo_root/.release/private/$private_fixture_commit"
    non_xcode_developer_dir="$test_root/fake-command-line-tools"
    /bin/mkdir -p "$non_xcode_developer_dir"
    default_app="$test_root/publication-gates/Erylo.app"
}

if release_harness_runs source-boundaries; then
/bin/bash Tests/ReleaseHarness/process-supervisor-tests.sh
release_harness_phase source-boundaries
admission_public_before="absent"
if [[ -d "$repo_root/.release/artifacts/current" ]]; then
    admission_public_before="$(release_set_digest "$repo_root/.release/artifacts/current")"
fi
expect_failure "caller-supplied snapshot state and a self-created pipe cannot enter worker mode" \
    external-worker-state /usr/bin/ruby -rdigest -e '
      read_io, write_io = IO.pipe
      tokens = "caller-selected-capability".ljust(64, "!")
      write_io.write(tokens)
      write_io.close
      read_io.close_on_exec = false
      environment = {
        "ERYLO_RELEASE_SNAPSHOT_ACTIVE" => "1",
        "ERYLO_RELEASE_SOURCE_ROOT" => Dir.pwd,
        "ERYLO_RELEASE_WORKER_CAPABILITY_FD" => read_io.fileno.to_s,
        "ERYLO_RELEASE_OUTER_CAPABILITY_SHA256" => Digest::SHA256.hexdigest(tokens.byteslice(0, 32)),
        "ERYLO_RELEASE_WORKER_CAPABILITY_SHA256" => Digest::SHA256.hexdigest(tokens.byteslice(32, 32)),
        "ERYLO_RELEASE_OUTER_AUTHENTICATED" => "1",
        "ERYLO_RELEASE_SUPERVISOR_HANDOFF" => "1"
      }
      pid = Process.spawn(
        environment, "/bin/bash", "Scripts/release/release.sh", "--help",
        read_io.fileno => read_io.fileno, close_others: false
      )
      read_io.close
      _pid, status = Process.wait2(pid)
      exit(status.exitstatus || 1)
    '
check "external worker-state rejection happens at the public admission boundary" \
    /usr/bin/grep -Fq \
        "external release invocation contains internal snapshot state: ERYLO_RELEASE_SNAPSHOT_ACTIVE" \
        "$test_root/logs/external-worker-state.err"
admission_public_after="absent"
if [[ -d "$repo_root/.release/artifacts/current" ]]; then
    admission_public_after="$(release_set_digest "$repo_root/.release/artifacts/current")"
fi
check "external worker-state rejection leaves publication unchanged" \
    test "$admission_public_after" = "$admission_public_before"

release_make_directory "$repo_root" .release/locks >/dev/null
expect_failure "caller-held real release lock plus self-certified worker state cannot bypass admission" \
    external-worker-state-held-lock /usr/bin/ruby -rdigest -e '
      lock = File.open(
        File.join(Dir.pwd, ".release", "locks", "production-release.lock"),
        File::RDWR | File::CREAT,
        0o600
      )
      abort("could not hold the real release lock fixture") unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      lock.close_on_exec = false
      read_io, write_io = IO.pipe
      tokens = "caller-held-lock-capability".ljust(64, "!")
      write_io.write(tokens)
      write_io.close
      read_io.close_on_exec = false
      environment = {
        "ERYLO_RELEASE_LOCK_HELD" => "1",
        "ERYLO_RELEASE_LOCK_FD" => lock.fileno.to_s,
        "ERYLO_RELEASE_SNAPSHOT_ACTIVE" => "1",
        "ERYLO_RELEASE_SOURCE_ROOT" => Dir.pwd,
        "ERYLO_RELEASE_WORKER_CAPABILITY_FD" => read_io.fileno.to_s,
        "ERYLO_RELEASE_OUTER_CAPABILITY_SHA256" => Digest::SHA256.hexdigest(tokens.byteslice(0, 32)),
        "ERYLO_RELEASE_WORKER_CAPABILITY_SHA256" => Digest::SHA256.hexdigest(tokens.byteslice(32, 32)),
        "ERYLO_RELEASE_OUTER_AUTHENTICATED" => "1",
        "ERYLO_RELEASE_SUPERVISOR_HANDOFF" => "1"
      }
      pid = Process.spawn(
        environment, "/bin/bash", "Scripts/release/release.sh", "--help",
        lock.fileno => lock.fileno,
        read_io.fileno => read_io.fileno,
        close_others: false
      )
      read_io.close
      _pid, status = Process.wait2(pid)
      lock.close
      exit(status.exitstatus || 1)
    '
check "caller-held lock path is rejected by the same public admission boundary" \
    /usr/bin/grep -Fq \
        "external release invocation contains internal snapshot state: ERYLO_RELEASE_SNAPSHOT_ACTIVE" \
        "$test_root/logs/external-worker-state-held-lock.err"
admission_public_after_locked="absent"
if [[ -d "$repo_root/.release/artifacts/current" ]]; then
    admission_public_after_locked="$(release_set_digest "$repo_root/.release/artifacts/current")"
fi
check "caller-held lock rejection leaves publication unchanged" \
    test "$admission_public_after_locked" = "$admission_public_before"

check "public release help remains available only through the public wrapper" \
    /bin/bash Scripts/release/release.sh --help
expect_failure "direct internal driver rejects a caller-authored lock record and capability before help" \
    direct-driver-self-certified /usr/bin/ruby -rdigest -e '
      repo = Dir.pwd
      lock = File.open(
        File.join(repo, ".release", "locks", "production-release.lock"),
        File::RDWR | File::CREAT,
        0o600
      )
      abort("could not hold the direct-driver fixture lock") unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      lock.close_on_exec = false
      token = "D" * 32
      record = [
        "ERYLO_RELEASE_CAPABILITY_V1",
        Process.pid,
        "0" * 64,
        Digest::SHA256.hexdigest(token)
      ].join("\t") + "\n"
      lock.rewind
      lock.truncate(0)
      lock.write(record)
      lock.flush
      lock.fsync
      lock.rewind
      read_io, write_io = IO.pipe
      write_io.write(token)
      write_io.close
      read_io.close_on_exec = false
      source_image = File.join(repo, "Package.swift")
      environment = {
        "ERYLO_RELEASE_LOCK_HELD" => "1",
        "ERYLO_RELEASE_LOCK_FD" => lock.fileno.to_s,
        "ERYLO_RELEASE_SNAPSHOT_ACTIVE" => "1",
        "ERYLO_RELEASE_SOURCE_ROOT" => repo,
        "ERYLO_RELEASE_SOURCE_COMMIT" => `git rev-parse HEAD`.strip,
        "ERYLO_RELEASE_SOURCE_TREE" => `git rev-parse HEAD^{tree}`.strip,
        "ERYLO_RELEASE_SOURCE_DEVICE" => File.stat(repo).dev.to_s,
        "ERYLO_RELEASE_SOURCE_IMAGE" => source_image,
        "ERYLO_RELEASE_SOURCE_IMAGE_SHA256" => Digest::SHA256.file(source_image).hexdigest,
        "ERYLO_RELEASE_SNAPSHOT_MANIFEST_SHA256" => "0" * 64,
        "ERYLO_RELEASE_WORKER_CAPABILITY_FD" => read_io.fileno.to_s,
        "ERYLO_RELEASE_SUPERVISOR_HANDOFF" => "1"
      }
      pid = Process.spawn(
        environment, "/bin/bash", "Scripts/release/release-driver.sh", "--help",
        lock.fileno => lock.fileno,
        read_io.fileno => read_io.fileno,
        close_others: false
      )
      read_io.close
      _pid, status = Process.wait2(pid)
      lock.close
      exit(status.exitstatus || 1)
    '
check "outer-only driver rejects worker state before lock/helper resolution" \
    /usr/bin/grep -Fq \
        "outer release driver contains worker-only state: ERYLO_RELEASE_SNAPSHOT_ACTIVE" \
        "$test_root/logs/direct-driver-self-certified.err"
check "direct-driver rejection emits no public usage response" \
    test ! -s "$test_root/logs/direct-driver-self-certified.out"
direct_driver_public_after="absent"
if [[ -d "$repo_root/.release/artifacts/current" ]]; then
    direct_driver_public_after="$(release_set_digest "$repo_root/.release/artifacts/current")"
fi
check "direct-driver rejection leaves publication unchanged" \
    test "$direct_driver_public_after" = "$admission_public_before"

outer_candidate_root="$test_root/direct-outer-candidate-root"
outer_candidate_marker="$test_root/direct-outer-candidate-helper-executed"
/bin/mkdir -p "$outer_candidate_root/Scripts/release"
outer_candidate_marker_literal="$(/usr/bin/ruby -rjson -e \
    'print JSON.generate(ARGV.fetch(0))' "$outer_candidate_marker")"
printf '#!/usr/bin/ruby\nFile.write(%s, "candidate helper executed\\n")\nexit 0\n' \
    "$outer_candidate_marker_literal" > "$outer_candidate_root/Scripts/release/fs-helper.rb"
/bin/chmod 0755 "$outer_candidate_root/Scripts/release/fs-helper.rb"
expect_failure "outer-only driver rejects candidate source-root redirection before lock assertion" \
    direct-outer-source-root /usr/bin/ruby -rdigest -e '
      repo = Dir.pwd
      candidate = ARGV.fetch(0)
      lock = File.open(
        File.join(repo, ".release", "locks", "production-release.lock"),
        File::RDWR | File::CREAT,
        0o600
      )
      abort("could not hold the direct-outer fixture lock") unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      lock.close_on_exec = false
      outer = "O" * 32
      worker = "W" * 32
      record = [
        "ERYLO_RELEASE_CAPABILITY_V1",
        Process.pid,
        Digest::SHA256.hexdigest(outer),
        Digest::SHA256.hexdigest(worker)
      ].join("\t") + "\n"
      lock.rewind
      lock.truncate(0)
      lock.write(record)
      lock.flush
      lock.fsync
      lock.rewind
      read_io, write_io = IO.pipe
      write_io.write(outer + worker)
      write_io.close
      read_io.close_on_exec = false
      environment = {
        "ERYLO_RELEASE_LOCK_HELD" => "1",
        "ERYLO_RELEASE_LOCK_FD" => lock.fileno.to_s,
        "ERYLO_RELEASE_WORKER_CAPABILITY_FD" => read_io.fileno.to_s,
        "ERYLO_RELEASE_SOURCE_ROOT" => candidate
      }
      pid = Process.spawn(
        environment, "/bin/bash", "Scripts/release/release-driver.sh", "--help",
        lock.fileno => lock.fileno,
        read_io.fileno => read_io.fileno,
        close_others: false
      )
      read_io.close
      _pid, status = Process.wait2(pid)
      lock.close
      exit(status.exitstatus || 1)
    ' "$outer_candidate_root"
check "outer driver reports source-root redirection at the fixed-role boundary" \
    /usr/bin/grep -Fq \
        "outer release driver contains worker-only state: ERYLO_RELEASE_SOURCE_ROOT" \
        "$test_root/logs/direct-outer-source-root.err"
check "outer driver never executes a caller-selected filesystem helper" \
    test ! -e "$outer_candidate_marker"

expect_failure "missing worker capability fails closed" worker-capability-missing \
    /bin/bash -c '
      source Scripts/release/lib.sh
      export ERYLO_RELEASE_SUPERVISOR_HANDOFF=1
      release_assert_worker_capability
    '
worker_capability_failure_fixture() {
    /usr/bin/ruby -rdigest -e '
      mode = ARGV.fetch(0)
      lock = File.open(
        File.join(Dir.pwd, ".release", "locks", "production-release.lock"),
        File::RDWR | File::CREAT,
        0o600
      )
      abort("could not hold the worker capability fixture lock") unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      lock.close_on_exec = false
      token = "R" * 32
      expected_token = mode == "wrong" ? ("E" * 32) : token
      record = [
        "ERYLO_RELEASE_CAPABILITY_V1",
        Process.pid,
        "0" * 64,
        Digest::SHA256.hexdigest(expected_token)
      ].join("\t") + "\n"
      lock.rewind
      lock.truncate(0)
      lock.write(record)
      lock.flush
      lock.fsync
      lock.rewind

      descriptors = {lock.fileno => lock.fileno}
      environment = {
        "ERYLO_RELEASE_LOCK_HELD" => "1",
        "ERYLO_RELEASE_LOCK_FD" => lock.fileno.to_s,
        "ERYLO_RELEASE_SUPERVISOR_HANDOFF" => "1"
      }
      if mode == "closed"
        environment["ERYLO_RELEASE_WORKER_CAPABILITY_FD"] = "999999"
      else
        read_io, write_io = IO.pipe
        write_io.write(token)
        write_io.close
        read_io.close_on_exec = false
        environment["ERYLO_RELEASE_WORKER_CAPABILITY_FD"] = read_io.fileno.to_s
        descriptors[read_io.fileno] = read_io.fileno
      end
      if mode == "reused"
        script = %q{
          descriptor="$ERYLO_RELEASE_WORKER_CAPABILITY_FD"
          source Scripts/release/lib.sh
          release_assert_worker_capability
          export ERYLO_RELEASE_SUPERVISOR_HANDOFF=1
          export ERYLO_RELEASE_WORKER_CAPABILITY_FD="$descriptor"
          release_assert_worker_capability
        }
      else
        script = "source Scripts/release/lib.sh; release_assert_worker_capability"
      end
      pid = Process.spawn(
        environment, "/bin/bash", "-c", script,
        descriptors.merge(close_others: false)
      )
      read_io&.close
      _pid, status = Process.wait2(pid)
      lock.close
      exit(status.exitstatus || 1)
    ' "$1"
}
expect_failure "closed worker capability descriptor fails closed" worker-capability-closed \
    worker_capability_failure_fixture closed
expect_failure "wrong lock-bound worker capability fails closed" worker-capability-wrong \
    worker_capability_failure_fixture wrong
expect_failure "one-use lock-bound worker capability cannot be reused" worker-capability-reused \
    worker_capability_failure_fixture reused

symlink_repo="$external_test_root/symlink-repo"
symlink_target="$external_test_root/symlink-target"
/bin/mkdir -p "$symlink_repo/Scripts/release" "$symlink_target/tests"
/bin/cp Scripts/release/lib.sh Scripts/release/fs-helper.rb "$symlink_repo/Scripts/release/"
printf 'external-release-tree-sentinel\n' > "$symlink_target/tests/sentinel"
/bin/ln -s "$symlink_target" "$symlink_repo/.release"
expect_failure "release harness cleanup rejects a symlinked staging root before mutation" \
    symlinked-release-root bash -c '
        source "$1/Scripts/release/lib.sh"
        release_remove_path "$1" .release/tests
      ' _ "$symlink_repo"
check "symlinked staging-root rejection preserves the external tree" \
    /usr/bin/grep -Fxq external-release-tree-sentinel "$symlink_target/tests/sentinel"

snapshot_fixture_repo="$external_test_root/snapshot-fixture-repo"
snapshot_fixture_root="$external_test_root/snapshot-fixture-root"
/bin/mkdir -p \
    "$snapshot_fixture_repo/Config" \
    "$snapshot_fixture_repo/Resources/App" \
    "$snapshot_fixture_repo/Scripts/release" \
    "$snapshot_fixture_repo/Sources/Fixture" \
    "$snapshot_fixture_root/Config" \
    "$snapshot_fixture_root/Resources/App" \
    "$snapshot_fixture_root/Scripts/release" \
    "$snapshot_fixture_root/Sources/Fixture"
snapshot_fixture_repo="$(cd "$snapshot_fixture_repo" && pwd -P)"
snapshot_fixture_root="$(cd "$snapshot_fixture_root" && pwd -P)"
git -C "$snapshot_fixture_repo" init -q
git -C "$snapshot_fixture_repo" config user.name "Release Harness"
git -C "$snapshot_fixture_repo" config user.email "release-harness@erylo.invalid"
printf '.release/\n' > "$snapshot_fixture_repo/.gitignore"
printf 'pinned-release-config\n' > "$snapshot_fixture_repo/config.txt"
printf 'Package.swift\nSources/Fixture/main.swift\n' \
    > "$snapshot_fixture_repo/Config/ReleaseCompilerInputs.txt"
printf '// swift-tools-version: 6.0\n\nimport PackageDescription\n\nlet package = Package(\n    name: "Fixture",\n    platforms: [.macOS(.v14)],\n    products: [.executable(name: "Fixture", targets: ["Fixture"])],\n    targets: [.executableTarget(name: "Fixture")]\n)\n' \
    > "$snapshot_fixture_repo/Package.swift"
printf 'print("PINNED_A_COMPILER_BYTES")\n' \
    > "$snapshot_fixture_repo/Sources/Fixture/main.swift"
printf 'PINNED_APPCAST_CONFIG_A\n' > "$snapshot_fixture_repo/Config/Appcast.plist"
printf 'PINNED_ENTITLEMENTS_A\n' > "$snapshot_fixture_repo/Config/Erylo.entitlements"
printf 'PINNED_ICON_A\n' > "$snapshot_fixture_repo/Resources/App/Erylo.icns"
printf 'PINNED_RESOURCE_A\n' > "$snapshot_fixture_repo/Resources/App/Info.plist.in"
printf '#!/usr/bin/env bash\nprintf "PINNED_WORKER_A\\n"\nif [[ "${1:-}" == "--hold" ]]; then exec /bin/sleep 300; fi\n' \
    > "$snapshot_fixture_repo/Scripts/release/worker.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nsource "$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"\nrelease_assert_worker_capability\nprintf "PINNED_WORKER_A\\n"\ncase "${1:-}" in\n  --success|"") exit 0 ;;\n  --fail) exit 23 ;;\n  --hold) printf "%%s\\n" "$$" > "${2}.worker-pid"; printf "PINNED_WORKER_A\\n" > "${2}.worker"; printf "SOURCE_MOUNT_TEST_READY:during-worker\\n" >&2; /bin/sleep 300; printf "unexpected-publication\\n" > "${2}.published" ;;\n  *) exit 64 ;;\nesac\n' \
    > "$snapshot_fixture_repo/Scripts/release/release-worker.sh"
/bin/cp Scripts/release/release.sh Scripts/release/release-driver.sh \
    "$snapshot_fixture_repo/Scripts/release/"
/bin/cp Scripts/release/verify-source-tree.rb \
    "$snapshot_fixture_repo/Scripts/release/verify-source-tree.rb"
/bin/cp \
    Scripts/release/fs-helper.rb \
    Scripts/release/lib.sh \
    Scripts/release/recover-source-mount.rb \
    Scripts/release/release-worker-supervisor.rb \
    "$snapshot_fixture_repo/Scripts/release/"
/bin/chmod 0755 \
    "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" \
    "$snapshot_fixture_repo/Scripts/release/recover-source-mount.rb" \
    "$snapshot_fixture_repo/Scripts/release/release-driver.sh" \
    "$snapshot_fixture_repo/Scripts/release/release.sh" \
    "$snapshot_fixture_repo/Scripts/release/release-worker.sh" \
    "$snapshot_fixture_repo/Scripts/release/release-worker-supervisor.rb" \
    "$snapshot_fixture_repo/Scripts/release/verify-source-tree.rb" \
    "$snapshot_fixture_repo/Scripts/release/worker.sh"
git -C "$snapshot_fixture_repo" add config.txt Config Package.swift Resources Scripts Sources
git -C "$snapshot_fixture_repo" add .gitignore
git -C "$snapshot_fixture_repo" commit -q -m fixture
check "fixture public wrapper, outer driver, and worker are fixed executable Git roles" /bin/bash -c '
    [[ "$(git -C "$1" ls-tree HEAD Scripts/release/release.sh | awk "{print \$1}")" == 100755 ]]
    [[ "$(git -C "$1" ls-tree HEAD Scripts/release/release-driver.sh | awk "{print \$1}")" == 100755 ]]
    [[ "$(git -C "$1" ls-tree HEAD Scripts/release/release-worker.sh | awk "{print \$1}")" == 100755 ]]
  ' _ "$snapshot_fixture_repo"
snapshot_fixture_remote="$external_test_root/snapshot-fixture-remote.git"
git init -q --bare "$snapshot_fixture_remote"
git -C "$snapshot_fixture_repo" remote add origin "$snapshot_fixture_remote"
git -C "$snapshot_fixture_repo" push -q -u origin HEAD
/bin/cp "$snapshot_fixture_repo/.gitignore" "$snapshot_fixture_root/.gitignore"
/bin/cp "$snapshot_fixture_repo/config.txt" "$snapshot_fixture_root/config.txt"
/bin/cp "$snapshot_fixture_repo/Config/ReleaseCompilerInputs.txt" \
    "$snapshot_fixture_root/Config/ReleaseCompilerInputs.txt"
/bin/cp "$snapshot_fixture_repo/Package.swift" "$snapshot_fixture_root/Package.swift"
/bin/cp "$snapshot_fixture_repo/Config/Appcast.plist" \
    "$snapshot_fixture_root/Config/Appcast.plist"
/bin/cp "$snapshot_fixture_repo/Config/Erylo.entitlements" \
    "$snapshot_fixture_root/Config/Erylo.entitlements"
/bin/cp "$snapshot_fixture_repo/Resources/App/Erylo.icns" \
    "$snapshot_fixture_root/Resources/App/Erylo.icns"
/bin/cp "$snapshot_fixture_repo/Resources/App/Info.plist.in" \
    "$snapshot_fixture_root/Resources/App/Info.plist.in"
/bin/cp "$snapshot_fixture_repo/Scripts/release/worker.sh" \
    "$snapshot_fixture_root/Scripts/release/worker.sh"
/bin/cp \
    "$snapshot_fixture_repo/Scripts/release/release-driver.sh" \
    "$snapshot_fixture_repo/Scripts/release/release.sh" \
    "$snapshot_fixture_repo/Scripts/release/release-worker.sh" \
    "$snapshot_fixture_root/Scripts/release/"
/bin/cp \
    "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" \
    "$snapshot_fixture_repo/Scripts/release/lib.sh" \
    "$snapshot_fixture_repo/Scripts/release/recover-source-mount.rb" \
    "$snapshot_fixture_repo/Scripts/release/release-worker-supervisor.rb" \
    "$snapshot_fixture_root/Scripts/release/"
/bin/cp "$snapshot_fixture_repo/Scripts/release/verify-source-tree.rb" \
    "$snapshot_fixture_root/Scripts/release/verify-source-tree.rb"
/bin/chmod 0755 \
    "$snapshot_fixture_root/Scripts/release/fs-helper.rb" \
    "$snapshot_fixture_root/Scripts/release/recover-source-mount.rb" \
    "$snapshot_fixture_root/Scripts/release/release-driver.sh" \
    "$snapshot_fixture_root/Scripts/release/release.sh" \
    "$snapshot_fixture_root/Scripts/release/release-worker.sh" \
    "$snapshot_fixture_root/Scripts/release/release-worker-supervisor.rb" \
    "$snapshot_fixture_root/Scripts/release/verify-source-tree.rb" \
    "$snapshot_fixture_root/Scripts/release/worker.sh"
/bin/cp "$snapshot_fixture_repo/Sources/Fixture/main.swift" \
    "$snapshot_fixture_root/Sources/Fixture/main.swift"
/bin/chmod -R a-w "$snapshot_fixture_root"
snapshot_fixture_commit="$(git -C "$snapshot_fixture_repo" rev-parse HEAD)"
snapshot_fixture_tree="$(git -C "$snapshot_fixture_repo" rev-parse HEAD^{tree})"
check "tracked-upstream admission accepts the fixture's exact pushed commit" \
    release_assert_tracked_upstream "$snapshot_fixture_repo" "$snapshot_fixture_commit"
expect_failure "tracked-upstream admission rejects a different source commit" \
    tracked-upstream-mismatch /bin/bash -c '
      source Scripts/release/lib.sh
      release_assert_tracked_upstream "$1" 0000000000000000000000000000000000000000
    ' _ "$snapshot_fixture_repo"
snapshot_fixture_manifest="$(release_snapshot_manifest_sha256 "$snapshot_fixture_root")"
compiler_fixture_inputs="$test_root/compiler-inputs"
release_make_directory "$repo_root" "$compiler_fixture_inputs" >/dev/null
compiler_fixture_audit="$test_root/compiler-audit.tsv"
compiler_fixture_manifest="$test_root/CompilerInputs.json"
compiler_fixture_scratch="$test_root/compiler-build"
compiler_fixture_binary="$compiler_fixture_scratch/arm64-apple-macosx/debug/Fixture"
/bin/chmod u+w "$snapshot_fixture_root/Sources/Fixture/main.swift"
printf 'print("INJECTED_B_COMPILER_BYTES")\n' \
    > "$snapshot_fixture_root/Sources/Fixture/main.swift"
/usr/bin/env -u ERYLO_RELEASE_SWIFTC_DRIVER_ACTIVE \
    SWIFT_EXEC="$repo_root/Scripts/release/verified-swiftc.rb" \
    ERYLO_RELEASE_REAL_SWIFTC="$(xcrun --find swiftc)" \
    ERYLO_RELEASE_REAL_SWIFT_FRONTEND="$(xcrun --find swift-frontend)" \
    ERYLO_RELEASE_SOURCE_REPOSITORY="$snapshot_fixture_repo" \
    ERYLO_RELEASE_SOURCE_ROOT="$snapshot_fixture_root" \
    ERYLO_RELEASE_SOURCE_COMMIT="$snapshot_fixture_commit" \
    ERYLO_RELEASE_COMPILER_INPUT_DIRECTORY="$compiler_fixture_inputs" \
    ERYLO_RELEASE_COMPILER_AUDIT="$compiler_fixture_audit" \
    swift build \
        --package-path "$snapshot_fixture_root" \
        --scratch-path "$compiler_fixture_scratch" \
        --configuration debug \
        --product Fixture \
        --disable-index-store
/usr/bin/ruby Scripts/release/compiler-input-audit.rb create \
    "$snapshot_fixture_repo" "$snapshot_fixture_commit" "$snapshot_fixture_tree" \
    "$compiler_fixture_audit" "$compiler_fixture_manifest"
/bin/cp "$snapshot_fixture_repo/Sources/Fixture/main.swift" \
    "$snapshot_fixture_root/Sources/Fixture/main.swift"
/bin/chmod a-w "$snapshot_fixture_root/Sources/Fixture/main.swift"
check "A-to-B-to-A mutation cannot inject B into compiler-consumed bytes" bash -c '
    [[ "$("$1")" == PINNED_A_COMPILER_BYTES ]]
    ! /usr/bin/strings "$1" | /usr/bin/grep -Fq INJECTED_B_COMPILER_BYTES
  ' _ "$compiler_fixture_binary"
check "verified compiler audit binds the exact compiled set to pinned Git blobs" \
    /usr/bin/ruby Scripts/release/compiler-input-audit.rb validate \
        "$snapshot_fixture_repo" "$snapshot_fixture_commit" "$snapshot_fixture_tree" \
        "$compiler_fixture_manifest"
compiler_fixture_pinned_binary="$test_root/compiler-pinned-a"
/bin/cp "$compiler_fixture_binary" "$compiler_fixture_pinned_binary"
release_remove_path "$repo_root" "$compiler_fixture_scratch"
/bin/chmod u+w \
    "$snapshot_fixture_root" \
    "$snapshot_fixture_root/Sources" \
    "$snapshot_fixture_root/Sources/Fixture"
/bin/mkdir "$snapshot_fixture_root/Sources/Fixture/Injected"
printf 'public let transientCompilerPayload = "TRANSIENT_NESTED_B_BYTES"\n' \
    > "$snapshot_fixture_root/Sources/Fixture/Injected/Evil.swift"
printf 'TRANSIENT_UNREVIEWED_COMPILER_ARGUMENT\n' \
    > "$snapshot_fixture_root/Sources/Fixture/Injected/Input.payload"
expect_failure "transient nested in-root Swift source is denied instead of compiled live" \
    compiler-transient-nested /usr/bin/env -u ERYLO_RELEASE_SWIFTC_DRIVER_ACTIVE \
        SWIFT_EXEC="$repo_root/Scripts/release/verified-swiftc.rb" \
        ERYLO_RELEASE_REAL_SWIFTC="$(xcrun --find swiftc)" \
        ERYLO_RELEASE_REAL_SWIFT_FRONTEND="$(xcrun --find swift-frontend)" \
        ERYLO_RELEASE_SOURCE_REPOSITORY="$snapshot_fixture_repo" \
        ERYLO_RELEASE_SOURCE_ROOT="$snapshot_fixture_root" \
        ERYLO_RELEASE_SOURCE_COMMIT="$snapshot_fixture_commit" \
        ERYLO_RELEASE_COMPILER_INPUT_DIRECTORY="$compiler_fixture_inputs" \
        ERYLO_RELEASE_COMPILER_AUDIT="$compiler_fixture_audit" \
        swift build \
            --package-path "$snapshot_fixture_root" \
            --scratch-path "$compiler_fixture_scratch" \
            --configuration debug \
            --product Fixture \
            --disable-index-store
check "nested source denial identifies the exact reviewed policy boundary" \
    bash -c '
        /bin/cat "$1" "$2" | /usr/bin/grep -Fq \
            "compiler input is not in the reviewed pinned policy: Sources/Fixture/Injected/Evil.swift"
      ' _ "$test_root/logs/compiler-transient-nested.out" \
        "$test_root/logs/compiler-transient-nested.err"
expect_failure "non-Swift in-root compiler path is also mandatory-deny by default" \
    compiler-transient-unusual /usr/bin/env \
        ERYLO_RELEASE_SWIFTC_DRIVER_ACTIVE=1 \
        ERYLO_RELEASE_REAL_SWIFTC="$(xcrun --find swiftc)" \
        ERYLO_RELEASE_REAL_SWIFT_FRONTEND="$(xcrun --find swift-frontend)" \
        ERYLO_RELEASE_SOURCE_REPOSITORY="$snapshot_fixture_repo" \
        ERYLO_RELEASE_SOURCE_ROOT="$snapshot_fixture_root" \
        ERYLO_RELEASE_SOURCE_COMMIT="$snapshot_fixture_commit" \
        ERYLO_RELEASE_COMPILER_INPUT_DIRECTORY="$compiler_fixture_inputs" \
        ERYLO_RELEASE_COMPILER_AUDIT="$compiler_fixture_audit" \
        "$repo_root/Scripts/release/verified-swiftc.rb" \
        -frontend "$snapshot_fixture_root/Sources/Fixture/Injected/Input.payload"
check "unusual in-root argument denial identifies the exact unreviewed path" \
    /usr/bin/grep -Fq \
        "compiler input is not in the reviewed pinned policy: Sources/Fixture/Injected/Input.payload" \
        "$test_root/logs/compiler-transient-unusual.err"
/bin/rm -f -- "$snapshot_fixture_root/Sources/Fixture/Injected/Evil.swift"
/bin/rm -f -- "$snapshot_fixture_root/Sources/Fixture/Injected/Input.payload"
/bin/rmdir "$snapshot_fixture_root/Sources/Fixture/Injected"
/bin/chmod a-w \
    "$snapshot_fixture_root/Sources/Fixture" \
    "$snapshot_fixture_root/Sources" \
    "$snapshot_fixture_root"
check "transient nested-source attempt cannot replace the accepted A binary" bash -c '
    [[ "$("$1")" == PINNED_A_COMPILER_BYTES ]]
    ! /usr/bin/strings "$1" | /usr/bin/grep -Fq TRANSIENT_NESTED_B_BYTES
    [[ ! -e "$2" ]]
  ' _ "$compiler_fixture_pinned_binary" "$compiler_fixture_binary"
tracked_mutation_index=0
for tracked_mutation_path in \
    Config/Appcast.plist \
    Config/Erylo.entitlements \
    Resources/App/Erylo.icns \
    Resources/App/Info.plist.in \
    Scripts/release/release-driver.sh \
    Scripts/release/release.sh \
    Scripts/release/release-worker.sh \
    Scripts/release/worker.sh; do
    tracked_mutation_index=$((tracked_mutation_index + 1))
    /bin/chmod u+w "$snapshot_fixture_root/$tracked_mutation_path"
    printf 'TRANSIENT_TRACKED_INPUT_B_%s\n' "$tracked_mutation_index" \
        > "$snapshot_fixture_root/$tracked_mutation_path"
    /bin/chmod a-w "$snapshot_fixture_root/$tracked_mutation_path"
    expect_failure "transient tracked input mutation is rejected for $tracked_mutation_path" \
        "tracked-input-${tracked_mutation_index}" \
        /usr/bin/ruby Scripts/release/verify-source-tree.rb \
            "$snapshot_fixture_repo" "$snapshot_fixture_commit" "$snapshot_fixture_root"
    check "tracked input rejection reports pinned Git byte mismatch for $tracked_mutation_path" \
        /usr/bin/grep -Fq "verified source bytes differ from the pinned Git object: $tracked_mutation_path" \
            "$test_root/logs/tracked-input-${tracked_mutation_index}.err"
    /bin/chmod u+w "$snapshot_fixture_root/$tracked_mutation_path"
    /bin/cp "$snapshot_fixture_repo/$tracked_mutation_path" \
        "$snapshot_fixture_root/$tracked_mutation_path"
    /bin/chmod a-w "$snapshot_fixture_root/$tracked_mutation_path"
done
pinned_source_tree_manifest="$(
    /usr/bin/ruby Scripts/release/verify-source-tree.rb \
        "$snapshot_fixture_repo" "$snapshot_fixture_commit" "$snapshot_fixture_root"
)"

direct_worker_candidate_failure() {
    /usr/bin/ruby -rdigest -e '
      repo, snapshot_temp, snapshot_root, source_image = ARGV
      lock = File.open(
        File.join(repo, ".release", "locks", "production-release.lock"),
        File::RDWR | File::CREAT,
        0o600
      )
      abort("could not hold the direct-worker fixture lock") unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      lock.close_on_exec = false
      token = "M" * 32
      record = [
        "ERYLO_RELEASE_CAPABILITY_V1",
        Process.pid,
        "0" * 64,
        Digest::SHA256.hexdigest(token)
      ].join("\t") + "\n"
      lock.rewind
      lock.truncate(0)
      lock.write(record)
      lock.flush
      lock.fsync
      lock.rewind
      read_io, write_io = IO.pipe
      write_io.write(token)
      write_io.close
      read_io.close_on_exec = false
      environment = {
        "ERYLO_RELEASE_LOCK_HELD" => "1",
        "ERYLO_RELEASE_LOCK_FD" => lock.fileno.to_s,
        "ERYLO_RELEASE_SNAPSHOT_ACTIVE" => "1",
        "ERYLO_RELEASE_SOURCE_ROOT" => snapshot_root,
        "ERYLO_RELEASE_SOURCE_COMMIT" => `git rev-parse HEAD`.strip,
        "ERYLO_RELEASE_SOURCE_TREE" => `git rev-parse HEAD^{tree}`.strip,
        "ERYLO_RELEASE_SOURCE_EPOCH" => `git show -s --format=%ct HEAD`.strip,
        "ERYLO_RELEASE_SOURCE_DEVICE" => File.stat(snapshot_root).dev.to_s,
        "ERYLO_RELEASE_SOURCE_IMAGE" => source_image,
        "ERYLO_RELEASE_SOURCE_IMAGE_SHA256" => Digest::SHA256.file(source_image).hexdigest,
        "ERYLO_RELEASE_SOURCE_DISK_DEVICE" => "/dev/disk999s1",
        "ERYLO_RELEASE_SNAPSHOT_TEMP" => snapshot_temp,
        "ERYLO_RELEASE_SNAPSHOT_MANIFEST_SHA256" => "0" * 64,
        "ERYLO_RELEASE_WORKER_CAPABILITY_FD" => read_io.fileno.to_s,
        "ERYLO_RELEASE_SUPERVISOR_HANDOFF" => "1"
      }
      pid = Process.spawn(
        environment, "/bin/bash", "Scripts/release/release-worker.sh", "--help",
        lock.fileno => lock.fileno,
        read_io.fileno => read_io.fileno,
        close_others: false
      )
      read_io.close
      _pid, status = Process.wait2(pid)
      lock.close
      exit(status.exitstatus || 1)
    ' "$repo_root" "$1" "$2" "$3"
}

make_unmounted_source_candidate() {
    local candidate_temp
    local candidate_root
    local candidate_image
    local candidate_hash
    local candidate_commit

    candidate_temp="$(release_make_temp_dir "$repo_root" source-snapshot)"
    candidate_root="$candidate_temp/mount"
    candidate_image="$candidate_temp/source.dmg"
    release_make_directory "$repo_root" "$candidate_root" >/dev/null
    candidate_commit="$(/usr/bin/git rev-parse --verify HEAD)"
    /usr/bin/git archive --format=tar "$candidate_commit" | /usr/bin/tar -x -C "$candidate_root"
    /bin/chmod -R a-w "$candidate_root"
    printf 'unrelated-hashed-file-not-an-attached-source-image\n' > "$candidate_image"
    /bin/chmod 0400 "$candidate_image"
    candidate_hash="$(/usr/bin/shasum -a 256 "$candidate_image" | /usr/bin/awk '{print $1}')"
    /usr/bin/ruby -rjson -e '
        payload = {
          "image" => "source.dmg", "imageSHA256" => ARGV.fetch(0),
          "mount" => "mount", "sourceCommit" => ARGV.fetch(1)
        }
        File.write(ARGV.fetch(2), JSON.generate(payload) + "\n", mode: "w", perm: 0o600)
      ' "$candidate_hash" "$candidate_commit" "$candidate_temp/SourceImage.json"
    release_seal_file "$repo_root" "$candidate_temp/SourceImage.json" 0400 >/dev/null
    printf '%s\t%s\t%s\n' "$candidate_temp" "$candidate_root" "$candidate_image"
}

IFS=$'\t' read -r candidate_program_temp candidate_program_root candidate_program_image \
    <<< "$(make_unmounted_source_candidate)"
candidate_verifier_marker="$test_root/candidate-root-verifier-executed"
candidate_verifier_literal="$(/usr/bin/ruby -rjson -e \
    'print JSON.generate(ARGV.fetch(0))' "$candidate_verifier_marker")"
/bin/chmod u+w "$candidate_program_root/Scripts/release/verify-source-tree.rb"
printf '#!/usr/bin/ruby\nFile.write(%s, "candidate verifier executed\\n")\nexit 0\n' \
    "$candidate_verifier_literal" > "$candidate_program_root/Scripts/release/verify-source-tree.rb"
/bin/chmod a-w "$candidate_program_root/Scripts/release/verify-source-tree.rb"
expect_failure "worker rejects a non-mounted candidate root before argument handling" \
    direct-worker-candidate-program direct_worker_candidate_failure \
        "$candidate_program_temp" "$candidate_program_root" "$candidate_program_image"
check "worker mount authentication reports the unattached image boundary" \
    /usr/bin/grep -Fq "managed source image is not attached exactly once" \
        "$test_root/logs/direct-worker-candidate-program.err"
check "worker never executes a verifier selected from the candidate source root" \
    test ! -e "$candidate_verifier_marker"
check "worker-only script emits no public help before source authentication" \
    test ! -s "$test_root/logs/direct-worker-candidate-program.out"
/bin/chmod -R u+w "$candidate_program_root"
release_remove_path "$repo_root" "$candidate_program_temp"

IFS=$'\t' read -r candidate_copy_temp candidate_copy_root candidate_copy_image \
    <<< "$(make_unmounted_source_candidate)"
expect_failure "chmod-only exact source copy plus unrelated hash is not a mounted release image" \
    direct-worker-unmounted-copy direct_worker_candidate_failure \
        "$candidate_copy_temp" "$candidate_copy_root" "$candidate_copy_image"
check "unmounted exact-copy rejection occurs at the authenticated APFS boundary" \
    /usr/bin/grep -Fq "managed source image is not attached exactly once" \
        "$test_root/logs/direct-worker-unmounted-copy.err"
/bin/chmod -R u+w "$candidate_copy_root"
release_remove_path "$repo_root" "$candidate_copy_temp"

for supervisor_result in success failure; do
    supervisor_record="$test_root/source-supervisor-${supervisor_result}.record"
    supervisor_log="$test_root/logs/source-supervisor-${supervisor_result}"
    set +e
    /usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" \
        run-locked "$snapshot_fixture_repo" \
        "$repo_root/Tests/ReleaseHarness/source-mount-crash-fixture.sh" \
        "$snapshot_fixture_repo" "$snapshot_fixture_root" "$snapshot_fixture_commit" \
        "supervisor-${supervisor_result}" "$supervisor_record" \
        >"${supervisor_log}.out" 2>"${supervisor_log}.err"
    supervisor_status=$?
    set -e
    if [[ "$supervisor_result" == "success" ]]; then
        check "outside-image supervisor returns the mounted worker success status" \
            test "$supervisor_status" = 0
    else
        check "outside-image supervisor returns the exact mounted worker failure status" \
            test "$supervisor_status" = 23
    fi
    check "mounted $supervisor_result worker executes pinned image content" \
        /usr/bin/grep -Fxq PINNED_WORKER_A "${supervisor_log}.out"
    IFS=$'\t' read -r supervisor_temp supervisor_mount < "$supervisor_record"
    check "rewound pinned helper executes lock assertion and $supervisor_result transaction removal" \
        test ! -e "$supervisor_temp"
    check "outside-image supervisor detaches only after the $supervisor_result worker exits" \
        bash -c '! /usr/bin/hdiutil info | /usr/bin/grep -Fq "$1"' _ "$supervisor_mount"
done
closure_mutation_record="$test_root/source-supervisor-closure-mutation.record"
/usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" \
    run-locked "$snapshot_fixture_repo" \
    "$repo_root/Tests/ReleaseHarness/source-mount-crash-fixture.sh" \
    "$snapshot_fixture_repo" "$snapshot_fixture_root" "$snapshot_fixture_commit" \
    supervisor-closure-mutation "$closure_mutation_record"
IFS=$'\t' read -r closure_mutation_temp closure_mutation_mount < "$closure_mutation_record"
check "post-verification A-to-B-to-A supervisor closure mutation executes no B dependency" \
    test ! -e "${closure_mutation_record}.b-executed"
check "pinned supervisor closure completes after every live dependency is replaced" \
    /usr/bin/grep -Fxq PINNED_WORKER_A "${closure_mutation_record}.worker"
check "pinned supervisor closure removes its source transaction" \
    test ! -e "$closure_mutation_temp"
check "pinned supervisor closure leaves no source attachment" \
    bash -c '! /usr/bin/hdiutil info | /usr/bin/grep -Fq "$1"' _ "$closure_mutation_mount"
anonymous_swap_record="$test_root/source-supervisor-anonymous-swap.record"
anonymous_swap_log="$test_root/logs/source-supervisor-anonymous-swap.err"
anonymous_swap_marker="$test_root/source-supervisor-anonymous-swap-b-executed"
release_harness_start_background source-supervisor-anonymous-swap \
    "$release_harness_background_timeout" /usr/bin/env \
    ERYLO_RELEASE_FS_TESTING=1 \
    ERYLO_RELEASE_FS_TEST_PAUSE_STAGE=anonymous-executable-before-unlink \
    ERYLO_RELEASE_FS_TEST_DELAY=5 \
    /usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" \
        run-locked "$snapshot_fixture_repo" \
        "$repo_root/Tests/ReleaseHarness/source-mount-crash-fixture.sh" \
        "$snapshot_fixture_repo" "$snapshot_fixture_root" "$snapshot_fixture_commit" \
        supervisor-success "$anonymous_swap_record" \
        2>"$anonymous_swap_log"
anonymous_swap_pid="$release_harness_background_pid"
anonymous_swap_state="$release_harness_background_state"
check "pinned supervisor launch reaches the held-descriptor unlink boundary" \
    wait_for_fs_test_pause "$anonymous_swap_log" "$anonymous_swap_pid" \
        "$anonymous_swap_state" source-supervisor-anonymous-swap
anonymous_swap_leaf="$(/usr/bin/find "$snapshot_fixture_repo/.release/tmp" \
    -maxdepth 1 -type f -name '.pinned-executable.*' -print | /usr/bin/head -n 1)"
anonymous_swap_held="${anonymous_swap_leaf}.held-a"
/bin/mv "$anonymous_swap_leaf" "$anonymous_swap_held"
anonymous_swap_marker_literal="$(/usr/bin/ruby -rjson -e \
    'print JSON.generate(ARGV.fetch(0))' "$anonymous_swap_marker")"
printf '#!/usr/bin/env ruby\nFile.write(%s, "B\\n")\nexit 97\n' \
    "$anonymous_swap_marker_literal" > "$anonymous_swap_leaf"
/bin/chmod 0600 "$anonymous_swap_leaf"
expect_background_failure \
    "same-user leaf swap cannot replace the already-authenticated supervisor descriptor" \
    "$anonymous_swap_pid" "$anonymous_swap_state"
check "held-descriptor leaf replacement is detected before inheritance" \
    /usr/bin/grep -Fq "pinned release executable leaf changed before unlink" \
        "$anonymous_swap_log"
check "replacement B executable never runs from the inherited descriptor" \
    test ! -e "$anonymous_swap_marker"
/usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" \
    remove "$snapshot_fixture_repo" "$anonymous_swap_leaf" file
/usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" \
    remove "$snapshot_fixture_repo" "$anonymous_swap_held" file
bash -c 'source "$1/Scripts/release/lib.sh"; release_recover_temporaries "$1"' \
    _ "$snapshot_fixture_repo"
IFS=$'\t' read -r anonymous_swap_temp anonymous_swap_mount < "$anonymous_swap_record"
check "failed held-descriptor launch recovery removes its source transaction" \
    test ! -e "$anonymous_swap_temp"
check "failed held-descriptor launch recovery leaves no attachment" \
    bash -c '! /usr/bin/hdiutil info | /usr/bin/grep -Fq "$1"' _ "$anonymous_swap_mount"
for bootstrap_failure in producer read hash; do
    bootstrap_failure_record="$test_root/source-supervisor-bootstrap-${bootstrap_failure}.record"
    expect_failure "pinned bootstrap $bootstrap_failure failure cannot silently succeed" \
        "source-supervisor-bootstrap-${bootstrap_failure}" \
        /usr/bin/env \
            ERYLO_RELEASE_TESTING=1 \
            ERYLO_RELEASE_TEST_BOOTSTRAP_FAILURE="$bootstrap_failure" \
            /usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" \
            run-locked "$snapshot_fixture_repo" \
            "$repo_root/Tests/ReleaseHarness/source-mount-crash-fixture.sh" \
            "$snapshot_fixture_repo" "$snapshot_fixture_root" "$snapshot_fixture_commit" \
            supervisor-success "$bootstrap_failure_record"
    if [[ "$bootstrap_failure" == "producer" ]]; then
        bootstrap_failure_message="could not synchronously read the pinned supervisor bootstrap"
    else
        bootstrap_failure_message="pinned supervisor bootstrap object hash mismatch"
    fi
    check "pinned bootstrap $bootstrap_failure failure reports its closed gate" \
        /usr/bin/grep -Fq "$bootstrap_failure_message" \
            "$test_root/logs/source-supervisor-bootstrap-${bootstrap_failure}.err"
    IFS=$'\t' read -r bootstrap_failure_temp bootstrap_failure_mount \
        < "$bootstrap_failure_record"
    bash -c 'source "$1/Scripts/release/lib.sh"; release_recover_temporaries "$1"' \
        _ "$snapshot_fixture_repo"
    check "pinned bootstrap $bootstrap_failure failure leaves a recoverable transaction" \
        test ! -e "$bootstrap_failure_temp"
    check "pinned bootstrap $bootstrap_failure recovery leaves no attachment" \
        bash -c '! /usr/bin/hdiutil info | /usr/bin/grep -Fq "$1"' \
            _ "$bootstrap_failure_mount"
done
for source_crash_stage in after-attach during-worker; do
    source_crash_record="$test_root/source-mount-${source_crash_stage}.record"
    source_crash_log="$test_root/logs/source-mount-${source_crash_stage}.err"
    source_crash_environment=(/usr/bin/env)
    if [[ "$source_crash_stage" == "during-worker" ]]; then
        source_crash_environment+=(
            ERYLO_RELEASE_TESTING=1
            ERYLO_RELEASE_TEST_PAUSE_STAGE=watchdog-before-worker-termination
            ERYLO_RELEASE_TEST_WATCHDOG_RECORD="${source_crash_record}.watchdog-pid"
        )
    fi
    release_harness_start_background "source-mount-${source_crash_stage}" \
        "$release_harness_background_timeout" "${source_crash_environment[@]}" \
        /usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" \
        run-locked "$snapshot_fixture_repo" \
        "$repo_root/Tests/ReleaseHarness/source-mount-crash-fixture.sh" \
        "$snapshot_fixture_repo" "$snapshot_fixture_root" "$snapshot_fixture_commit" \
        "$source_crash_stage" "$source_crash_record" \
        2>"$source_crash_log"
    source_crash_pid="$release_harness_background_pid"
    source_crash_state="$release_harness_background_state"
    check "source image reaches the $source_crash_stage SIGKILL boundary" \
        wait_for_fs_test_pause "$source_crash_log" "$source_crash_pid" \
            "$source_crash_state" "source-mount-${source_crash_stage}"
    expect_failure "a concurrent release cannot reclaim an active $source_crash_stage mount" \
        "source-mount-concurrent-${source_crash_stage}" \
        /usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" \
            run-locked "$snapshot_fixture_repo" /usr/bin/true
    check "concurrent $source_crash_stage invocation fails at the repository lock" \
        /usr/bin/grep -Fq "another release operation owns this repository" \
            "$test_root/logs/source-mount-concurrent-${source_crash_stage}.err"
    kill_paused_process "source image process is SIGKILLed at $source_crash_stage" \
        "$source_crash_pid" "$source_crash_state"
    IFS=$'\t' read -r source_crash_temp source_crash_mount < "$source_crash_record"
    check "SIGKILL at $source_crash_stage leaves the recorded read-only image mounted" \
        test "$(/usr/bin/stat -f '%d' "$source_crash_mount")" \
            != "$(/usr/bin/stat -f '%d' "$source_crash_temp")"
    if [[ "$source_crash_stage" == "during-worker" ]]; then
        check "worker crash cut consumed only the pinned read-only script" \
            /usr/bin/grep -Fxq PINNED_WORKER_A "${source_crash_record}.worker"
        source_crash_worker_pid="$(<"${source_crash_record}.worker-pid")"
        watchdog_paused=0
        if /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-log \
            "$source_crash_log" "$release_harness_readiness_timeout" \
            'SOURCE_MOUNT_WATCHDOG_TEST_READY:before-worker-termination' \
            source-mount-watchdog \
            && [[ -s "${source_crash_record}.watchdog-pid" ]]; then
            watchdog_paused=1
        fi
        check "outer SIGKILL leaves its live worker under a lock-holding supervisor watchdog" \
            test "$watchdog_paused" = 1
        check "worker remains live before watchdog settlement" \
            /bin/kill -0 "$source_crash_worker_pid"
        expect_failure "outer SIGKILL cannot release ownership while its live worker remains" \
            source-mount-live-worker-lock \
            /usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" \
                run-locked "$snapshot_fixture_repo" /usr/bin/true
        check "live worker retains the inherited repository lock after owner SIGKILL" \
            /usr/bin/grep -Fq "another release operation owns this repository" \
                "$test_root/logs/source-mount-live-worker-lock.err"
        source_crash_watchdog_pid="$(<"${source_crash_record}.watchdog-pid")"
        /bin/kill -CONT "$source_crash_watchdog_pid"
        worker_lock_settled=0
        if /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" retry-command \
            "$release_harness_readiness_timeout" 5 source-mount-worker-lock -- \
            /usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" \
                run-locked "$snapshot_fixture_repo" /usr/bin/true \
            >/dev/null 2>&1; then
            worker_lock_settled=1
        fi
        check "killed release worker releases its inherited lock before recovery" \
            test "$worker_lock_settled" = 1
        check "killed release attempt publishes nothing after its crash cut" \
            test ! -e "${source_crash_record}.published"
    fi
    bash -c 'source "$1/Scripts/release/lib.sh"; release_recover_temporaries "$1"' \
        _ "$snapshot_fixture_repo"
    check "fresh startup recovery removes the $source_crash_stage transaction" \
        test ! -e "$source_crash_temp"
    check "fresh startup recovery leaves no $source_crash_stage attachment" bash -c '
        ! /usr/bin/hdiutil info | /usr/bin/grep -Fq "$1"
      ' _ "$source_crash_mount"
    release_harness_finish_crash_owner "$source_crash_pid" "$source_crash_state" \
        "source-mount-${source_crash_stage}"
done

unrelated_mount_temp="$(release_make_temp_dir "$repo_root" source-snapshot)"
unrelated_mount_path="$unrelated_mount_temp/mount"
unrelated_recorded_image="$unrelated_mount_temp/source.dmg"
unrelated_actual_image="$unrelated_mount_temp/unrelated.dmg"
release_make_directory "$repo_root" "$unrelated_mount_path" >/dev/null
/usr/bin/hdiutil create -quiet -fs APFS -format UDRO \
    -volname EryloRecordedFixture -srcfolder "$snapshot_fixture_root" "$unrelated_recorded_image"
/usr/bin/hdiutil create -quiet -fs APFS -format UDRO \
    -volname EryloUnrelatedFixture -srcfolder "$snapshot_fixture_root" "$unrelated_actual_image"
/bin/chmod 0400 "$unrelated_recorded_image" "$unrelated_actual_image"
unrelated_recorded_hash="$(/usr/bin/shasum -a 256 "$unrelated_recorded_image" | /usr/bin/awk '{print $1}')"
/usr/bin/ruby -rjson -e '
    payload = {
      "image" => "source.dmg", "imageSHA256" => ARGV.fetch(0),
      "mount" => "mount", "sourceCommit" => ARGV.fetch(1)
    }
    File.write(ARGV.fetch(2), JSON.generate(payload) + "\n", mode: "w", perm: 0o600)
  ' "$unrelated_recorded_hash" "$snapshot_fixture_commit" \
    "$unrelated_mount_temp/SourceImage.json"
release_seal_file "$repo_root" "$unrelated_mount_temp/SourceImage.json" 0400 >/dev/null
/usr/bin/hdiutil attach -quiet -readonly -nobrowse \
    -mountpoint "$unrelated_mount_path" "$unrelated_actual_image"
expect_failure "startup recovery refuses an unrelated replacement mount" \
    source-mount-unrelated-replacement bash -c '
        source Scripts/release/lib.sh
        release_recover_temporaries "$1"
      ' _ "$repo_root"
check "rejected recovery leaves the unrelated replacement mounted and untouched" \
    test "$("$unrelated_mount_path/Scripts/release/worker.sh")" = PINNED_WORKER_A
/usr/bin/hdiutil detach -quiet "$unrelated_mount_path"
release_remove_path "$repo_root" "$unrelated_mount_temp"
unrelated_mount_path=""
unrelated_mount_temp=""

source_image_temp="$(/usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" \
    make-temp "$snapshot_fixture_repo" source-snapshot)"
source_image_mount="$source_image_temp/mount"
source_image_path="$source_image_temp/source.dmg"
/usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" make-directory \
    "$snapshot_fixture_repo" "$source_image_mount" >/dev/null
/usr/bin/hdiutil create -quiet -fs APFS -format UDRO \
    -volname EryloHarnessSource -srcfolder "$snapshot_fixture_root" "$source_image_path"
/bin/chmod 0400 "$source_image_path"
source_image_sha256="$(/usr/bin/shasum -a 256 "$source_image_path" | /usr/bin/awk '{print $1}')"
/usr/bin/ruby -rjson -e '
    payload = {
      "image" => "source.dmg", "imageSHA256" => ARGV.fetch(0),
      "mount" => "mount", "sourceCommit" => ARGV.fetch(1)
    }
    File.write(ARGV.fetch(2), JSON.generate(payload) + "\n", mode: "w", perm: 0o600)
  ' "$source_image_sha256" "$snapshot_fixture_commit" "$source_image_temp/SourceImage.json"
/usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" seal-file \
    "$snapshot_fixture_repo" "$source_image_temp/SourceImage.json" 0400 >/dev/null
/usr/bin/hdiutil attach -quiet -readonly -nobrowse \
    -mountpoint "$source_image_mount" "$source_image_path"
source_image_device="$(/usr/bin/stat -f '%d' "$source_image_mount")"
source_image_disk_device="$(release_authenticate_source_mount \
    "$snapshot_fixture_repo" "$snapshot_fixture_commit" "$source_image_mount")"
check "read-only source image is exactly bound to the pinned Git tree" \
    test "$(/usr/bin/ruby Scripts/release/verify-source-tree.rb \
        "$snapshot_fixture_repo" "$snapshot_fixture_commit" "$source_image_mount")" \
        = "$pinned_source_tree_manifest"
expect_failure "read-only source store rejects a transient worker-script mutation" \
    readonly-worker-mutation bash -c 'printf "INJECTED_WORKER_B\n" > "$1"' _ \
        "$source_image_mount/Scripts/release/worker.sh"
expect_failure "read-only source store rejects a transient appcast mutation" \
    readonly-appcast-mutation bash -c 'printf "INJECTED_APPCAST_B\n" > "$1"' _ \
        "$source_image_mount/Config/Appcast.plist"
expect_failure "read-only source store rejects a transient icon mutation" \
    readonly-icon-mutation bash -c 'printf "INJECTED_ICON_B\n" > "$1"' _ \
        "$source_image_mount/Resources/App/Erylo.icns"
check "worker executed from the bound source image retains pinned A bytes" \
    test "$("$source_image_mount/Scripts/release/worker.sh")" = PINNED_WORKER_A
worker_admission_developer="$test_root/WorkerAdmissionXcode.app/Contents/Developer"
worker_admission_git_marker="$test_root/worker-admission-selected-git-executed"
/bin/mkdir -p "$worker_admission_developer/usr/bin"
printf '#!/bin/bash\nprintf "selected git executed\\n" >> %q\nexit 97\n' \
    "$worker_admission_git_marker" > "$worker_admission_developer/usr/bin/git"
/bin/chmod 0755 "$worker_admission_developer/usr/bin/git"
check "clean immutable source snapshot satisfies the final release invariant" /usr/bin/env \
    DEVELOPER_DIR="$worker_admission_developer" \
    ERYLO_RELEASE_SOURCE_ROOT="$source_image_mount" \
    ERYLO_RELEASE_SOURCE_DEVICE="$source_image_device" \
    ERYLO_RELEASE_SOURCE_IMAGE="$source_image_path" \
    ERYLO_RELEASE_SOURCE_IMAGE_SHA256="$source_image_sha256" \
    ERYLO_RELEASE_SOURCE_DISK_DEVICE="$source_image_disk_device" \
    ERYLO_RELEASE_SNAPSHOT_TEMP="$source_image_temp" \
    ERYLO_RELEASE_SNAPSHOT_MANIFEST_SHA256="$pinned_source_tree_manifest" \
    bash -c '
        source Scripts/release/lib.sh
        release_assert_source_snapshot "$1" "$2" "$3"
      ' _ "$snapshot_fixture_repo" "$snapshot_fixture_commit" "$snapshot_fixture_tree"
check "worker source admission executes no caller-selected Git before Xcode authentication" \
    test ! -e "$worker_admission_git_marker"
printf 'mutated-live-config-same-release-commit\n' > "$snapshot_fixture_repo/config.txt"
expect_failure "mid-run live input mutation fails the final source invariant before publication" \
    snapshot-mid-run-mutation /usr/bin/env \
        ERYLO_RELEASE_SOURCE_ROOT="$source_image_mount" \
        ERYLO_RELEASE_SOURCE_DEVICE="$source_image_device" \
        ERYLO_RELEASE_SOURCE_IMAGE="$source_image_path" \
        ERYLO_RELEASE_SOURCE_IMAGE_SHA256="$source_image_sha256" \
        ERYLO_RELEASE_SOURCE_DISK_DEVICE="$source_image_disk_device" \
        ERYLO_RELEASE_SNAPSHOT_TEMP="$source_image_temp" \
        ERYLO_RELEASE_SNAPSHOT_MANIFEST_SHA256="$pinned_source_tree_manifest" \
        bash -c '
            source Scripts/release/lib.sh
            release_assert_source_snapshot "$1" "$2" "$3"
          ' _ "$snapshot_fixture_repo" "$snapshot_fixture_commit" "$snapshot_fixture_tree"
check "mid-run live mutation does not alter the immutable snapshot bytes" \
    /usr/bin/grep -Fxq pinned-release-config "$source_image_mount/config.txt"
/usr/bin/git -C "$snapshot_fixture_repo" show HEAD:config.txt > "$snapshot_fixture_repo/config.txt"
/usr/bin/hdiutil detach -quiet "$source_image_mount"
source_image_mount=""
/usr/bin/ruby "$snapshot_fixture_repo/Scripts/release/fs-helper.rb" remove \
    "$snapshot_fixture_repo" "$source_image_temp" any
source_image_temp=""

fi
if release_harness_runs build-validation; then
release_harness_phase build-validation
for symlink_case in escape dangling cycle; do
    symlink_source_repo="$external_test_root/source-symlink-${symlink_case}-repo"
    symlink_source_root="$external_test_root/source-symlink-${symlink_case}-root"
    /bin/mkdir -p "$symlink_source_repo/Inputs" "$symlink_source_root/Inputs"
    git -C "$symlink_source_repo" init -q
    git -C "$symlink_source_repo" config user.name "Release Harness"
    git -C "$symlink_source_repo" config user.email "release-harness@erylo.invalid"
    printf 'pinned\n' > "$symlink_source_repo/Inputs/pinned.txt"
    /bin/cp "$symlink_source_repo/Inputs/pinned.txt" "$symlink_source_root/Inputs/pinned.txt"
    case "$symlink_case" in
        escape)
            /bin/ln -s ../../external-sentinel "$symlink_source_repo/Inputs/link"
            /bin/ln -s ../../external-sentinel "$symlink_source_root/Inputs/link"
            ;;
        dangling)
            /bin/ln -s missing "$symlink_source_repo/Inputs/link"
            /bin/ln -s missing "$symlink_source_root/Inputs/link"
            ;;
        cycle)
            /bin/ln -s second "$symlink_source_repo/Inputs/first"
            /bin/ln -s first "$symlink_source_repo/Inputs/second"
            /bin/ln -s second "$symlink_source_root/Inputs/first"
            /bin/ln -s first "$symlink_source_root/Inputs/second"
            ;;
    esac
    git -C "$symlink_source_repo" add Inputs
    git -C "$symlink_source_repo" commit -q -m "$symlink_case symlink fixture"
    /bin/chmod a-w "$symlink_source_root" "$symlink_source_root/Inputs" \
        "$symlink_source_root/Inputs/pinned.txt"
    symlink_source_commit="$(git -C "$symlink_source_repo" rev-parse HEAD)"
    expect_failure "pinned $symlink_case symlink is rejected from production source images" \
        "source-symlink-${symlink_case}" \
        /usr/bin/ruby Scripts/release/verify-source-tree.rb \
            "$symlink_source_repo" "$symlink_source_commit" "$symlink_source_root"
    check "$symlink_case symlink rejection occurs at the source-tree type boundary" \
        /usr/bin/grep -Fq "release commit contains an unsupported source-tree entry" \
            "$test_root/logs/source-symlink-${symlink_case}.err"
done

wrong_mode_dir="$test_root/wrong-mode-parent"
release_make_directory "$repo_root" "$wrong_mode_dir" >/dev/null
/bin/chmod 0777 "$wrong_mode_dir"
check "anchored directory creation repairs an unsafe pre-existing mode under umask 000" bash -c '
    umask 000
    source Scripts/release/lib.sh
    release_make_directory "$1" "$2/child" >/dev/null
    [[ "$(/usr/bin/stat -f "%Lp" "$1/.release")" == 700 ]]
    [[ "$(/usr/bin/stat -f "%Lp" "$2")" == 700 ]]
    [[ "$(/usr/bin/stat -f "%Lp" "$2/child")" == 700 ]]
  ' _ "$repo_root" "$wrong_mode_dir"
umask_temp="$(bash -c 'umask 022; source Scripts/release/lib.sh; release_make_temp_dir "$1" umask-fixture' _ "$repo_root")"
check "release temporary directories remain 0700 under caller umask 022" \
    test "$(/usr/bin/stat -f '%Lp' "$umask_temp")" = 700
release_remove_path "$repo_root" "$umask_temp"

race_external_parent="$external_test_root/descriptor-race-external"
/bin/mkdir "$race_external_parent"
printf 'external-parent-sentinel\n' > "$race_external_parent/sentinel"

race_remove_parent="$test_root/descriptor-race-remove"
race_remove_held="$test_root/descriptor-race-remove-held"
release_make_directory "$repo_root" "$race_remove_parent" >/dev/null
printf 'remove-me\n' > "$race_remove_parent/victim"
race_remove_log="$test_root/logs/descriptor-race-remove.err"
release_harness_start_background descriptor-race-remove \
    "$release_harness_background_timeout" /usr/bin/env \
    ERYLO_RELEASE_FS_TESTING=1 ERYLO_RELEASE_FS_TEST_PAUSE_STAGE=remove \
    /usr/bin/ruby Scripts/release/fs-helper.rb remove "$repo_root" \
    "$race_remove_parent/victim" any 2>"$race_remove_log"
race_pid="$release_harness_background_pid"
race_state="$release_harness_background_state"
wait_for_fs_test_pause "$race_remove_log" "$race_pid" "$race_state" descriptor-race-remove
/bin/mv "$race_remove_parent" "$race_remove_held"
/bin/ln -s "$race_external_parent" "$race_remove_parent"
expect_background_success \
    "descriptor-anchored removal completes against the originally opened parent" \
    "$race_pid" "$race_state"
check "removal parent swap cannot touch an external tree" \
    /usr/bin/grep -Fxq external-parent-sentinel "$race_external_parent/sentinel"
check "removal parent swap removed only the originally anchored leaf" test ! -e "$race_remove_held/victim"
/bin/rm -f -- "$race_remove_parent"
/bin/mv "$race_remove_held" "$race_remove_parent"

race_publish_parent="$test_root/descriptor-race-publish"
race_publish_held="$test_root/descriptor-race-publish-held"
release_make_directory "$repo_root" "$race_publish_parent" >/dev/null
printf 'anchored-publication-bytes\n' > "$race_publish_parent/source"
printf 'external-destination-sentinel\n' > "$race_external_parent/destination"
race_publish_log="$test_root/logs/descriptor-race-publish.err"
release_harness_start_background descriptor-race-publish \
    "$release_harness_background_timeout" /usr/bin/env \
    ERYLO_RELEASE_FS_TESTING=1 ERYLO_RELEASE_FS_TEST_PAUSE_STAGE=publish-file \
    /usr/bin/ruby Scripts/release/fs-helper.rb publish-file "$repo_root" \
        "$race_publish_parent/source" "$race_publish_parent/destination" \
    2>"$race_publish_log"
race_pid="$release_harness_background_pid"
race_state="$release_harness_background_state"
wait_for_fs_test_pause "$race_publish_log" "$race_pid" "$race_state" descriptor-race-publish
/bin/mv "$race_publish_parent" "$race_publish_held"
/bin/ln -s "$race_external_parent" "$race_publish_parent"
expect_background_success \
    "descriptor-anchored publication completes against the originally opened parent" \
    "$race_pid" "$race_state"
check "publication parent swap cannot overwrite the external destination" \
    /usr/bin/grep -Fxq external-destination-sentinel "$race_external_parent/destination"
check "publication parent swap installs only into the originally anchored directory" \
    /usr/bin/grep -Fxq anchored-publication-bytes "$race_publish_held/destination"
/bin/rm -f -- "$race_publish_parent"
/bin/mv "$race_publish_held" "$race_publish_parent"

race_tmp_held="$repo_root/.release/tmp-held-for-race"
race_tmp_log="$test_root/logs/descriptor-race-temp.err"
race_tmp_output="$test_root/logs/descriptor-race-temp.out"
release_harness_start_background descriptor-race-make-temp \
    "$release_harness_background_timeout" /usr/bin/env \
    ERYLO_RELEASE_FS_TESTING=1 ERYLO_RELEASE_FS_TEST_PAUSE_STAGE=make-temp \
    /usr/bin/ruby Scripts/release/fs-helper.rb make-temp "$repo_root" parent-swap \
    >"$race_tmp_output" 2>"$race_tmp_log"
race_pid="$release_harness_background_pid"
race_state="$release_harness_background_state"
wait_for_fs_test_pause "$race_tmp_log" "$race_pid" "$race_state" descriptor-race-make-temp
/bin/mv "$repo_root/.release/tmp" "$race_tmp_held"
/bin/ln -s "$race_external_parent" "$repo_root/.release/tmp"
expect_background_success \
    "temporary-directory creation remains anchored after its parent is swapped" \
    "$race_pid" "$race_state"
check "temporary parent swap creates nothing in the external directory" bash -c '
    [[ "$(find "$1" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d " ")" == 0 ]]
  ' _ "$race_external_parent"
/bin/rm -f -- "$repo_root/.release/tmp"
/bin/mv "$race_tmp_held" "$repo_root/.release/tmp"
race_created_temp="$(<"$race_tmp_output")"
race_created_name="$(basename "$race_created_temp")"
check "temporary parent swap creates only in the originally anchored directory" \
    test -d "$repo_root/.release/tmp/$race_created_name"
release_remove_path "$repo_root" "$repo_root/.release/tmp/$race_created_name"

prepare_hostile_path_fixture
/usr/bin/ruby -rjson -e '
  identity = JSON.parse(ARGV.fetch(0))
  identity["kind"] = "Xcode"
  identity["xcodeVersion"] = "99.0"
  identity["xcodeBuildVersion"] = "99A1"
  identity["macOSSDKVersion"] = "99.0"
  identity["macOSSDKBuildVersion"] = "99A1"
  File.write(ARGV.fetch(1), JSON.generate(identity))
' "$ERYLO_RELEASE_TOOLCHAIN_JSON" "$test_root/reviewed-toolchain-identity.json"
reviewed_toolchain_identity="$(<"$test_root/reviewed-toolchain-identity.json")"
reviewed_swift_hash="$(/usr/bin/ruby -rdigest -rjson -e '
  print Digest::SHA256.hexdigest(JSON.parse(ARGV.fetch(0)).fetch("swiftCompilerVersion"))
' "$reviewed_toolchain_identity")"
reviewed_toolchain_policy="$(printf '%s\n' \
    'XCODE_VERSION=99.0' \
    'XCODE_BUILD_VERSION=99A1' \
    'MACOS_SDK_VERSION=99.0' \
    'MACOS_SDK_BUILD_VERSION=99A1' \
    "SWIFT_COMPILER_VERSION_SHA256=$reviewed_swift_hash")"
expect_failure "UNCONFIRMED production toolchain policy fails closed" \
    toolchain-policy-unconfirmed release_validate_reviewed_toolchain_policy \
    "$(<Config/ReleaseToolchain.env)" "$reviewed_toolchain_identity"
check "an exact reviewed Xcode, SDK, and Swift identity policy is accepted" \
    release_validate_reviewed_toolchain_policy \
    "$reviewed_toolchain_policy" "$reviewed_toolchain_identity"
mismatched_toolchain_policy="${reviewed_toolchain_policy/XCODE_BUILD_VERSION=99A1/XCODE_BUILD_VERSION=99A2}"
expect_failure "reviewed toolchain identity mismatch fails closed" \
    toolchain-policy-mismatch release_validate_reviewed_toolchain_policy \
    "$mismatched_toolchain_policy" "$reviewed_toolchain_identity"
fake_xcode="$test_root/FakeXcode.app"
/bin/mkdir -p \
    "$fake_xcode/Contents/Developer/usr/bin" \
    "$fake_xcode/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
fake_xcode_tool_marker="$test_root/fake-xcode-selected-tool-executed"
for fake_xcode_tool in \
    "$fake_xcode/Contents/Developer/usr/bin/git" \
    "$fake_xcode/Contents/Developer/usr/bin/xcodebuild" \
    "$fake_xcode/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"; do
    printf '#!/bin/bash\nprintf "%%s\\n" "$0" >> %q\nexit 97\n' "$fake_xcode_tool_marker" \
        > "$fake_xcode_tool"
    /bin/chmod 0755 "$fake_xcode_tool"
done
expect_failure "outer admission resolves source control independently of unverified Xcode" \
    toolchain-source-control-auth-order /usr/bin/env \
        DEVELOPER_DIR="$fake_xcode/Contents/Developer" \
        Scripts/release/release.sh --identity fixture
check "outer admission reaches fixed argument validation before toolchain selection" \
    /usr/bin/grep -Fq \
        "identity, Keychain profile, signed appcast config, and reviewed icon are required" \
        "$test_root/logs/toolchain-source-control-auth-order.err"
check "source-control admission executes no unverified developer tool" \
    test ! -e "$fake_xcode_tool_marker"
expect_failure "unverified Xcode application fails before release publication" \
    toolchain-unverified-xcode /bin/bash -c '
      source Scripts/release/lib.sh
      release_verify_xcode_application "$1"
    ' _ "$fake_xcode"
expect_failure "toolchain capture authenticates Xcode before selected tool execution" \
    toolchain-capture-auth-order /usr/bin/env \
        -u ERYLO_RELEASE_DEVELOPER_DIR \
        -u ERYLO_RELEASE_TOOLCHAIN_JSON \
        -u ERYLO_RELEASE_TOOLCHAIN_SHA256 \
        -u ERYLO_RELEASE_TOOLCHAIN_POLICY_SHA256 \
        DEVELOPER_DIR="$fake_xcode/Contents/Developer" \
        /bin/bash -c 'source Scripts/release/lib.sh; release_capture_toolchain 1'
check "toolchain capture reports Apple authenticity before any selected-tool result" \
    /usr/bin/grep -Fq \
        "selected Xcode application fails Apple code-signature verification" \
        "$test_root/logs/toolchain-capture-auth-order.err"
check "toolchain capture executes no unverified Xcode binary" \
    test ! -e "$fake_xcode_tool_marker"
expect_failure "existing non-Xcode JSON cannot weaken full-Xcode selection or authenticity" \
    toolchain-existing-json-auth-order /usr/bin/env \
        -u ERYLO_RELEASE_DEVELOPER_DIR \
        DEVELOPER_DIR="$fake_xcode/Contents/Developer" \
        ERYLO_RELEASE_TOOLCHAIN_JSON="$ERYLO_RELEASE_TOOLCHAIN_JSON" \
        ERYLO_RELEASE_TOOLCHAIN_SHA256="$ERYLO_RELEASE_TOOLCHAIN_SHA256" \
        /bin/bash -c 'source Scripts/release/lib.sh; release_require_full_xcode'
check "existing JSON still reaches Apple authentication before selected tools" \
    /usr/bin/grep -Fq \
        "selected Xcode application fails Apple code-signature verification" \
        "$test_root/logs/toolchain-existing-json-auth-order.err"
check "existing JSON path executes no unverified Xcode binary" \
    test ! -e "$fake_xcode_tool_marker"
fake_xcode_assertion_sha="$(printf '%s\n' "$reviewed_toolchain_identity" | \
    /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
expect_failure "final full toolchain assertion reauthenticates Xcode before selected tool execution" \
    toolchain-final-auth-order /usr/bin/env \
        DEVELOPER_DIR="$fake_xcode/Contents/Developer" \
        ERYLO_RELEASE_DEVELOPER_DIR="$fake_xcode/Contents/Developer" \
        ERYLO_RELEASE_TOOLCHAIN_JSON="$reviewed_toolchain_identity" \
        ERYLO_RELEASE_TOOLCHAIN_SHA256="$fake_xcode_assertion_sha" \
        /bin/bash -c 'source Scripts/release/lib.sh; release_assert_toolchain full'
check "final full assertion reports Apple authenticity before any selected-tool result" \
    /usr/bin/grep -Fq \
        "selected Xcode application fails Apple code-signature verification" \
        "$test_root/logs/toolchain-final-auth-order.err"
check "final full assertion executes no unverified Xcode binary" \
    test ! -e "$fake_xcode_tool_marker"
check "toolchain policy and authenticity failures leave no public current set" \
    test ! -e "$repo_root/.release/artifacts/current"

fi
if release_harness_runs build-artifact; then
release_harness_phase build-artifact
if [[ "$release_harness_shard" != all ]]; then
    prepare_hostile_path_fixture
fi
/usr/bin/env PATH="$hostile_path:/usr/bin:/bin:/usr/sbin:/sbin" Scripts/release/build-app.sh
check "closed production PATH and pinned interpreter execute no shadow build tool" \
    test ! -e "$hostile_path_marker"
expect_failure "developer-directory drift fails before any publication" toolchain-developer-dir-drift \
    /usr/bin/env \
        ERYLO_RELEASE_DEVELOPER_DIR="$ERYLO_RELEASE_DEVELOPER_DIR" \
        ERYLO_RELEASE_TOOLCHAIN_JSON="$ERYLO_RELEASE_TOOLCHAIN_JSON" \
        ERYLO_RELEASE_TOOLCHAIN_SHA256="$ERYLO_RELEASE_TOOLCHAIN_SHA256" \
        DEVELOPER_DIR="$test_root/hostile-path/replaced-developer-directory" \
        /bin/bash -c 'source Scripts/release/lib.sh; release_assert_toolchain'
check "toolchain drift gate leaves no public current set" \
    test ! -e "$repo_root/.release/artifacts/current"
check "Sparkle public-key lookup tool is staged but never shipped" \
    test -x "$repo_root/.release/build/arm64/release/Tools/generate_keys"
staged_binary="$repo_root/.release/build/arm64/release/Erylo"
staged_dsym="$repo_root/.release/build/arm64/release/Symbols/Erylo.app.dSYM"
fixture_toolchain_hash="$(/usr/bin/shasum -a 256 \
    "$repo_root/.release/build/arm64/release/Toolchain.json" | /usr/bin/awk '{print $1}')"
check "release build records a canonical selected toolchain identity" \
    test "$fixture_toolchain_hash" = "$ERYLO_RELEASE_TOOLCHAIN_SHA256"
check "Release build generates a separate dSYM" test -f "$staged_dsym/Contents/Resources/DWARF/Erylo"

fi
if release_harness_runs symbol-validation; then
release_harness_phase symbol-validation
if [[ "$release_harness_shard" != all ]]; then
    prepare_compiled_symbol_fixture
fi
check "Release dSYM UUIDs match the executable" \
    Scripts/release/validate-symbols.sh --binary "$staged_binary" --dsym "$staged_dsym"
expect_failure "missing dSYM validation fails closed" missing-dsym \
    Scripts/release/validate-symbols.sh --binary "$staged_binary" --dsym "$test_root/missing/Erylo.app.dSYM"
mismatch_binary="$test_root/mismatch/Erylo"
/bin/mkdir -p "$(dirname "$mismatch_binary")"
if [[ "$release_harness_shard" == all ]]; then
    mismatch_source="$repo_root/.release/build/arm64/release/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
else
    mismatch_source="$fixture_framework/Versions/B/Autoupdate"
fi
/usr/bin/lipo "$mismatch_source" -thin arm64 -output "$mismatch_binary"
/bin/chmod 0755 "$mismatch_binary"
expect_failure "mismatched dSYM UUID validation fails closed" mismatched-dsym \
    Scripts/release/validate-symbols.sh --binary "$mismatch_binary" --dsym "$staged_dsym"

fi
if release_harness_runs private-symbols; then
release_harness_phase private-symbols
if [[ "$release_harness_shard" != all ]]; then
    prepare_compiled_symbol_fixture
fi
symbols_one="$repo_root/.release/private/Erylo-0.1.0-1-arm64.dSYM.zip"
symbols_two="$test_root/symbols-two/Erylo.dSYM.zip"
if [[ "$release_harness_shard" == all ]]; then
    release_harness_start_background symbol-archive-one 720 \
        Scripts/release/archive-symbols.sh \
            --output "$symbols_one" --source-date-epoch 1700000000
else
    release_harness_start_background symbol-archive-one 720 \
        Scripts/release/archive-symbols.sh --binary "$staged_binary" --dsym "$staged_dsym" \
            --output "$symbols_one" --source-date-epoch 1700000000
fi
symbols_one_pid="$release_harness_background_pid"
symbols_one_state="$release_harness_background_state"
if [[ "$release_harness_shard" == all ]]; then
    release_harness_start_background symbol-archive-two 720 \
        Scripts/release/archive-symbols.sh \
            --output "$symbols_two" --source-date-epoch 1700000000
else
    release_harness_start_background symbol-archive-two 720 \
        Scripts/release/archive-symbols.sh --binary "$staged_binary" --dsym "$staged_dsym" \
            --output "$symbols_two" --source-date-epoch 1700000000
fi
symbols_two_pid="$release_harness_background_pid"
symbols_two_state="$release_harness_background_state"
release_harness_require_background_success "$symbols_one_pid" "$symbols_one_state" \
    symbol-archive-one
release_harness_require_background_success "$symbols_two_pid" "$symbols_two_state" \
    symbol-archive-two
symbols_hash_one="$(shasum -a 256 "$symbols_one" | awk '{print $1}')"
symbols_hash_two="$(shasum -a 256 "$symbols_two" | awk '{print $1}')"
check "private dSYM archives are reproducible for identical input and epoch" \
    test "$symbols_hash_one" = "$symbols_hash_two"
symbols_manifest="$repo_root/.release/private/SHA256SUMS"
Scripts/release/checksums.sh --output "$symbols_manifest" "$symbols_one"
check "private symbol checksum manifest includes the retained dSYM archive" \
    /usr/bin/grep -Fq "$symbols_hash_one  Erylo-0.1.0-1-arm64.dSYM.zip" "$symbols_manifest"

fi
if release_harness_runs private-evidence; then
release_harness_phase private-evidence
if [[ "$release_harness_shard" != all ]]; then
    prepare_private_evidence_fixture
fi

private_fixture_commit="$harness_private_commit"
private_fixture_tree="2222222222222222222222222222222222222222"
private_fixture_appcast_hash="$(shasum -a 256 Config/Appcast.example.plist | awk '{print $1}')"
private_fixture_dir="$test_root/private-transaction/first"
release_make_directory "$repo_root" "$private_fixture_dir" >/dev/null
private_fixture_name="Erylo-0.1.0-1-${private_fixture_commit:0:12}-arm64.dSYM.zip"
/bin/cp "$symbols_one" "$private_fixture_dir/$private_fixture_name"
/usr/bin/ruby -rjson -e '
    payload = {
      "archive" => ARGV.fetch(0), "marketingVersion" => "0.1.0", "buildVersion" => "1",
      "sourceCommit" => ARGV.fetch(1), "sourceTree" => ARGV.fetch(2),
      "appcastConfigSHA256" => ARGV.fetch(3), "toolchainSHA256" => ARGV.fetch(4)
    }
    File.write(ARGV.fetch(5), JSON.pretty_generate(payload) + "\n")
  ' "$private_fixture_name" "$private_fixture_commit" "$private_fixture_tree" \
    "$private_fixture_appcast_hash" "$fixture_toolchain_hash" "$private_fixture_dir/ReleaseManifest.json"
Scripts/release/checksums.sh --output "$private_fixture_dir/SHA256SUMS" \
    "$private_fixture_dir/$private_fixture_name" "$private_fixture_dir/ReleaseManifest.json"
check "private dSYM, manifest, and hashes validate as one exact commit set" \
    release_validate_private_artifacts "$repo_root" "$private_fixture_dir" \
        0.1.0 1 "$private_fixture_commit" "$private_fixture_tree" \
        "$private_fixture_appcast_hash" "$fixture_toolchain_hash"
expect_failure "private evidence rejects a different selected toolchain binding" \
    private-toolchain-binding bash -c '
      source Scripts/release/lib.sh
      release_validate_private_artifacts "$1" "$2" 0.1.0 1 "$3" "$4" "$5" "$6"
    ' _ "$repo_root" "$private_fixture_dir" "$private_fixture_commit" "$private_fixture_tree" \
        "$private_fixture_appcast_hash" "$(printf '0%.0s' {1..64})"

for private_race_variant in archive manifest checksum; do
    private_race_source="$test_root/private-transaction/post-check-${private_race_variant}"
    private_race_replacement="$test_root/private-transaction/post-check-${private_race_variant}-replacement"
    /usr/bin/ditto "$private_fixture_dir" "$private_race_source"
    /usr/bin/ditto "$private_fixture_dir" "$private_race_replacement"
    case "$private_race_variant" in
        archive)
            printf 'post-check-private-archive-substitution\n' >> \
                "$private_race_replacement/$private_fixture_name"
            Scripts/release/checksums.sh --output "$private_race_replacement/SHA256SUMS" \
                "$private_race_replacement/$private_fixture_name" \
                "$private_race_replacement/ReleaseManifest.json"
            ;;
        manifest)
            /usr/bin/ruby -rjson -e '
              path = ARGV.fetch(0)
              File.write(path, JSON.generate(JSON.parse(File.read(path))) + "\n")
            ' "$private_race_replacement/ReleaseManifest.json"
            Scripts/release/checksums.sh --output "$private_race_replacement/SHA256SUMS" \
                "$private_race_replacement/$private_fixture_name" \
                "$private_race_replacement/ReleaseManifest.json"
            ;;
        checksum)
            /bin/cp "$private_race_replacement/SHA256SUMS" \
                "$private_race_replacement/SHA256SUMS.replacement"
            ;;
    esac
    private_race_log="$test_root/logs/private-post-check-${private_race_variant}.err"
    release_harness_start_background "private-post-check-${private_race_variant}" \
        "$release_harness_background_timeout" /usr/bin/env \
        ERYLO_RELEASE_FS_TESTING=1 \
        ERYLO_RELEASE_FS_TEST_PAUSE_STAGE=after-private-publication-sync \
        ERYLO_RELEASE_FS_TEST_DELAY=5 \
        /usr/bin/ruby Scripts/release/fs-helper.rb publish-private-set "$repo_root" \
            "$private_race_source" 0.1.0 1 "$private_fixture_commit" \
            "$private_fixture_tree" "$private_fixture_appcast_hash" "$fixture_toolchain_hash" \
        2>"$private_race_log"
    private_race_pid="$release_harness_background_pid"
    private_race_state="$release_harness_background_state"
    check "private publication reaches the post-check $private_race_variant race boundary" \
        wait_for_fs_test_pause "$private_race_log" "$private_race_pid" \
            "$private_race_state" "private-post-check-${private_race_variant}"
    private_race_destination="$repo_root/.release/private/$private_fixture_commit"
    case "$private_race_variant" in
        archive)
            /bin/mv "$private_race_replacement/$private_fixture_name" \
                "$private_race_destination/$private_fixture_name"
            /bin/mv "$private_race_replacement/SHA256SUMS" \
                "$private_race_destination/SHA256SUMS"
            ;;
        manifest)
            /bin/mv "$private_race_replacement/ReleaseManifest.json" \
                "$private_race_destination/ReleaseManifest.json"
            /bin/mv "$private_race_replacement/SHA256SUMS" \
                "$private_race_destination/SHA256SUMS"
            ;;
        checksum)
            /bin/mv "$private_race_replacement/SHA256SUMS.replacement" \
                "$private_race_destination/SHA256SUMS"
            ;;
    esac
    expect_background_failure \
        "post-check private $private_race_variant substitution is rejected and rolled back" \
        "$private_race_pid" "$private_race_state"
    check "failed private $private_race_variant substitution publishes no commit directory" \
        test ! -e "$private_race_destination"
    release_remove_path "$repo_root" "$private_race_source"
    release_remove_path "$repo_root" "$private_race_replacement"
done

private_rollback_source="$test_root/private-transaction/planted-source-rollback"
/usr/bin/ditto "$private_fixture_dir" "$private_rollback_source"
private_rollback_log="$test_root/logs/private-planted-source-rollback.err"
release_harness_start_background private-planted-source-rollback \
    "$release_harness_background_timeout" /usr/bin/env \
    ERYLO_RELEASE_FS_TESTING=1 \
    ERYLO_RELEASE_FS_TEST_PAUSE_STAGE=after-private-publication-rename \
    ERYLO_RELEASE_FS_TEST_DELAY=5 \
    /usr/bin/ruby Scripts/release/fs-helper.rb publish-private-set "$repo_root" \
        "$private_rollback_source" 0.1.0 1 "$private_fixture_commit" \
        "$private_fixture_tree" "$private_fixture_appcast_hash" "$fixture_toolchain_hash" \
    2>"$private_rollback_log"
private_rollback_pid="$release_harness_background_pid"
private_rollback_state="$release_harness_background_state"
check "private publication reaches the planted source-leaf rollback boundary" \
    wait_for_fs_test_pause "$private_rollback_log" "$private_rollback_pid" \
        "$private_rollback_state" private-planted-source-rollback
check "private publication moved the candidate out of the caller-controlled source leaf" \
    test ! -e "$private_rollback_source"
/bin/mkdir -p "$private_rollback_source"
printf 'private-caller-leaf-sentinel\n' > "$private_rollback_source/sentinel"
private_rollback_destination="$repo_root/.release/private/$private_fixture_commit"
printf 'invalid-private-checksum\n' > "$private_rollback_destination/SHA256SUMS"
expect_background_failure \
    "private rollback ignores a planted nonempty caller source leaf" \
    "$private_rollback_pid" "$private_rollback_state"
check "failed private rollback leaves no invalid commit evidence published" \
    test ! -e "$private_rollback_destination"
check "private rollback does not remove or consume the planted caller directory" \
    /usr/bin/grep -Fxq private-caller-leaf-sentinel "$private_rollback_source/sentinel"
check "private rollback leaves no internal ambiguous transaction" bash -c '
    [[ -z "$(find "$1/.release/tmp" -maxdepth 1 -name "private-rollback.*" -print -quit)" ]]
  ' _ "$repo_root"
release_remove_path "$repo_root" "$private_rollback_source"

release_publish_private_artifacts "$repo_root" "$private_fixture_dir" \
    0.1.0 1 "$private_fixture_commit" "$private_fixture_tree" \
    "$private_fixture_appcast_hash" "$fixture_toolchain_hash"
private_published_dir="$repo_root/.release/private/$private_fixture_commit"
private_published_hash="$(shasum -a 256 "$private_published_dir/SHA256SUMS" | awk '{print $1}')"
check "private evidence publishes only in an immutable commit-qualified directory" \
    test -f "$private_published_dir/$private_fixture_name"
check "private evidence remains 0600 and its directory remains 0700" bash -c '
    [[ "$(stat -f "%Lp" "$1")" == 700 ]]
    find "$1" -type f -exec stat -f "%Lp" {} \; | grep -vFx 600 | grep -q . && exit 1
    exit 0
  ' _ "$private_published_dir"

private_resume_dir="$test_root/private-transaction/resume-identical"
/usr/bin/ditto "$private_published_dir" "$private_resume_dir"
release_publish_private_artifacts "$repo_root" "$private_resume_dir" \
    0.1.0 1 "$private_fixture_commit" "$private_fixture_tree" \
    "$private_fixture_appcast_hash" "$fixture_toolchain_hash"
check "identical private release resume reuses the immutable set without a duplicate" \
    test ! -e "$private_resume_dir"

private_conflict_dir="$test_root/private-transaction/conflicting-resume"
/usr/bin/ditto "$private_published_dir" "$private_conflict_dir"
/bin/chmod 0600 "$private_conflict_dir/$private_fixture_name"
printf 'conflicting-private-bytes\n' >> "$private_conflict_dir/$private_fixture_name"
Scripts/release/checksums.sh --output "$private_conflict_dir/SHA256SUMS" \
    "$private_conflict_dir/$private_fixture_name" "$private_conflict_dir/ReleaseManifest.json"
expect_failure "conflicting same-commit private evidence cannot replace the immutable pair" \
    private-conflicting-resume bash -c '
        source Scripts/release/lib.sh
        release_publish_private_artifacts "$1" "$2" 0.1.0 1 "$3" "$4" "$5" "$6"
      ' _ "$repo_root" "$private_conflict_dir" "$private_fixture_commit" \
        "$private_fixture_tree" "$private_fixture_appcast_hash" "$fixture_toolchain_hash"
check "failed private resume preserves the prior complete checksum pair" \
    test "$(shasum -a 256 "$private_published_dir/SHA256SUMS" | awk '{print $1}')" = "$private_published_hash"

private_hardlink_alias="$external_test_root/private-symbol-hardlink.zip"
/bin/ln "$private_conflict_dir/$private_fixture_name" "$private_hardlink_alias"
expect_failure "private set validation rejects an external hardlink alias" private-hardlink-alias \
    bash -c '
        source Scripts/release/lib.sh
        release_validate_private_artifacts "$1" "$2" 0.1.0 1 "$3" "$4" "$5" "$6"
      ' _ "$repo_root" "$private_conflict_dir" "$private_fixture_commit" \
        "$private_fixture_tree" "$private_fixture_appcast_hash" "$fixture_toolchain_hash"
/bin/rm -f -- "$private_hardlink_alias"
release_remove_path "$repo_root" "$private_conflict_dir"

fi
if release_harness_runs bundle-default; then
release_harness_phase bundle-default
if [[ "$release_harness_shard" != all ]]; then
    prepare_compiled_release_fixture
fi
default_app="$test_root/default/Erylo.app"
if [[ "$release_harness_shard" == all ]]; then
    Scripts/release/assemble-app.sh --output "$default_app"
else
    assemble_compiled_fixture --output "$default_app"
fi
release_harness_queue_background_success \
    "default bundle passes deterministic validation" default-bundle-valid 720 \
    Scripts/release/validate-app.sh "$default_app"
release_harness_queue_background_failure \
    "default bundle must not pass the production updater gate" missing-updater 720 \
    Scripts/release/validate-app.sh --require-updater "$default_app"

plist="$default_app/Contents/Info.plist"
check "bundle identifier matches release metadata" test "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" = "com.erylo.Erylo"
check "bundle is an agent application" test "$(plutil -extract LSUIElement raw -o - "$plist")" = "true"
apple_events_usage="Erylo reads current playback and now-playing details when you refresh media, and sends playback commands only when you use media controls."
check "Apple Events usage copy discloses explicit reads and commands without background monitoring" \
    test "$(plutil -extract NSAppleEventsUsageDescription raw -o - "$plist")" = "$apple_events_usage"
tampered_apple_events_app="$test_root/tampered-apple-events-copy/Erylo.app"
/usr/bin/ditto "$default_app" "$tampered_apple_events_app"
/usr/bin/plutil -replace NSAppleEventsUsageDescription -string \
    "Erylo sends playback commands to supported media apps only when you use media controls." \
    "$tampered_apple_events_app/Contents/Info.plist"
release_harness_queue_background_failure \
    "bundle validation rejects incomplete Apple Events usage disclosure" \
    incomplete-apple-events-copy 720 Scripts/release/validate-app.sh "$tampered_apple_events_app"
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
check "bundle toolchain provenance is bound by Info.plist" \
    test "$(/usr/bin/shasum -a 256 "$default_app/Contents/Resources/Toolchain.json" | /usr/bin/awk '{print $1}')" = \
        "$(/usr/bin/plutil -extract EryloToolchainSHA256 raw -o - "$default_app/Contents/Info.plist")"
missing_toolchain_app="$test_root/missing-toolchain/Erylo.app"
/usr/bin/ditto "$default_app" "$missing_toolchain_app"
/bin/rm -f -- "$missing_toolchain_app/Contents/Resources/Toolchain.json"
release_harness_queue_background_failure \
    "bundle validation rejects missing toolchain provenance" missing-toolchain-provenance 720 \
    Scripts/release/validate-app.sh "$missing_toolchain_app"
tampered_toolchain_app="$test_root/tampered-toolchain/Erylo.app"
/usr/bin/ditto "$default_app" "$tampered_toolchain_app"
/usr/bin/ruby -rjson -e '
    path = ARGV.fetch(0)
    payload = JSON.parse(File.read(path))
    payload["xcodeBuildVersion"] = "transient-replacement"
    File.write(path, JSON.generate(payload) + "\n")
  ' "$tampered_toolchain_app/Contents/Resources/Toolchain.json"
/usr/bin/plutil -replace EryloToolchainSHA256 -string \
    "$(/usr/bin/shasum -a 256 "$tampered_toolchain_app/Contents/Resources/Toolchain.json" | /usr/bin/awk '{print $1}')" \
    "$tampered_toolchain_app/Contents/Info.plist"
release_harness_queue_background_failure \
    "bundle validation rejects a self-consistently rewritten toolchain claim" \
    tampered-toolchain-provenance 720 Scripts/release/validate-app.sh "$tampered_toolchain_app"
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
release_harness_queue_background_failure \
    "bundle validation rejects a missing third-party notice" missing-third-party-notice 720 \
    Scripts/release/validate-app.sh "$missing_notice_app"
tampered_notice_app="$test_root/tampered-notice/Erylo.app"
/usr/bin/ditto "$default_app" "$tampered_notice_app"
printf '\nmodified\n' >> "$tampered_notice_app/Contents/Resources/ThirdPartyNotices.txt"
release_harness_queue_background_failure \
    "bundle validation rejects a modified third-party notice" tampered-third-party-notice 720 \
    Scripts/release/validate-app.sh "$tampered_notice_app"
release_harness_drain_background_assertions

fi
if release_harness_runs bundle-ticket; then
release_harness_phase bundle-ticket
if [[ "$release_harness_shard" != all ]]; then
    prepare_default_bundle_fixture
fi
ticket_app="$test_root/post-staple/Erylo.app"
/usr/bin/ditto "$default_app" "$ticket_app"
printf 'structural ticket fixture; not notarization evidence\n' > "$ticket_app/Contents/CodeResources"
release_harness_queue_background_failure \
    "pre-staple bundle validation rejects Contents/CodeResources" pre-staple-ticket 720 \
    Scripts/release/validate-app.sh "$ticket_app"
release_harness_queue_background_success \
    "post-staple structure permits exactly one regular ticket file" post-staple-ticket 720 \
    Scripts/release/validate-app.sh --post-staple "$ticket_app"
symlink_ticket_app="$test_root/symlink-ticket/Erylo.app"
/usr/bin/ditto "$default_app" "$symlink_ticket_app"
/bin/ln -s PkgInfo "$symlink_ticket_app/Contents/CodeResources"
release_harness_queue_background_failure \
    "post-staple validation rejects a symlink ticket" symlink-ticket 720 \
    Scripts/release/validate-app.sh --post-staple "$symlink_ticket_app"
directory_ticket_app="$test_root/directory-ticket/Erylo.app"
/usr/bin/ditto "$default_app" "$directory_ticket_app"
/bin/mkdir "$directory_ticket_app/Contents/CodeResources"
release_harness_queue_background_failure \
    "post-staple validation rejects a directory ticket" directory-ticket 720 \
    Scripts/release/validate-app.sh --post-staple "$directory_ticket_app"
extra_ticket_app="$test_root/extra-ticket/Erylo.app"
/usr/bin/ditto "$ticket_app" "$extra_ticket_app"
printf 'unexpected\n' > "$extra_ticket_app/Contents/Unexpected.txt"
release_harness_queue_background_failure \
    "post-staple validation still rejects extra Contents entries" post-staple-extra 720 \
    Scripts/release/validate-app.sh --post-staple "$extra_ticket_app"
release_harness_drain_background_assertions

fi
if release_harness_runs updater-vectors; then
release_harness_phase updater-vectors
if [[ "$release_harness_shard" != all ]]; then
    prepare_compiled_release_fixture
fi
updater_assembler=(Scripts/release/assemble-app.sh)
if [[ "$release_harness_shard" != all ]]; then
    updater_assembler+=(
        --binary "$fixture_binary"
        --framework "$fixture_framework"
        --toolchain "$fixture_toolchain"
    )
fi
test_appcast="$test_root/appcast.plist"
/bin/cp Config/Appcast.example.plist "$test_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test/appcast.xml" "$test_appcast"
test_public_key="$(/usr/bin/ruby -rbase64 -e 'print Base64.strict_encode64("x" * 32)')"
/usr/bin/plutil -replace SUPublicEDKey -string "$test_public_key" "$test_appcast"
updater_app="$test_root/updater/Erylo.app"
"${updater_assembler[@]}" --appcast-config "$test_appcast" --output "$updater_app"
release_harness_queue_background_success \
    "explicit signed appcast metadata passes the production gate" updater-valid 720 \
    Scripts/release/validate-app.sh --require-updater "$updater_app"
for sparkle_defaults_variant in custom-domain persisted-profile string-automatic number-automatic; do
    defaults_bundle="$test_root/sparkle-defaults-${sparkle_defaults_variant}/Erylo.app"
    /usr/bin/ditto "$updater_app" "$defaults_bundle"
    case "$sparkle_defaults_variant" in
        custom-domain)
            /usr/bin/plutil -insert SUDefaultsDomain -string app.erylo.unreviewed \
                "$defaults_bundle/Contents/Info.plist"
            ;;
        persisted-profile)
            /usr/bin/plutil -insert SUSendProfileInfo -bool true "$defaults_bundle/Contents/Info.plist"
            ;;
        string-automatic)
            /usr/bin/plutil -replace SUEnableAutomaticChecks -string YES "$defaults_bundle/Contents/Info.plist"
            ;;
        number-automatic)
            /usr/bin/plutil -replace SUAutomaticallyUpdate -integer 1 "$defaults_bundle/Contents/Info.plist"
            ;;
    esac
    release_harness_queue_background_failure \
        "bundle rejects unsafe effective Sparkle preference metadata: $sparkle_defaults_variant" \
        "sparkle-defaults-${sparkle_defaults_variant}" \
        720 \
        Scripts/release/validate-app.sh --require-updater "$defaults_bundle"
done
release_harness_queue_background_failure_with_stderr \
    "tracked example appcast placeholders are rejected" placeholder-appcast 720 \
    "appcast feed URL is invalid" "${updater_assembler[@]}" \
    --appcast-config Config/Appcast.example.plist --output "$test_root/rejected/Erylo.app"

credential_appcast="$test_root/credential-appcast.plist"
/bin/cp "$test_appcast" "$credential_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://user:password@updates.erylo.test/appcast.xml" "$credential_appcast"
release_harness_queue_background_failure_with_stderr \
    "appcast URL credentials are rejected before Info.plist assembly" credential-appcast 720 \
    "appcast feed URL is invalid" "${updater_assembler[@]}" \
    --appcast-config "$credential_appcast" --output "$test_root/credential/Erylo.app"
credential_bundle="$test_root/credential-bundle/Erylo.app"
/usr/bin/ditto "$updater_app" "$credential_bundle"
/usr/bin/plutil -replace SUFeedURL -string "https://user:password@updates.erylo.test/appcast.xml" \
    "$credential_bundle/Contents/Info.plist"
release_harness_queue_background_failure \
    "bundle validation rejects injected appcast URL credentials" credential-bundle 720 \
    Scripts/release/validate-app.sh --require-updater "$credential_bundle"

empty_userinfo_appcast="$test_root/empty-userinfo-appcast.plist"
/bin/cp "$test_appcast" "$empty_userinfo_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://@updates.erylo.test/appcast.xml" "$empty_userinfo_appcast"
release_harness_queue_background_failure_with_stderr \
    "empty appcast URL userinfo is rejected before Info.plist assembly" empty-userinfo-appcast 720 \
    "appcast feed URL is invalid" "${updater_assembler[@]}" \
    --appcast-config "$empty_userinfo_appcast" --output "$test_root/empty-userinfo/Erylo.app"
empty_userinfo_bundle="$test_root/empty-userinfo-bundle/Erylo.app"
/usr/bin/ditto "$updater_app" "$empty_userinfo_bundle"
/usr/bin/plutil -replace SUFeedURL -string "https://@updates.erylo.test/appcast.xml" \
    "$empty_userinfo_bundle/Contents/Info.plist"
release_harness_queue_background_failure \
    "bundle validation rejects injected empty appcast userinfo" empty-userinfo-bundle 720 \
    Scripts/release/validate-app.sh --require-updater "$empty_userinfo_bundle"

default_port_appcast="$test_root/default-port-appcast.plist"
/bin/cp "$test_appcast" "$default_port_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test:443/appcast.xml" "$default_port_appcast"
release_harness_queue_background_failure_with_stderr \
    "explicit default appcast ports are rejected" default-port-appcast 720 \
    "appcast feed URL is invalid" "${updater_assembler[@]}" \
    --appcast-config "$default_port_appcast" --output "$test_root/default-port/Erylo.app"
default_port_bundle="$test_root/default-port-bundle/Erylo.app"
/usr/bin/ditto "$updater_app" "$default_port_bundle"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test:443/appcast.xml" \
    "$default_port_bundle/Contents/Info.plist"
release_harness_queue_background_failure \
    "bundle validation rejects an injected explicit default port" default-port-bundle 720 \
    Scripts/release/validate-app.sh --require-updater "$default_port_bundle"

custom_port_appcast="$test_root/custom-port-appcast.plist"
/bin/cp "$test_appcast" "$custom_port_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test:8443/appcast.xml" "$custom_port_appcast"
release_harness_queue_background_failure_with_stderr \
    "nondefault appcast ports are rejected" custom-port-appcast 720 \
    "appcast feed URL is invalid" "${updater_assembler[@]}" \
    --appcast-config "$custom_port_appcast" --output "$test_root/custom-port/Erylo.app"

uppercase_scheme_appcast="$test_root/uppercase-scheme-appcast.plist"
/bin/cp "$test_appcast" "$uppercase_scheme_appcast"
/usr/bin/plutil -replace SUFeedURL -string "HTTPS://updates.erylo.test/appcast.xml" "$uppercase_scheme_appcast"
release_harness_queue_background_failure_with_stderr \
    "noncanonical appcast scheme spelling is rejected" uppercase-scheme-appcast 720 \
    "appcast feed URL is invalid" "${updater_assembler[@]}" \
    --appcast-config "$uppercase_scheme_appcast" --output "$test_root/uppercase-scheme/Erylo.app"

query_appcast="$test_root/query-appcast.plist"
/bin/cp "$test_appcast" "$query_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test/appcast.xml?channel=stable" "$query_appcast"
release_harness_queue_background_failure_with_stderr \
    "noncanonical appcast URL queries are rejected" query-appcast 720 \
    "appcast feed URL is invalid" "${updater_assembler[@]}" \
    --appcast-config "$query_appcast" --output "$test_root/query/Erylo.app"
query_bundle="$test_root/query-bundle/Erylo.app"
/usr/bin/ditto "$updater_app" "$query_bundle"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test/appcast.xml?channel=stable" \
    "$query_bundle/Contents/Info.plist"
release_harness_queue_background_failure \
    "bundle validation rejects injected appcast URL queries" query-bundle 720 \
    Scripts/release/validate-app.sh --require-updater "$query_bundle"

fragment_appcast="$test_root/fragment-appcast.plist"
/bin/cp "$test_appcast" "$fragment_appcast"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test/appcast.xml#latest" "$fragment_appcast"
release_harness_queue_background_failure_with_stderr \
    "noncanonical appcast URL fragments are rejected" fragment-appcast 720 \
    "appcast feed URL is invalid" "${updater_assembler[@]}" \
    --appcast-config "$fragment_appcast" --output "$test_root/fragment/Erylo.app"
fragment_bundle="$test_root/fragment-bundle/Erylo.app"
/usr/bin/ditto "$updater_app" "$fragment_bundle"
/usr/bin/plutil -replace SUFeedURL -string "https://updates.erylo.test/appcast.xml#latest" \
    "$fragment_bundle/Contents/Info.plist"
release_harness_queue_background_failure \
    "bundle validation rejects injected appcast URL fragments" fragment-bundle 720 \
    Scripts/release/validate-app.sh --require-updater "$fragment_bundle"
release_harness_drain_background_assertions

fi
if release_harness_runs output-boundaries; then
release_harness_phase output-boundaries
bad_entitlements="$test_root/bad.entitlements"
/bin/cp Resources/App/Erylo.entitlements "$bad_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.network.server bool true' "$bad_entitlements"
expect_failure "entitlement denylist rejects network server capability" bad-entitlements \
    Scripts/release/validate-entitlements.sh "$bad_entitlements"
check "reviewed entitlements remain minimal" Scripts/release/validate-entitlements.sh Resources/App/Erylo.entitlements

secret_app="$test_root/secret/Erylo.app"
/bin/mkdir -p "$secret_app/Contents/Resources"
/bin/cp Resources/App/Info.plist.in "$secret_app/Contents/Info.plist"
printf '%s%s\n' '-----BEGIN TEST ' 'PRIVATE KEY-----' > "$secret_app/Contents/Resources/secret-fixture.txt"
expect_failure_with_stderr "bundle validation rejects private-key markers" private-key-marker \
    "placeholder or secret-marker validation failed" \
    Scripts/release/validate-app.sh "$secret_app"

escape_path="$repo_root/release-harness-escape/Erylo.app"
expect_failure_with_stderr "assembler rejects path traversal outside release staging" assemble-traversal \
    "unsafe release output path: .release/../release-harness-escape/Erylo.app" \
    Scripts/release/assemble-app.sh --output ".release/../release-harness-escape/Erylo.app"
check "path traversal attempt creates no external output" test ! -e "$escape_path"
expect_failure_with_stderr "archiver rejects output traversal" archive-traversal \
    "unsafe release output path: .release/../release-harness-escape.zip" \
    Scripts/release/archive-app.sh --app "$secret_app" --output ".release/../release-harness-escape.zip"

/bin/mkdir -p "$test_root/real-parent"
/bin/ln -s "$test_root/real-parent" "$test_root/symlink-parent"
expect_failure_with_stderr "release output refuses symlink parents" symlink-parent \
    "unsafe release output path: $test_root/symlink-parent/Erylo.app" \
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

fi
if release_harness_runs archive-core; then
release_harness_phase archive-core
if [[ "$release_harness_shard" != all ]]; then
    prepare_default_bundle_fixture
    prepare_appcast_fixture
fi
archive_one="$test_root/archive-one/Erylo.zip"
archive_two="$test_root/archive-two/Erylo.zip"
release_harness_start_background app-archive-one 720 \
    Scripts/release/archive-app.sh --app "$default_app" --output "$archive_one" \
    --source-date-epoch 1700000000
archive_one_pid="$release_harness_background_pid"
archive_one_state="$release_harness_background_state"
release_harness_start_background app-archive-two 720 \
    Scripts/release/archive-app.sh --app "$default_app" --output "$archive_two" \
    --source-date-epoch 1700000000
archive_two_pid="$release_harness_background_pid"
archive_two_state="$release_harness_background_state"
release_harness_require_background_success "$archive_one_pid" "$archive_one_state" app-archive-one
release_harness_require_background_success "$archive_two_pid" "$archive_two_state" app-archive-two
hash_one="$(shasum -a 256 "$archive_one" | awk '{print $1}')"
hash_two="$(shasum -a 256 "$archive_two" | awk '{print $1}')"
check "archives are reproducible for identical input and epoch" test "$hash_one" = "$hash_two"
check "dSYM is not embedded in the public update archive" bash -c '
    ! /usr/bin/zipinfo -1 "$1" | /usr/bin/grep -Fq ".dSYM"
  ' _ "$archive_one"

archive_hardlink_alias="$external_test_root/archive-hardlink-alias.zip"
/bin/ln "$archive_one" "$archive_hardlink_alias"
expect_failure "checksum generation rejects a staged input with an external hardlink alias" \
    hardlinked-checksum-input Scripts/release/checksums.sh \
        --output "$test_root/hardlink-checksum/SHA256SUMS" "$archive_one"
expect_failure "update signing rejects a staged archive with an external hardlink alias before credentials" \
    hardlinked-signing-input Scripts/release/sign-update.sh \
        --archive "$archive_one" --appcast-config "$test_appcast"
check "hardlink rejection leaves the aliased archive bytes unchanged" \
    test "$(shasum -a 256 "$archive_hardlink_alias" | awk '{print $1}')" = "$hash_one"
/bin/rm -f -- "$archive_hardlink_alias"

hardlink_publish_source="$test_root/hardlink-publication/source.txt"
hardlink_publish_destination="$test_root/hardlink-publication/destination.txt"
release_make_directory "$repo_root" "$(dirname "$hardlink_publish_source")" >/dev/null
printf 'hardlink-publication-sentinel\n' > "$hardlink_publish_source"
hardlink_publish_alias="$external_test_root/publication-hardlink-alias.txt"
/bin/ln "$hardlink_publish_source" "$hardlink_publish_alias"
expect_failure "anchored file publication rejects a hardlinked source inode" \
    hardlinked-publication-source bash -c '
        source Scripts/release/lib.sh
        release_publish_file "$1" "$2" "$3"
      ' _ "$repo_root" "$hardlink_publish_source" "$hardlink_publish_destination"
check "hardlinked publication failure preserves the external alias" \
    /usr/bin/grep -Fxq hardlink-publication-sentinel "$hardlink_publish_alias"
/bin/rm -f -- "$hardlink_publish_alias"

non_xcode_developer_dir="$test_root/fake-command-line-tools"
/bin/mkdir -p "$non_xcode_developer_dir"

checksum_file="$test_root/checksums/SHA256SUMS"
Scripts/release/checksums.sh --output "$checksum_file" "$archive_one"
check "checksum manifest records the archive digest" /usr/bin/grep -Fq "$hash_one  Erylo.zip" "$checksum_file"
expect_failure "archive creation rejects an app missing third-party notices" archive-missing-notice \
    Scripts/release/archive-app.sh --app "$missing_notice_app" --output "$test_root/missing-notice.zip"

fi
if release_harness_runs feed-vectors; then
release_harness_phase feed-vectors
if [[ "$release_harness_shard" != all ]]; then
    prepare_update_vector_fixtures
fi
feed_assembler=(Scripts/release/assemble-app.sh)
if [[ "$release_harness_shard" != all ]]; then
    feed_assembler+=(
        --binary "$fixture_binary"
        --framework "$fixture_framework"
        --toolchain "$fixture_toolchain"
    )
fi
feed_vector_index=0
feed_ready_indices=()
feed_ready_names=()
feed_ready_apps=()
feed_invalid_indices=()
feed_invalid_names=()
while IFS=$'\t' read -r feed_expected feed_name feed_url; do
    [[ -n "$feed_expected" && "$feed_expected" != \#* ]] || continue
    feed_vector_index=$((feed_vector_index + 1))
    vector_config="$test_root/feed-vectors/${feed_vector_index}.plist"
    /bin/mkdir -p "$(dirname "$vector_config")"
    /bin/cp "$test_appcast" "$vector_config"
    /usr/bin/plutil -replace SUFeedURL -string "$feed_url" "$vector_config"
    if [[ "$feed_expected" == "ready" ]]; then
        check "shared shell feed vector $feed_name is accepted" bash -c '
            source Scripts/release/lib.sh
            release_validate_feed_url "$1"
          ' _ "$feed_url"
        if [[ "$feed_name" == canonical ]]; then
            [[ "$feed_url" == "$(release_plist_value "$test_appcast" SUFeedURL)" ]] \
                || release_die "canonical feed vector differs from the shared updater fixture"
            vector_app="$updater_app"
            check "assembler accepts shared feed vector $feed_name" \
                "${feed_assembler[@]}" --appcast-config "$vector_config" --output "$vector_app"
        else
            vector_app="$test_root/feed-vectors/${feed_vector_index}/Erylo.app"
            release_harness_queue_background_success \
                "assembler accepts shared feed vector $feed_name" \
                "feed-vector-assemble-${feed_vector_index}" 720 \
                "${feed_assembler[@]}" --appcast-config "$vector_config" --output "$vector_app"
        fi
        feed_ready_indices+=("$feed_vector_index")
        feed_ready_names+=("$feed_name")
        feed_ready_apps+=("$vector_app")
    else
        expect_failure "shared shell feed vector $feed_name is rejected" \
            "feed-vector-shell-${feed_vector_index}" bash -c '
                source Scripts/release/lib.sh
                release_validate_feed_url "$1"
              ' _ "$feed_url"
        release_harness_queue_background_failure_with_stderr \
            "assembler rejects shared feed vector $feed_name" \
            "feed-vector-assemble-${feed_vector_index}" 720 "appcast feed URL is invalid" \
                "${feed_assembler[@]}" \
                --appcast-config "$vector_config" \
                --output "$test_root/feed-vectors/${feed_vector_index}/assembled/Erylo.app"
        vector_bundle="$test_root/feed-vectors/${feed_vector_index}/injected/Erylo.app"
        [[ -d "$updater_app" ]] || release_die "canonical feed vector did not construct the updater fixture"
        /usr/bin/ditto "$updater_app" "$vector_bundle"
        /usr/bin/plutil -replace SUFeedURL -string "$feed_url" "$vector_bundle/Contents/Info.plist"
        release_harness_queue_background_failure_with_stderr \
            "bundle validator rejects shared feed vector $feed_name" \
            "feed-vector-bundle-${feed_vector_index}" 720 "appcast feed URL is invalid" \
                Scripts/release/validate-app.sh \
                --require-updater "$vector_bundle"
        release_harness_queue_background_failure_with_stderr \
            "update signing rejects shared feed vector $feed_name at the URL gate" \
            "feed-vector-sign-${feed_vector_index}" 720 "appcast feed URL is invalid" \
                Scripts/release/sign-update.sh \
                --archive "$archive_one" --appcast-config "$vector_config"
        feed_invalid_indices+=("$feed_vector_index")
        feed_invalid_names+=("$feed_name")
    fi
done < Tests/Fixtures/ReleaseFeedURLVectors.tsv
release_harness_drain_background_assertions
for ((feed_invalid_offset = 0; feed_invalid_offset < ${#feed_invalid_indices[@]}; feed_invalid_offset++)); do
    feed_vector_index="${feed_invalid_indices[$feed_invalid_offset]}"
    feed_name="${feed_invalid_names[$feed_invalid_offset]}"
    check "invalid signing vector $feed_name reports the canonical URL gate" \
        /usr/bin/grep -Fq "appcast feed URL is invalid" \
            "$test_root/logs/feed-vector-sign-${feed_vector_index}.err"
done
for ((feed_ready_offset = 0; feed_ready_offset < ${#feed_ready_indices[@]}; feed_ready_offset++)); do
    feed_vector_index="${feed_ready_indices[$feed_ready_offset]}"
    feed_name="${feed_ready_names[$feed_ready_offset]}"
    vector_app="${feed_ready_apps[$feed_ready_offset]}"
    vector_config="$test_root/feed-vectors/${feed_vector_index}.plist"
    release_harness_queue_background_success \
        "bundle validator accepts shared feed vector $feed_name" \
        "feed-vector-bundle-${feed_vector_index}" 720 \
        Scripts/release/validate-app.sh --require-updater "$vector_app"
    release_harness_queue_background_failure \
        "update signing accepts $feed_name through the URL gate then fails closed on Xcode" \
        "feed-vector-sign-${feed_vector_index}" 720 /usr/bin/env \
            DEVELOPER_DIR="$non_xcode_developer_dir" Scripts/release/sign-update.sh \
            --archive "$archive_one" --appcast-config "$vector_config"
done
release_harness_drain_background_assertions
for ((feed_ready_offset = 0; feed_ready_offset < ${#feed_ready_indices[@]}; feed_ready_offset++)); do
    feed_vector_index="${feed_ready_indices[$feed_ready_offset]}"
    feed_name="${feed_ready_names[$feed_ready_offset]}"
    check "valid signing vector $feed_name reaches the full-Xcode gate" \
        /usr/bin/grep -Fq "full Xcode is required" \
            "$test_root/logs/feed-vector-sign-${feed_vector_index}.err"
done

fi
if release_harness_runs key-vectors; then
release_harness_phase key-vectors
if [[ "$release_harness_shard" != all ]]; then
    prepare_update_vector_fixtures
fi
key_assembler=(Scripts/release/assemble-app.sh)
if [[ "$release_harness_shard" != all ]]; then
    key_assembler+=(
        --binary "$fixture_binary"
        --framework "$fixture_framework"
        --toolchain "$fixture_toolchain"
    )
fi
key_vector_index=0
key_ready_indices=()
key_ready_names=()
key_ready_apps=()
key_invalid_indices=()
key_invalid_names=()
while IFS=$'\t' read -r key_expected key_name public_key; do
    [[ -n "$key_expected" && "$key_expected" != \#* ]] || continue
    key_vector_index=$((key_vector_index + 1))
    vector_config="$test_root/key-vectors/${key_vector_index}.plist"
    /bin/mkdir -p "$(dirname "$vector_config")"
    /bin/cp "$test_appcast" "$vector_config"
    /usr/bin/plutil -replace SUPublicEDKey -string "$public_key" "$vector_config"
    if [[ "$key_expected" == "ready" ]]; then
        check "shared shell public-key vector $key_name is accepted" bash -c '
            source Scripts/release/lib.sh
            release_validate_public_key "$1"
          ' _ "$public_key"
        if [[ "$key_name" == canonical-32-bytes ]]; then
            [[ "$public_key" == "$(release_plist_value "$test_appcast" SUPublicEDKey)" ]] \
                || release_die "canonical public-key vector differs from the shared updater fixture"
            vector_app="$updater_app"
            check "assembler accepts shared public-key vector $key_name" \
                "${key_assembler[@]}" --appcast-config "$vector_config" --output "$vector_app"
        else
            vector_app="$test_root/key-vectors/${key_vector_index}/Erylo.app"
            release_harness_queue_background_success \
                "assembler accepts shared public-key vector $key_name" \
                "key-vector-assemble-${key_vector_index}" 720 \
                "${key_assembler[@]}" --appcast-config "$vector_config" --output "$vector_app"
        fi
        key_ready_indices+=("$key_vector_index")
        key_ready_names+=("$key_name")
        key_ready_apps+=("$vector_app")
    else
        expect_failure "shared shell public-key vector $key_name is rejected" \
            "key-vector-shell-${key_vector_index}" bash -c '
                source Scripts/release/lib.sh
                release_validate_public_key "$1"
              ' _ "$public_key"
        release_harness_queue_background_failure_with_stderr \
            "assembler rejects shared public-key vector $key_name" \
            "key-vector-assemble-${key_vector_index}" 720 "appcast public key is invalid" \
                "${key_assembler[@]}" \
                --appcast-config "$vector_config" \
                --output "$test_root/key-vectors/${key_vector_index}/assembled/Erylo.app"
        vector_bundle="$test_root/key-vectors/${key_vector_index}/injected/Erylo.app"
        [[ -d "$updater_app" ]] || release_die "canonical public-key vector did not construct the updater fixture"
        /usr/bin/ditto "$updater_app" "$vector_bundle"
        /usr/bin/plutil -replace SUPublicEDKey -string "$public_key" "$vector_bundle/Contents/Info.plist"
        release_harness_queue_background_failure_with_stderr \
            "bundle validator rejects shared public-key vector $key_name" \
            "key-vector-bundle-${key_vector_index}" 720 "appcast public key is invalid" \
                Scripts/release/validate-app.sh \
                --require-updater "$vector_bundle"
        release_harness_queue_background_failure_with_stderr \
            "update signing rejects shared public-key vector $key_name at the key gate" \
            "key-vector-sign-${key_vector_index}" 720 "appcast public key is invalid" \
                Scripts/release/sign-update.sh \
                --archive "$archive_one" --appcast-config "$vector_config"
        key_invalid_indices+=("$key_vector_index")
        key_invalid_names+=("$key_name")
    fi
done < Tests/Fixtures/ReleasePublicKeyVectors.tsv
release_harness_drain_background_assertions
for ((key_invalid_offset = 0; key_invalid_offset < ${#key_invalid_indices[@]}; key_invalid_offset++)); do
    key_vector_index="${key_invalid_indices[$key_invalid_offset]}"
    key_name="${key_invalid_names[$key_invalid_offset]}"
    check "invalid signing key vector $key_name reports the canonical key gate" \
        /usr/bin/grep -Fq "appcast public key is invalid" \
            "$test_root/logs/key-vector-sign-${key_vector_index}.err"
done
for ((key_ready_offset = 0; key_ready_offset < ${#key_ready_indices[@]}; key_ready_offset++)); do
    key_vector_index="${key_ready_indices[$key_ready_offset]}"
    key_name="${key_ready_names[$key_ready_offset]}"
    vector_app="${key_ready_apps[$key_ready_offset]}"
    vector_config="$test_root/key-vectors/${key_vector_index}.plist"
    release_harness_queue_background_success \
        "bundle validator accepts shared public-key vector $key_name" \
        "key-vector-bundle-${key_vector_index}" 720 \
        Scripts/release/validate-app.sh --require-updater "$vector_app"
    release_harness_queue_background_failure \
        "update signing accepts $key_name through the key gate then fails closed on Xcode" \
        "key-vector-sign-${key_vector_index}" 720 /usr/bin/env \
            DEVELOPER_DIR="$non_xcode_developer_dir" Scripts/release/sign-update.sh \
            --archive "$archive_one" --appcast-config "$vector_config"
done
release_harness_drain_background_assertions
for ((key_ready_offset = 0; key_ready_offset < ${#key_ready_indices[@]}; key_ready_offset++)); do
    key_vector_index="${key_ready_indices[$key_ready_offset]}"
    key_name="${key_ready_names[$key_ready_offset]}"
    check "valid signing key vector $key_name reaches the full-Xcode gate" \
        /usr/bin/grep -Fq "full Xcode is required" \
            "$test_root/logs/key-vector-sign-${key_vector_index}.err"
done

fi
if release_harness_runs evidence-boundaries; then
release_harness_phase evidence-boundaries
if [[ "$release_harness_shard" != all ]]; then
    prepare_evidence_metadata_fixtures
fi
publishable_fixture="$test_root/publishable-boundary"
publishable_final="$publishable_fixture/Erylo-0.1.0-1-arm64.zip"
publishable_signature="${publishable_final}.sparkle-signature.json"
publishable_checksums="$publishable_fixture/SHA256SUMS"
publishable_final_held="$test_root/publishable-final-held.zip"
/bin/mkdir -p "$publishable_fixture"
/bin/cp "$archive_one" "$publishable_final"
publishable_length="$(/usr/bin/stat -f '%z' "$publishable_final")"
fixture_signature="$(/usr/bin/ruby -rbase64 -e 'print Base64.strict_encode64("structural fixture".ljust(64, "!"))')"
fixture_source_commit="$private_fixture_commit"
fixture_source_tree="$private_fixture_tree"
fixture_appcast_hash="$private_fixture_appcast_hash"
printf '{"archive":"Erylo-0.1.0-1-arm64.zip","length":%s,"sparkleEdSignature":"%s","sourceCommit":"%s","sourceTree":"%s","appcastConfigSHA256":"%s","toolchainSHA256":"%s"}\n' \
    "$publishable_length" "$fixture_signature" "$fixture_source_commit" "$fixture_source_tree" \
    "$fixture_appcast_hash" "$fixture_toolchain_hash" > "$publishable_signature"
Scripts/release/checksums.sh --output "$publishable_checksums" "$publishable_final" "$publishable_signature"
check "complete publication boundary requires the singular current artifact pair and evidence" bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_artifacts "$1" 0.1.0 1 complete "$2"
  ' _ "$repo_root" "$publishable_fixture"

verify_update_tool="$repo_root/.release/build/arm64/release/Tools/sign_update"
verify_update_tool_backup="$test_root/verify-update/real-sign_update"
/bin/mkdir -p "$(/usr/bin/dirname "$verify_update_tool_backup")"
/bin/mv "$verify_update_tool" "$verify_update_tool_backup"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    '[[ "$#" -eq 3 && "$1" == "--verify" && -f "$2" ]]' \
    '[[ "$3" == "${ERYLO_RELEASE_EXPECTED_SIGNATURE:?}" ]]' \
    > "$verify_update_tool"
/bin/chmod 0755 "$verify_update_tool"
check "valid signature metadata parses and reaches the positive verification seam" \
    /usr/bin/env ERYLO_RELEASE_EXPECTED_SIGNATURE="$fixture_signature" \
        Scripts/release/verify-update.sh \
            --archive "$publishable_final" \
            --signature-metadata "$publishable_signature"
/bin/mv "$verify_update_tool_backup" "$verify_update_tool"

expect_failure "public evidence rejects a different selected toolchain binding" \
    public-toolchain-binding bash -c '
      source Scripts/release/lib.sh
      release_validate_publishable_artifacts "$1" 0.1.0 1 complete "$2" "$3" "$4" "$5" "$6"
    ' _ "$repo_root" "$publishable_fixture" "$fixture_source_commit" "$fixture_source_tree" \
        "$fixture_appcast_hash" "$(printf '0%.0s' {1..64})"

stale_final="$publishable_fixture/Erylo-0.0.9-9-arm64.zip"
/bin/cp "$archive_one" "$stale_final"
expect_failure "publication boundary rejects a stale old-version final ZIP" stale-publishable-final bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_artifacts "$1" 0.1.0 1 complete "$2"
  ' _ "$repo_root" "$publishable_fixture"
/bin/rm -f -- "$stale_final"

/bin/mv "$publishable_final" "$publishable_final_held"
expect_failure "publication boundary rejects an orphan current signature" orphan-publishable-signature bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_artifacts "$1" 0.1.0 1 complete "$2"
  ' _ "$repo_root" "$publishable_fixture"
/bin/mv "$publishable_final_held" "$publishable_final"

signature_hash="$(/usr/bin/shasum -a 256 "$publishable_signature" | /usr/bin/awk '{print $1}')"
printf '%064d  %s\n%s  %s\n' \
    0 "$(basename "$publishable_final")" \
    "$signature_hash" "$(basename "$publishable_signature")" > "$publishable_checksums"
expect_failure "publication boundary rejects a mismatched artifact checksum" mismatched-publishable-checksum bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_artifacts "$1" 0.1.0 1 complete "$2"
  ' _ "$repo_root" "$publishable_fixture"
Scripts/release/checksums.sh --output "$publishable_checksums" "$publishable_final" "$publishable_signature"

/usr/bin/sed -n '1p' "$publishable_checksums" >> "$publishable_checksums"
expect_failure "publication boundary rejects a duplicate checksum line" duplicate-publishable-checksum bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_artifacts "$1" 0.1.0 1 complete "$2"
  ' _ "$repo_root" "$publishable_fixture"
Scripts/release/checksums.sh --output "$publishable_checksums" "$publishable_final" "$publishable_signature"

printf '%064d  Extra.zip\n' 0 >> "$publishable_checksums"
expect_failure "publication boundary rejects an extra checksum line" extra-publishable-checksum bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_artifacts "$1" 0.1.0 1 complete "$2"
  ' _ "$repo_root" "$publishable_fixture"
Scripts/release/checksums.sh --output "$publishable_checksums" "$publishable_final" "$publishable_signature"

publishable_symlink_target="$external_test_root/publishable-symlink-target.zip"
/bin/cp "$publishable_final" "$publishable_symlink_target"
/bin/mv "$publishable_final" "$publishable_final_held"
/bin/ln -s "$publishable_symlink_target" "$publishable_final"
expect_failure "publication boundary rejects a symlinked current final ZIP" symlink-publishable-final bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_artifacts "$1" 0.1.0 1 complete "$2"
  ' _ "$repo_root" "$publishable_fixture"
/bin/rm -f -- "$publishable_final"
/bin/mv "$publishable_final_held" "$publishable_final"
check "publication symlink validation leaves its external target unchanged" \
    test "$(/usr/bin/shasum -a 256 "$publishable_symlink_target" | /usr/bin/awk '{print $1}')" = "$hash_one"

publishable_hardlink="$external_test_root/publishable-hardlink.zip"
/bin/ln "$publishable_final" "$publishable_hardlink"
expect_failure "publication boundary rejects a hardlinked current final ZIP" hardlink-publishable-final bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_artifacts "$1" 0.1.0 1 complete "$2"
  ' _ "$repo_root" "$publishable_fixture"
/bin/rm -f -- "$publishable_hardlink"

/bin/mkdir "$publishable_fixture/Unexpected"
expect_failure "publication boundary rejects extra directories" directory-publishable-extra bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_artifacts "$1" 0.1.0 1 complete "$2"
  ' _ "$repo_root" "$publishable_fixture"
/bin/rmdir "$publishable_fixture/Unexpected"

empty_publishable_fixture="$test_root/publishable-empty"
/bin/mkdir -p "$empty_publishable_fixture"
check "pre-release publication boundary accepts only an empty directory" bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_artifacts "$1" 0.1.0 1 empty "$2"
  ' _ "$repo_root" "$empty_publishable_fixture"
printf 'unexpected\n' > "$empty_publishable_fixture/Unexpected.zip"
expect_failure "pre-release publication boundary rejects every stale entry" nonempty-publishable-start bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_artifacts "$1" 0.1.0 1 empty "$2"
  ' _ "$repo_root" "$empty_publishable_fixture"

fi
if release_harness_runs archive-evidence; then
release_harness_phase archive-evidence
if [[ "$release_harness_shard" != all ]]; then
    prepare_archive_evidence_fixtures
fi
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

fi
if release_harness_runs release-cleanup; then
release_harness_phase release-cleanup
if [[ "$release_harness_shard" != all ]]; then
    prepare_release_cleanup_fixture
fi
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

current_final="$repo_root/.release/artifacts/Erylo-0.1.0-1-arm64.zip"
current_signature="${current_final}.sparkle-signature.json"
current_checksums="$repo_root/.release/artifacts/SHA256SUMS"
printf 'interrupted-current-final\n' > "$current_final"
printf 'interrupted-current-signature\n' > "$current_signature"
printf 'interrupted-current-checksums\n' > "$current_checksums"
expect_failure "resumed release preparation removes only the exact current partial artifact set" release-cleans-current-partials \
    Scripts/release/release.sh \
        --identity "Developer ID Application: Release Harness (AAAAAAAAAA)" \
        --keychain-profile RELEASE_HARNESS \
        --appcast-config Config/Appcast.example.plist \
        --icon Resources/App/Missing.icns
check "resume cleanup leaves no partial current artifact or evidence" bash -c '
    [[ ! -e "$1" && ! -e "$2" && ! -e "$3" ]]
  ' _ "$current_final" "$current_signature" "$current_checksums"

current_symlink_external="$external_test_root/current-final-symlink.zip"
printf 'current-final-symlink-sentinel\n' > "$current_symlink_external"
/bin/ln -s "$current_symlink_external" "$current_final"
expect_failure "resume cleanup removes a current final symlink without following it" release-cleans-current-symlink \
    Scripts/release/release.sh \
        --identity "Developer ID Application: Release Harness (AAAAAAAAAA)" \
        --keychain-profile RELEASE_HARNESS \
        --appcast-config Config/Appcast.example.plist \
        --icon Resources/App/Missing.icns
check "current-final symlink cleanup leaves the external target unchanged" \
    /usr/bin/grep -Fxq current-final-symlink-sentinel "$current_symlink_external"

current_hardlink_external="$external_test_root/current-final-hardlink.zip"
printf 'current-final-hardlink-sentinel\n' > "$current_hardlink_external"
/bin/ln "$current_hardlink_external" "$current_final"
expect_failure "resume cleanup removes a current final hardlink without changing its peer" release-cleans-current-hardlink \
    Scripts/release/release.sh \
        --identity "Developer ID Application: Release Harness (AAAAAAAAAA)" \
        --keychain-profile RELEASE_HARNESS \
        --appcast-config Config/Appcast.example.plist \
        --icon Resources/App/Missing.icns
check "current-final hardlink cleanup leaves the external peer unchanged" \
    /usr/bin/grep -Fxq current-final-hardlink-sentinel "$current_hardlink_external"

stale_release_final="$repo_root/.release/artifacts/Erylo-0.0.9-9-arm64.zip"
printf 'stale-old-version-final\n' > "$stale_release_final"
expect_failure "failed release preparation refuses an unrelated stale final" release-rejects-stale-final \
    Scripts/release/release.sh \
        --identity "Developer ID Application: Release Harness (AAAAAAAAAA)" \
        --keychain-profile RELEASE_HARNESS \
        --appcast-config Config/Appcast.example.plist \
        --icon Resources/App/Missing.icns
check "failed preparation does not silently delete an unrelated old release" \
    /usr/bin/grep -Fxq stale-old-version-final "$stale_release_final"
/bin/rm -f -- "$stale_release_final"

check "publishable artifacts are exactly empty after failed or resumed preparation" bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_artifacts "$1" 0.1.0 1 empty
  ' _ "$repo_root"

fi
if release_harness_runs publication; then
release_harness_phase publication
if [[ "$release_harness_shard" != all ]]; then
    prepare_publication_fixtures
fi
transaction_prior="$test_root/transaction/prior"
/bin/mkdir -p "$(dirname "$transaction_prior")"
/usr/bin/ditto "$publishable_fixture" "$transaction_prior"
release_publish_artifact_directory "$repo_root" "$transaction_prior" 0.1.0 1
check "transactional publication installs one validated current directory" \
    bash -c 'source Scripts/release/lib.sh; release_validate_publishable_root "$1" 0.1.0 1' _ "$repo_root"
check "final public evidence is exactly 0644 inside 0700 release directories" bash -c '
    [[ "$(stat -f "%Lp" "$1/.release/artifacts")" == 700 ]]
    [[ "$(stat -f "%Lp" "$1/.release/artifacts/current")" == 700 ]]
    find "$1/.release/artifacts/current" -type f -exec stat -f "%Lp" {} \; | grep -vFx 644 | grep -q . && exit 1
    exit 0
  ' _ "$repo_root"
published_manifest="$repo_root/.release/artifacts/current/SHA256SUMS"
prior_published_hash="$(/usr/bin/shasum -a 256 "$published_manifest" | /usr/bin/awk '{print $1}')"
check "an injected final-archive failure leaves the prior complete set unchanged" \
    test "$(/usr/bin/shasum -a 256 "$published_manifest" | /usr/bin/awk '{print $1}')" = "$prior_published_hash"

archive_only_source="$test_root/transaction/archive-only"
/bin/mkdir -p "$archive_only_source"
/bin/cp "$archive_one" "$archive_only_source/Erylo-0.1.0-1-arm64.zip"
expect_failure "an injected signing failure cannot publish an archive-only set" transaction-archive-only bash -c '
    source Scripts/release/lib.sh
    release_publish_artifact_directory "$1" "$2" 0.1.0 1
  ' _ "$repo_root" "$archive_only_source"
check "archive-only failure preserves the prior complete set" \
    test "$(/usr/bin/shasum -a 256 "$published_manifest" | /usr/bin/awk '{print $1}')" = "$prior_published_hash"

missing_checksum_source="$test_root/transaction/missing-checksum"
/bin/mkdir -p "$missing_checksum_source"
/bin/cp "$repo_root/.release/artifacts/current/Erylo-0.1.0-1-arm64.zip" "$missing_checksum_source/"
/bin/cp "$repo_root/.release/artifacts/current/Erylo-0.1.0-1-arm64.zip.sparkle-signature.json" "$missing_checksum_source/"
expect_failure "an injected checksum failure cannot publish an incomplete pair" transaction-missing-checksum bash -c '
    source Scripts/release/lib.sh
    release_publish_artifact_directory "$1" "$2" 0.1.0 1
  ' _ "$repo_root" "$missing_checksum_source"
check "checksum-step failure preserves the prior complete set" \
    test "$(/usr/bin/shasum -a 256 "$published_manifest" | /usr/bin/awk '{print $1}')" = "$prior_published_hash"

bad_validation_source="$test_root/transaction/bad-validation"
/usr/bin/ditto "$repo_root/.release/artifacts/current" "$bad_validation_source"
printf '%064d  Erylo-0.1.0-1-arm64.zip\n' 0 > "$bad_validation_source/SHA256SUMS"
expect_failure "an injected final-validation failure cannot replace the prior set" transaction-bad-validation bash -c '
    source Scripts/release/lib.sh
    release_publish_artifact_directory "$1" "$2" 0.1.0 1
  ' _ "$repo_root" "$bad_validation_source"
check "validation failure preserves the prior complete set" \
    test "$(/usr/bin/shasum -a 256 "$published_manifest" | /usr/bin/awk '{print $1}')" = "$prior_published_hash"

same_version_manifest_backup="$test_root/transaction/prior-SHA256SUMS"
/bin/cp "$published_manifest" "$same_version_manifest_backup"
printf '%064d  Erylo-0.1.0-1-arm64.zip\n' 0 > "$published_manifest"
expect_failure "release startup rejects prior same-version stale evidence" same-version-stale-evidence \
    Scripts/release/release.sh \
        --identity "Developer ID Application: Release Harness (AAAAAAAAAA)" \
        --keychain-profile RELEASE_HARNESS \
        --appcast-config Config/Appcast.example.plist \
        --icon Resources/App/Missing.icns
/bin/cp "$same_version_manifest_backup" "$published_manifest"
check "restored prior current set validates after stale-evidence rejection" \
    bash -c 'source Scripts/release/lib.sh; release_validate_publishable_root "$1" 0.1.0 1' _ "$repo_root"

for injected_step in before-swap after-quarantine after-install; do
    injected_source="$test_root/transaction/injected-${injected_step}"
    /usr/bin/ditto "$repo_root/.release/artifacts/current" "$injected_source"
    expect_failure "publication rollback preserves current after $injected_step failure" \
        "transaction-${injected_step}" bash -c '
            source Scripts/release/lib.sh
            release_publish_artifact_directory "$1" "$2" 0.1.0 1 "$3"
          ' _ "$repo_root" "$injected_source" "$injected_step"
    check "current set is unchanged after $injected_step failure" \
        test "$(/usr/bin/shasum -a 256 "$published_manifest" | /usr/bin/awk '{print $1}')" = "$prior_published_hash"
done

planted_rollback_source="$test_root/transaction/planted-source-rollback"
/usr/bin/ditto "$repo_root/.release/artifacts/current" "$planted_rollback_source"
planted_rollback_prior_digest="$(release_set_digest "$repo_root/.release/artifacts/current")"
planted_rollback_log="$test_root/logs/public-planted-source-rollback.err"
release_harness_start_background public-planted-source-rollback \
    "$release_harness_background_timeout" /usr/bin/env \
    ERYLO_RELEASE_FS_TESTING=1 \
    ERYLO_RELEASE_FS_TEST_PAUSE_STAGE=after-current-exchange \
    ERYLO_RELEASE_FS_TEST_DELAY=5 \
    /usr/bin/ruby Scripts/release/fs-helper.rb swap-current "$repo_root" \
        "$planted_rollback_source" 0.1.0 1 after-install \
    2>"$planted_rollback_log"
planted_rollback_pid="$release_harness_background_pid"
planted_rollback_state="$release_harness_background_state"
check "public publication reaches the planted source-leaf rollback boundary" \
    wait_for_fs_test_pause "$planted_rollback_log" "$planted_rollback_pid" \
        "$planted_rollback_state" public-planted-source-rollback
check "public publication moved the predecessor out of the caller-controlled source leaf" \
    test ! -e "$planted_rollback_source"
/bin/mkdir -p "$planted_rollback_source"
printf 'public-caller-leaf-sentinel\n' > "$planted_rollback_source/sentinel"
expect_background_failure \
    "public rollback ignores a planted caller source-leaf replacement" \
    "$planted_rollback_pid" "$planted_rollback_state"
check "planted source-leaf rollback restores the exact prior public set" \
    test "$(release_set_digest "$repo_root/.release/artifacts/current")" = "$planted_rollback_prior_digest"
check "planted source-leaf rollback leaves current fully valid" \
    bash -c 'source Scripts/release/lib.sh; release_validate_publishable_root "$1" 0.1.0 1' _ "$repo_root"
check "public rollback does not remove or consume the planted caller directory" \
    /usr/bin/grep -Fxq public-caller-leaf-sentinel "$planted_rollback_source/sentinel"
check "public rollback leaves no internal ambiguous transaction" bash -c '
    [[ -z "$(find "$1/.release/tmp" -maxdepth 1 -name "publication-rollback.*" -print -quit)" ]]
  ' _ "$repo_root"
release_remove_path "$repo_root" "$planted_rollback_source"

transaction_new="$test_root/transaction/new-complete"
/usr/bin/ditto "$repo_root/.release/artifacts/current" "$transaction_new"
new_fixture_signature="$(/usr/bin/ruby -rbase64 -e 'print Base64.strict_encode64("new structural fixture".ljust(64, "!"))')"
printf '{"archive":"Erylo-0.1.0-1-arm64.zip","length":%s,"sparkleEdSignature":"%s","sourceCommit":"%s","sourceTree":"%s","appcastConfigSHA256":"%s","toolchainSHA256":"%s"}\n' \
    "$publishable_length" "$new_fixture_signature" "$fixture_source_commit" "$fixture_source_tree" \
    "$fixture_appcast_hash" "$fixture_toolchain_hash" \
    > "$transaction_new/Erylo-0.1.0-1-arm64.zip.sparkle-signature.json"
Scripts/release/checksums.sh --output "$transaction_new/SHA256SUMS" \
    "$transaction_new/Erylo-0.1.0-1-arm64.zip" \
    "$transaction_new/Erylo-0.1.0-1-arm64.zip.sparkle-signature.json"
release_publish_artifact_directory "$repo_root" "$transaction_new" 0.1.0 1
new_published_hash="$(/usr/bin/shasum -a 256 "$published_manifest" | /usr/bin/awk '{print $1}')"
check "successful directory transaction replaces the whole validated set" \
    test "$new_published_hash" != "$prior_published_hash"

for crash_stage in \
    before-publication-sync \
    after-publication-sync \
    before-current-exchange \
    after-current-exchange \
    after-publication-directory-sync \
    after-retired-publication-cleanup; do
    crash_temp="$(release_make_temp_dir "$repo_root" final-publication)"
    crash_source="$crash_temp/current"
    /usr/bin/ditto "$repo_root/.release/artifacts/current" "$crash_source"
    crash_signature="$(/usr/bin/ruby -rbase64 -e 'print Base64.strict_encode64(ARGV.fetch(0).ljust(64, "!"))' "$crash_stage")"
    printf '{"archive":"Erylo-0.1.0-1-arm64.zip","length":%s,"sparkleEdSignature":"%s","sourceCommit":"%s","sourceTree":"%s","appcastConfigSHA256":"%s","toolchainSHA256":"%s"}\n' \
        "$publishable_length" "$crash_signature" "$fixture_source_commit" "$fixture_source_tree" \
        "$fixture_appcast_hash" "$fixture_toolchain_hash" \
        > "$crash_source/Erylo-0.1.0-1-arm64.zip.sparkle-signature.json"
    Scripts/release/checksums.sh --output "$crash_source/SHA256SUMS" \
        "$crash_source/Erylo-0.1.0-1-arm64.zip" \
        "$crash_source/Erylo-0.1.0-1-arm64.zip.sparkle-signature.json"
    crash_log="$test_root/logs/publication-crash-${crash_stage}.err"
    release_harness_start_background "publication-crash-${crash_stage}" \
        "$release_harness_background_timeout" /usr/bin/env \
        ERYLO_RELEASE_FS_TESTING=1 \
        ERYLO_RELEASE_FS_TEST_PAUSE_STAGE="$crash_stage" \
        ERYLO_RELEASE_FS_TEST_DELAY=5 \
        /usr/bin/ruby Scripts/release/fs-helper.rb swap-current "$repo_root" \
            "$crash_source" 0.1.0 1 none \
        2>"$crash_log"
    crash_pid="$release_harness_background_pid"
    crash_state="$release_harness_background_state"
    check "publication reaches the $crash_stage crash boundary" \
        wait_for_fs_test_pause "$crash_log" "$crash_pid" "$crash_state" \
            "publication-crash-${crash_stage}"
    kill_paused_process "publication helper is SIGKILLed at $crash_stage" \
        "$crash_pid" "$crash_state"
    check "SIGKILL at $crash_stage leaves one complete public current set" \
        bash -c 'source Scripts/release/lib.sh; release_validate_publishable_root "$1" 0.1.0 1' _ "$repo_root"
    release_recover_temporaries "$repo_root"
    check "restart recovery removes the abandoned $crash_stage transaction" \
        test ! -e "$crash_temp"
    check "restart recovery after $crash_stage preserves public/private commit parity" \
        /usr/bin/ruby -rjson -e '
          public_data = JSON.parse(File.read(ARGV.fetch(0)))
          private_data = JSON.parse(File.read(ARGV.fetch(1)))
          abort unless public_data.fetch("sourceCommit") == private_data.fetch("sourceCommit")
          abort unless public_data.fetch("sourceTree") == private_data.fetch("sourceTree")
          abort unless public_data.fetch("appcastConfigSHA256") == private_data.fetch("appcastConfigSHA256")
          abort unless public_data.fetch("toolchainSHA256") == private_data.fetch("toolchainSHA256")
        ' "$repo_root/.release/artifacts/current/Erylo-0.1.0-1-arm64.zip.sparkle-signature.json" \
            "$private_published_dir/ReleaseManifest.json"
    release_harness_finish_crash_owner "$crash_pid" "$crash_state" \
        "publication-crash-${crash_stage}"
done

identity_race_source="$test_root/transaction/identity-race-source"
/usr/bin/ditto "$repo_root/.release/artifacts/current" "$identity_race_source"
identity_race_final="$identity_race_source/Erylo-0.1.0-1-arm64.zip"
identity_race_signature="$identity_race_source/Erylo-0.1.0-1-arm64.zip.sparkle-signature.json"
identity_race_checksums="$identity_race_source/SHA256SUMS"
identity_race_final_id="$(release_file_identity "$repo_root" "$identity_race_final")"
identity_race_signature_id="$(release_file_identity "$repo_root" "$identity_race_signature")"
identity_race_checksums_id="$(release_file_identity "$repo_root" "$identity_race_checksums")"
identity_race_log="$test_root/logs/artifact-byte-substitution.err"
identity_race_previous_hash="$(/usr/bin/shasum -a 256 "$published_manifest" | /usr/bin/awk '{print $1}')"
release_harness_start_background artifact-byte-substitution \
    "$release_harness_background_timeout" /usr/bin/env \
    ERYLO_RELEASE_FS_TESTING=1 ERYLO_RELEASE_FS_TEST_PAUSE_STAGE=swap-current \
    /usr/bin/ruby Scripts/release/fs-helper.rb swap-current "$repo_root" \
        "$identity_race_source" 0.1.0 1 none \
        "$fixture_source_commit" "$fixture_source_tree" "$fixture_appcast_hash" "$fixture_toolchain_hash" \
        "$identity_race_final_id" "$identity_race_signature_id" "$identity_race_checksums_id" \
    2>"$identity_race_log"
race_pid="$release_harness_background_pid"
race_state="$release_harness_background_state"
wait_for_fs_test_pause "$identity_race_log" "$race_pid" "$race_state" \
    artifact-byte-substitution
printf 'same-run-substituted-archive-bytes\n' > "$identity_race_final"
expect_background_failure \
    "same-run archive substitution is rejected immediately before publication" \
    "$race_pid" "$race_state"
check "artifact substitution failure preserves the previous complete public set" \
    test "$(shasum -a 256 "$published_manifest" | awk '{print $1}')" = "$identity_race_previous_hash"

for public_race_variant in archive signature checksum; do
    public_race_source="$test_root/transaction/post-sync-${public_race_variant}"
    public_race_replacement="$test_root/transaction/post-sync-${public_race_variant}-replacement"
    /usr/bin/ditto "$repo_root/.release/artifacts/current" "$public_race_source"
    /usr/bin/ditto "$public_race_source" "$public_race_replacement"
    public_race_archive="$public_race_source/Erylo-0.1.0-1-arm64.zip"
    public_race_signature="$public_race_source/Erylo-0.1.0-1-arm64.zip.sparkle-signature.json"
    public_race_checksums="$public_race_source/SHA256SUMS"
    replacement_archive="$public_race_replacement/Erylo-0.1.0-1-arm64.zip"
    replacement_signature="$public_race_replacement/Erylo-0.1.0-1-arm64.zip.sparkle-signature.json"
    replacement_checksums="$public_race_replacement/SHA256SUMS"
    case "$public_race_variant" in
        archive)
            printf 'post-sync-archive-substitution\n' >> "$replacement_archive"
            /usr/bin/ruby -rjson -e '
              path, archive = ARGV
              payload = JSON.parse(File.read(path))
              payload["length"] = File.size(archive)
              File.write(path, JSON.generate(payload) + "\n")
            ' "$replacement_signature" "$replacement_archive"
            Scripts/release/checksums.sh --output "$replacement_checksums" \
                "$replacement_archive" "$replacement_signature"
            ;;
        signature)
            /usr/bin/ruby -rbase64 -rjson -e '
              path = ARGV.fetch(0)
              payload = JSON.parse(File.read(path))
              payload["sparkleEdSignature"] = Base64.strict_encode64("post-sync replacement".ljust(64, "!"))
              File.write(path, JSON.generate(payload) + "\n")
            ' "$replacement_signature"
            Scripts/release/checksums.sh --output "$replacement_checksums" \
                "$replacement_archive" "$replacement_signature"
            ;;
        checksum)
            /bin/cp "$replacement_checksums" "$public_race_replacement/SHA256SUMS.replacement"
            ;;
    esac
    public_race_archive_id="$(release_file_identity "$repo_root" "$public_race_archive")"
    public_race_signature_id="$(release_file_identity "$repo_root" "$public_race_signature")"
    public_race_checksums_id="$(release_file_identity "$repo_root" "$public_race_checksums")"
    public_race_prior_digest="$(release_set_digest "$repo_root/.release/artifacts/current")"
    public_race_log="$test_root/logs/public-post-sync-${public_race_variant}.err"
    release_harness_start_background "public-post-sync-${public_race_variant}" \
        "$release_harness_background_timeout" /usr/bin/env \
        ERYLO_RELEASE_FS_TESTING=1 \
        ERYLO_RELEASE_FS_TEST_PAUSE_STAGE=after-publication-sync \
        ERYLO_RELEASE_FS_TEST_DELAY=5 \
        /usr/bin/ruby Scripts/release/fs-helper.rb swap-current "$repo_root" \
            "$public_race_source" 0.1.0 1 none \
            "$fixture_source_commit" "$fixture_source_tree" "$fixture_appcast_hash" "$fixture_toolchain_hash" \
            "$public_race_archive_id" "$public_race_signature_id" "$public_race_checksums_id" \
        2>"$public_race_log"
    public_race_pid="$release_harness_background_pid"
    public_race_state="$release_harness_background_state"
    check "publication reaches the exact post-sync $public_race_variant substitution boundary" \
        wait_for_fs_test_pause "$public_race_log" "$public_race_pid" \
            "$public_race_state" "public-post-sync-${public_race_variant}"
    case "$public_race_variant" in
        archive)
            /bin/mv "$replacement_archive" "$public_race_archive"
            /bin/mv "$replacement_signature" "$public_race_signature"
            /bin/mv "$replacement_checksums" "$public_race_checksums"
            ;;
        signature)
            /bin/mv "$replacement_signature" "$public_race_signature"
            /bin/mv "$replacement_checksums" "$public_race_checksums"
            ;;
        checksum)
            /bin/mv "$public_race_replacement/SHA256SUMS.replacement" "$public_race_checksums"
            ;;
    esac
    expect_background_failure \
        "post-sync public $public_race_variant substitution fails closed" \
        "$public_race_pid" "$public_race_state"
    check "post-sync public $public_race_variant substitution preserves the exact prior current set" \
        test "$(release_set_digest "$repo_root/.release/artifacts/current")" = "$public_race_prior_digest"
    release_remove_path "$repo_root" "$public_race_source"
    release_remove_path "$repo_root" "$public_race_replacement"
done

artifacts_parent_held="$repo_root/.release/artifacts-held-for-race"
artifacts_external="$external_test_root/artifacts-parent-race"
/bin/mkdir -p "$artifacts_external/current"
printf 'external-artifacts-sentinel\n' > "$artifacts_external/current/sentinel"
race_swap_source="$test_root/transaction/artifacts-parent-race-source"
/usr/bin/ditto "$repo_root/.release/artifacts/current" "$race_swap_source"
race_swap_log="$test_root/logs/descriptor-race-swap-current.err"
release_harness_start_background descriptor-race-swap-current \
    "$release_harness_background_timeout" /usr/bin/env \
    ERYLO_RELEASE_FS_TESTING=1 ERYLO_RELEASE_FS_TEST_PAUSE_STAGE=swap-current \
    /usr/bin/ruby Scripts/release/fs-helper.rb swap-current "$repo_root" \
        "$race_swap_source" 0.1.0 1 none 2>"$race_swap_log"
race_pid="$release_harness_background_pid"
race_state="$release_harness_background_state"
wait_for_fs_test_pause "$race_swap_log" "$race_pid" "$race_state" descriptor-race-swap-current
/bin/mv "$repo_root/.release/artifacts" "$artifacts_parent_held"
/bin/ln -s "$artifacts_external" "$repo_root/.release/artifacts"
expect_background_success \
    "whole-set swap remains anchored after artifacts parent replacement" \
    "$race_pid" "$race_state"
check "artifacts parent swap leaves the external current directory unchanged" \
    /usr/bin/grep -Fxq external-artifacts-sentinel "$artifacts_external/current/sentinel"
/bin/rm -f -- "$repo_root/.release/artifacts"
/bin/mv "$artifacts_parent_held" "$repo_root/.release/artifacts"
check "originally anchored artifact root contains a complete validated set after the race" \
    bash -c 'source Scripts/release/lib.sh; release_validate_publishable_root "$1" 0.1.0 1' _ "$repo_root"

held_current="$test_root/transaction/held-current"
/bin/mv "$repo_root/.release/artifacts/current" "$held_current"
current_symlink_directory="$external_test_root/current-symlink-directory"
/bin/mkdir "$current_symlink_directory"
printf 'external-current-directory-sentinel\n' > "$current_symlink_directory/sentinel"
/bin/ln -s "$current_symlink_directory" "$repo_root/.release/artifacts/current"
symlink_race_source="$test_root/transaction/symlink-race-source"
/usr/bin/ditto "$held_current" "$symlink_race_source"
expect_failure "publication refuses a symlink planted at artifacts/current" transaction-current-symlink bash -c '
    source Scripts/release/lib.sh
    release_publish_artifact_directory "$1" "$2" 0.1.0 1
  ' _ "$repo_root" "$symlink_race_source"
check "current-directory symlink rejection leaves the external target unchanged" \
    /usr/bin/grep -Fxq external-current-directory-sentinel "$current_symlink_directory/sentinel"
/bin/rm -f -- "$repo_root/.release/artifacts/current"
/bin/mv "$held_current" "$repo_root/.release/artifacts/current"

current_final_hardlink="$external_test_root/current-published-hardlink.zip"
/bin/ln "$repo_root/.release/artifacts/current/Erylo-0.1.0-1-arm64.zip" "$current_final_hardlink"
expect_failure "current-set validation rejects a hardlinked published ZIP" current-published-hardlink bash -c '
    source Scripts/release/lib.sh
    release_validate_publishable_root "$1" 0.1.0 1
  ' _ "$repo_root"
/bin/rm -f -- "$current_final_hardlink"
check "current set validates again after the external hardlink is removed" \
    bash -c 'source Scripts/release/lib.sh; release_validate_publishable_root "$1" 0.1.0 1' _ "$repo_root"
release_remove_path "$repo_root" ".release/artifacts/current"
check "transaction harness leaves no publishable current set" \
    bash -c 'source Scripts/release/lib.sh; release_validate_publishable_root "$1"' _ "$repo_root"

expect_failure "Sparkle signing rejects empty userinfo before tool or credential gates" signing-empty-userinfo \
    Scripts/release/sign-update.sh --archive "$archive_one" --appcast-config "$empty_userinfo_appcast"
check "Sparkle signing failure identifies the shared appcast URL gate" \
    /usr/bin/grep -Fq "appcast feed URL is invalid" "$test_root/logs/signing-empty-userinfo.err"

expect_failure "signing fails closed without full Xcode" missing-full-xcode \
    /usr/bin/env DEVELOPER_DIR="$non_xcode_developer_dir" Scripts/release/sign-app.sh \
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

check "later publication gates retain the immutable commit-qualified private dSYM" \
    test -f "$private_published_dir/$private_fixture_name"
check "later publication gates retain the matching private checksum evidence" \
    test -f "$private_published_dir/SHA256SUMS"
release_remove_path "$repo_root" "$private_published_dir"
check "private harness cleanup leaves no loose or partial private evidence" bash -c '
    source Scripts/release/lib.sh
    release_fs_helper "$1" validate-private-root
  ' _ "$repo_root"

fi
release_harness_phase complete
if [[ "$check_count" -ne "$release_harness_expected_checks" ]]; then
    printf 'Release harness shard %s executed %d checks; contract requires %d.\n' \
        "$release_harness_shard" "$check_count" "$release_harness_expected_checks" >&2
    exit 65
fi
if [[ "$failure_count" -ne 0 ]]; then
    printf 'Release harness failed %d of %d checks.\n' "$failure_count" "$check_count" >&2
    exit 1
fi

printf 'Release harness passed %d checks.\n' "$check_count"
