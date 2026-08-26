#!/usr/bin/ruby

require "digest"
require "find"
require "open3"

def command_output(*arguments)
  output, error, status = Open3.capture3(*arguments, binmode: true)
  abort(error.empty? ? "source-tree Git lookup failed" : error) unless status.success?
  output
end

repository = File.realpath(ARGV.fetch(0))
commit = ARGV.fetch(1)
root = File.realpath(ARGV.fetch(2))
abort("invalid source-tree commit") unless /\A[0-9a-f]{40}\z/.match?(commit)
root_stat = File.lstat(root)
abort("verified source root is not one read-only directory") \
  unless root_stat.directory? && !root_stat.symlink? && (root_stat.mode & 0o222).zero?

listing = command_output("/usr/bin/git", "-C", repository, "ls-tree", "-r", "-z", "--full-tree", commit)
expected = {}
listing.split("\0").each do |record|
  next if record.empty?
  match = /\A(100644|100755) blob ([0-9a-f]{40,64})\t(.+)\z/m.match(record)
  abort("release commit contains an unsupported source-tree entry") unless match
  path = match[3]
  abort("release commit contains a noncanonical path") \
    if path.start_with?("/") || path.split("/").any? { |part| part.empty? || part == "." || part == ".." }
  abort("release commit contains a duplicate path") if expected.key?(path)
  expected[path] = [match[1], match[2]]
end

actual = {}
Find.find(root) do |path|
  relative = path == root ? "." : path.delete_prefix(root + File::SEPARATOR)
  stat = File.lstat(path)
  case stat.ftype
  when "directory"
    abort("verified source directory is writable: #{relative}") unless (stat.mode & 0o222).zero?
  when "file"
    abort("verified source file is writable: #{relative}") unless (stat.mode & 0o222).zero?
    abort("verified source file is hardlinked: #{relative}") unless stat.nlink == 1
    actual[relative] = ["file", stat]
  when "link"
    abort("verified source tree may not contain symlinks: #{relative}")
  else
    abort("verified source tree contains an unsupported entry: #{relative}")
  end
end

abort("verified source tree path set differs from the pinned commit") unless actual.keys.sort == expected.keys.sort
manifest = Digest::SHA256.new
expected.keys.sort.each do |relative|
  mode, object_id = expected.fetch(relative)
  kind, stat = actual.fetch(relative)
  path = File.join(root, relative)
  bytes = File.binread(path)
  abort("verified source entry type differs from the pinned commit: #{relative}") unless kind == "file"
  expected_executable = mode == "100755"
  abort("verified source executable mode differs from the pinned commit: #{relative}") \
    unless ((stat.mode & 0o111) != 0) == expected_executable
  pinned = command_output("/usr/bin/git", "-C", repository, "cat-file", "blob", object_id)
  abort("verified source bytes differ from the pinned Git object: #{relative}") unless bytes == pinned
  manifest << relative << "\0" << mode << "\0" << object_id << "\0" << Digest::SHA256.hexdigest(bytes) << "\0"
end

puts manifest.hexdigest
