#!/usr/bin/ruby

require "json"

EXIT_TIMEOUT = 124
EXIT_CANCELLED = 125
EXIT_USAGE = 64
EXIT_READINESS_TIMEOUT = 70
EXIT_READINESS_EXITED = 71
EXIT_ORPHANED_DESCENDANTS = 72
EXIT_OWNERSHIP_ERROR = 73
EXIT_UNSETTLED_DESCENDANTS = 74

class OwnershipError < StandardError; end

class OwnedChild
  attr_reader :process_id, :status

  def initialize(process_id)
    @process_id = process_id
    @status = nil
  end

  def reaped?
    !@status.nil?
  end

  def reap_nonblocking
    return @status if reaped?

    waited_pid, status = Process.waitpid2(@process_id, Process::WNOHANG)
    @status = status if waited_pid
  rescue Errno::EINTR
    retry
  rescue Errno::ECHILD
    raise OwnershipError, "owned child #{@process_id} is no longer waitable"
  end
end

CleanupResult = Struct.new(:status, :group_settled, :error, keyword_init: true)

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def parse_duration(value, label)
  duration = Float(value)
  abort "#{label} must be greater than zero" unless duration.positive? && duration.finite?
  duration
rescue ArgumentError
  abort "#{label} must be a finite number"
end

def safe_diagnostic_field(value)
  raw = value.to_s.b
  truncated = raw.bytesize > 512
  raw = raw.byteslice(0, 512)
  encoded = raw.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
  encoded << "..." if truncated
  JSON.generate(encoded)
rescue StandardError
  '"<unprintable>"'
end

def write_state(path, payload)
  directory = File.dirname(path)
  temporary = File.join(directory, ".#{File.basename(path)}.#{Process.pid}.tmp")
  File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate(payload) + "\n")
    file.flush
    file.fsync
  end
  File.rename(temporary, path)
ensure
  File.unlink(temporary) if defined?(temporary) && File.exist?(temporary)
end

def read_state(path)
  JSON.parse(File.read(path))
rescue Errno::ENOENT, JSON::ParserError
  nil
end

def signal_group(process_group_id, signal)
  Process.kill(signal, -process_group_id)
  true
rescue Errno::ESRCH
  false
end

def group_alive?(process_group_id)
  signal_group(process_group_id, 0)
rescue Errno::EPERM
  true
end

def process_alive?(process_id)
  Process.kill(0, process_id)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true
end

def settle_group(process_group_id, grace)
  deadline = monotonic + grace
  sleep 0.01 while group_alive?(process_group_id) && monotonic < deadline
  return false if ENV["ERYLO_RELEASE_SUPERVISOR_TEST_FORCE_UNSETTLED"] == "1"

  !group_alive?(process_group_id)
end

def stop_group(process_group_id, grace, first_signal)
  signal_group(process_group_id, first_signal)
  deadline = monotonic + grace
  sleep 0.01 while group_alive?(process_group_id) && monotonic < deadline
  signal_group(process_group_id, "KILL") if group_alive?(process_group_id)
  settle_group(process_group_id, grace)
end

def cleanup_owned_child(owned_child, grace, first_signal)
  process_id = owned_child.process_id
  cleanup_error = nil
  begin
    signal_group(process_id, first_signal)
  rescue SystemCallError => error
    cleanup_error ||= error
  end
  deadline = monotonic + grace
  loop do
    owned_child.reap_nonblocking
    break if owned_child.reaped? && !group_alive?(process_id)
    break if monotonic >= deadline
    sleep 0.01
  rescue OwnershipError, SystemCallError => error
    cleanup_error ||= error
    break
  end
  begin
    signal_group(process_id, "KILL") if group_alive?(process_id)
  rescue SystemCallError => error
    cleanup_error ||= error
  end
  settlement_deadline = monotonic + grace
  loop do
    begin
      owned_child.reap_nonblocking unless owned_child.reaped? || cleanup_error.is_a?(OwnershipError)
      break if owned_child.reaped? && !group_alive?(process_id)
    rescue OwnershipError, SystemCallError => error
      cleanup_error ||= error
    end
    break if monotonic >= settlement_deadline
    sleep 0.01
  end
  group_settled = begin
    !group_alive?(process_id)
  rescue SystemCallError => error
    cleanup_error ||= error
    false
  end
  group_settled = false if ENV["ERYLO_RELEASE_SUPERVISOR_TEST_FORCE_UNSETTLED"] == "1"
  unless owned_child.reaped? || cleanup_error
    cleanup_error = OwnershipError.new(
      "owned child #{process_id} was not reaped within #{format('%.3f', grace)}s after KILL"
    )
  end
  CleanupResult.new(
    status: owned_child.status,
    group_settled: group_settled,
    error: cleanup_error
  )
end

def terminate_owned_group(owned_child, grace, first_signal)
  result = cleanup_owned_child(owned_child, grace, first_signal)
  raise result.error if result.error

  [result.status, result.group_settled]
end

def state_for(name, command, timeout, started, process_id)
  {
    "version" => 1,
    "name" => name,
    "command" => command,
    "timeoutSeconds" => timeout,
    "startedMonotonic" => started,
    "supervisorPid" => Process.pid,
    "processGroupId" => process_id,
    "classification" => "running"
  }
end

def finish_state(state, classification, started, status = nil)
  state.merge(
    "classification" => classification,
    "elapsedSeconds" => (monotonic - started).round(6),
    "exitStatus" => status&.exited? ? status.exitstatus : nil,
    "termSignal" => status&.signaled? ? status.termsig : nil
  )
end

def run_command(arguments)
  state_path, name, timeout_text, grace_text, separator, *command = arguments
  unless separator == "--" && !command.empty?
    warn "usage: process-supervisor.rb run STATE NAME TIMEOUT GRACE -- COMMAND [ARG ...]"
    exit EXIT_USAGE
  end
  timeout = parse_duration(timeout_text, "timeout")
  grace = parse_duration(grace_text, "termination grace")
  started = monotonic
  cancellation = nil
  Signal.trap("TERM") { cancellation = "TERM" }
  Signal.trap("INT") { cancellation = "INT" }
  process_id = Process.spawn(*command, pgroup: true)
  owned_child = OwnedChild.new(process_id)
  ownership_complete = false
  emergency_cleanup = nil
  begin
    state = state_for(name, command, timeout, started, process_id)
    if (gate = ENV["ERYLO_RELEASE_SUPERVISOR_TEST_PREPUBLICATION_GATE"])
      File.write("#{gate}.child", "#{process_id}\n")
      File.write("#{gate}.ready", "ready\n")
      gate_deadline = started + timeout
      sleep 0.01 until cancellation || File.exist?("#{gate}.release") || monotonic >= gate_deadline
    end
    write_state(state_path, state)
    Process.waitpid2(process_id) if ENV["ERYLO_RELEASE_SUPERVISOR_TEST_FORCE_ECHILD"] == "1"
    deadline = started + timeout
    status = nil
    classification = nil
    direct_classification = nil
    group_settled = true

    loop do
      unless owned_child.reaped?
        status = owned_child.reap_nonblocking
        if status
          direct_classification = status.signaled? ? "signaled" : "exited"
          state = state.merge(
            "classification" => group_alive?(process_id) ? "settling_descendants" : direct_classification,
            "directExitStatus" => status.exited? ? status.exitstatus : nil,
            "directTermSignal" => status.signaled? ? status.termsig : nil
          )
          write_state(state_path, state)
        end
      end
      if cancellation
        if owned_child.reaped?
          group_settled = stop_group(process_id, grace, "TERM")
        else
          status, group_settled = terminate_owned_group(owned_child, grace, "TERM")
        end
        classification = group_settled ? "cancelled" : "unsettled_descendants"
        break
      end
      if owned_child.reaped? && !group_alive?(process_id)
        classification = direct_classification
        break
      end
      if monotonic >= deadline
        if owned_child.reaped?
          group_settled = stop_group(process_id, grace, "TERM")
          classification = group_settled ? "orphaned_descendants" : "unsettled_descendants"
        else
          status, group_settled = terminate_owned_group(owned_child, grace, "TERM")
          classification = group_settled ? "timed_out" : "unsettled_descendants"
        end
        break
      end
      sleep 0.01
    end

    final_state = finish_state(state, classification, started, status).merge(
      "groupSettled" => group_settled
    )
    ownership_complete = owned_child.reaped? && group_settled
    write_state(state_path, final_state)
    case classification
    when "timed_out"
      warn format(
        "HARNESS_PROCESS_TIMEOUT name=%s timeout=%.3fs elapsed=%.3fs pgid=%d command=%s",
        name, timeout, final_state.fetch("elapsedSeconds"), process_id, command.inspect
      )
      exit EXIT_TIMEOUT
    when "cancelled"
      warn format(
        "HARNESS_PROCESS_CANCELLED name=%s signal=%s elapsed=%.3fs pgid=%d",
        name, cancellation, final_state.fetch("elapsedSeconds"), process_id
      )
      exit EXIT_CANCELLED
    when "orphaned_descendants"
      warn format(
        "HARNESS_ORPHANED_DESCENDANTS name=%s elapsed=%.3fs pgid=%d command=%s",
        name, final_state.fetch("elapsedSeconds"), process_id, command.inspect
      )
      exit EXIT_ORPHANED_DESCENDANTS
    when "unsettled_descendants"
      warn format(
        "HARNESS_UNSETTLED_DESCENDANTS name=%s elapsed=%.3fs pgid=%d command=%s",
        name, final_state.fetch("elapsedSeconds"), process_id, command.inspect
      )
      exit EXIT_UNSETTLED_DESCENDANTS
    when "signaled"
      exit 128 + status.termsig
    else
      exit status.exitstatus
    end
  ensure
    emergency_cleanup = cleanup_owned_child(owned_child, grace, "TERM") unless ownership_complete
  end
rescue OwnershipError => error
  cleanup = emergency_cleanup || if defined?(owned_child) && owned_child
                                   cleanup_owned_child(owned_child, grace || 0.1, "KILL")
                                 end
  settled = cleanup ? cleanup.group_settled : true
  ownership_state = if defined?(state) && state
                      finish_state(
                        state,
                        settled ? "ownership_error" : "unsettled_descendants",
                        started,
                        cleanup&.status
                      ).merge("groupSettled" => settled)
                    else
                      { "classification" => "ownership_error", "name" => name }
                    end
  write_state(state_path, ownership_state) if defined?(state_path) && state_path
  if settled
    warn "HARNESS_OWNERSHIP_ERROR name=#{name || "unknown"} error=#{error.message}"
    exit EXIT_OWNERSHIP_ERROR
  end
  warn "HARNESS_UNSETTLED_DESCENDANTS name=#{name || "unknown"} after=ownership_error"
  exit EXIT_UNSETTLED_DESCENDANTS
rescue SystemCallError => error
  cleanup = emergency_cleanup || if defined?(owned_child) && owned_child
                                   cleanup_owned_child(owned_child, grace || 0.1, "TERM")
                                 end
  if cleanup && !cleanup.group_settled
    warn "HARNESS_UNSETTLED_DESCENDANTS name=#{name || "unknown"} after=process_error"
    exit EXIT_UNSETTLED_DESCENDANTS
  end
  if cleanup&.error.is_a?(OwnershipError) \
      || (defined?(owned_child) && owned_child && !owned_child.reaped?)
    detail = cleanup&.error&.message || "direct child was not reaped"
    warn "HARNESS_OWNERSHIP_ERROR name=#{name || "unknown"} error=#{detail}"
    exit EXIT_OWNERSHIP_ERROR
  end
  warn format(
    "HARNESS_PROCESS_ERROR name=%s error=%s:%s group_settled=%s direct_reaped=%s",
    name || "unknown", error.class, error.message,
    cleanup ? cleanup.group_settled : true,
    defined?(owned_child) && owned_child ? owned_child.reaped? : true
  )
  exit 1
rescue StandardError => error
  cleanup = emergency_cleanup || if defined?(owned_child) && owned_child
                                   cleanup_owned_child(owned_child, grace || 0.1, "TERM")
                                 end
  group_settled = cleanup ? cleanup.group_settled : true
  direct_reaped = if defined?(owned_child) && owned_child
                    owned_child.reaped?
                  else
                    true
                  end
  safe_name = safe_diagnostic_field(name || "unknown")
  safe_error_class = safe_diagnostic_field(error.class.name)
  unless group_settled
    warn format(
      "HARNESS_UNSETTLED_DESCENDANTS name=%s after=process_exception error_class=%s group_settled=false direct_reaped=%s",
      safe_name, safe_error_class, direct_reaped
    )
    exit EXIT_UNSETTLED_DESCENDANTS
  end
  if cleanup&.error.is_a?(OwnershipError) || !direct_reaped
    warn format(
      "HARNESS_OWNERSHIP_ERROR name=%s after=process_exception error_class=%s cleanup_error=%s group_settled=true direct_reaped=%s",
      safe_name, safe_error_class,
      safe_diagnostic_field(cleanup&.error&.message || "direct child was not reaped"),
      direct_reaped
    )
    exit EXIT_OWNERSHIP_ERROR
  end
  warn format(
    "HARNESS_PROCESS_EXCEPTION name=%s error_class=%s error=%s group_settled=true direct_reaped=true",
    safe_name, safe_error_class, safe_diagnostic_field(error.message)
  )
  exit 1
end

def wait_started(arguments)
  state_path, supervisor_text, timeout_text, name = arguments
  unless name
    warn "usage: process-supervisor.rb wait-started STATE SUPERVISOR_PID TIMEOUT NAME"
    exit EXIT_USAGE
  end
  supervisor_id = Integer(supervisor_text, 10)
  timeout = parse_duration(timeout_text, "startup timeout")
  started = monotonic
  deadline = started + timeout
  loop do
    state = read_state(state_path)
    if state && state["supervisorPid"] == supervisor_id && state["processGroupId"]
      exit 0
    end
    unless process_alive?(supervisor_id)
      warn format(
        "HARNESS_STARTUP_EXIT name=%s elapsed=%.3fs supervisor_pid=%d state=%s",
        name, monotonic - started, supervisor_id, state ? state["classification"] : "missing"
      )
      exit EXIT_READINESS_EXITED
    end
    if monotonic >= deadline
      warn format(
        "HARNESS_STARTUP_TIMEOUT name=%s timeout=%.3fs elapsed=%.3fs supervisor_pid=%d state=%s",
        name, timeout, monotonic - started, supervisor_id,
        state ? state["classification"] : "missing"
      )
      exit EXIT_TIMEOUT
    end
    sleep 0.01
  end
rescue ArgumentError
  warn "supervisor PID must be an integer"
  exit EXIT_USAGE
end

def diagnostic_tail(path)
  contents = File.binread(path)
  contents.byteslice(-4096, 4096) || contents
rescue Errno::ENOENT
  "<missing>"
end

def wait_ready(arguments)
  state_path, log_path, timeout_text, pattern_text, name = arguments
  unless name
    warn "usage: process-supervisor.rb wait-ready STATE LOG TIMEOUT PATTERN NAME"
    exit EXIT_USAGE
  end
  timeout = parse_duration(timeout_text, "readiness timeout")
  pattern = Regexp.new(pattern_text)
  started = monotonic
  deadline = started + timeout
  test_gate_held = false
  loop do
    begin
      contents = File.binread(log_path)
      exit 0 if pattern.match?(contents)
    rescue Errno::ENOENT
      # The owned process may not have opened its log yet.
    end
    if !test_gate_held && (gate = ENV["ERYLO_RELEASE_SUPERVISOR_TEST_READINESS_GATE"])
      gate_started = monotonic
      File.write("#{gate}.ready", "ready\n")
      sleep 0.01 until File.exist?("#{gate}.release")
      deadline += monotonic - gate_started
      test_gate_held = true
    end
    state = read_state(state_path)
    if state && state["classification"] != "running"
      warn format(
        "HARNESS_READINESS_PROCESS_EXIT name=%s classification=%s elapsed=%.3fs log=%s tail=%s",
        name, state["classification"], monotonic - started, log_path,
        diagnostic_tail(log_path).inspect
      )
      exit EXIT_READINESS_EXITED
    end
    if monotonic >= deadline
      classification = state ? state["classification"] : "state-missing"
      warn format(
        "HARNESS_READINESS_TIMEOUT name=%s timeout=%.3fs elapsed=%.3fs classification=%s log=%s tail=%s",
        name, timeout, monotonic - started, classification, log_path,
        diagnostic_tail(log_path).inspect
      )
      exit EXIT_READINESS_TIMEOUT
    end
    sleep 0.01
  end
rescue RegexpError => error
  warn "invalid readiness pattern: #{error.message}"
  exit EXIT_USAGE
end

def wait_log(arguments)
  log_path, timeout_text, pattern_text, name = arguments
  unless name
    warn "usage: process-supervisor.rb wait-log LOG TIMEOUT PATTERN NAME"
    exit EXIT_USAGE
  end
  timeout = parse_duration(timeout_text, "log timeout")
  pattern = Regexp.new(pattern_text)
  started = monotonic
  deadline = started + timeout
  loop do
    begin
      contents = File.binread(log_path)
      exit 0 if pattern.match?(contents)
    rescue Errno::ENOENT
      nil
    end
    if monotonic >= deadline
      warn format(
        "HARNESS_LOG_TIMEOUT name=%s timeout=%.3fs elapsed=%.3fs log=%s tail=%s",
        name, timeout, monotonic - started, log_path, diagnostic_tail(log_path).inspect
      )
      exit EXIT_READINESS_TIMEOUT
    end
    sleep 0.01
  end
rescue RegexpError => error
  warn "invalid log pattern: #{error.message}"
  exit EXIT_USAGE
end

def retry_command(arguments)
  timeout_text, attempt_timeout_text, name, separator, *command = arguments
  unless separator == "--" && !command.empty?
    warn "usage: process-supervisor.rb retry-command TIMEOUT ATTEMPT_TIMEOUT NAME -- COMMAND [ARG ...]"
    exit EXIT_USAGE
  end
  timeout = parse_duration(timeout_text, "retry timeout")
  attempt_timeout = parse_duration(attempt_timeout_text, "attempt timeout")
  started = monotonic
  deadline = started + timeout
  attempts = 0
  last_status = nil
  cancellation = nil
  Signal.trap("TERM") { cancellation = "TERM" }
  Signal.trap("INT") { cancellation = "INT" }
  loop do
    attempts += 1
    emergency_cleanup = nil
    owned_child = nil
    ownership_complete = true
    process_id = Process.spawn(*command, pgroup: true, out: File::NULL, err: File::NULL)
    owned_child = OwnedChild.new(process_id)
    ownership_complete = false
    begin
      attempt_deadline = [monotonic + attempt_timeout, deadline].min
      if (gate = ENV["ERYLO_RELEASE_SUPERVISOR_TEST_RETRY_GATE"])
        File.write("#{gate}.child", "#{process_id}\n")
        File.write("#{gate}.ready", "ready\n")
        sleep 0.01 until cancellation || File.exist?("#{gate}.release") || monotonic >= attempt_deadline
      end
      loop do
        break if cancellation
        owned_child.reap_nonblocking
        break if owned_child.reaped?
        break if monotonic >= attempt_deadline
        sleep 0.01
      end
      unless owned_child.reaped? && !group_alive?(process_id)
        status, settled = terminate_owned_group(owned_child, 0.05, "TERM")
        raise OwnershipError, "retry command group #{process_id} did not settle" unless settled
      end
      ownership_complete = owned_child.reaped? && !group_alive?(process_id)
      if cancellation
        warn format(
          "HARNESS_RETRY_CANCELLED name=%s signal=%s elapsed=%.3fs attempts=%d pgid=%d",
          name, cancellation, monotonic - started, attempts, process_id
        )
        exit EXIT_CANCELLED
      end
      status = owned_child.status
      exit 0 if status.success?
      last_status = status
    ensure
      emergency_cleanup = cleanup_owned_child(owned_child, 0.05, "TERM") unless ownership_complete
    end
    break if monotonic >= deadline
    sleep 0.01
  end
  warn format(
    "HARNESS_RETRY_TIMEOUT name=%s timeout=%.3fs elapsed=%.3fs attempts=%d last_status=%s command=%s",
    name, timeout, monotonic - started, attempts,
    last_status&.exited? ? last_status.exitstatus : "signal-#{last_status&.termsig}", command.inspect
  )
  exit EXIT_TIMEOUT
rescue OwnershipError => error
  if emergency_cleanup && !emergency_cleanup.group_settled
    warn "HARNESS_RETRY_UNSETTLED_DESCENDANTS name=#{name || "unknown"} after=ownership_error"
    exit EXIT_UNSETTLED_DESCENDANTS
  end
  warn "HARNESS_RETRY_OWNERSHIP_ERROR name=#{name || "unknown"} error=#{error.message}"
  exit EXIT_OWNERSHIP_ERROR
rescue SystemCallError => error
  if emergency_cleanup && !emergency_cleanup.group_settled
    warn "HARNESS_RETRY_UNSETTLED_DESCENDANTS name=#{name || "unknown"} after=retry_error"
    exit EXIT_UNSETTLED_DESCENDANTS
  end
  if emergency_cleanup&.error.is_a?(OwnershipError) \
      || (defined?(owned_child) && owned_child && !owned_child.reaped?)
    detail = emergency_cleanup&.error&.message || "direct child was not reaped"
    warn "HARNESS_RETRY_OWNERSHIP_ERROR name=#{name || "unknown"} error=#{detail}"
    exit EXIT_OWNERSHIP_ERROR
  end
  warn format(
    "HARNESS_RETRY_ERROR name=%s error=%s:%s group_settled=%s direct_reaped=%s",
    name || "unknown", error.class, error.message,
    emergency_cleanup ? emergency_cleanup.group_settled : true,
    defined?(owned_child) && owned_child ? owned_child.reaped? : true
  )
  exit 1
end

def control(arguments)
  state_path, supervisor_text, grace_text, signal = arguments
  unless %w[TERM KILL DIRECT-KILL].include?(signal)
    warn "usage: process-supervisor.rb control STATE SUPERVISOR_PID GRACE TERM|KILL|DIRECT-KILL"
    exit EXIT_USAGE
  end
  supervisor_id = Integer(supervisor_text, 10)
  grace = parse_duration(grace_text, "control grace")
  state = read_state(state_path)
  process_group_id = state && state["processGroupId"]
  if signal == "DIRECT-KILL"
    Process.kill("KILL", process_group_id) if process_group_id && process_alive?(process_group_id)
    return
  elsif signal == "KILL"
    signal_group(process_group_id, "KILL") if process_group_id
  else
    Process.kill("TERM", supervisor_id) if process_alive?(supervisor_id)
  end
  # The owner may use its full grace period before recording cancellation.
  deadline = monotonic + (grace * 2) + 0.05
  while process_alive?(supervisor_id) && monotonic < deadline
    current = read_state(state_path)
    process_group_id ||= current && current["processGroupId"]
    break if current && !%w[running settling_descendants].include?(current["classification"])
    sleep 0.01
  end
  current = read_state(state_path)
  process_group_id ||= current && current["processGroupId"]
  if process_group_id && group_alive?(process_group_id)
    signal_group(process_group_id, "KILL")
    unless settle_group(process_group_id, grace)
      warn "HARNESS_CONTROL_UNSETTLED_DESCENDANTS supervisor_pid=#{supervisor_id} pgid=#{process_group_id}"
      exit EXIT_UNSETTLED_DESCENDANTS
    end
  end
  if process_alive?(supervisor_id) \
      && (!current || %w[running settling_descendants].include?(current["classification"]))
    Process.kill("KILL", supervisor_id)
  end
rescue ArgumentError
  warn "supervisor PID must be an integer"
  exit EXIT_USAGE
rescue Errno::ESRCH
  nil
end

def wait_direct(arguments)
  state_path, timeout_text, name = arguments
  unless name
    warn "usage: process-supervisor.rb wait-direct STATE TIMEOUT NAME"
    exit EXIT_USAGE
  end
  timeout = parse_duration(timeout_text, "direct-child timeout")
  started = monotonic
  deadline = started + timeout
  loop do
    state = read_state(state_path)
    if state && state["classification"] != "running"
      puts JSON.generate(state)
      exit 0
    end
    if monotonic >= deadline
      warn format(
        "HARNESS_DIRECT_CHILD_TIMEOUT name=%s timeout=%.3fs elapsed=%.3fs state=%s",
        name, timeout, monotonic - started, state ? state["classification"] : "state-missing"
      )
      exit EXIT_TIMEOUT
    end
    sleep 0.01
  end
end

def print_state(arguments)
  state_path = arguments.fetch(0)
  state = read_state(state_path)
  abort "missing or invalid supervisor state: #{state_path}" unless state
  puts JSON.generate(state)
end

command = ARGV.shift
case command
when "run"
  run_command(ARGV)
when "wait-ready"
  wait_ready(ARGV)
when "wait-started"
  wait_started(ARGV)
when "wait-log"
  wait_log(ARGV)
when "retry-command"
  retry_command(ARGV)
when "wait-direct"
  wait_direct(ARGV)
when "control"
  control(ARGV)
when "state"
  print_state(ARGV)
else
  warn "usage: process-supervisor.rb run|wait-started|wait-ready|wait-log|wait-direct|retry-command|control|state ..."
  exit EXIT_USAGE
end
