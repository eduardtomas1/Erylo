#!/usr/bin/ruby

require "json"

EXPECTED_TOTAL = 548
manifest = File.expand_path("shards.tsv", __dir__)
rows = []
File.readlines(manifest, chomp: true).each do |line|
  next if line.empty? || line.start_with?("#")

  fields = line.split("\t", -1)
  abort "invalid release-harness shard row: #{line.inspect}" unless fields.length == 3
  name, count_text, timeout_text = fields
  abort "invalid release-harness shard name: #{name.inspect}" unless /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.match?(name)
  count = Integer(count_text, 10)
  timeout = Integer(timeout_text, 10)
  abort "invalid release-harness check count for #{name}" unless count.positive?
  abort "invalid release-harness timeout for #{name}" unless timeout.between?(1, 900)
  rows << [name, count, timeout]
rescue ArgumentError
  abort "non-integer release-harness shard contract: #{line.inspect}"
end

names = rows.map(&:first)
duplicates = names.select { |name| names.count(name) > 1 }.uniq
abort "duplicate release-harness shards: #{duplicates.join(', ')}" unless duplicates.empty?
total = rows.sum { |_name, count, _timeout| count }
abort "release-harness shard count is #{total}, expected #{EXPECTED_TOTAL}" unless total == EXPECTED_TOTAL

harness = File.read(File.expand_path("run.sh", __dir__))
guards = harness.scan(/^if release_harness_runs ([a-z0-9-]+); then$/).flatten
guard_duplicates = guards.select { |name| guards.count(name) > 1 }.uniq
abort "duplicate executable release-harness phases: #{guard_duplicates.join(', ')}" unless guard_duplicates.empty?
abort "manifest and executable release-harness phases differ: manifest=#{names.inspect} executable=#{guards.inspect}" \
  unless guards == names
markers = harness.scan(/^release_harness_phase ([a-z0-9-]+)$/).flatten.reject { |name| name == "complete" }
abort "phase markers do not match the executable shard union: #{markers.inspect}" unless markers == guards
unless harness.include?('[[ "$release_harness_shard" == all || "$release_harness_shard" == "$1" ]]')
  abort "all mode is not the exact union of named release-harness phases"
end

matrix = {
  "include" => rows.map do |name, count, timeout|
    { "shard" => name, "expected_checks" => count, "command_timeout_seconds" => timeout }
  end
}
if ARGV.empty?
  puts "Release harness shard contract covers #{total} checks across #{rows.length} unique executable phases."
elsif ARGV.length == 2 && ARGV.first == "--github-output"
  File.open(ARGV.last, "a") { |output| output.puts("matrix=#{JSON.generate(matrix)}") }
else
  abort "usage: #{File.basename($PROGRAM_NAME)} [--github-output PATH]"
end
