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

phase_sections = harness.scan(
  /^if release_harness_runs ([a-z0-9-]+); then$\n(.*?)(?=^if release_harness_runs |\z)/m
).to_h
abort "could not map every executable release-harness phase" unless phase_sections.keys == guards
full_build_owners = phase_sections.each_with_object([]) do |(name, body), owners|
  owners << name if body.include?("Scripts/release/build-app.sh")
end
abort "the full production build must have one build-artifact owner: #{full_build_owners.inspect}" \
  unless full_build_owners == ["build-artifact"]
output_body = phase_sections.fetch("output-boundaries")
abort "output-boundaries must remain fixture-free" if output_body.match?(/^\s+prepare_[a-z0-9_]+/)
%w[private-key-marker assemble-traversal archive-traversal symlink-parent].each do |log_name|
  abort "output-boundaries does not prove the #{log_name} failure boundary" \
    unless output_body.match?(/^expect_failure_with_stderr "[^"]+" #{Regexp.escape(log_name)} \\$/)
end
release_library = File.read(File.expand_path("../../Scripts/release/lib.sh", __dir__))
build_script = File.read(File.expand_path("../../Scripts/release/build-app.sh", __dir__))
abort "production staging and compiled fixtures must share the release-product builder" \
  unless build_script.include?("release_build_swift_product") &&
    harness.include?("release_build_swift_product")
abort "the shared compiled fixture must preserve release mode, target, and warnings-as-errors" \
  unless release_library.include?("--configuration release") &&
    release_library.include?('--product "$product"') &&
    release_library.include?('--triple "$triple"') &&
    release_library.include?("-Xswiftc -warnings-as-errors")

%w[updater-vectors feed-vectors key-vectors].each do |name|
  body = phase_sections.fetch(name)
  prefix = name.split("-").first
  assembler = "#{prefix}_assembler"
  abort "#{name} must route isolated assembly through the compiled release fixture" \
    unless body.include?("#{assembler}+=(") &&
      body.include?('--binary "$fixture_binary"') &&
      body.include?('--framework "$fixture_framework"') &&
      body.include?('--toolchain "$fixture_toolchain"') &&
      body.include?('"${' + assembler + '[@]}"')
end
feed_body = phase_sections.fetch("feed-vectors")
key_body = phase_sections.fetch("key-vectors")
abort "feed-vectors must reuse its counted canonical assembly as the updater fixture" \
  unless feed_body.include?('if [[ "$feed_name" == canonical ]]') &&
    feed_body.include?('vector_app="$updater_app"')
abort "key-vectors must reuse its counted canonical assembly as the updater fixture" \
  unless key_body.include?('if [[ "$key_name" == canonical-32-bytes ]]') &&
    key_body.include?('vector_app="$updater_app"')

assembler_script = File.read(File.expand_path("../../Scripts/release/assemble-app.sh", __dir__))
bundle_validator = File.read(File.expand_path("../../Scripts/release/validate-app.sh", __dir__))
signer = File.read(File.expand_path("../../Scripts/release/sign-update.sh", __dir__))
shared_gate = "release_validate_signed_appcast_metadata"
abort "the assembler must reject malformed appcast metadata before toolchain or artifact work" \
  unless assembler_script.index(shared_gate) < assembler_script.index("release_capture_toolchain")
abort "the bundle validator must reject malformed appcast metadata before toolchain or artifact work" \
  unless bundle_validator.index(shared_gate) < bundle_validator.index("release_configure_developer_dir")
abort "update signing must reach the full-Xcode boundary immediately after appcast validation" \
  unless signer.index(shared_gate) < signer.index("release_require_full_xcode") &&
    signer.index("release_require_full_xcode") < signer.index('.release/build/arm64/release/Tools/sign_update')
abort "the vector harness must bind malformed consumer assertions to canonical diagnostics" \
  unless feed_body.scan("release_harness_queue_background_failure_with_stderr").length >= 3 &&
    key_body.scan("release_harness_queue_background_failure_with_stderr").length >= 3

archive_validator = File.read(File.expand_path("../../Scripts/release/validate-archive.sh", __dir__))
abort "archive fixture equivalence is not proven after extracted-app validation" \
  unless archive_validator.include?("unless actual == expected") &&
    archive_validator.include?("validate-app.sh\" \"$extracted_app")
archive_evidence_body = phase_sections.fetch("archive-evidence")
archive_evidence_fixture = harness.match(
  /^prepare_archive_evidence_fixtures\(\) \{\n(.*?)^\}/m
)&.captures&.first || abort("archive-evidence fixture is missing")
abort "archive-evidence must not build and validate an uncounted duplicate archive" \
  if archive_evidence_fixture.include?("archive-app.sh")
abort "archive-evidence must combine the predictable-symlink defense with counted post-staple validation" \
  unless archive_evidence_body.include?('set -- --post-staple --archive "$1" --app "$2"') &&
    archive_evidence_body.include?("archive validation leaves the planted predictable symlink untouched")
symbol_archiver = File.read(File.expand_path("../../Scripts/release/archive-symbols.sh", __dir__))
abort "symbol fixture equivalence is not proven after source dSYM validation" \
  unless symbol_archiver.include?("symbol archive differs from the validated dSYM")
filesystem_helper = File.read(File.expand_path("../../Scripts/release/fs-helper.rb", __dir__))
build_validation_body = phase_sections.fetch("build-validation")
abort "descriptor-anchored parent creation must reopen and validate a concurrent winner" \
  unless filesystem_helper.include?('mkdirat(current.fileno, value, 0o700, allow_exists: true)') &&
    filesystem_helper.include?('mkdirat(parent_fd, name, mode, allow_exists: true)')
abort "the concurrent temp-parent regression must gate two helpers after the same missing observation" \
  unless build_validation_body.scan("ERYLO_RELEASE_FS_TEST_PAUSE_STAGE=before-create-directory-tmp").length == 2 &&
    build_validation_body.include?('ERYLO_RELEASE_FS_TEST_GATE="$concurrent_create_gate"') &&
    build_validation_body.include?("anchored directory creation repairs unsafe modes and admits concurrent creators")
supervisor = File.read(File.expand_path("process-supervisor.rb", __dir__))
supervisor_tests = File.read(File.expand_path("process-supervisor-tests.sh", __dir__))
gate_name = "ERYLO_RELEASE_SUPERVISOR_TEST_READINESS_GATE"
abort "the trickled-readiness regression must use a test-only observer gate" \
  unless supervisor.include?(gate_name) && supervisor_tests.include?(gate_name) &&
    supervisor.include?("deadline += monotonic - gate_started") &&
    supervisor_tests.include?("an incomplete readiness prefix cannot satisfy the observer") &&
    supervisor_tests.include?("ERYLO_RELEASE_HARNESS_READINESS_TIMEOUT_SECONDS=0.08")

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
