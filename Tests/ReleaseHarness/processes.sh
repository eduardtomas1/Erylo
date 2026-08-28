#!/usr/bin/env bash

# The harness defines repo_root and test_root before sourcing this library.
# shellcheck disable=SC2154

release_harness_process_pids=()
release_harness_process_names=()
release_harness_process_states=()
release_harness_process_active=()
release_harness_process_serial=0
release_harness_assertion_pids=()
release_harness_assertion_states=()
release_harness_assertion_names=()
release_harness_assertion_messages=()
release_harness_assertion_expectations=()
release_harness_assertion_head=0
release_harness_assertion_started=0
release_harness_assertion_reaped=0
release_harness_assertion_peak_active=0
release_harness_assertion_throttle_reported=0
release_harness_background_timeout="${ERYLO_RELEASE_HARNESS_BACKGROUND_TIMEOUT_SECONDS:-180}"
release_harness_readiness_timeout="${ERYLO_RELEASE_HARNESS_READINESS_TIMEOUT_SECONDS:-120}"
release_harness_startup_timeout="${ERYLO_RELEASE_HARNESS_STARTUP_TIMEOUT_SECONDS:-10}"
release_harness_termination_grace="${ERYLO_RELEASE_HARNESS_TERMINATION_GRACE_SECONDS:-2}"
release_harness_assertion_limit="${ERYLO_RELEASE_HARNESS_MAX_BACKGROUND_ASSERTIONS:-12}"
if [[ ! "$release_harness_assertion_limit" =~ ^[1-9][0-9]*$ \
    || "$release_harness_assertion_limit" -gt 64 ]]; then
    printf 'ERYLO_RELEASE_HARNESS_MAX_BACKGROUND_ASSERTIONS must be an integer from 1 through 64\n' >&2
    exit 64
fi

release_harness_start_background() {
    local name="$1"
    local timeout="${2:-$release_harness_background_timeout}"
    shift 2
    release_harness_process_serial=$((release_harness_process_serial + 1))
    release_harness_background_state="$test_root/logs/process-${release_harness_process_serial}.json"
    /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" run \
        "$release_harness_background_state" "$name" "$timeout" \
        "$release_harness_termination_grace" -- "$@" &
    release_harness_background_pid=$!
    release_harness_process_pids+=("$release_harness_background_pid")
    release_harness_process_names+=("$name")
    release_harness_process_states+=("$release_harness_background_state")
    release_harness_process_active+=(1)
    if ! /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-started \
        "$release_harness_background_state" "$release_harness_background_pid" \
        "$release_harness_startup_timeout" "$name"; then
        release_harness_control_background "$release_harness_background_pid" \
            "$release_harness_background_state" TERM || true
        release_harness_wait_status "$release_harness_background_pid"
        printf 'ERROR: helper %s did not publish ownership before its startup deadline\n' \
            "$name" >&2
        return 1
    fi
}

release_harness_mark_reaped() {
    local process_id="$1"
    local index
    for ((index = 0; index < ${#release_harness_process_pids[@]}; index++)); do
        if [[ "${release_harness_process_pids[$index]}" == "$process_id" ]]; then
            release_harness_process_active[$index]=0
            return
        fi
    done
}

release_harness_control_background() {
    local process_id="$1"
    local state_path="$2"
    local signal="$3"
    /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" control \
        "$state_path" "$process_id" "$release_harness_termination_grace" "$signal"
}

release_harness_wait_direct_child() {
    local state_path="$1"
    local name="$2"
    /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-direct \
        "$state_path" "$release_harness_termination_grace" "$name" >/dev/null
}

release_harness_wait_status() {
    local process_id="$1"
    if wait "$process_id"; then
        release_harness_wait_result=0
    else
        release_harness_wait_result=$?
    fi
    release_harness_mark_reaped "$process_id"
}

release_harness_state_field() {
    local state_path="$1"
    local field="$2"
    /usr/bin/ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch(ARGV.fetch(1))' \
        "$state_path" "$field"
}

wait_for_fs_test_pause() {
    local log_file="$1"
    local process_id="$2"
    local state_path="$3"
    local name="$4"
    if /usr/bin/ruby "$repo_root/Tests/ReleaseHarness/process-supervisor.rb" wait-ready \
        "$state_path" "$log_file" "$release_harness_readiness_timeout" \
        '(RELEASE_FS|SOURCE_MOUNT)_TEST_READY:' "$name"; then
        return 0
    fi
    release_harness_control_background "$process_id" "$state_path" TERM || true
    release_harness_wait_status "$process_id"
    return 1
}

expect_background_success() {
    local message="$1"
    local process_id="$2"
    local state_path="$3"
    check_count=$((check_count + 1))
    release_harness_wait_status "$process_id"
    if [[ "$release_harness_wait_result" -eq 0 ]]; then
        return
    fi
    printf 'FAIL: %s (classification=%s, status=%d)\n' \
        "$message" "$(release_harness_state_field "$state_path" classification)" \
        "$release_harness_wait_result" >&2
    failure_count=$((failure_count + 1))
}

release_harness_require_background_success() {
    local process_id="$1"
    local state_path="$2"
    local name="$3"
    local classification
    release_harness_wait_status "$process_id"
    if [[ "$release_harness_wait_result" -eq 0 ]]; then
        return
    fi
    classification="$(release_harness_state_field "$state_path" classification)"
    printf 'ERROR: required helper %s failed (classification=%s, status=%d)\n' \
        "$name" "$classification" "$release_harness_wait_result" >&2
    return 1
}

expect_background_failure() {
    local message="$1"
    local process_id="$2"
    local state_path="$3"
    local classification
    check_count=$((check_count + 1))
    release_harness_wait_status "$process_id"
    classification="$(release_harness_state_field "$state_path" classification)"
    if [[ "$release_harness_wait_result" -ne 0 && "$classification" == exited ]]; then
        return
    fi
    printf 'FAIL: %s (classification=%s, status=%d)\n' \
        "$message" "$classification" "$release_harness_wait_result" >&2
    failure_count=$((failure_count + 1))
}

release_harness_queue_background_assertion() {
    local expectation="$1"
    local message="$2"
    local name="$3"
    local timeout="$4"
    shift 4
    local stdout_path="$test_root/logs/${name}.out"
    local stderr_path="$test_root/logs/${name}.err"
    local active_count=$((${#release_harness_assertion_pids[@]} - release_harness_assertion_head))
    if [[ "$active_count" -ge "$release_harness_assertion_limit" ]]; then
        if [[ "$release_harness_assertion_throttle_reported" == 0 ]]; then
            printf 'HARNESS_BATCH_THROTTLE queued=1 active=%d limit=%d started=%d reaped=%d\n' \
                "$active_count" "$release_harness_assertion_limit" \
                "$release_harness_assertion_started" "$release_harness_assertion_reaped"
            release_harness_assertion_throttle_reported=1
        fi
        release_harness_drain_background_assertion
    fi
    release_harness_start_background "$name" "$timeout" "$@" \
        >"$stdout_path" 2>"$stderr_path"
    release_harness_assertion_pids+=("$release_harness_background_pid")
    release_harness_assertion_states+=("$release_harness_background_state")
    release_harness_assertion_names+=("$name")
    release_harness_assertion_messages+=("$message")
    release_harness_assertion_expectations+=("$expectation")
    release_harness_assertion_started=$((release_harness_assertion_started + 1))
    active_count=$((${#release_harness_assertion_pids[@]} - release_harness_assertion_head))
    if [[ "$active_count" -gt "$release_harness_assertion_peak_active" ]]; then
        release_harness_assertion_peak_active="$active_count"
    fi
}

release_harness_queue_background_success() {
    release_harness_queue_background_assertion success "$@"
}

release_harness_queue_background_failure() {
    release_harness_queue_background_assertion failure "$@"
}

release_harness_drain_background_assertion() {
    local index="$release_harness_assertion_head"
    [[ "$index" -lt "${#release_harness_assertion_pids[@]}" ]] || return 0
    if [[ "${release_harness_assertion_expectations[$index]}" == success ]]; then
        expect_background_success \
            "${release_harness_assertion_messages[$index]}" \
            "${release_harness_assertion_pids[$index]}" \
            "${release_harness_assertion_states[$index]}"
    else
        expect_background_failure \
            "${release_harness_assertion_messages[$index]}" \
            "${release_harness_assertion_pids[$index]}" \
            "${release_harness_assertion_states[$index]}"
    fi
    release_harness_assertion_head=$((release_harness_assertion_head + 1))
    release_harness_assertion_reaped=$((release_harness_assertion_reaped + 1))
}

release_harness_discard_background_assertions() {
    release_harness_assertion_pids=()
    release_harness_assertion_states=()
    release_harness_assertion_names=()
    release_harness_assertion_messages=()
    release_harness_assertion_expectations=()
    release_harness_assertion_head=0
    release_harness_assertion_started=0
    release_harness_assertion_reaped=0
    release_harness_assertion_peak_active=0
    release_harness_assertion_throttle_reported=0
}

release_harness_drain_background_assertions() {
    while [[ "$release_harness_assertion_head" -lt "${#release_harness_assertion_pids[@]}" ]]; do
        release_harness_drain_background_assertion
    done
    printf 'HARNESS_BATCH_COMPLETE queued=0 active=0 limit=%d started=%d reaped=%d peak=%d\n' \
        "$release_harness_assertion_limit" "$release_harness_assertion_started" \
        "$release_harness_assertion_reaped" "$release_harness_assertion_peak_active"
    release_harness_discard_background_assertions
}

kill_paused_process() {
    local message="$1"
    local process_id="$2"
    local state_path="$3"
    local direct_classification
    local direct_signal
    check_count=$((check_count + 1))
    release_harness_control_background "$process_id" "$state_path" DIRECT-KILL
    if ! release_harness_wait_direct_child "$state_path" "$message"; then
        printf 'FAIL: %s (direct child did not classify after SIGKILL)\n' "$message" >&2
        failure_count=$((failure_count + 1))
        return
    fi
    direct_classification="$(release_harness_state_field "$state_path" directTermSignal 2>/dev/null || true)"
    direct_signal="$direct_classification"
    if [[ "$direct_signal" == 9 ]]; then
        return
    fi
    printf 'FAIL: %s (direct signal=%s)\n' "$message" "$direct_signal" >&2
    failure_count=$((failure_count + 1))
}

release_harness_finish_crash_owner() {
    local process_id="$1"
    local state_path="$2"
    local name="$3"
    local classification
    release_harness_wait_status "$process_id"
    classification="$(release_harness_state_field "$state_path" classification)"
    if [[ "$classification" == signaled \
        && "$(release_harness_state_field "$state_path" termSignal)" == 9 ]]; then
        return
    fi
    printf 'ERROR: crash owner %s settled as %s (status=%d)\n' \
        "$name" "$classification" "$release_harness_wait_result" >&2
    return 1
}

cleanup_release_harness_processes() {
    local index
    local process_id
    local name
    local state_path
    for ((index = 0; index < ${#release_harness_process_pids[@]}; index++)); do
        [[ "${release_harness_process_active[$index]}" == 1 ]] || continue
        process_id="${release_harness_process_pids[$index]}"
        name="${release_harness_process_names[$index]}"
        state_path="${release_harness_process_states[$index]}"
        printf 'HARNESS_CLEANUP name=%s supervisor_pid=%s\n' "$name" "$process_id" >&2
        release_harness_control_background "$process_id" "$state_path" TERM || true
        wait "$process_id" 2>/dev/null || true
        release_harness_process_active[$index]=0
    done
    release_harness_discard_background_assertions
}
