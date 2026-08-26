#!/usr/bin/ruby

require "open3"

repo = File.realpath(ARGV.shift || abort("missing release repository"))
source_commit = ARGV.shift || abort("missing release source commit")
snapshot_temp = File.expand_path(ARGV.shift || abort("missing source snapshot transaction"))
snapshot_mount = File.expand_path(ARGV.shift || abort("missing source snapshot mount"))
worker = File.expand_path(ARGV.shift || abort("missing mounted release worker"))
worker_arguments = ARGV
abort("release source commit is invalid") unless /\A[0-9a-f]{40}\z/.match?(source_commit)
pinned_helper = ENV.fetch("ERYLO_RELEASE_PINNED_FS_HELPER")
pinned_recovery = ENV.fetch("ERYLO_RELEASE_PINNED_MOUNT_RECOVERY")
program_descriptors = [pinned_helper, pinned_recovery].map do |program|
  abort("pinned supervisor dependency is not an inherited anonymous descriptor") \
    unless /\A\/dev\/fd\/[0-9]+\z/.match?(program) && File.file?(program)
  descriptor = Integer(program.delete_prefix("/dev/fd/"), 10)
  File.for_fd(descriptor, "r", autoclose: false)
end
pinned_helper_io, pinned_recovery_io = program_descriptors

expected_prefix = File.join(repo, ".release", "tmp") + File::SEPARATOR
relative = snapshot_temp.delete_prefix(expected_prefix)
abort("source snapshot transaction is outside the managed release root") \
  unless snapshot_temp.start_with?(expected_prefix) && /\Asource-snapshot\.\d+\.[0-9a-f]{12}\z/.match?(relative)
abort("source snapshot mount does not match its transaction") \
  unless snapshot_mount == File.join(snapshot_temp, "mount")
abort("mounted release worker is missing or unsafe") \
  unless worker == File.join(snapshot_mount, "Scripts", "release", "release-worker.sh") && File.file?(worker) && File.executable?(worker)

pinned_helper_io.rewind
assert_output, assert_error, assert_status = Open3.capture3(
  "/usr/bin/ruby", pinned_helper,
  "assert-lock-supervisor", repo,
  close_others: false
)
abort("release worker supervisor did not execute its pinned lock assertion") \
  unless assert_status.success? && assert_output == "ERYLO_PINNED_LOCK_OK\n" && assert_error.empty?

lock_descriptor = Integer(ENV.fetch("ERYLO_RELEASE_LOCK_FD"), 10)
lock = File.for_fd(lock_descriptor, "r+", autoclose: false)
capability_record = lock.pread(512, 0)
capability_match = /\AERYLO_RELEASE_CAPABILITY_V1\t([1-9][0-9]*)\t([0-9a-f]{64})\t([0-9a-f]{64})\n\z/.match(capability_record)
abort("release supervisor capability record is missing or invalid") unless capability_match
admission_process = Integer(capability_match[1], 10)
abort("release supervisor is outside the authenticated lock-helper process chain") \
  unless admission_process == Process.pid || admission_process == Process.ppid
supervisor_record = [
  "ERYLO_RELEASE_CAPABILITY_V1",
  Process.pid,
  capability_match[2],
  capability_match[3]
].join("\t") + "\n"
lock.rewind
lock.truncate(0)
lock.write(supervisor_record)
lock.flush
lock.fsync
lock.rewind

control_read, control_write = IO.pipe
ready_read, ready_write = IO.pipe
watchdog_pid = fork do
  control_write.close
  ready_read.close
  Process.setpgid(0, 0)
  Signal.trap("TERM", "IGNORE")
  ready_write.write("R")
  ready_write.close
  normal = control_read.read(1) == "N"
  control_read.close
  exit!(0) if normal
  if ENV["ERYLO_RELEASE_TESTING"] == "1" &&
      ENV["ERYLO_RELEASE_TEST_PAUSE_STAGE"] == "watchdog-before-worker-termination"
    record = ENV.fetch("ERYLO_RELEASE_TEST_WATCHDOG_RECORD")
    File.write(record, "#{Process.pid}\n", mode: "w", perm: 0o600)
    warn("SOURCE_MOUNT_WATCHDOG_TEST_READY:before-worker-termination")
    Process.kill("STOP", Process.pid)
  end
  process_group = Process.getpgrp
  begin
    Process.kill("TERM", -process_group)
  rescue Errno::ESRCH
    exit!(0)
  end
  sleep(0.5)
  Process.kill("KILL", -process_group)
end

control_read.close
ready_write.close
abort("release worker watchdog did not initialize") unless ready_read.read(1) == "R"
ready_read.close

worker_environment = ENV.to_h
worker_environment.delete("ERYLO_RELEASE_PINNED_FS_HELPER")
worker_environment.delete("ERYLO_RELEASE_PINNED_MOUNT_RECOVERY")
abort("release supervisor did not inherit authenticated outer admission") \
  unless worker_environment.delete("ERYLO_RELEASE_OUTER_AUTHENTICATED") == "1"
inherited_source_commit = worker_environment["ERYLO_RELEASE_SOURCE_COMMIT"]
abort("release supervisor source commit differs from the pinned handoff") \
  if inherited_source_commit && inherited_source_commit != source_commit
worker_environment["ERYLO_RELEASE_SOURCE_COMMIT"] = source_commit
capability_fd = Integer(worker_environment.fetch("ERYLO_RELEASE_WORKER_CAPABILITY_FD"), 10)
capability_read = IO.for_fd(capability_fd, "rb", autoclose: false)
abort("release supervisor worker capability is not an inherited pipe") unless capability_read.stat.pipe?
capability_read.close_on_exec = false
worker_environment["ERYLO_RELEASE_SUPERVISOR_HANDOFF"] = "1"
worker_spawn_options = {
  pgroup: watchdog_pid,
  control_write => :close,
  pinned_helper_io.fileno => :close,
  pinned_recovery_io.fileno => :close,
  close_others: false
}
worker_pid = Process.spawn(
  worker_environment,
  worker,
  *worker_arguments,
  worker_spawn_options
)
capability_read.close
_finished_pid, worker_status = Process.wait2(worker_pid)
control_write.write("N")
control_write.close
_watchdog_finished, watchdog_status = Process.wait2(watchdog_pid)
abort("release worker watchdog failed during normal settlement") unless watchdog_status.success?

pinned_recovery_io.rewind
device, recovery_error, recovery_status = Open3.capture3(
  "/usr/bin/ruby", pinned_recovery, repo, snapshot_mount, source_commit,
  close_others: false
)
abort(recovery_error.empty? ? "could not authenticate mounted source cleanup" : recovery_error) \
  unless recovery_status.success?
device = device.strip
abort("could not detach the settled release source image") \
  unless system("/usr/bin/hdiutil", "detach", "-quiet", device)
cleanup_environment = ENV.to_h.merge("ERYLO_RELEASE_SOURCE_ROOT" => repo)
pinned_helper_io.rewind
cleanup_status = system(
  cleanup_environment,
  "/usr/bin/ruby", pinned_helper,
  "remove", repo, snapshot_temp, "any",
  close_others: false
)
abort("could not remove the settled source snapshot transaction") unless cleanup_status
begin
  File.lstat(snapshot_temp)
  abort("pinned release cleanup reported success without removing its transaction")
rescue Errno::ENOENT
  nil
end

if worker_status.exited?
  exit(worker_status.exitstatus)
end
exit(128 + (worker_status.termsig || 1))
