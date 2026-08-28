#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
fixture_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/erylo-process-supervisor.XXXXXX")"
test_root="$fixture_root/test-root"
/bin/mkdir -p "$test_root/logs"

ERYLO_RELEASE_HARNESS_BACKGROUND_TIMEOUT_SECONDS=2
ERYLO_RELEASE_HARNESS_READINESS_TIMEOUT_SECONDS=0.08
ERYLO_RELEASE_HARNESS_TERMINATION_GRACE_SECONDS=0.08
ERYLO_RELEASE_HARNESS_MAX_BACKGROUND_ASSERTIONS=2
# shellcheck source=Tests/ReleaseHarness/processes.sh
source Tests/ReleaseHarness/processes.sh
check_count=0
failure_count=0

cleanup_fixture() {
    local status=$?
    trap - EXIT
    cleanup_release_harness_processes
    /bin/chmod -R u+w "$fixture_root" 2>/dev/null || true
    /bin/rm -R "$fixture_root"
    exit "$status"
}
trap cleanup_fixture EXIT

assert() {
    local message="$1"
    shift
    if ! "$@"; then
        printf 'FAIL: %s\n' "$message" >&2
        exit 1
    fi
}

state_field() {
    release_harness_state_field "$1" "$2"
}

process_group_gone() {
    /usr/bin/ruby -e '
      process_group_id = Integer(ARGV.fetch(0), 10)
      begin
        Process.kill(0, -process_group_id)
        exit 1
      rescue Errno::ESRCH
        exit 0
      end
    ' "$1"
}

process_group_alive() {
    /usr/bin/ruby -e '
      process_group_id = Integer(ARGV.fetch(0), 10)
      Process.kill(0, -process_group_id)
    ' "$1"
}

missed_log="$test_root/logs/missed-readiness.log"
missed_diagnostic="$test_root/logs/missed-readiness.diagnostic"
release_harness_start_background missed-readiness 2 \
    /bin/bash -c 'printf "not-ready-yet\n" >&2; /bin/sleep 10' 2>"$missed_log"
missed_pid="$release_harness_background_pid"
missed_state="$release_harness_background_state"
set +e
wait_for_fs_test_pause "$missed_log" "$missed_pid" "$missed_state" missed-readiness \
    2>"$missed_diagnostic"
missed_status=$?
set -e
assert "missed readiness has its distinct failure status" test "$missed_status" = 1
assert "missed readiness emits the exact monotonic timeout classification" \
    /usr/bin/grep -Fq \
    'HARNESS_READINESS_TIMEOUT name=missed-readiness timeout=0.080s' "$missed_diagnostic"
assert "missed readiness cancels and reaps its owned command" \
    test "$(state_field "$missed_state" classification)" = cancelled

trickle_log="$test_root/logs/trickle-readiness.log"
trickle_writer_gate="$test_root/logs/trickle-writer"
trickle_reader_gate="$test_root/logs/trickle-reader"
release_harness_start_background trickle-readiness 2 /bin/bash -c '
    printf "RELEASE_FS_TEST_" >&2
    printf "ready\n" > "$1.ready"
    while [[ ! -e "$1.release" ]]; do /bin/sleep 0.01; done
    printf "READY:trickled\n" >&2
    while [[ ! -e "$1.complete" ]]; do /bin/sleep 0.01; done
  ' _ "$trickle_writer_gate" 2>"$trickle_log"
trickle_pid="$release_harness_background_pid"
trickle_state="$release_harness_background_state"
/usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-log \
    "$trickle_writer_gate.ready" 0.5 ready trickle-writer-prefix
/usr/bin/env ERYLO_RELEASE_SUPERVISOR_TEST_READINESS_GATE="$trickle_reader_gate" \
    /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-ready \
        "$trickle_state" "$trickle_log" "$release_harness_readiness_timeout" \
        '(RELEASE_FS|SOURCE_MOUNT)_TEST_READY:' trickle-readiness &
trickle_reader_pid=$!
/usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-log \
    "$trickle_reader_gate.ready" 0.5 ready trickle-reader-prefix
assert "an incomplete readiness prefix cannot satisfy the observer" \
    /bin/kill -0 "$trickle_reader_pid"
/usr/bin/touch "$trickle_writer_gate.release"
/usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-log \
    "$trickle_log" 0.5 'RELEASE_FS_TEST_READY:trickled' trickle-writer-suffix
/usr/bin/touch "$trickle_reader_gate.release"
wait "$trickle_reader_pid"
/usr/bin/touch "$trickle_writer_gate.complete"
release_harness_wait_status "$trickle_pid"
assert "trickled readiness completes successfully" test "$release_harness_wait_result" = 0
assert "trickled readiness requires the complete marker" \
    /usr/bin/grep -Fq 'RELEASE_FS_TEST_READY:trickled' "$trickle_log"

fast_readiness_failures=0
for fast_readiness_index in {1..75}; do
    fast_log="$test_root/logs/fast-readiness-${fast_readiness_index}.log"
    release_harness_start_background "fast-readiness-${fast_readiness_index}" 2 \
        /bin/bash -c 'printf "RELEASE_FS_TEST_READY:fast\n" >&2' 2>"$fast_log"
    fast_pid="$release_harness_background_pid"
    fast_state="$release_harness_background_state"
    if ! wait_for_fs_test_pause "$fast_log" "$fast_pid" "$fast_state" \
        "fast-readiness-${fast_readiness_index}"; then
        fast_readiness_failures=$((fast_readiness_failures + 1))
        continue
    fi
    release_harness_wait_status "$fast_pid"
    [[ "$release_harness_wait_result" == 0 ]] \
        || fast_readiness_failures=$((fast_readiness_failures + 1))
done
assert "a complete readiness marker wins atomically across 75 immediate exits" \
    test "$fast_readiness_failures" = 0

timeout_log="$test_root/logs/exact-timeout.log"
release_harness_start_background exact-timeout 0.08 \
    /bin/bash -c 'trap "" TERM; /bin/sleep 10' 2>"$timeout_log"
timeout_pid="$release_harness_background_pid"
timeout_state="$release_harness_background_state"
release_harness_wait_status "$timeout_pid"
assert "owned timeout returns the reserved timeout status" test "$release_harness_wait_result" = 124
assert "owned timeout has the exact timeout classification" \
    test "$(state_field "$timeout_state" classification)" = timed_out
assert "stubborn timeout receives the hard-stop signal" \
    test "$(state_field "$timeout_state" termSignal)" = 9
assert "stubborn timeout owner proves its whole process group settled" \
    test "$(state_field "$timeout_state" groupSettled)" = true
assert "timeout diagnostic names the exact owned command" \
    /usr/bin/grep -Fq 'HARNESS_PROCESS_TIMEOUT name=exact-timeout timeout=0.080s' "$timeout_log"

unsettled_state="$test_root/logs/unsettled.json"
unsettled_log="$test_root/logs/unsettled.log"
set +e
/usr/bin/env ERYLO_RELEASE_SUPERVISOR_TEST_FORCE_UNSETTLED=1 \
    /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" run \
    "$unsettled_state" forced-unsettled 0.08 0.08 -- \
    /bin/bash -c 'trap "" TERM; /bin/sleep 10' 2>"$unsettled_log"
unsettled_status=$?
set -e
assert "an unproven post-KILL settlement returns its reserved failure status" \
    test "$unsettled_status" = 74
assert "an unproven post-KILL settlement has a distinct classification" \
    test "$(state_field "$unsettled_state" classification)" = unsettled_descendants
assert "an unproven post-KILL settlement emits its exact diagnostic" \
    /usr/bin/grep -Fq 'HARNESS_UNSETTLED_DESCENDANTS name=forced-unsettled' "$unsettled_log"

prepublication_gate="$test_root/prepublication"
prepublication_state="$test_root/logs/prepublication.json"
prepublication_log="$test_root/logs/prepublication.log"
/usr/bin/env ERYLO_RELEASE_SUPERVISOR_TEST_PREPUBLICATION_GATE="$prepublication_gate" \
    /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" run \
    "$prepublication_state" prepublication-cancellation 2 0.08 -- \
    /bin/bash -c 'trap "" TERM; /bin/sleep 10' 2>"$prepublication_log" &
prepublication_supervisor_pid=$!
/usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-log \
    "$prepublication_gate.ready" 0.5 ready prepublication-gate
prepublication_child_pid="$(<"$prepublication_gate.child")"
assert "prepublication gate freezes ownership before state is visible" \
    test ! -e "$prepublication_state"
/usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" control \
    "$prepublication_state" "$prepublication_supervisor_pid" 0.08 TERM
set +e
wait "$prepublication_supervisor_pid"
prepublication_status=$?
set -e
assert "prepublication cancellation returns the reserved cancellation status" \
    test "$prepublication_status" = 125
assert "prepublication cancellation publishes its exact final classification" \
    test "$(state_field "$prepublication_state" classification)" = cancelled
assert "prepublication cancellation cannot orphan the already spawned child group" \
    /bin/bash -c '! /bin/kill -0 "$1" 2>/dev/null' _ "$prepublication_child_pid"

postspawn_gate="$test_root/postspawn-state-error"
postspawn_state="$test_root/logs/postspawn-state-directory"
postspawn_log="$test_root/logs/postspawn-state-error.log"
/bin/mkdir "$postspawn_state"
/usr/bin/env ERYLO_RELEASE_SUPERVISOR_TEST_PREPUBLICATION_GATE="$postspawn_gate" \
    /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" run \
    "$postspawn_state" postspawn-state-error 2 0.08 -- \
    /bin/bash -c 'trap "" TERM; /bin/sleep 10' 2>"$postspawn_log" &
postspawn_supervisor_pid=$!
/usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-log \
    "$postspawn_gate.ready" 0.5 ready postspawn-state-gate
postspawn_child_pid="$(<"$postspawn_gate.child")"
/usr/bin/touch "$postspawn_gate.release"
set +e
wait "$postspawn_supervisor_pid"
postspawn_status=$?
set -e
assert "a forced post-spawn state-publication error fails the owner" \
    test "$postspawn_status" = 1
assert "post-spawn error cleanup reports whole-group settlement and one direct reap" \
    /usr/bin/grep -Eq \
        'HARNESS_PROCESS_ERROR name=postspawn-state-error .*group_settled=true direct_reaped=true' \
        "$postspawn_log"
assert "post-spawn error cleanup leaves no direct child" \
    /bin/bash -c '! /bin/kill -0 "$1" 2>/dev/null' _ "$postspawn_child_pid"
assert "post-spawn error cleanup leaves no owned process group" \
    process_group_gone "$postspawn_child_pid"

nonsystem_gate="$test_root/postspawn-nonsystem"
nonsystem_state="$test_root/logs/postspawn-nonsystem.json"
nonsystem_log="$test_root/logs/postspawn-nonsystem.log"
/usr/bin/ruby -e '
  gate, supervisor, state_path, name_prefix = ARGV
  ENV["ERYLO_RELEASE_SUPERVISOR_TEST_PREPUBLICATION_GATE"] = gate
  invalid_name = name_prefix.b + "\xFF".b
  exec(
    "/usr/bin/ruby", supervisor, "run", state_path, invalid_name, "2", "0.08", "--",
    "/bin/bash", "-c", "trap \"\" TERM; /bin/sleep 10"
  )
' "$nonsystem_gate" "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" \
    "$nonsystem_state" postspawn-nonsystem- 2>"$nonsystem_log" &
nonsystem_supervisor_pid=$!
/usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-log \
    "$nonsystem_gate.ready" 0.5 ready postspawn-nonsystem-gate
nonsystem_child_pid="$(<"$nonsystem_gate.child")"
assert "non-SystemCall publication failure is gated with its direct child live" \
    /bin/kill -0 "$nonsystem_child_pid"
assert "non-SystemCall publication failure is gated with its owned process group live" \
    process_group_alive "$nonsystem_child_pid"
/usr/bin/touch "$nonsystem_gate.release"
set +e
wait "$nonsystem_supervisor_pid"
nonsystem_status=$?
set -e
assert "non-SystemCall publication failure returns the generic failure status" \
    test "$nonsystem_status" = 1
assert "non-SystemCall failure emits one safe bounded cleanup diagnostic" \
    /bin/bash -c '[[ "$(/usr/bin/grep -Ec "^HARNESS_PROCESS_EXCEPTION " "$1")" == 1 ]] && /usr/bin/grep -Eq '\''^HARNESS_PROCESS_EXCEPTION name="postspawn-nonsystem-\?" error_class="JSON::GeneratorError" error=.* group_settled=true direct_reaped=true$'\'' "$1"' \
    _ "$nonsystem_log"
assert "non-SystemCall failure emits no raw Ruby stack trace" \
    /bin/bash -c '! /usr/bin/grep -Eq "process-supervisor\\.rb:[0-9]+:in" "$1"' \
    _ "$nonsystem_log"
assert "non-SystemCall cleanup leaves no direct child" \
    /bin/bash -c '! /bin/kill -0 "$1" 2>/dev/null' _ "$nonsystem_child_pid"
assert "non-SystemCall cleanup leaves no owned process group" \
    process_group_gone "$nonsystem_child_pid"

nonsystem_unsettled_gate="$test_root/postspawn-nonsystem-unsettled"
nonsystem_unsettled_state="$test_root/logs/postspawn-nonsystem-unsettled.json"
nonsystem_unsettled_log="$test_root/logs/postspawn-nonsystem-unsettled.log"
/usr/bin/env ERYLO_RELEASE_SUPERVISOR_TEST_FORCE_UNSETTLED=1 /usr/bin/ruby -e '
  gate, supervisor, state_path, name_prefix = ARGV
  ENV["ERYLO_RELEASE_SUPERVISOR_TEST_PREPUBLICATION_GATE"] = gate
  invalid_name = name_prefix.b + "\xFF".b
  exec(
    "/usr/bin/ruby", supervisor, "run", state_path, invalid_name, "2", "0.08", "--",
    "/bin/bash", "-c", "trap \"\" TERM; /bin/sleep 10"
  )
' "$nonsystem_unsettled_gate" "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" \
    "$nonsystem_unsettled_state" postspawn-unsettled- 2>"$nonsystem_unsettled_log" &
nonsystem_unsettled_supervisor_pid=$!
/usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-log \
    "$nonsystem_unsettled_gate.ready" 0.5 ready postspawn-nonsystem-unsettled-gate
nonsystem_unsettled_child_pid="$(<"$nonsystem_unsettled_gate.child")"
assert "forced-unsettled publication failure is gated with its direct child live" \
    /bin/kill -0 "$nonsystem_unsettled_child_pid"
assert "forced-unsettled publication failure is gated with its owned process group live" \
    process_group_alive "$nonsystem_unsettled_child_pid"
/usr/bin/touch "$nonsystem_unsettled_gate.release"
set +e
wait "$nonsystem_unsettled_supervisor_pid"
nonsystem_unsettled_status=$?
set -e
assert "unsettled cleanup takes precedence over the original non-SystemCall exception" \
    test "$nonsystem_unsettled_status" = 74
assert "unsettled precedence emits one safe bounded cleanup diagnostic" \
    /bin/bash -c '[[ "$(/usr/bin/grep -Ec "^HARNESS_UNSETTLED_DESCENDANTS " "$1")" == 1 ]] && /usr/bin/grep -Eq '\''^HARNESS_UNSETTLED_DESCENDANTS name="postspawn-unsettled-\?" after=process_exception error_class="JSON::GeneratorError" group_settled=false direct_reaped=true$'\'' "$1"' \
    _ "$nonsystem_unsettled_log"
assert "unsettled precedence emits no raw Ruby stack trace" \
    /bin/bash -c '! /usr/bin/grep -Eq "process-supervisor\\.rb:[0-9]+:in" "$1"' \
    _ "$nonsystem_unsettled_log"
assert "forced-unsettled cleanup still leaves no direct child" \
    /bin/bash -c '! /bin/kill -0 "$1" 2>/dev/null' _ "$nonsystem_unsettled_child_pid"
assert "forced-unsettled cleanup still leaves no owned process group" \
    process_group_gone "$nonsystem_unsettled_child_pid"

ownership_state="$test_root/logs/ownership-error.json"
ownership_log="$test_root/logs/ownership-error.log"
set +e
/usr/bin/env ERYLO_RELEASE_SUPERVISOR_TEST_FORCE_ECHILD=1 \
    /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" run \
    "$ownership_state" forced-echild 2 0.08 -- /usr/bin/true 2>"$ownership_log"
ownership_status=$?
set -e
assert "unexpected ECHILD returns its reserved fatal ownership status" \
    test "$ownership_status" = 73
assert "unexpected ECHILD has a distinct fatal ownership classification" \
    test "$(state_field "$ownership_state" classification)" = ownership_error
assert "unexpected ECHILD emits an exact ownership diagnostic" \
    /usr/bin/grep -Fq \
        'HARNESS_OWNERSHIP_ERROR name=forced-echild error=owned child' "$ownership_log"

sole_reaper_log="$test_root/logs/sole-reaper.log"
release_harness_start_background sole-reaper 2 \
    /bin/bash -c '/bin/sleep 10' 2>"$sole_reaper_log"
sole_reaper_pid="$release_harness_background_pid"
sole_reaper_state="$release_harness_background_state"
kill_paused_process "direct crash control observes SIGKILL without shell-reaping" \
    "$sole_reaper_pid" "$sole_reaper_state"
release_harness_finish_crash_owner "$sole_reaper_pid" "$sole_reaper_state" sole-reaper
assert "crash finalization is the sole shell reaper and records no wait-127" \
    test "$release_harness_wait_result" = 137
assert "sole-reaper crash finalization marks its wrapper reaped exactly once" \
    /bin/bash -c 'for active in "$@"; do [[ "$active" == 0 ]]; done' \
    _ "${release_harness_process_active[@]}"
check_count=0
failure_count=0

orphan_pid_file="$test_root/orphan.pid"
orphan_log="$test_root/logs/orphan.log"
release_harness_start_background orphan-descendant 0.12 /bin/bash -c '
    trap "" TERM
    /bin/sleep 10 &
    printf "%s\n" "$!" > "$1"
    printf "RELEASE_FS_TEST_READY:orphan\n" >&2
    exit 0
  ' _ "$orphan_pid_file" 2>"$orphan_log"
orphan_supervisor_pid="$release_harness_background_pid"
orphan_state="$release_harness_background_state"
wait_for_fs_test_pause "$orphan_log" "$orphan_supervisor_pid" "$orphan_state" orphan-descendant
orphan_pid="$(<"$orphan_pid_file")"
release_harness_wait_status "$orphan_supervisor_pid"
assert "a successful parent with a live descendant is classified separately" \
    test "$(state_field "$orphan_state" classification)" = orphaned_descendants
assert "orphan cleanup returns its reserved failure status" \
    test "$release_harness_wait_result" = 72
assert "orphan cleanup hard-stops the escaped descendant" \
    /bin/bash -c '! /bin/kill -0 "$1" 2>/dev/null' _ "$orphan_pid"
assert "orphan cleanup records bounded whole-group settlement" \
    test "$(state_field "$orphan_state" groupSettled)" = true

batch_diagnostic="$test_root/logs/batch-accounting.log"
batch_active="$test_root/batch-active"
batch_peak="$test_root/batch-peak"
{
    for batch_name in one two three; do
        release_harness_queue_background_success "batch $batch_name succeeds" \
            "batch-${batch_name}" 2 /usr/bin/ruby -e '
              active_path, peak_path = ARGV
              lock_path = "#{active_path}.lock"
              File.open(lock_path, "w") do |lock|
                lock.flock(File::LOCK_EX)
                active = File.exist?(active_path) ? File.read(active_path).to_i : 0
                active += 1
                File.write(active_path, "#{active}\n")
                peak = File.exist?(peak_path) ? File.read(peak_path).to_i : 0
                File.write(peak_path, "#{[peak, active].max}\n")
              end
              sleep 0.08
              File.open(lock_path, "w") do |lock|
                lock.flock(File::LOCK_EX)
                active = File.read(active_path).to_i - 1
                File.write(active_path, "#{active}\n")
              end
            ' "$batch_active" "$batch_peak"
    done
    release_harness_drain_background_assertions
} >"$batch_diagnostic"
assert "bounded assertion batches execute every queued assertion" \
    test "$check_count" = 3
assert "bounded assertion batches preserve successful classifications" \
    test "$failure_count" = 0
assert "batch throttle reports the exact queued and active accounting" \
    /usr/bin/grep -Fq \
        'HARNESS_BATCH_THROTTLE queued=1 active=2 limit=2 started=2 reaped=0' \
        "$batch_diagnostic"
assert "completed batches report exact peak and reap accounting" \
    /usr/bin/grep -Fq \
        'HARNESS_BATCH_COMPLETE queued=0 active=0 limit=2 started=3 reaped=3 peak=2' \
        "$batch_diagnostic"
assert "measured physical child concurrency is nonzero and never exceeds the owner cap" \
    /bin/bash -c '(( $1 >= 1 && $1 <= $2 ))' _ \
    "$(<"$batch_peak")" "$ERYLO_RELEASE_HARNESS_MAX_BACKGROUND_ASSERTIONS"

nested_outer_state="$test_root/logs/nested-outer.json"
nested_inner_state="$test_root/logs/nested-inner.json"
nested_child_pid_file="$test_root/nested-child.pid"
nested_timeout_log="$test_root/logs/nested-timeout.log"
set +e
/usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" run \
    "$nested_outer_state" shard-timeout 0.4 0.12 -- \
    /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" run \
        "$nested_inner_state" nested-helper 5 0.08 -- \
        /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" > "$1"; /bin/sleep 10' \
        _ "$nested_child_pid_file" 2>"$nested_timeout_log"
nested_timeout_status=$?
set -e
nested_child_pid="$(<"$nested_child_pid_file")"
assert "top-level shard timeout returns the reserved timeout status" \
    test "$nested_timeout_status" = 124
assert "top-level shard timeout proves its outer process group settled" \
    test "$(state_field "$nested_outer_state" groupSettled)" = true
assert "top-level shard timeout lets the nested owner classify cancellation" \
    test "$(state_field "$nested_inner_state" classification)" = cancelled
assert "top-level shard timeout proves the nested helper group settled" \
    test "$(state_field "$nested_inner_state" groupSettled)" = true
assert "top-level shard timeout leaves no nested TERM-resistant child" \
    /bin/bash -c '! /bin/kill -0 "$1" 2>/dev/null' _ "$nested_child_pid"

retry_gate="$test_root/retry-cancellation"
retry_outer_state="$test_root/logs/retry-cancellation-outer.json"
retry_cancellation_log="$test_root/logs/retry-cancellation.log"
/usr/bin/env ERYLO_RELEASE_SUPERVISOR_TEST_RETRY_GATE="$retry_gate" \
    /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" run \
    "$retry_outer_state" retry-top-level-cancellation 3 0.3 -- \
    /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" retry-command \
        2 1 gated-retry-attempt -- \
        /bin/bash -c 'trap "" TERM; /bin/sleep 10' 2>"$retry_cancellation_log" &
retry_outer_pid=$!
/usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-started \
    "$retry_outer_state" "$retry_outer_pid" 0.5 retry-cancellation-outer
/usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-log \
    "$retry_gate.ready" 0.5 ready retry-cancellation-gate
retry_attempt_pid="$(<"$retry_gate.child")"
/usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" control \
    "$retry_outer_state" "$retry_outer_pid" 0.3 TERM
set +e
wait "$retry_outer_pid"
retry_cancellation_status=$?
set -e
assert "top-level cancellation during a gated retry returns cancellation" \
    test "$retry_cancellation_status" = 125
assert "top-level retry cancellation proves its outer process group settled" \
    test "$(state_field "$retry_outer_state" groupSettled)" = true
assert "the retry owner classifies gated-attempt cancellation exactly" \
    /usr/bin/grep -Fq \
        'HARNESS_RETRY_CANCELLED name=gated-retry-attempt signal=TERM' \
        "$retry_cancellation_log"
assert "gated retry cancellation reports no ownership failure" \
    /bin/bash -c '! /usr/bin/grep -Eq "HARNESS_(RETRY_)?OWNERSHIP_ERROR" "$1"' \
    _ "$retry_cancellation_log"
assert "top-level cancellation leaves no retry attempt child" \
    /bin/bash -c '! /bin/kill -0 "$1" 2>/dev/null' _ "$retry_attempt_pid"
assert "top-level cancellation leaves no retry attempt process group" \
    process_group_gone "$retry_attempt_pid"

partial_one_pid_file="$test_root/partial-one.pid"
partial_two_pid_file="$test_root/partial-two.pid"
release_harness_queue_background_success "partial one never drains" partial-one 2 \
    /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" > "$1"; /bin/sleep 10' \
    _ "$partial_one_pid_file"
release_harness_queue_background_success "partial two never drains" partial-two 2 \
    /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" > "$1"; /bin/sleep 10' \
    _ "$partial_two_pid_file"
/usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" retry-command \
    0.5 0.05 partial-batch-readiness -- /bin/bash -c '[[ -s "$1" && -s "$2" ]]' \
    _ "$partial_one_pid_file" "$partial_two_pid_file"
partial_one_pid="$(<"$partial_one_pid_file")"
partial_two_pid="$(<"$partial_two_pid_file")"
cleanup_release_harness_processes
assert "central cleanup kills every partially started batch command" \
    /bin/bash -c '! /bin/kill -0 "$1" 2>/dev/null && ! /bin/kill -0 "$2" 2>/dev/null' \
    _ "$partial_one_pid" "$partial_two_pid"
assert "central cleanup discards all unconsumed batch accounting" \
    test "${#release_harness_assertion_pids[@]}" = 0

cleanup_pid_file="$test_root/cleanup.pid"
cleanup_log="$test_root/logs/cleanup.log"
release_harness_start_background cleanup-stubborn-descendant 2 /bin/bash -c '
    trap "" TERM
    /bin/sleep 10 &
    printf "%s\n" "$!" > "$1"
    printf "RELEASE_FS_TEST_READY:cleanup\n" >&2
    wait
  ' _ "$cleanup_pid_file" 2>"$cleanup_log"
cleanup_supervisor_pid="$release_harness_background_pid"
cleanup_state="$release_harness_background_state"
wait_for_fs_test_pause "$cleanup_log" "$cleanup_supervisor_pid" "$cleanup_state" \
    cleanup-stubborn-descendant
cleanup_descendant_pid="$(<"$cleanup_pid_file")"
cleanup_release_harness_processes
assert "central cleanup classifies external cancellation exactly" \
    test "$(state_field "$cleanup_state" classification)" = cancelled
assert "central cleanup hard-stops stubborn descendants" \
    /bin/bash -c '! /bin/kill -0 "$1" 2>/dev/null' _ "$cleanup_descendant_pid"
assert "central cleanup marks every owned wrapper reaped" \
    /bin/bash -c 'for active in "$@"; do [[ "$active" == 0 ]]; done' \
    _ "${release_harness_process_active[@]}"

printf 'Release process supervisor regressions passed 67 checks.\n'
