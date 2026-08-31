#!/bin/bash

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# Shared release helpers. Caller scripts enable strict mode before sourcing.

# Release staging is private by default, independent of the invoking shell.
# The anchored publication helper deliberately changes only validated public
# release files to 0644 at the final directory swap.
umask 077

release_die() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

release_require_command() {
    command -v "$1" >/dev/null 2>&1 || release_die "required tool is unavailable: $1"
}

release_developer_id_team_id() {
    local identity="${1:-}"
    local team_id

    [[ "$#" -eq 1 ]] || release_die "Developer ID identity parser requires one identity"
    team_id="$(/usr/bin/ruby -e '
      identity = ARGV.fetch(0)
      match = /\ADeveloper ID Application: (.+) \(([A-Z0-9]{10})\)\z/.match(identity)
      abort unless match
      organization = match[1]
      abort unless organization == organization.strip
      abort if organization.match?(/[[:cntrl:]]/)
      print match[2]
    ' "$identity" 2>/dev/null)" \
        || release_die "identity must exactly match Developer ID Application: ORGANIZATION (TEAMID)"
    [[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] \
        || release_die "Developer ID identity contains an invalid team identifier"
    printf '%s\n' "$team_id"
}

release_system_git() {
    # Source-control admission must not resolve Git through a caller-selected
    # developer directory before that Xcode application is authenticated.
    /usr/bin/env -u DEVELOPER_DIR /usr/bin/git "$@"
}

release_repo_root() {
    release_system_git rev-parse --show-toplevel 2>/dev/null \
        || release_die "run this script from an Erylo Git worktree"
}

release_fs_helper() {
    local repo_root="$1"
    shift
    local helper_root="${ERYLO_RELEASE_SOURCE_ROOT:-$repo_root}"
    local helper="$helper_root/Scripts/release/fs-helper.rb"
    local command_name="${1:-}"

    [[ -n "$command_name" ]] || release_die "release filesystem command is missing"
    shift
    [[ -f "$helper" && ! -L "$helper" ]] || release_die "release filesystem helper is missing or unsafe"
    /usr/bin/ruby "$helper" "$command_name" "$repo_root" "$@"
}

release_output_path() {
    local repo_root="$1"
    local requested="$2"

    release_fs_helper "$repo_root" output-path "$requested" \
        || release_die "unsafe release output path: $requested"
}

release_assert_lock() {
    local repo_root="$1"

    release_fs_helper "$repo_root" assert-lock \
        || release_die "repository release lock is not held by this operation"
}

release_lock_capability_hash() {
    local phase="$1"
    local descriptor="${ERYLO_RELEASE_LOCK_FD:-}"

    [[ "$descriptor" =~ ^[0-9]+$ ]] || release_die "release capability lock descriptor is missing"
    /usr/bin/ruby -e '
      descriptor = Integer(ARGV.fetch(0), 10)
      phase = ARGV.fetch(1)
      process_id = Integer(ARGV.fetch(2), 10)
      parent_id = Integer(ARGV.fetch(3), 10)
      lock = IO.for_fd(descriptor, "rb", autoclose: false)
      record = lock.pread(512, 0)
      match = /\AERYLO_RELEASE_CAPABILITY_V1\t([1-9][0-9]*)\t([0-9a-f]{64})\t([0-9a-f]{64})\n\z/.match(record)
      abort("release capability record is missing or invalid") unless match
      owner = Integer(match[1], 10)
      case phase
      when "outer"
        abort("outer release process is not the lock-helper admission process") unless process_id == owner
        print match[2]
      when "worker"
        abort("release worker parent is not the authenticated supervisor") unless parent_id == owner
        print match[3]
      else
        abort("unknown release capability phase")
      end
    ' "$descriptor" "$phase" "$$" "$PPID" \
        || release_die "release capability is not bound to the lock-helper process chain"
}

release_assert_outer_capability() {
    local descriptor="${ERYLO_RELEASE_WORKER_CAPABILITY_FD:-}"
    local expected_sha256

    [[ "$descriptor" =~ ^[0-9]+$ ]] \
        || release_die "authenticated outer release capability is missing"
    expected_sha256="$(release_lock_capability_hash outer)"
    /usr/bin/ruby -rdigest -e '
      descriptor = Integer(ARGV.fetch(0), 10)
      expected = ARGV.fetch(1)
      io = IO.for_fd(descriptor, "rb", autoclose: false)
      abort("outer release capability is not an inherited one-use pipe") unless io.stat.pipe?
      token = io.read(32)
      abort("outer release capability payload is invalid or already consumed") unless token&.bytesize == 32
      abort("outer release capability authentication failed") \
        unless Digest::SHA256.hexdigest(token) == expected
    ' "$descriptor" "$expected_sha256" \
        || release_die "authenticated outer release capability is invalid or already consumed"
    export ERYLO_RELEASE_OUTER_AUTHENTICATED=1
}

release_assert_worker_capability() {
    local descriptor="${ERYLO_RELEASE_WORKER_CAPABILITY_FD:-}"
    local expected_sha256

    [[ "${ERYLO_RELEASE_SUPERVISOR_HANDOFF:-0}" == "1" \
        && "$descriptor" =~ ^[0-9]+$ ]] \
        || release_die "authenticated release worker capability is missing"
    expected_sha256="$(release_lock_capability_hash worker)"
    /usr/bin/ruby -rdigest -e '
      descriptor = Integer(ARGV.fetch(0), 10)
      expected = ARGV.fetch(1)
      io = IO.for_fd(descriptor, "rb", autoclose: false)
      abort("release worker capability is not an inherited one-use pipe") unless io.stat.pipe?
      token = io.read
      abort("release worker capability payload is invalid or already consumed") unless token.bytesize == 32
      abort("release worker capability authentication failed") \
        unless Digest::SHA256.hexdigest(token) == expected
    ' "$descriptor" "$expected_sha256" \
        || release_die "authenticated release worker capability is invalid or already consumed"
    unset \
        ERYLO_RELEASE_WORKER_CAPABILITY_FD \
        ERYLO_RELEASE_OUTER_AUTHENTICATED \
        ERYLO_RELEASE_SUPERVISOR_HANDOFF
    export ERYLO_RELEASE_WORKER_AUTHENTICATED=1
}

release_reject_external_snapshot_state() {
    local variable
    for variable in \
        ERYLO_RELEASE_SNAPSHOT_ACTIVE \
        ERYLO_RELEASE_SOURCE_ROOT \
        ERYLO_RELEASE_SOURCE_COMMIT \
        ERYLO_RELEASE_SOURCE_TREE \
        ERYLO_RELEASE_SOURCE_EPOCH \
        ERYLO_RELEASE_SOURCE_DEVICE \
        ERYLO_RELEASE_SOURCE_IMAGE \
        ERYLO_RELEASE_SOURCE_IMAGE_SHA256 \
        ERYLO_RELEASE_SOURCE_DISK_DEVICE \
        ERYLO_RELEASE_SNAPSHOT_TEMP \
        ERYLO_RELEASE_SNAPSHOT_MANIFEST_SHA256 \
        ERYLO_RELEASE_OUTER_CAPABILITY_SHA256 \
        ERYLO_RELEASE_WORKER_CAPABILITY_FD \
        ERYLO_RELEASE_WORKER_CAPABILITY_SHA256 \
        ERYLO_RELEASE_OUTER_AUTHENTICATED \
        ERYLO_RELEASE_SUPERVISOR_HANDOFF \
        ERYLO_RELEASE_WORKER_AUTHENTICATED; do
        [[ -z "${!variable:-}" ]] \
            || release_die "external release invocation contains internal snapshot state: $variable"
    done
}

release_reject_outer_driver_state() {
    local variable
    for variable in \
        ERYLO_RELEASE_SNAPSHOT_ACTIVE \
        ERYLO_RELEASE_SOURCE_ROOT \
        ERYLO_RELEASE_SOURCE_COMMIT \
        ERYLO_RELEASE_SOURCE_TREE \
        ERYLO_RELEASE_SOURCE_EPOCH \
        ERYLO_RELEASE_SOURCE_DEVICE \
        ERYLO_RELEASE_SOURCE_IMAGE \
        ERYLO_RELEASE_SOURCE_IMAGE_SHA256 \
        ERYLO_RELEASE_SOURCE_DISK_DEVICE \
        ERYLO_RELEASE_SNAPSHOT_TEMP \
        ERYLO_RELEASE_SNAPSHOT_MANIFEST_SHA256 \
        ERYLO_RELEASE_OUTER_AUTHENTICATED \
        ERYLO_RELEASE_SUPERVISOR_HANDOFF \
        ERYLO_RELEASE_WORKER_AUTHENTICATED; do
        [[ -z "${!variable:-}" ]] \
            || release_die "outer release driver contains worker-only state: $variable"
    done
}

release_assert_tracked_upstream() {
    local repo_root="$1"
    local expected_commit="$2"
    local upstream

    [[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] \
        || release_die "tracked-upstream release commit is invalid"
    upstream="$(release_system_git -C "$repo_root" rev-parse \
        --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" \
        || release_die "production release branch must have an upstream"
    [[ "$(release_system_git -C "$repo_root" rev-parse --verify "$upstream")" == "$expected_commit" ]] \
        || release_die "production release commit must equal its tracked upstream"
}

release_pinned_supervisor() {
    local launch_mode="$1"
    local repo_root="$2"
    local source_commit="$3"
    local snapshot_temp="$4"
    local snapshot_mount="$5"
    local worker="$6"
    shift 6
    local launcher_path="Scripts/release/fs-helper.rb"
    local listing
    local object
    local read_object
    local launcher_bytes
    local actual_object
    local injected_failure=""

    [[ "$launch_mode" == "exec" || "$launch_mode" == "run" ]] \
        || release_die "invalid pinned supervisor launch mode"
    [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] \
        || release_die "invalid pinned supervisor source commit"
    listing="$(release_system_git -C "$repo_root" ls-tree "$source_commit" -- "$launcher_path")" \
        || release_die "could not inspect the pinned supervisor bootstrap"
    if [[ "$listing" =~ ^100755\ blob\ ([0-9a-f]+)$'\t'${launcher_path}$ ]]; then
        object="${BASH_REMATCH[1]}"
    else
        release_die "pinned supervisor bootstrap is missing or has a non-executable Git mode"
    fi
    if [[ "${ERYLO_RELEASE_TESTING:-0}" == "1" ]]; then
        injected_failure="${ERYLO_RELEASE_TEST_BOOTSTRAP_FAILURE:-}"
    fi
    read_object="$object"
    if [[ "$injected_failure" == "producer" ]]; then
        read_object="${object}invalid"
    fi
    if ! launcher_bytes="$(release_system_git -C "$repo_root" cat-file blob "$read_object")"; then
        release_die "could not synchronously read the pinned supervisor bootstrap"
    fi
    if [[ "$injected_failure" == "read" ]]; then
        launcher_bytes="${launcher_bytes%?}"
    fi
    actual_object="$(printf '%s\n' "$launcher_bytes" | \
        release_system_git -C "$repo_root" hash-object --stdin)" \
        || release_die "could not hash the pinned supervisor bootstrap"
    if [[ "$injected_failure" == "hash" ]]; then
        actual_object="0000000000000000000000000000000000000000"
    fi
    [[ "$actual_object" == "$object" ]] \
        || release_die "pinned supervisor bootstrap object hash mismatch"

    if [[ "$launch_mode" == "exec" ]]; then
        exec /usr/bin/ruby - exec-supervisor \
            "$repo_root" "$source_commit" "$snapshot_temp" "$snapshot_mount" \
            "$worker" "$@" <<< "$launcher_bytes"
    fi
    /usr/bin/ruby - exec-supervisor \
        "$repo_root" "$source_commit" "$snapshot_temp" "$snapshot_mount" \
        "$worker" "$@" <<< "$launcher_bytes"
}

release_recover_temporaries() {
    local repo_root="$1"
    local mounted_snapshot
    local mounted_device
    local recovery_tool="$repo_root/Scripts/release/recover-source-mount.rb"

    if [[ "${ERYLO_RELEASE_LOCK_HELD:-0}" != "1" ]]; then
        /usr/bin/ruby "$repo_root/Scripts/release/fs-helper.rb" run-locked "$repo_root" \
            /bin/bash -c 'source "$1"; release_recover_temporaries "$2"' \
            _ "$repo_root/Scripts/release/lib.sh" "$repo_root" \
            || release_die "could not acquire the repository lock for recovery"
        return
    fi
    release_assert_lock "$repo_root"

    while IFS= read -r mounted_snapshot; do
        [[ -n "$mounted_snapshot" ]] || continue
        release_require_command hdiutil
        [[ -f "$recovery_tool" && -x "$recovery_tool" && ! -L "$recovery_tool" ]] \
            || release_die "source snapshot recovery tool is missing or unsafe"
        mounted_device="$("$recovery_tool" "$repo_root" "$mounted_snapshot")" \
            || release_die "abandoned source snapshot attachment identity is invalid"
        /usr/bin/hdiutil detach -quiet "$mounted_device" \
            || release_die "could not detach an abandoned read-only source snapshot"
    done < <(release_fs_helper "$repo_root" snapshot-mounts)

    release_fs_helper "$repo_root" recover-temporaries \
        || release_die "could not recover abandoned release transactions"
}

release_existing_path() {
    local repo_root="$1"
    local requested="$2"

    release_fs_helper "$repo_root" existing-path "$requested" any \
        || release_die "release input is missing or outside .release: $requested"
}

release_repo_file() {
    local repo_root="$1"
    local requested="$2"
    local source_root="$repo_root"

    if [[ "${ERYLO_RELEASE_SNAPSHOT_ACTIVE:-0}" == "1" ]]; then
        source_root="${ERYLO_RELEASE_SOURCE_ROOT:-}"
        [[ -n "$source_root" ]] || release_die "authenticated release source root is missing"
    fi

    /usr/bin/ruby -ropen3 -e '
        repo = File.realpath(ARGV.fetch(0))
        requested = File.expand_path(ARGV.fetch(1), repo)
        abort("tracked release input may not be a symlink") if File.symlink?(requested)
        candidate = File.realpath(requested)
        prefix = repo + File::SEPARATOR
        abort("release input is outside the repository") unless candidate.start_with?(prefix)
        abort("release input is not a regular file") unless File.file?(candidate)
        if ENV["ERYLO_RELEASE_SNAPSHOT_ACTIVE"] == "1"
          expected_device = ENV.fetch("ERYLO_RELEASE_SOURCE_DEVICE")
          abort("release source filesystem identity changed") unless File.stat(repo).dev.to_s == expected_device
          abort("release source root became writable") unless (File.stat(repo).mode & 0o222).zero?
          abort("tracked release input became writable") unless (File.stat(candidate).mode & 0o222).zero?
          commit = ENV.fetch("ERYLO_RELEASE_SOURCE_COMMIT")
          relative = candidate.delete_prefix(prefix)
          listing, listing_error, listing_status = Open3.capture3(
            "/usr/bin/git", "-C", ARGV.fetch(2), "ls-tree", "-z", commit, "--", relative,
            binmode: true
          )
          match = /\A(100644|100755) blob ([0-9a-f]{40,64})\t([^\0]+)\0\z/.match(listing)
          abort(listing_error) unless listing_status.success?
          abort("tracked release input is not one pinned regular Git object") unless match && match[3] == relative
          pinned, pinned_error, pinned_status = Open3.capture3(
            "/usr/bin/git", "-C", ARGV.fetch(2), "cat-file", "blob", match[2],
            binmode: true
          )
          abort(pinned_error) unless pinned_status.success?
          abort("tracked release input bytes differ from the pinned Git object") unless File.binread(candidate) == pinned
        end
        puts candidate
    ' "$source_root" "$requested" "$repo_root" || release_die "invalid repository release input: $requested"
}

release_validated_source_root() {
    local repo_root="$1"
    local source_commit
    local source_tree

    if [[ "${ERYLO_RELEASE_SNAPSHOT_ACTIVE:-0}" != "1" ]]; then
        [[ -z "${ERYLO_RELEASE_SOURCE_ROOT:-}" ]] \
            || release_die "ambient release source root is not permitted outside an authenticated snapshot"
        printf '%s\n' "$repo_root"
        return
    fi

    source_commit="$(release_source_commit "$repo_root")"
    source_tree="$(release_source_tree "$repo_root")"
    release_assert_source_snapshot "$repo_root" "$source_commit" "$source_tree"
    printf '%s\n' "${ERYLO_RELEASE_SOURCE_ROOT}"
}

release_source_commit() {
    local repo_root="$1"
    local commit="${ERYLO_RELEASE_SOURCE_COMMIT:-}"

    if [[ -z "$commit" ]]; then
        commit="$(release_system_git -C "$repo_root" rev-parse --verify HEAD)"
    fi
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || release_die "release source commit is invalid"
    printf '%s\n' "$commit"
}

release_source_tree() {
    local repo_root="$1"
    local tree="${ERYLO_RELEASE_SOURCE_TREE:-}"

    if [[ -z "$tree" ]]; then
        tree="$(release_system_git -C "$repo_root" rev-parse --verify HEAD^{tree})"
    fi
    [[ "$tree" =~ ^[0-9a-f]{40}$ ]] || release_die "release source tree is invalid"
    printf '%s\n' "$tree"
}

release_source_epoch() {
    local repo_root="$1"
    local epoch="${ERYLO_RELEASE_SOURCE_EPOCH:-}"

    if [[ -z "$epoch" ]]; then
        epoch="$(release_system_git -C "$repo_root" show -s --format=%ct HEAD)"
    fi
    [[ "$epoch" =~ ^[0-9]{9,12}$ && "$epoch" -ge 315532800 ]] \
        || release_die "release source epoch is invalid"
    printf '%s\n' "$epoch"
}

release_snapshot_manifest_sha256() {
    local source_root="$1"

    /usr/bin/ruby -rdigest -rfind -e '
        root = File.realpath(ARGV.fetch(0))
        digest = Digest::SHA256.new
        entries = []
        Find.find(root) do |path|
          relative = path == root ? "." : path.delete_prefix(root + File::SEPARATOR)
          stat = File.lstat(path)
          case stat.ftype
          when "directory"
            abort("source snapshot directory is writable") unless (stat.mode & 0o222).zero?
            entries << [relative, "directory", stat.mode & 0o777, ""]
          when "file"
            abort("source snapshot file is writable") unless (stat.mode & 0o222).zero?
            entries << [relative, "file", stat.mode & 0o777, Digest::SHA256.file(path).hexdigest]
          when "link"
            target = File.readlink(path)
            resolved = File.realpath(path)
            abort("source snapshot symlink escapes its root") unless resolved.start_with?(root + File::SEPARATOR)
            entries << [relative, "link", 0, target]
          else
            abort("source snapshot contains an unsupported entry")
          end
        end
        entries.sort.each { |entry| digest << entry.join("\0") << "\0" }
        puts digest.hexdigest
    ' "$source_root" || release_die "could not validate immutable source snapshot"
}

release_run_pinned_git_ruby() {
    local repo_root="$1"
    local expected_commit="$2"
    local script_path="$3"
    shift 3
    local listing
    local object
    local script_bytes
    local actual_object

    [[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] \
        || release_die "pinned release script commit is invalid"
    [[ "$script_path" =~ ^[A-Za-z0-9._/-]+$ \
        && "$script_path" != /* \
        && "$script_path" != *".."* ]] \
        || release_die "pinned release script path is invalid"
    listing="$(release_system_git -C "$repo_root" ls-tree "$expected_commit" -- "$script_path")" \
        || release_die "could not inspect pinned release script: $script_path"
    if [[ "$listing" =~ ^100755\ blob\ ([0-9a-f]+)$'\t'(.+)$ \
        && "${BASH_REMATCH[2]}" == "$script_path" ]]; then
        object="${BASH_REMATCH[1]}"
    else
        release_die "pinned release script is missing or non-executable: $script_path"
    fi
    script_bytes="$(release_system_git -C "$repo_root" cat-file blob "$object")" \
        || release_die "could not read pinned release script: $script_path"
    actual_object="$(printf '%s\n' "$script_bytes" | \
        release_system_git -C "$repo_root" hash-object --stdin)" \
        || release_die "could not hash pinned release script: $script_path"
    [[ "$actual_object" == "$object" ]] \
        || release_die "pinned release script object hash mismatch: $script_path"
    printf '%s\n' "$script_bytes" | \
        /usr/bin/env -u DEVELOPER_DIR /usr/bin/ruby - "$@"
}

release_verify_source_tree() {
    local repo_root="$1"
    local expected_commit="$2"
    local source_root="$3"

    release_run_pinned_git_ruby \
        "$repo_root" "$expected_commit" Scripts/release/verify-source-tree.rb \
        "$repo_root" "$expected_commit" "$source_root" \
        || release_die "read-only source snapshot does not match the pinned Git objects"
}

release_authenticate_source_mount() {
    local repo_root="$1"
    local expected_commit="$2"
    local source_root="$3"

    release_run_pinned_git_ruby \
        "$repo_root" "$expected_commit" Scripts/release/recover-source-mount.rb \
        "$repo_root" "$source_root" "$expected_commit" \
        || release_die "release source is not the authenticated read-only APFS image"
}

release_assert_source_snapshot() {
    local repo_root="$1"
    local expected_commit="$2"
    local expected_tree="$3"
    local source_root="${ERYLO_RELEASE_SOURCE_ROOT:-}"
    local snapshot_temp="${ERYLO_RELEASE_SNAPSHOT_TEMP:-}"
    local source_image="${ERYLO_RELEASE_SOURCE_IMAGE:-}"
    local attached_device
    local actual_commit
    local actual_tree

    [[ -n "$source_root" && -d "$source_root" && ! -L "$source_root" ]] \
        || release_die "immutable release source snapshot is missing"
    [[ -n "$snapshot_temp" \
        && "$source_root" == "$snapshot_temp/mount" \
        && "$source_image" == "$snapshot_temp/source.dmg" ]] \
        || release_die "release source snapshot paths are not one managed transaction"
    attached_device="$(release_authenticate_source_mount \
        "$repo_root" "$expected_commit" "$source_root")"
    [[ "$attached_device" == "${ERYLO_RELEASE_SOURCE_DISK_DEVICE:-}" ]] \
        || release_die "release source attachment identity changed"
    [[ "$(/usr/bin/stat -f '%d' "$source_root")" == "${ERYLO_RELEASE_SOURCE_DEVICE:-}" ]] \
        || release_die "release source filesystem identity changed"
    [[ "$(/usr/bin/shasum -a 256 "$source_image" | /usr/bin/awk '{print $1}')" \
        == "${ERYLO_RELEASE_SOURCE_IMAGE_SHA256:-}" ]] \
        || release_die "release source image changed during release"
    actual_commit="$(release_system_git -C "$repo_root" rev-parse --verify HEAD)"
    actual_tree="$(release_system_git -C "$repo_root" rev-parse --verify HEAD^{tree})"
    [[ "$actual_commit" == "$expected_commit" && "$actual_tree" == "$expected_tree" ]] \
        || release_die "live source commit changed during release"
    [[ -z "$(release_system_git -C "$repo_root" status --porcelain=v1 --untracked-files=normal)" ]] \
        || release_die "live worktree changed during release; no artifacts were published"
    [[ "$(release_verify_source_tree "$repo_root" "$expected_commit" "$source_root")" \
        == "${ERYLO_RELEASE_SNAPSHOT_MANIFEST_SHA256:-}" ]] \
        || release_die "release snapshot manifest no longer matches the pinned commit"
}

release_assert_compiler_inputs() {
    local repo_root="$1"
    local expected_commit="$2"
    local expected_tree="$3"
    local manifest_input="${4:-.release/build/arm64/release/CompilerInputs.json}"
    local audit_tool
    local manifest

    audit_tool="$(release_repo_file "$repo_root" "Scripts/release/compiler-input-audit.rb")"
    manifest="$(release_existing_path "$repo_root" "$manifest_input")"
    "$audit_tool" validate "$repo_root" "$expected_commit" "$expected_tree" "$manifest" \
        || release_die "compiler inputs are not bound to the pinned Git content"
}

release_metadata_value() {
    local metadata_file="$1"
    local key="$2"
    local value

    value="$({
        /usr/bin/awk -F= -v wanted="$key" '
            $0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/ { next }
            $1 == wanted { count += 1; print substr($0, length($1) + 2) }
            END { if (count != 1) exit 2 }
        ' "$metadata_file"
    } || true)"
    [[ -n "$value" ]] || release_die "metadata key is missing, duplicated, or empty: $key"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || release_die "metadata value contains a line break: $key"
    printf '%s\n' "$value"
}

release_git_metadata_value() {
    local repo_root="$1"
    local source_commit="$2"
    local key="$3"
    local value

    value="$(
        release_system_git -C "$repo_root" cat-file blob \
            "$source_commit:Config/ReleaseVersion.env" | \
            /usr/bin/awk -F= -v wanted="$key" '
                $0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/ { next }
                $1 == wanted { count += 1; print substr($0, length($1) + 2) }
                END { if (count != 1) exit 2 }
            '
    )" || release_die "could not read pinned release metadata: $key"
    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
        || release_die "pinned release metadata is invalid: $key"
    printf '%s\n' "$value"
}

release_plist_value() {
    local plist="$1"
    local key="$2"
    local value

    # Older plutil versions write missing-key diagnostics to stdout. Capture
    # first and emit only after a successful extraction so optional keys cannot
    # be mistaken for configured metadata.
    if ! value="$(/usr/bin/plutil -extract "$key" raw -o - "$plist" 2>/dev/null)"; then
        return 1
    fi
    printf '%s\n' "$value"
}

release_validate_feed_url() {
    local feed_url="$1"

    /usr/bin/ruby -ruri -e '
        raw = ARGV.fetch(0)
        abort("feed URL must be canonical ASCII") unless raw.ascii_only? && !raw.match?(/[[:space:][:cntrl:]]/)
        match = /\Ahttps:\/\/([^\/?#]+)(\/[^?#]*)?\z/.match(raw)
        abort("feed URL must use canonical lowercase HTTPS") unless match

        authority = match[1]
        path = match[2].to_s
        abort("feed authority may not contain userinfo") if authority.include?("@")
        abort("feed authority may not contain an explicit port") if authority.include?(":")
        abort("feed authority may not contain percent encoding") if authority.include?("%")
        abort("feed path has noncanonical percent encoding") if path.gsub(/%[0-9A-F]{2}/, "").include?("%")

        url = URI.parse(raw)
        host = url.host.to_s.downcase
        abort("feed URL must use canonical lowercase HTTPS") unless url.is_a?(URI::HTTPS) && url.scheme == "https"
        abort("feed URL serialization is noncanonical") unless url.to_s == raw
        abort("feed host is missing or noncanonical") unless authority.downcase == host
        abort("feed host is a placeholder") if host.empty? || host.end_with?(".invalid") || host.include?("example")
        abort("feed host is local or special-use") if host == "localhost" || host.end_with?(".localhost") || host.end_with?(".local")
        abort("feed URL may not contain userinfo") unless url.userinfo.nil?
        abort("feed URL may not contain a query") unless url.query.nil?
        abort("feed URL may not contain a fragment") unless url.fragment.nil?

        labels = host.split(".", -1)
        valid_label = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
        abort("feed host is not a canonical DNS FQDN") if labels.length < 2 || labels.last !~ /[a-z]/
        abort("feed host is missing or noncanonical") if host.bytesize > 253 || labels.any? { |label| label.start_with?("xn--") || !valid_label.match?(label) }
    ' "$feed_url"
}

release_validate_public_key() {
    local public_key="$1"

    /usr/bin/ruby -rbase64 -e '
        key = ARGV.fetch(0)
        normalized = key.downcase
        abort("public key contains a placeholder") if ["placeholder", "replace_me", "replace-me", "todo"].any? { |token| normalized.include?(token) }
        decoded = Base64.strict_decode64(key)
        abort("public key must decode to 32 bytes") unless decoded.bytesize == 32
        abort("public key Base64 is noncanonical") unless Base64.strict_encode64(decoded) == key
    ' "$public_key"
}

release_validate_signed_appcast_metadata() {
    local feed_url="$1"
    local public_key="$2"
    local signed_feed="$3"
    local verify_before_extraction="$4"

    [[ "$signed_feed" == "true" && "$verify_before_extraction" == "true" ]] \
        || release_die "appcast config must require a signed feed and pre-extraction verification"
    release_validate_feed_url "$feed_url" || release_die "appcast feed URL is invalid"
    release_validate_public_key "$public_key" \
        || release_die "appcast public key is invalid or noncanonical"
}

release_submission_archive_path() {
    local marketing_version="$1"
    local build_version="$2"
    local source_commit="${3:-}"
    local commit_component=""

    [[ "$marketing_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || release_die "invalid submission marketing version"
    [[ "$build_version" =~ ^[1-9][0-9]{0,17}$ ]] || release_die "invalid submission build version"
    if [[ -n "$source_commit" ]]; then
        [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || release_die "invalid submission source commit"
        commit_component="-${source_commit:0:12}"
    fi
    printf '.release/notarization/submissions/Erylo-%s-%s%s-arm64-submission.zip\n' \
        "$marketing_version" "$build_version" "$commit_component"
}

release_validate_publishable_artifacts() {
    local repo_root="$1"
    local marketing_version="$2"
    local build_version="$3"
    local state="$4"
    local artifacts_input="${5:-.release/artifacts}"
    local source_commit="${6:-}"
    local source_tree="${7:-}"
    local appcast_hash="${8:-}"
    local toolchain_hash="${9:-}"

    if [[ -n "$source_commit" || -n "$source_tree" || -n "$appcast_hash" || -n "$toolchain_hash" ]]; then
        release_fs_helper "$repo_root" validate-set \
            "$artifacts_input" "$marketing_version" "$build_version" "$state" \
            "$source_commit" "$source_tree" "$appcast_hash" "$toolchain_hash" \
            || release_die "publishable artifact boundary validation failed"
    else
        release_fs_helper "$repo_root" validate-set \
            "$artifacts_input" "$marketing_version" "$build_version" "$state" \
            || release_die "publishable artifact boundary validation failed"
    fi
}

release_validate_private_artifacts() {
    local repo_root="$1"
    local private_input="$2"
    local marketing_version="$3"
    local build_version="$4"
    local source_commit="$5"
    local source_tree="$6"
    local appcast_hash="$7"
    local toolchain_hash="$8"

    release_fs_helper "$repo_root" validate-private-set \
        "$private_input" "$marketing_version" "$build_version" \
        "$source_commit" "$source_tree" "$appcast_hash" "$toolchain_hash" \
        || release_die "private release artifact boundary validation failed"
}

release_publish_private_artifacts() {
    local repo_root="$1"
    local private_input="$2"
    local marketing_version="$3"
    local build_version="$4"
    local source_commit="$5"
    local source_tree="$6"
    local appcast_hash="$7"
    local toolchain_hash="$8"

    release_fs_helper "$repo_root" publish-private-set \
        "$private_input" "$marketing_version" "$build_version" \
        "$source_commit" "$source_tree" "$appcast_hash" "$toolchain_hash" \
        || release_die "immutable private release publication failed"
}

release_prepare_private_artifacts() {
    local repo_root="$1"
    local marketing_version="$2"
    local build_version="$3"

    release_remove_path "$repo_root" \
        ".release/private/Erylo-${marketing_version}-${build_version}-arm64.dSYM.zip" file
    release_remove_path "$repo_root" ".release/private/SHA256SUMS" file
    release_fs_helper "$repo_root" validate-private-root \
        || release_die "private release root boundary validation failed"
}

release_prepare_publishable_artifacts() {
    local repo_root="$1"
    local marketing_version="$2"
    local build_version="$3"
    local final_archive=".release/artifacts/Erylo-${marketing_version}-${build_version}-arm64.zip"
    local signature_metadata="${final_archive}.sparkle-signature.json"
    local checksums=".release/artifacts/SHA256SUMS"
    local legacy_submission=".release/artifacts/Erylo-${marketing_version}-${build_version}-arm64-submission.zip"

    [[ "$marketing_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || release_die "invalid publishable marketing version"
    [[ "$build_version" =~ ^[1-9][0-9]{0,17}$ ]] || release_die "invalid publishable build version"
    release_remove_path "$repo_root" "$final_archive" file
    release_remove_path "$repo_root" "$signature_metadata" file
    release_remove_path "$repo_root" "$checksums" file
    release_remove_path "$repo_root" "$legacy_submission" file
    release_validate_publishable_root "$repo_root"
}

release_validate_publishable_root() {
    local repo_root="$1"
    local expected_marketing_version="${2:-}"
    local expected_build_version="${3:-}"
    if [[ -n "$expected_marketing_version" || -n "$expected_build_version" ]]; then
        release_fs_helper "$repo_root" validate-root \
            "$expected_marketing_version" "$expected_build_version" \
            || release_die "publishable root boundary validation failed"
    else
        release_fs_helper "$repo_root" validate-root \
            || release_die "publishable root boundary validation failed"
    fi
}

release_publish_artifact_directory() {
    local repo_root="$1"
    local source_input="$2"
    local marketing_version="$3"
    local build_version="$4"
    local failure_injection="${5:-none}"
    local source_commit="${6:-}"
    local source_tree="${7:-}"
    local appcast_hash="${8:-}"
    local toolchain_hash="${9:-}"
    local archive_identity="${10:-}"
    local signature_identity="${11:-}"
    local checksum_identity="${12:-}"
    if [[ -n "$source_commit" || -n "$source_tree" || -n "$appcast_hash" || -n "$toolchain_hash" ]]; then
        release_fs_helper "$repo_root" swap-current \
            "$source_input" "$marketing_version" "$build_version" "$failure_injection" \
            "$source_commit" "$source_tree" "$appcast_hash" "$toolchain_hash" \
            "$archive_identity" "$signature_identity" "$checksum_identity" \
            || release_die "complete publication directory transaction failed"
    else
        release_fs_helper "$repo_root" swap-current \
            "$source_input" "$marketing_version" "$build_version" "$failure_injection" \
            || release_die "complete publication directory transaction failed"
    fi
}

release_publish_file() {
    local repo_root="$1"
    local source_input="$2"
    local destination_input="$3"
    release_fs_helper "$repo_root" publish-file "$source_input" "$destination_input" \
        || release_die "could not publish staged file safely"
}

release_publish_directory() {
    local repo_root="$1"
    local source_input="$2"
    local destination_input="$3"

    release_fs_helper "$repo_root" publish-directory "$source_input" "$destination_input" \
        || release_die "could not publish staged directory safely"
}

release_make_temp_dir() {
    local repo_root="$1"
    local label="$2"
    release_fs_helper "$repo_root" make-temp "$label" \
        || release_die "could not create a release temporary directory"
}

release_make_directory() {
    local repo_root="$1"
    local directory_input="$2"

    release_fs_helper "$repo_root" make-directory "$directory_input" \
        || release_die "could not create anchored release directory: $directory_input"
}

release_file_identity() {
    local repo_root="$1"
    local file_input="$2"

    release_fs_helper "$repo_root" file-identity "$file_input" \
        || release_die "release file is unsafe or changed while hashing: $file_input"
}

release_seal_file() {
    local repo_root="$1"
    local file_input="$2"
    local mode="${3:-0400}"

    release_fs_helper "$repo_root" seal-file "$file_input" "$mode" \
        || release_die "release file could not be sealed safely: $file_input"
}

release_assert_file_identity() {
    local repo_root="$1"
    local file_input="$2"
    local expected_identity="$3"

    release_fs_helper "$repo_root" assert-identity "$file_input" "$expected_identity" \
        || release_die "release file identity changed: $file_input"
}

release_remove_path() {
    local repo_root="$1"
    local requested="$2"
    local removal_kind="${3:-any}"
    release_fs_helper "$repo_root" remove "$requested" "$removal_kind" \
        || release_die "unsafe release removal path: $requested"
}

release_configure_developer_dir() {
    local require_full="${1:-0}"
    local developer_path="${DEVELOPER_DIR:-}"
    local canonical_path

    if [[ -z "$developer_path" ]]; then
        developer_path="$(/usr/bin/xcode-select -p 2>/dev/null)" \
            || release_die "an Apple developer toolchain is required"
    fi
    [[ "$developer_path" == /* && -d "$developer_path" && ! -L "$developer_path" ]] \
        || release_die "selected developer directory is missing or noncanonical"
    canonical_path="$(/usr/bin/ruby -e 'puts File.realpath(ARGV.fetch(0))' "$developer_path")" \
        || release_die "could not resolve the selected developer directory"
    if [[ "$require_full" == "1" ]]; then
        case "$canonical_path" in
            *.app/Contents/Developer) ;;
            *) release_die "full Xcode is required; Command Line Tools alone are insufficient" ;;
        esac
    fi
    if [[ -n "${ERYLO_RELEASE_DEVELOPER_DIR:-}" \
        && "$canonical_path" != "$ERYLO_RELEASE_DEVELOPER_DIR" ]]; then
        release_die "selected developer directory changed during release"
    fi
    export DEVELOPER_DIR="$canonical_path"
}

release_current_toolchain_json() {
    local require_full="${1:-0}"
    local hash_tools="${2:-1}"
    local xcode_version="CommandLineTools"
    local xcode_build_version
    local xcode_output=""
    local sdk_version
    local sdk_build_version
    local sdk_path
    local swift_version
    local tool
    local tool_path
    local arguments=()

    release_configure_developer_dir "$require_full"
    if [[ "$require_full" == "1" ]]; then
        # Authenticate the selected application entirely with pinned system
        # tools before asking xcrun to resolve or execute any of its contents.
        release_verify_xcode_application "${DEVELOPER_DIR%/Contents/Developer}"
    fi
    DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun --find swiftc >/dev/null 2>&1 \
        || release_die "selected developer directory does not provide swiftc"
    if [[ "$require_full" == "1" ]]; then
        DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1 \
            || release_die "selected Xcode does not provide xcodebuild"
    fi
    if xcode_output="$(DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun xcodebuild -version 2>/dev/null)"; then
        xcode_version="$(printf '%s\n' "$xcode_output" | /usr/bin/sed -nE 's/^Xcode (.+)$/\1/p')"
        xcode_build_version="$(printf '%s\n' "$xcode_output" | /usr/bin/sed -nE 's/^Build version (.+)$/\1/p')"
        [[ -n "$xcode_version" && -n "$xcode_build_version" ]] \
            || release_die "selected Xcode version output is noncanonical"
    else
        [[ "$require_full" == "0" ]] || release_die "selected Xcode does not report its version"
        xcode_build_version="$({
            /usr/sbin/pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null | \
                /usr/bin/awk -F': ' '$1 == "version" { print $2 }'
        } || true)"
        [[ -n "$xcode_build_version" ]] || xcode_build_version="unavailable"
    fi
    sdk_version="$(DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun --sdk macosx --show-sdk-version)" \
        || release_die "selected toolchain does not report the macOS SDK version"
    sdk_build_version="$(DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun --sdk macosx --show-sdk-build-version)" \
        || release_die "selected toolchain does not report the macOS SDK build version"
    sdk_path="$(DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun --sdk macosx --show-sdk-path)" \
        || release_die "selected toolchain does not report the macOS SDK path"
    swift_version="$(DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun swiftc --version 2>&1)" \
        || release_die "selected toolchain does not report the Swift compiler version"
    arguments=(
        "$require_full" "$hash_tools" "$DEVELOPER_DIR" "$xcode_version" "$xcode_build_version"
        "$sdk_version" "$sdk_build_version" "$sdk_path" "$swift_version"
    )
    for tool in swift swiftc swift-frontend install_name_tool lipo otool dsymutil dwarfdump notarytool stapler; do
        tool_path="$(DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun --find "$tool")" \
            || release_die "selected developer directory does not provide $tool"
        arguments+=("$tool" "$tool_path")
    done
    /usr/bin/ruby -rdigest -rjson -e '
      require_full, hash_tools, developer, xcode_version, xcode_build, sdk_version,
        sdk_build, sdk_path, swift_version, *tool_pairs = ARGV
      developer = File.realpath(developer)
      prefix = developer + File::SEPARATOR
      canonical_sdk = File.realpath(sdk_path)
      abort("selected SDK is outside the developer directory") unless canonical_sdk.start_with?(prefix)
      tools = {}
      tool_pairs.each_slice(2) do |name, path|
        canonical = File.realpath(path)
        abort("developer tool is outside the selected directory: #{name}") unless canonical.start_with?(prefix)
        stat = File.stat(canonical)
        abort("developer tool is not one executable regular file: #{name}") \
          unless stat.file? && stat.executable?
        tools[name] = {
          "path" => canonical.delete_prefix(prefix),
          "sha256" => hash_tools == "1" ? Digest::SHA256.file(canonical).hexdigest : "SKIPPED"
        }
      end
      payload = {
        "kind" => require_full == "1" ? "Xcode" : (xcode_version == "CommandLineTools" ? "CommandLineTools" : "Xcode"),
        "xcodeVersion" => xcode_version,
        "xcodeBuildVersion" => xcode_build,
        "macOSSDKVersion" => sdk_version,
        "macOSSDKBuildVersion" => sdk_build,
        "macOSSDKPath" => canonical_sdk.delete_prefix(prefix),
        "swiftCompilerVersion" => swift_version,
        "tools" => tools.sort.to_h
      }
      print JSON.generate(payload)
    ' "${arguments[@]}" || release_die "could not capture the selected toolchain identity"
}

release_capture_toolchain() {
    local require_full="${1:-1}"
    local identity
    local identity_sha256

    release_configure_developer_dir "$require_full"
    identity="$(release_current_toolchain_json "$require_full")" \
        || release_die "could not capture the selected toolchain identity"
    identity_sha256="$(printf '%s\n' "$identity" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
    [[ "$identity_sha256" =~ ^[0-9a-f]{64}$ ]] \
        || release_die "selected toolchain identity hash is invalid"
    export ERYLO_RELEASE_DEVELOPER_DIR="$DEVELOPER_DIR"
    export ERYLO_RELEASE_TOOLCHAIN_JSON="$identity"
    export ERYLO_RELEASE_TOOLCHAIN_SHA256="$identity_sha256"
}

release_assert_toolchain() {
    local mode="${1:-quick}"
    local expected_identity="${ERYLO_RELEASE_TOOLCHAIN_JSON:-}"
    local expected_sha256="${ERYLO_RELEASE_TOOLCHAIN_SHA256:-}"
    local require_full=0
    local actual_identity
    local actual_sha256
    local expected_comparison

    [[ -n "$expected_identity" && "$expected_sha256" =~ ^[0-9a-f]{64}$ \
        && -n "${ERYLO_RELEASE_DEVELOPER_DIR:-}" ]] \
        || release_die "pinned release toolchain identity is missing"
    if [[ "$expected_identity" == *'"kind":"Xcode"'* ]]; then
        require_full=1
    fi
    [[ "$mode" == "quick" || "$mode" == "full" ]] || release_die "invalid toolchain assertion mode"
    if [[ "$mode" == "full" ]]; then
        actual_identity="$(release_current_toolchain_json "$require_full" 1)" \
            || release_die "could not revalidate the selected toolchain identity"
        expected_comparison="$expected_identity"
    else
        actual_identity="$(release_current_toolchain_json "$require_full" 0)" \
            || release_die "could not revalidate the selected toolchain identity"
        expected_comparison="$(/usr/bin/ruby -rjson -e '
          payload = JSON.parse(ARGV.fetch(0))
          payload.fetch("tools").each_value { |tool| tool["sha256"] = "SKIPPED" }
          print JSON.generate(payload)
        ' "$expected_identity")" || release_die "pinned toolchain identity is invalid"
    fi
    actual_sha256="$(printf '%s\n' "$actual_identity" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
    [[ "$actual_identity" == "$expected_comparison" ]] \
        || release_die "selected Xcode, SDK, or compiler identity changed during release"
    if [[ "$mode" == "full" ]]; then
        [[ "$actual_sha256" == "$expected_sha256" ]] \
            || release_die "selected Xcode, SDK, or compiler content hash changed during release"
    fi
}

release_developer_tool_path() {
    local tool="$1"
    local path

    [[ "$tool" =~ ^[A-Za-z0-9_-]+$ ]] || release_die "invalid developer tool name"
    if [[ -z "${ERYLO_RELEASE_TOOLCHAIN_JSON:-}" ]]; then
        release_configure_developer_dir 0
    else
        [[ "${DEVELOPER_DIR:-}" == "${ERYLO_RELEASE_DEVELOPER_DIR:-}" ]] \
            || release_die "selected developer directory changed during release"
    fi
    path="$(DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun --find "$tool")" \
        || release_die "selected developer directory does not provide $tool"
    [[ "$path" == /* && -x "$path" ]] || release_die "resolved developer tool is unsafe: $tool"
    printf '%s\n' "$path"
}

release_build_swift_product() {
    local swift_tool="$1"
    local source_root="$2"
    local scratch_path="$3"
    local product="$4"
    local triple="$5"
    shift 5
    local build_arguments

    [[ "$swift_tool" == /* && -x "$swift_tool" ]] \
        || release_die "release Swift tool path is unsafe"
    [[ "$source_root" == /* && -d "$source_root" && ! -L "$source_root" ]] \
        || release_die "release Swift source root is unsafe"
    [[ "$scratch_path" == /* && ! -L "$scratch_path" ]] \
        || release_die "release Swift scratch path is unsafe"
    [[ "$product" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] \
        || release_die "release Swift product is invalid"
    [[ "$triple" =~ ^arm64-apple-macosx[0-9]+\.[0-9]+$ ]] \
        || release_die "release Swift target triple is invalid"
    build_arguments=(
        --package-path "$source_root"
        --scratch-path "$scratch_path"
        --configuration release
        --product "$product"
        --triple "$triple"
        --disable-index-store
        -Xswiftc -warnings-as-errors
    )
    if [[ "$#" -gt 0 ]]; then
        /usr/bin/env "$@" "$swift_tool" build "${build_arguments[@]}"
        release_swift_product_bin_path="$(
            /usr/bin/env "$@" "$swift_tool" build "${build_arguments[@]}" --show-bin-path
        )"
    else
        "$swift_tool" build "${build_arguments[@]}"
        release_swift_product_bin_path="$(
            "$swift_tool" build "${build_arguments[@]}" --show-bin-path
        )"
    fi
    [[ "$release_swift_product_bin_path" == "$scratch_path"/* \
        && -d "$release_swift_product_bin_path" \
        && ! -L "$release_swift_product_bin_path" ]] \
        || release_die "release Swift product directory is unsafe"
}

release_xcrun() {
    if [[ -n "${ERYLO_RELEASE_TOOLCHAIN_JSON:-}" ]]; then
        [[ "${DEVELOPER_DIR:-}" == "${ERYLO_RELEASE_DEVELOPER_DIR:-}" ]] \
            || release_die "selected developer directory changed during release"
    else
        release_configure_developer_dir 0
    fi
    DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun "$@"
}

release_require_full_xcode() {
    # Full-Xcode shape and Apple authenticity are mandatory regardless of any
    # inherited JSON claim. Both checks precede selected xcrun/tool execution.
    release_configure_developer_dir 1
    release_verify_xcode_application "${DEVELOPER_DIR%/Contents/Developer}"
    if [[ -n "${ERYLO_RELEASE_TOOLCHAIN_JSON:-}" ]]; then
        release_assert_toolchain
    else
        release_capture_toolchain 1
    fi
}

release_validate_reviewed_toolchain_policy() {
    local policy="$1"
    local identity_json="$2"

    /usr/bin/ruby -rdigest -rjson -e '
      policy_text, identity_text = ARGV
      policy = {}
      policy_text.each_line do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")
        match = /\A([A-Z][A-Z0-9_]*)=(.*)\z/.match(line)
        abort("reviewed toolchain policy line is invalid") unless match && !match[2].empty?
        abort("reviewed toolchain policy key is duplicated") if policy.key?(match[1])
        policy[match[1]] = match[2]
      end
      expected_keys = %w[
        MACOS_SDK_BUILD_VERSION MACOS_SDK_VERSION SWIFT_COMPILER_VERSION_SHA256
        XCODE_BUILD_VERSION XCODE_VERSION
      ]
      abort("reviewed toolchain policy fields are noncanonical") unless policy.keys.sort == expected_keys.sort
      abort("production toolchain policy is UNCONFIRMED") if policy.values.any? { |value| value == "UNCONFIRMED" }
      abort("reviewed Xcode version is invalid") unless /\A[0-9]+(?:\.[0-9]+)*\z/.match?(policy.fetch("XCODE_VERSION"))
      abort("reviewed Xcode build is invalid") unless /\A[A-Za-z0-9._-]+\z/.match?(policy.fetch("XCODE_BUILD_VERSION"))
      abort("reviewed macOS SDK version is invalid") unless /\A[0-9]+(?:\.[0-9]+)*\z/.match?(policy.fetch("MACOS_SDK_VERSION"))
      abort("reviewed macOS SDK build is invalid") unless /\A[A-Za-z0-9._-]+\z/.match?(policy.fetch("MACOS_SDK_BUILD_VERSION"))
      abort("reviewed Swift compiler identity hash is invalid") \
        unless /\A[0-9a-f]{64}\z/.match?(policy.fetch("SWIFT_COMPILER_VERSION_SHA256"))

      identity = JSON.parse(identity_text)
      abort("production toolchain must be full Xcode") unless identity.fetch("kind") == "Xcode"
      actual = {
        "XCODE_VERSION" => identity.fetch("xcodeVersion"),
        "XCODE_BUILD_VERSION" => identity.fetch("xcodeBuildVersion"),
        "MACOS_SDK_VERSION" => identity.fetch("macOSSDKVersion"),
        "MACOS_SDK_BUILD_VERSION" => identity.fetch("macOSSDKBuildVersion"),
        "SWIFT_COMPILER_VERSION_SHA256" => Digest::SHA256.hexdigest(identity.fetch("swiftCompilerVersion"))
      }
      abort("selected Xcode, SDK, or Swift compiler does not match the reviewed release policy") \
        unless actual == policy
    ' "$policy" "$identity_json"
}

release_verify_xcode_application() {
    local xcode_app="$1"
    local signature_details

    [[ "$xcode_app" == /*.app && -d "$xcode_app/Contents/Developer" && ! -L "$xcode_app" ]] \
        || release_die "selected Xcode application path is invalid"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$xcode_app" >/dev/null 2>&1 \
        || release_die "selected Xcode application fails Apple code-signature verification"
    signature_details="$(/usr/bin/codesign -dv --verbose=4 "$xcode_app" 2>&1)" \
        || release_die "selected Xcode application signature identity is unreadable"
    printf '%s\n' "$signature_details" | /usr/bin/grep -Fxq 'Identifier=com.apple.dt.Xcode' \
        || release_die "selected developer application is not Apple Xcode"
    printf '%s\n' "$signature_details" | /usr/bin/grep -Fxq 'TeamIdentifier=59GAB85EFG' \
        || release_die "selected Xcode application has an unexpected signing team"
    printf '%s\n' "$signature_details" | /usr/bin/grep -Fq 'Authority=Apple Code Signing Certification Authority' \
        || release_die "selected Xcode application lacks the Apple signing chain"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$xcode_app" >/dev/null 2>&1 \
        || release_die "selected Xcode application fails system policy assessment"
}

release_require_reviewed_toolchain() {
    local repo_root="$1"
    local source_commit="$2"
    local policy
    local policy_sha256
    local xcode_app

    [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || release_die "reviewed toolchain source commit is invalid"
    [[ -n "${ERYLO_RELEASE_TOOLCHAIN_JSON:-}" ]] || release_die "selected toolchain identity is missing"
    policy="$(release_system_git -C "$repo_root" cat-file blob \
        "$source_commit:Config/ReleaseToolchain.env")" \
        || release_die "could not read the commit-pinned reviewed toolchain policy"
    release_validate_reviewed_toolchain_policy "$policy" "$ERYLO_RELEASE_TOOLCHAIN_JSON" \
        || release_die "selected toolchain is not approved for production release"
    policy_sha256="$(printf '%s\n' "$policy" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
    [[ "$policy_sha256" =~ ^[0-9a-f]{64}$ ]] || release_die "reviewed toolchain policy hash is invalid"
    if [[ -n "${ERYLO_RELEASE_TOOLCHAIN_POLICY_SHA256:-}" \
        && "$policy_sha256" != "$ERYLO_RELEASE_TOOLCHAIN_POLICY_SHA256" ]]; then
        release_die "reviewed toolchain policy changed during release"
    fi
    [[ "${DEVELOPER_DIR:-}" == *.app/Contents/Developer ]] \
        || release_die "reviewed production toolchain is not full Xcode"
    xcode_app="${DEVELOPER_DIR%/Contents/Developer}"
    release_verify_xcode_application "$xcode_app"
    export ERYLO_RELEASE_TOOLCHAIN_POLICY_SHA256="$policy_sha256"
}

release_require_notary_tools() {
    release_require_full_xcode
    release_xcrun --find notarytool >/dev/null 2>&1 \
        || release_die "selected Xcode does not provide notarytool"
    release_xcrun --find stapler >/dev/null 2>&1 \
        || release_die "selected Xcode does not provide stapler"
}
