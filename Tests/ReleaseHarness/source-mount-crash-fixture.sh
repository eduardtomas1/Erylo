#!/usr/bin/env bash

set -euo pipefail

repo_root="$1"
source_root="$2"
source_commit="$3"
crash_stage="$4"
record_file="$5"

cd "$repo_root"
# shellcheck source=Scripts/release/lib.sh
source Scripts/release/lib.sh
release_assert_outer_capability

[[ "$crash_stage" == "after-attach" \
    || "$crash_stage" == "during-worker" \
    || "$crash_stage" == "supervisor-success" \
    || "$crash_stage" == "supervisor-failure" \
    || "$crash_stage" == "supervisor-closure-mutation" ]] \
    || release_die "invalid source mount crash stage"
snapshot_temp="$(release_make_temp_dir "$repo_root" source-snapshot)"
snapshot_mount="$snapshot_temp/mount"
snapshot_image="$snapshot_temp/source.dmg"
release_make_directory "$repo_root" "$snapshot_mount" >/dev/null
/usr/bin/hdiutil create -quiet -fs APFS -format UDRO \
    -volname EryloCrashFixture -srcfolder "$source_root" "$snapshot_image"
/bin/chmod 0400 "$snapshot_image"
snapshot_hash="$(/usr/bin/shasum -a 256 "$snapshot_image" | /usr/bin/awk '{print $1}')"
/usr/bin/ruby -rjson -e '
    payload = {
      "image" => "source.dmg",
      "imageSHA256" => ARGV.fetch(0),
      "mount" => "mount",
      "sourceCommit" => ARGV.fetch(1)
    }
    File.open(ARGV.fetch(2), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
      output.write(JSON.generate(payload) + "\n")
      output.flush
      output.fsync
    end
  ' "$snapshot_hash" "$source_commit" "$snapshot_temp/SourceImage.json"
release_seal_file "$repo_root" "$snapshot_temp/SourceImage.json" 0400 >/dev/null
/usr/bin/hdiutil attach -quiet -readonly -nobrowse \
    -mountpoint "$snapshot_mount" "$snapshot_image"
printf '%s\t%s\n' "$snapshot_temp" "$snapshot_mount" > "$record_file"
case "$crash_stage" in
    during-worker)
        export ERYLO_RELEASE_SOURCE_ROOT="$snapshot_mount"
        release_pinned_supervisor exec \
            "$repo_root" "$source_commit" "$snapshot_temp" "$snapshot_mount" \
            "$snapshot_mount/Scripts/release/release-worker.sh" --hold "$record_file"
        ;;
    supervisor-success|supervisor-failure)
        if [[ "$crash_stage" == "supervisor-success" ]]; then
            worker_result="--success"
        else
            worker_result="--fail"
        fi
        export ERYLO_RELEASE_SOURCE_ROOT="$snapshot_mount"
        release_pinned_supervisor exec \
            "$repo_root" "$source_commit" "$snapshot_temp" "$snapshot_mount" \
            "$snapshot_mount/Scripts/release/release-worker.sh" "$worker_result"
        ;;
    supervisor-closure-mutation)
        closure_marker="${record_file}.b-executed"
        marker_literal="$(/usr/bin/ruby -rjson -e 'print JSON.generate(ARGV.fetch(0))' "$closure_marker")"
        closure_dependencies=(
            fs-helper.rb
            recover-source-mount.rb
            release-worker-supervisor.rb
        )
        restore_closure_dependencies() {
            local dependency
            for dependency in "${closure_dependencies[@]}"; do
                if [[ -f "${record_file}.${dependency}.backup" ]]; then
                    /bin/cp "${record_file}.${dependency}.backup" \
                        "$repo_root/Scripts/release/$dependency"
                    /bin/chmod 0755 "$repo_root/Scripts/release/$dependency"
                    /bin/rm -f -- "${record_file}.${dependency}.backup"
                fi
            done
        }
        trap restore_closure_dependencies EXIT
        for dependency in "${closure_dependencies[@]}"; do
            /bin/cp "$repo_root/Scripts/release/$dependency" \
                "${record_file}.${dependency}.backup"
            printf '#!/usr/bin/env ruby\nFile.write(%s, "B\\n")\nexit 97\n' \
                "$marker_literal" > "$repo_root/Scripts/release/$dependency"
            /bin/chmod 0755 "$repo_root/Scripts/release/$dependency"
        done
        set +e
        export ERYLO_RELEASE_SOURCE_ROOT="$snapshot_mount"
        release_pinned_supervisor run \
            "$repo_root" "$source_commit" "$snapshot_temp" "$snapshot_mount" \
            "$snapshot_mount/Scripts/release/release-worker.sh" --success \
            > "${record_file}.worker"
        closure_status=$?
        set -e
        restore_closure_dependencies
        trap - EXIT
        exit "$closure_status"
        ;;
    after-attach)
        printf 'SOURCE_MOUNT_TEST_READY:%s\n' "$crash_stage" >&2
        /bin/kill -STOP "$$"
        release_die "source mount crash fixture resumed unexpectedly"
        ;;
esac
