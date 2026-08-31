#!/usr/bin/ruby

require "json"
require "open3"
require "pathname"

POLICY_PATH = "Config/ReleaseCompilerInputs.txt"

def fail_closed(message)
  abort("release compiler-input policy validation failed: #{message}")
end

begin
root = Pathname.new(ARGV.shift || ".").realpath
fail_closed("unexpected arguments") unless ARGV.empty?
fail_closed("repository root is not a directory") unless root.directory?

swift_path, find_error, find_status = Open3.capture3(
  "/usr/bin/xcrun", "--find", "swift", binmode: true
)
fail_closed("Swift driver could not be selected (#{find_error.lines.first.to_s.strip})") \
  unless find_status.success?
swift = Pathname.new(swift_path.strip)
fail_closed("selected Swift driver is not an absolute executable") \
  unless swift.absolute? && swift.file? && swift.executable?

description_bytes, describe_error, describe_status = Open3.capture3(
  swift.to_s,
  "package",
  "describe",
  "--type",
  "json",
  chdir: root.to_s,
  binmode: true
)
fail_closed("SwiftPM could not describe the package (#{describe_error.lines.first.to_s.strip})") \
  unless describe_status.success?
description = JSON.parse(description_bytes)
products = description.fetch("products")
targets = description.fetch("targets")
fail_closed("SwiftPM product description is malformed") \
  unless products.is_a?(Array) && targets.is_a?(Array)
product_matches = products.select { |product| product.is_a?(Hash) && product["name"] == "Erylo" }
fail_closed("SwiftPM must describe exactly one Erylo product") unless product_matches.length == 1

targets_by_name = {}
targets.each do |target|
  fail_closed("SwiftPM target description is malformed") unless target.is_a?(Hash)
  name = target.fetch("name")
  fail_closed("SwiftPM target name is invalid or duplicated") \
    unless name.is_a?(String) && /\A[A-Za-z0-9._-]+\z/.match?(name) && !targets_by_name.key?(name)
  targets_by_name[name] = target
end

pending = product_matches.fetch(0).fetch("targets")
fail_closed("Erylo product targets are malformed") \
  unless pending.is_a?(Array) && pending.all? { |name| name.is_a?(String) }
visited = {}
reviewed_paths = ["Package.swift"]
until pending.empty?
  name = pending.shift
  next if visited[name]
  target = targets_by_name[name]
  # External product dependencies are not local compiler inputs.
  next unless target
  visited[name] = true
  path = target.fetch("path")
  sources = target.fetch("sources")
  dependencies = target.fetch("target_dependencies", [])
  fail_closed("SwiftPM local target path is noncanonical: #{name}") \
    unless path.is_a?(String) && /\ASources\/[A-Za-z0-9._-]+\z/.match?(path)
  fail_closed("SwiftPM local target sources are malformed: #{name}") \
    unless sources.is_a?(Array) && sources.all? { |source| source.is_a?(String) }
  fail_closed("SwiftPM local target dependencies are malformed: #{name}") \
    unless dependencies.is_a?(Array) && dependencies.all? { |dependency| dependency.is_a?(String) }
  sources.each do |source|
    fail_closed("SwiftPM source path is noncanonical: #{name}/#{source}") \
      unless /\A(?:[A-Za-z0-9._-]+\/)*[A-Za-z0-9._-]+\.swift\z/.match?(source)
    relative = File.join(path, source)
    candidate = root.join(relative)
    stat = candidate.lstat
    fail_closed("SwiftPM source is not one regular non-symlink file: #{relative}") \
      unless stat.file? && !stat.symlink?
    reviewed_paths << relative
  end
  pending.concat(dependencies)
end

reviewed_paths.sort!
fail_closed("SwiftPM production source closure is duplicated") unless reviewed_paths.uniq == reviewed_paths
policy = root.join(POLICY_PATH)
policy_stat = policy.lstat
fail_closed("compiler-input policy is not one regular non-symlink file") \
  unless policy_stat.file? && !policy_stat.symlink?
policy_bytes = File.binread(policy)
fail_closed("compiler-input policy is not canonical UTF-8") \
  unless policy_bytes.force_encoding(Encoding::UTF_8).valid_encoding? && policy_bytes.end_with?("\n")
policy_paths = policy_bytes.lines(chomp: true)
fail_closed("compiler-input policy must be sorted and unique") \
  unless !policy_paths.empty? && policy_paths == policy_paths.sort && policy_paths.uniq == policy_paths
fail_closed("compiler-input policy differs from the Erylo product source closure") \
  unless policy_paths == reviewed_paths

puts "Release compiler-input policy matches the exact Erylo product source closure."
rescue Errno::ENOENT, JSON::ParserError, KeyError => error
  fail_closed(error.message)
end
