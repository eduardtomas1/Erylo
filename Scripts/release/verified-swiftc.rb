#!/usr/bin/ruby

require "digest"
require "json"
require "open3"
require "tempfile"

def required_environment(name)
  value = ENV.fetch(name, "")
  abort("missing verified compiler environment: #{name}") if value.empty?
  value
end

def command_output(*arguments)
  output, error, status = Open3.capture3(*arguments, binmode: true)
  abort(error.empty? ? "verified compiler Git lookup failed" : error) unless status.success?
  output
end

def canonical_blob(repository, commit, relative)
  listing = command_output("/usr/bin/git", "-C", repository, "ls-tree", "-z", commit, "--", relative)
  match = /\A(100644|100755) blob ([0-9a-f]{40,64})\t([^\0]+)\0\z/.match(listing)
  abort("compiler input is not one canonical tracked regular file: #{relative}") unless match && match[3] == relative
  bytes = command_output("/usr/bin/git", "-C", repository, "cat-file", "blob", match[2])
  [bytes, match[2], Digest::SHA256.hexdigest(bytes)]
end

real_swiftc = required_environment("ERYLO_RELEASE_REAL_SWIFTC")
real_frontend = required_environment("ERYLO_RELEASE_REAL_SWIFT_FRONTEND")
source_repository = File.realpath(required_environment("ERYLO_RELEASE_SOURCE_REPOSITORY"))
source_root = File.realpath(required_environment("ERYLO_RELEASE_SOURCE_ROOT"))
source_commit = required_environment("ERYLO_RELEASE_SOURCE_COMMIT")
input_directory = File.realpath(required_environment("ERYLO_RELEASE_COMPILER_INPUT_DIRECTORY"))
audit_path = File.expand_path(required_environment("ERYLO_RELEASE_COMPILER_AUDIT"))

abort("invalid verified compiler source commit") unless /\A[0-9a-f]{40}\z/.match?(source_commit)
abort("verified compiler executable is unavailable") unless File.file?(real_swiftc) && File.executable?(real_swiftc)
abort("verified compiler frontend is unavailable") unless File.file?(real_frontend) && File.executable?(real_frontend)
abort("verified compiler input directory is unsafe") unless File.directory?(input_directory) && !File.symlink?(input_directory)
abort("verified compiler file-list inputs are unsupported") \
  if ARGV.any? { |argument| argument == "-filelist" || argument.start_with?("-filelist=") }
policy_bytes, = canonical_blob(source_repository, source_commit, "Config/ReleaseCompilerInputs.txt")
abort("verified compiler policy is not canonical UTF-8") unless policy_bytes.force_encoding(Encoding::UTF_8).valid_encoding?
reviewed_inputs = policy_bytes.lines(chomp: true)
abort("verified compiler policy is empty, unsorted, or duplicated") \
  if reviewed_inputs.empty? || reviewed_inputs != reviewed_inputs.sort || reviewed_inputs.uniq != reviewed_inputs

unless ENV["ERYLO_RELEASE_SWIFTC_DRIVER_ACTIVE"] == "1"
  ENV["ERYLO_RELEASE_SWIFTC_DRIVER_ACTIVE"] = "1"
  exec(real_swiftc, "-driver-use-frontend-path", File.expand_path(__FILE__), *ARGV)
end

root_prefix = source_root + File::SEPARATOR
release_scratch_prefix = File.join(source_repository, ".release") + File::SEPARATOR
expanded_arguments = ARGV.flat_map do |argument|
  next argument unless argument.start_with?("@")
  response_input = File.expand_path(argument.delete_prefix("@"))
  response_file = File.realpath(response_input)
  response_stat = File.lstat(response_file)
  abort("verified compiler response file is outside private release staging") \
    unless response_file.start_with?(release_scratch_prefix)
  abort("verified compiler response file is unsafe") \
    unless response_stat.file? && response_stat.nlink == 1 && response_stat.uid == Process.euid && (response_stat.mode & 0o022).zero?
  response_bytes = File.binread(response_file)
  abort("verified compiler response file is not canonical UTF-8") \
    unless response_bytes.force_encoding(Encoding::UTF_8).valid_encoding? && response_bytes.end_with?("\n")
  response_lines = response_bytes.lines(chomp: true)
  abort("verified compiler response file is empty or duplicated") \
    if response_lines.empty? || response_lines.uniq != response_lines
  response_lines.each do |path|
    abort("verified compiler response file contains a non-source argument") \
      unless path.start_with?(root_prefix) && path.end_with?(".swift") && !path.match?(/[\0\r\t]/)
  end
  response_lines
rescue Errno::ENOENT
  abort("verified compiler response file is missing")
end
ARGV.replace(expanded_arguments)

tracked_arguments = []
ARGV.each_with_index do |argument, index|
  next if argument.start_with?("-")
  absolute = File.expand_path(argument)
  next unless argument.include?(File::SEPARATOR) || File.exist?(absolute)
  abort("compiler Swift source input is outside the reviewed source root") \
    if !absolute.start_with?(root_prefix) && argument.end_with?(".swift")
  next unless absolute.start_with?(root_prefix)
  relative = absolute.delete_prefix(root_prefix)
  abort("compiler input path is noncanonical") if relative.empty? || relative.split(File::SEPARATOR).any? { |part| part.empty? || part == "." || part == ".." }
  abort("compiler input is not in the reviewed pinned policy: #{relative}") unless reviewed_inputs.include?(relative)
  abort("reviewed compiler input is not a Swift source: #{relative}") unless relative.end_with?(".swift")
  tracked_arguments << [index, absolute, relative]
end

if tracked_arguments.empty?
  exec(real_frontend, *ARGV)
end

held_files = []
overlay_roots = tracked_arguments.map do |_index, absolute, relative|
  bytes, object_id, sha256 = canonical_blob(source_repository, source_commit, relative)
  source = Tempfile.new(["compiler-input-", ".swift"], input_directory, binmode: true)
  source.write(bytes)
  source.flush
  source.fsync
  source.chmod(0o400)
  source.rewind
  abort("held compiler source bytes differ from the pinned Git blob: #{relative}") \
    unless Digest::SHA256.hexdigest(source.read) == sha256
  source.rewind
  source_stat = source.stat
  abort("held compiler source inode is unsafe: #{relative}") \
    unless source_stat.file? && source_stat.uid == Process.euid && source_stat.nlink == 1 && (source_stat.mode & 0o777) == 0o400
  File.unlink(source.path)
  abort("held compiler source retained a pathname alias: #{relative}") unless source.stat.nlink.zero?
  source.rewind
  abort("anonymous compiler source bytes changed before inheritance: #{relative}") \
    unless Digest::SHA256.hexdigest(source.read) == sha256
  source.rewind
  source.close_on_exec = false
  held_files << source

  File.open(audit_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |audit|
    audit.flock(File::LOCK_EX)
    audit.write([relative, object_id, sha256].join("\t") + "\n")
    audit.flush
    audit.fsync
  end

  {
    "type" => "file",
    "name" => absolute,
    "external-contents" => "/dev/fd/#{source.fileno}"
  }
end

overlay = Tempfile.new(["compiler-overlay-", ".json"], input_directory, binmode: true)
overlay_bytes = JSON.generate({
  "version" => 0,
  "case-sensitive" => "true",
  "roots" => overlay_roots
})
overlay.write(overlay_bytes)
overlay.flush
overlay.fsync
overlay.chmod(0o400)
overlay.rewind
abort("held compiler overlay bytes changed before unlink") \
  unless Digest::SHA256.hexdigest(overlay.read) == Digest::SHA256.hexdigest(overlay_bytes)
overlay.rewind
overlay_stat = overlay.stat
abort("held compiler overlay inode is unsafe") \
  unless overlay_stat.file? && overlay_stat.uid == Process.euid && overlay_stat.nlink == 1 && (overlay_stat.mode & 0o777) == 0o400
File.unlink(overlay.path)
abort("held compiler overlay retained a pathname alias") unless overlay.stat.nlink.zero?
overlay.rewind
abort("anonymous compiler overlay bytes changed before inheritance") \
  unless Digest::SHA256.hexdigest(overlay.read) == Digest::SHA256.hexdigest(overlay_bytes)
overlay.rewind
overlay.close_on_exec = false
held_files << overlay

frontend_arguments = if ARGV.first == "-frontend"
  [ARGV.first, "-vfsoverlay", "/dev/fd/#{overlay.fileno}", *ARGV.drop(1)]
else
  ["-vfsoverlay", "/dev/fd/#{overlay.fileno}", *ARGV]
end
exec(real_frontend, *frontend_arguments)
