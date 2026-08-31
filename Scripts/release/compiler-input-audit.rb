#!/usr/bin/ruby

require "digest"
require "json"
require "open3"

POLICY_PATH = "Config/ReleaseCompilerInputs.txt"

def command_output(*arguments)
  output, error, status = Open3.capture3(*arguments, binmode: true)
  abort(error.empty? ? "compiler audit Git lookup failed" : error) unless status.success?
  output
end

def canonical_blob(repository, commit, relative)
  listing = command_output("/usr/bin/git", "-C", repository, "ls-tree", "-z", commit, "--", relative)
  match = /\A(100644|100755) blob ([0-9a-f]{40,64})\t([^\0]+)\0\z/.match(listing)
  abort("compiler audit input is not one canonical tracked regular file: #{relative}") unless match && match[3] == relative
  bytes = command_output("/usr/bin/git", "-C", repository, "cat-file", "blob", match[2])
  [bytes, match[2], Digest::SHA256.hexdigest(bytes)]
end

def expected_manifest(repository, commit, tree)
  actual_tree = command_output("/usr/bin/git", "-C", repository, "rev-parse", "#{commit}^{tree}").strip
  abort("compiler audit source tree does not match its commit") unless actual_tree == tree
  policy_bytes, policy_object, policy_sha256 = canonical_blob(repository, commit, POLICY_PATH)
  abort("compiler input policy is not canonical UTF-8") unless policy_bytes.force_encoding(Encoding::UTF_8).valid_encoding?
  paths = policy_bytes.lines(chomp: true)
  abort("compiler input policy is empty or unsorted") if paths.empty? || paths != paths.sort || paths.uniq != paths
  abort("compiler input policy has a noncanonical path") unless paths.all? do |path|
    path == "Package.swift" ||
      /\ASources\/[A-Za-z0-9._-]+\/(?:[A-Za-z0-9._-]+\/)*[A-Za-z0-9._-]+\.swift\z/.match?(path)
  end
  inputs = paths.map do |path|
    _bytes, object_id, sha256 = canonical_blob(repository, commit, path)
    { "path" => path, "gitObject" => object_id, "sha256" => sha256 }
  end
  {
    "sourceCommit" => commit,
    "sourceTree" => tree,
    "policy" => {
      "path" => POLICY_PATH,
      "gitObject" => policy_object,
      "sha256" => policy_sha256
    },
    "inputs" => inputs
  }
end

mode = ARGV.shift || abort("missing compiler audit mode")
repository = File.realpath(ARGV.shift || abort("missing compiler audit repository"))
commit = ARGV.shift || abort("missing compiler audit commit")
tree = ARGV.shift || abort("missing compiler audit tree")
abort("invalid compiler audit commit") unless /\A[0-9a-f]{40}\z/.match?(commit)
abort("invalid compiler audit tree") unless /\A[0-9a-f]{40}\z/.match?(tree)
expected = expected_manifest(repository, commit, tree)

case mode
when "create"
  audit_path = ARGV.shift || abort("missing compiler audit log")
  output_path = ARGV.shift || abort("missing compiler audit output")
  audit_stat = File.lstat(audit_path)
  abort("compiler audit log is not one private regular file") \
    unless audit_stat.file? && audit_stat.nlink == 1 && audit_stat.uid == Process.euid && (audit_stat.mode & 0o777) == 0o600
  seen = {}
  File.readlines(audit_path, chomp: true).each do |line|
    match = /\A([^\t]+)\t([0-9a-f]{40,64})\t([0-9a-f]{64})\z/.match(line)
    abort("compiler audit log line is noncanonical") unless match
    entry = { "path" => match[1], "gitObject" => match[2], "sha256" => match[3] }
    abort("compiler audit recorded inconsistent bytes for one path") if seen.key?(match[1]) && seen[match[1]] != entry
    seen[match[1]] = entry
  end
  expected_entries = expected.fetch("inputs")
  abort("compiler audit does not cover the exact reviewed input set") unless seen.keys.sort == expected_entries.map { |entry| entry.fetch("path") }
  expected_entries.each do |entry|
    abort("compiler audit entry does not match the pinned Git blob") unless seen.fetch(entry.fetch("path")) == entry
  end
  File.open(output_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
    output.write(JSON.pretty_generate(expected) + "\n")
    output.flush
    output.fsync
  end
when "validate"
  manifest_path = ARGV.shift || abort("missing compiler input manifest")
  manifest_stat = File.lstat(manifest_path)
  abort("compiler input manifest is not one regular file") unless manifest_stat.file? && manifest_stat.nlink == 1
  actual = JSON.parse(File.read(manifest_path))
  abort("compiler input manifest does not match the pinned Git content") unless actual == expected
else
  abort("unknown compiler audit mode")
end
