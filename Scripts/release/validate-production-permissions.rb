#!/usr/bin/ruby

require "json"
require "digest"
require "open3"
require "pathname"
require "rexml/document"

POLICY_PATH = "Config/ProductionCapabilities.json"
INFO_TEMPLATE_PATH = "Resources/App/Info.plist.in"
ENTITLEMENTS_PATH = "Resources/App/Erylo.entitlements"
PRODUCTION_MANIFEST_PATH = "Sources/EryloAppRuntime/ProductionCapabilities.swift"
COMPILER_INPUT_POLICY_PATH = "Config/ReleaseCompilerInputs.txt"
REVIEWED_CAPABILITY_MODULES = %w[
  Sources/EryloGlance
  Sources/EryloIntegrations
].freeze
FORBIDDEN_DIRECT_COMPOSITION_IDENTIFIERS = %w[
  FoundationMediaScriptProcessRunner
  MediaScriptExecuting
  MediaScriptProcessRunning
  MediaScriptRequest
  MediaScriptRoute
  ProcessMediaScriptExecutor
].freeze

UTILITY_RULES = {
  "apple-music" => {
    identifiers: ["AppleMusicDesktopAdapter"],
    privacy: ["NSAppleEventsUsageDescription"],
    entitlements: ["com.apple.security.automation.apple-events"]
  },
  "battery" => {
    identifiers: ["PowerGlanceProvider"],
    privacy: [],
    entitlements: []
  },
  "calendar" => {
    identifiers: ["CalendarGlanceProvider", "EKEventStore", "EventKit", "EventKitCalendarEventSource"],
    privacy: ["NSCalendarsFullAccessUsageDescription"],
    entitlements: []
  },
  "file-hold" => {
    identifiers: ["FileHoldStore", "EryloFileHold"],
    privacy: [],
    entitlements: []
  },
  "focus-timer" => {
    identifiers: ["FocusTimerRuntimeService"],
    privacy: [],
    entitlements: []
  },
  "local-integrations" => {
    identifiers: ["UnixSocketIntegrationService", "EryloLocalIntegrations"],
    privacy: [],
    entitlements: []
  },
  "spotify" => {
    identifiers: ["SpotifyDesktopAdapter"],
    privacy: ["NSAppleEventsUsageDescription"],
    entitlements: ["com.apple.security.automation.apple-events"]
  },
  "volume" => {
    identifiers: ["VolumeGlanceProvider"],
    privacy: [],
    entitlements: []
  }
}.freeze

UTILITY_CASES = {
  "appleMusic" => "apple-music",
  "battery" => "battery",
  "calendar" => "calendar",
  "fileHold" => "file-hold",
  "focusTimer" => "focus-timer",
  "localIntegrations" => "local-integrations",
  "spotify" => "spotify",
  "volume" => "volume"
}.freeze

class DuplicateJSONKeyError < StandardError; end

class DuplicateRejectingHash < Hash
  def []=(key, value)
    raise DuplicateJSONKeyError, key if key?(key)
    super
  end
end

def fail_closed(message)
  abort("production permission validation failed: #{message}")
end

def regular_file(path, label)
  candidate = Pathname.new(path)
  fail_closed("#{label} is missing") unless candidate.exist?
  stat = candidate.lstat
  fail_closed("#{label} must be one regular non-symlink file") unless stat.file? && !stat.symlink?
  candidate.realpath
end

def repository_file(root, relative)
  candidate = regular_file(root.join(relative), relative)
  prefix = root.to_s + File::SEPARATOR
  fail_closed("#{relative} escapes the repository root") unless candidate.to_s.start_with?(prefix)
  candidate
end

def repository_swift_files(root, relative_directory)
  directory = root.join(relative_directory)
  fail_closed("#{relative_directory} is missing") unless directory.exist?
  stat = directory.lstat
  fail_closed("#{relative_directory} must be one real directory") unless stat.directory? && !stat.symlink?
  files = []
  pending = [[directory, relative_directory]]
  until pending.empty?
    current, current_relative = pending.shift
    Dir.children(current).sort.each do |name|
      fail_closed("unsafe Swift source path in #{relative_directory}") \
        unless /\A[A-Za-z0-9._-]+\z/.match?(name)
      child = current.join(name)
      child_relative = File.join(current_relative, name)
      child_stat = child.lstat
      fail_closed("symlinks are forbidden in #{relative_directory}") if child_stat.symlink?
      if child_stat.directory?
        pending << [child, child_relative]
      elsif child_stat.file?
        files << repository_file(root, child_relative) if name.end_with?(".swift")
      else
        fail_closed("special filesystem entries are forbidden in #{relative_directory}")
      end
    end
  end
  files.sort_by(&:to_s)
end

def compiler_input_swift_files(root)
  policy_path = repository_file(root, COMPILER_INPUT_POLICY_PATH)
  bytes = File.binread(policy_path)
  fail_closed("compiler-input policy is not canonical UTF-8") \
    unless bytes.force_encoding(Encoding::UTF_8).valid_encoding? && bytes.end_with?("\n")
  paths = bytes.lines(chomp: true)
  fail_closed("compiler-input policy must be sorted and unique") \
    unless !paths.empty? && paths == paths.sort && paths.uniq == paths
  swift_paths = paths.select { |path| path != "Package.swift" && path.end_with?(".swift") }
  fail_closed("compiler-input policy contains a noncanonical Swift path") unless swift_paths.all? do |path|
    /\ASources\/[A-Za-z0-9._-]+\/(?:[A-Za-z0-9._-]+\/)*[A-Za-z0-9._-]+\.swift\z/.match?(path)
  end
  swift_paths.map { |path| repository_file(root, path) }
end

def canonical_source_tree_sha256(root, paths)
  digest = Digest::SHA256.new
  relative_paths = paths.map { |path| path.relative_path_from(root).to_s }
  fail_closed("reviewed module source tree is empty or duplicated") \
    if relative_paths.empty? || relative_paths.uniq.length != relative_paths.length
  paths.zip(relative_paths).sort_by(&:last).each do |path, relative|
    bytes = File.binread(path)
    digest.update([relative.bytesize].pack("Q>"))
    digest.update(relative.b)
    digest.update([bytes.bytesize].pack("Q>"))
    digest.update(bytes)
  end
  digest.hexdigest
end

def identifier_start_byte?(byte)
  byte == 95 || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
end

def identifier_byte?(byte)
  identifier_start_byte?(byte) || (byte >= 48 && byte <= 57)
end

def skip_swift_block_comment(bytes, index)
  depth = 1
  index += 2
  while index < bytes.bytesize
    if bytes.getbyte(index) == 47 && bytes.getbyte(index + 1) == 42
      depth += 1
      index += 2
    elsif bytes.getbyte(index) == 42 && bytes.getbyte(index + 1) == 47
      depth -= 1
      index += 2
      return index if depth.zero?
    else
      index += 1
    end
  end
  fail_closed("production composition contains an unterminated block comment")
end

def scan_swift_string(bytes, index, identifier_tokens, hash_count)
  triple = bytes.byteslice(index, 3) == '"""'
  quote_count = triple ? 3 : 1
  index += quote_count
  closing = ('"' * quote_count) + ('#' * hash_count)
  interpolation = '\\' + ('#' * hash_count) + '('
  while index < bytes.bytesize
    return index + closing.bytesize if bytes.byteslice(index, closing.bytesize) == closing
    if bytes.byteslice(index, interpolation.bytesize) == interpolation
      index = scan_swift_code(
        bytes,
        index + interpolation.bytesize,
        identifier_tokens,
        interpolation_depth: 1
      )
      next
    end
    if hash_count.zero? && bytes.getbyte(index) == 92
      index += 2
    else
      index += 1
    end
  end
  fail_closed("production composition contains an unterminated string literal")
end

def scan_swift_code(bytes, index, identifier_tokens, interpolation_depth: nil)
  while index < bytes.bytesize
    byte = bytes.getbyte(index)
    following = bytes.getbyte(index + 1)
    if byte == 47 && following == 47
      line_feed = bytes.index("\n", index + 2)
      carriage_return = bytes.index("\r", index + 2)
      newline = [line_feed, carriage_return].compact.min
      index = newline || bytes.bytesize
    elsif byte == 47 && following == 42
      index = skip_swift_block_comment(bytes, index)
    elsif byte == 34
      index = scan_swift_string(bytes, index, identifier_tokens, 0)
    elsif byte == 35
      hash_count = 0
      hash_count += 1 while bytes.getbyte(index + hash_count) == 35
      if bytes.getbyte(index + hash_count) == 34
        index = scan_swift_string(bytes, index + hash_count, identifier_tokens, hash_count)
      else
        index += 1
      end
    elsif identifier_start_byte?(byte)
      ending = index + 1
      ending += 1 while ending < bytes.bytesize && identifier_byte?(bytes.getbyte(ending))
      identifier_tokens << {
        value: bytes.byteslice(index, ending - index),
        escaped: index.positive? && bytes.getbyte(index - 1) == 96 && bytes.getbyte(ending) == 96
      }
      index = ending
    elsif interpolation_depth && byte == 40
      interpolation_depth += 1
      index += 1
    elsif interpolation_depth && byte == 41
      interpolation_depth -= 1
      return index + 1 if interpolation_depth.zero?
      index += 1
    else
      index += 1
    end
  end
  fail_closed("production composition contains an unterminated string interpolation") if interpolation_depth
  index
end

def swift_identifiers(source)
  swift_identifier_tokens(source).map { |token| token.fetch(:value) }
end

def swift_identifier_tokens(source)
  tokens = []
  scan_swift_code(source.b, 0, tokens)
  tokens
end

def sexpression_blocks(source, form)
  marker = "(#{form}"
  node_start = /^[ \t]*#{Regexp.escape(marker)}(?=[ )])/
  blocks = []
  search_index = 0
  while (match = source.match(node_start, search_index))
    start_index = match.begin(0) + match[0].index(marker)
    depth = 0
    in_string = false
    escaped = false
    index = start_index
    while index < source.bytesize
      byte = source.getbyte(index)
      if in_string
        if escaped
          escaped = false
        elsif byte == 92
          escaped = true
        elsif byte == 34
          in_string = false
        end
      elsif byte == 34
        in_string = true
      elsif byte == 40
        depth += 1
      elsif byte == 41
        depth -= 1
        if depth.zero?
          blocks << source.byteslice(start_index, index - start_index + 1)
          # Advance past only this node marker so nested nodes of the same form
          # remain independently observable to structural callers.
          search_index = start_index + marker.bytesize
          break
        end
      end
      index += 1
    end
    fail_closed("Swift parser returned an incomplete #{form} syntax node") unless depth.zero?
  end
  blocks
end

def sexpression_header_fields(block, expected_form)
  header = block.lines.first.to_s.strip
  prefix = "(#{expected_form}"
  fail_closed("Swift parser returned an unexpected syntax node") \
    unless header.start_with?(prefix) && [nil, " ", ")"].include?(header[prefix.length])
  body = header.byteslice(prefix.bytesize, header.bytesize - prefix.bytesize).to_s
  tokens = []
  token = +""
  quoted = false
  escaped = false
  bracket_depth = 0
  body.each_char do |character|
    if quoted
      token << character
      if escaped
        escaped = false
      elsif character == "\\"
        escaped = true
      elsif character == '"'
        quoted = false
      end
    elsif character == '"'
      quoted = true
      token << character
    elsif character == "["
      bracket_depth += 1
      token << character
    elsif character == "]"
      bracket_depth -= 1
      fail_closed("Swift parser returned a malformed syntax-node header") if bracket_depth.negative?
      token << character
    elsif character.match?(/\s/) && bracket_depth.zero?
      unless token.empty?
        tokens << token
        token = +""
      end
    else
      token << character
    end
  end
  tokens << token unless token.empty?
  fail_closed("Swift parser returned a malformed syntax-node header") if quoted || !bracket_depth.zero?

  attributes = {}
  positional = []
  flags = []
  tokens.each do |entry|
    entry = entry.delete_suffix(")")
    next if entry.empty?
    if entry.include?("=")
      key, value = entry.split("=", 2)
      fail_closed("Swift parser returned a duplicate or malformed node attribute") \
        unless /\A[A-Za-z_][A-Za-z0-9_]*\z/.match?(key) && !attributes.key?(key)
      attributes[key] = if value.start_with?('"')
                          JSON.parse(value)
                        else
                          value
                        end
    elsif entry.start_with?('"')
      positional << JSON.parse(entry)
    else
      flags << entry
    end
  end
  [attributes, positional, flags]
rescue JSON::ParserError
  fail_closed("Swift parser returned a malformed quoted node attribute")
end

def sexpression_nodes(source, form)
  sexpression_blocks(source, form).select do |block|
    header = block.lines.first.to_s.strip
    prefix = "(#{form}"
    header.start_with?(prefix) && [nil, " ", ")"].include?(header[prefix.length])
  end
end

def syntax_node_attribute_values(source, form, attribute)
  prefix = "(#{form}"
  source.lines.each_with_object([]) do |line, values|
    header = line.strip
    next unless header.start_with?(prefix) && [nil, " ", ")"].include?(header[prefix.length])
    attributes, = sexpression_header_fields(header, form)
    values << attributes[attribute] if attributes.key?(attribute)
  end
end

def swift_parse_tree(path)
  compiler_output, compiler_error, compiler_status = Open3.capture3(
    "/usr/bin/xcrun", "--find", "swiftc", binmode: true
  )
  fail_closed("Swift compiler could not be selected (#{compiler_error.strip})") \
    unless compiler_status.success?
  compiler = Pathname.new(compiler_output.strip).realpath
  fail_closed("selected Swift compiler is not executable") unless compiler.file? && compiler.executable?
  output, error, status = Open3.capture3(
    compiler.to_s,
    "-frontend",
    "-dump-parse",
    "-swift-version",
    "6",
    path.to_s,
    binmode: true
  )
  fail_closed("production capability manifest does not parse as Swift (#{error.lines.first.to_s.strip})") \
    unless status.success?
  output
end

def parse_plist_node(element)
  case element.name
  when "dict"
    children = element.elements.to_a
    fail_closed("plist dictionary has an unmatched key or value") unless children.length.even?
    result = {}
    children.each_slice(2) do |key_element, value_element|
      fail_closed("plist dictionary contains a non-key entry") unless key_element.name == "key"
      key = key_element.text.to_s
      fail_closed("plist dictionary contains an empty or duplicate key") if key.empty? || result.key?(key)
      result[key] = parse_plist_node(value_element)
    end
    result
  when "array"
    element.elements.map { |child| parse_plist_node(child) }
  when "string", "data", "date"
    element.text.to_s
  when "integer"
    Integer(element.text.to_s, 10)
  when "real"
    Float(element.text.to_s)
  when "true"
    true
  when "false"
    false
  else
    fail_closed("plist contains unsupported element #{element.name}")
  end
rescue ArgumentError
  fail_closed("plist contains an invalid #{element.name} value")
end

def parse_plist(path)
  document = REXML::Document.new(File.binread(path))
  plist = document.root
  fail_closed("#{path} is not an XML plist") unless plist&.name == "plist"
  roots = plist.elements.to_a
  fail_closed("#{path} must contain exactly one plist root value") unless roots.length == 1
  parse_plist_node(roots.fetch(0))
rescue REXML::ParseException => error
  fail_closed("#{path} is not a valid XML plist (#{error.message.lines.first.to_s.strip})")
end

def canonical_string_array(value, label)
  fail_closed("#{label} must be an array of strings") unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) }
  fail_closed("#{label} must be sorted and unique") unless value == value.sort && value.uniq == value
  value
end

def load_policy(root)
  path = repository_file(root, POLICY_PATH)
  policy = JSON.parse(File.binread(path), object_class: DuplicateRejectingHash)
  expected_keys = %w[
    entitlementAllowlist
    mountedUtilities
    privacyUsageDescriptionAllowlist
    reviewedModuleSourceSHA256
    schemaVersion
  ]
  fail_closed("production capability policy root must be a dictionary") unless policy.is_a?(Hash)
  fail_closed("production capability policy fields are noncanonical") unless policy.keys.sort == expected_keys
  schema_version = policy.fetch("schemaVersion")
  fail_closed("production capability policy schema is unsupported") \
    unless schema_version.instance_of?(Integer) && schema_version == 2

  mounted = canonical_string_array(policy.fetch("mountedUtilities"), "mountedUtilities")
  privacy = canonical_string_array(
    policy.fetch("privacyUsageDescriptionAllowlist"),
    "privacyUsageDescriptionAllowlist"
  )
  entitlements = canonical_string_array(policy.fetch("entitlementAllowlist"), "entitlementAllowlist")
  reviewed_module_hashes = policy.fetch("reviewedModuleSourceSHA256")
  fail_closed("reviewed module source hashes must be a dictionary") \
    unless reviewed_module_hashes.is_a?(Hash)
  fail_closed("reviewed module source hash set is noncanonical") \
    unless reviewed_module_hashes.keys.sort == REVIEWED_CAPABILITY_MODULES.sort
  reviewed_module_hashes.each do |path, sha256|
    fail_closed("reviewed module source hash is invalid: #{path}") \
      unless sha256.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(sha256)
  end
  unknown_utilities = mounted - UTILITY_RULES.keys
  fail_closed("unknown mounted utility: #{unknown_utilities.join(", ")}") unless unknown_utilities.empty?

  required_privacy = mounted.flat_map { |utility| UTILITY_RULES.fetch(utility).fetch(:privacy) }.uniq.sort
  required_entitlements = mounted.flat_map do |utility|
    UTILITY_RULES.fetch(utility).fetch(:entitlements)
  end.uniq.sort
  fail_closed("privacy usage-description allowlist does not match mounted utilities") unless privacy == required_privacy
  fail_closed("entitlement allowlist does not match mounted utilities") unless entitlements == required_entitlements

  {
    mounted: mounted,
    privacy: privacy,
    entitlements: entitlements,
    reviewed_module_hashes: reviewed_module_hashes
  }
rescue JSON::ParserError => error
  fail_closed("production capability policy is invalid JSON (#{error.message})")
rescue DuplicateJSONKeyError => error
  fail_closed("production capability policy contains a duplicate key: #{error.message}")
rescue KeyError => error
  fail_closed("production capability policy is incomplete (#{error.message})")
end

def validate_composition(root, policy)
  reviewed_module_paths = REVIEWED_CAPABILITY_MODULES.each_with_object({}) do |relative, paths|
    sources = repository_swift_files(root, relative)
    actual_sha256 = canonical_source_tree_sha256(root, sources)
    expected_sha256 = policy.fetch(:reviewed_module_hashes).fetch(relative)
    fail_closed("reviewed capability module source digest differs: #{relative}") \
      unless actual_sha256 == expected_sha256
    paths[relative] = sources
  end
  reviewed_sources = reviewed_module_paths.values.flatten.map(&:to_s).each_with_object({}) do |path, values|
    values[path] = true
  end
  source_paths = (
    compiler_input_swift_files(root) +
      repository_swift_files(root, "Sources/EryloApp") +
      repository_swift_files(root, "Sources/EryloAppRuntime")
  ).uniq.reject { |path| reviewed_sources.key?(path.to_s) }
  fail_closed("production composition source set is empty") if source_paths.empty?
  source_identifiers = source_paths.map do |path|
    source = File.binread(path)
    identifier_tokens = swift_identifier_tokens(source)
    wrapper_observed = identifier_tokens.each_with_index.any? do |token, index|
      next false unless token.fetch(:value) == "EryloGlance"
      previous = index.positive? ? identifier_tokens.fetch(index - 1) : nil
      !previous || previous.fetch(:value) != "import" || previous.fetch(:escaped)
    end
    [identifier_tokens.map { |token| token.fetch(:value) }, wrapper_observed]
  end
  identifiers = source_identifiers.flat_map(&:first).each_with_object({}) do |identifier, values|
    values[identifier] = true
  end
  direct_execution_seams = FORBIDDEN_DIRECT_COMPOSITION_IDENTIFIERS.select do |identifier|
    identifiers.key?(identifier)
  end
  fail_closed(
    "production composition uses a direct media execution seam: #{direct_execution_seams.join(", ")}"
  ) unless direct_execution_seams.empty?
  calendar_wrapper_observed = source_identifiers.any?(&:last)

  observed = UTILITY_RULES.each_with_object([]) do |(utility, rule), values|
    identifier_observed = rule.fetch(:identifiers).any? { |identifier| identifiers.key?(identifier) }
    values << utility if identifier_observed || (utility == "calendar" && calendar_wrapper_observed)
  end.sort
  fail_closed(
    "mounted utility set differs from the reviewed allowlist (observed #{observed.join(", ")})"
  ) unless observed == policy.fetch(:mounted)

  manifest_path = repository_file(root, PRODUCTION_MANIFEST_PATH)
  syntax_tree = swift_parse_tree(manifest_path)
  bindings = sexpression_nodes(syntax_tree, "pattern_binding_decl").select do |block|
    sexpression_nodes(block, "pattern_named").any? do |pattern|
      _attributes, positional, = sexpression_header_fields(pattern, "pattern_named")
      positional == ["mountedUtilities"]
    end
  end
  fail_closed("production composition must contain one canonical mounted-utility declaration") \
    unless bindings.length == 1
  binding = bindings.fetch(0)
  variable_declarations = sexpression_nodes(syntax_tree, "var_decl").select do |block|
    _attributes, positional, = sexpression_header_fields(block, "var_decl")
    positional == ["mountedUtilities"]
  end
  _attributes, _positional, variable_flags = if variable_declarations.length == 1
                                                sexpression_header_fields(
                                                  variable_declarations.fetch(0),
                                                  "var_decl"
                                                )
                                              else
                                                [{}, [], []]
                                              end
  fail_closed("production mounted-utility declaration must be one static let") \
    unless variable_declarations.length == 1 &&
      variable_flags.include?("let") && variable_flags.include?("static")
  type_names = syntax_node_attribute_values(binding, "type_unqualified_ident", "id")
  fail_closed("production mounted-utility declaration is malformed") \
    unless type_names.include?("Set") && type_names.include?("ProductionUtility")
  initializers = sexpression_nodes(binding, "original_init=array_expr")
  fail_closed("production mounted-utility declaration must use one literal array") \
    unless initializers.length == 1
  initializer = initializers.fetch(0)
  member_names = syntax_node_attribute_values(initializer, "unresolved_member_expr", "name")
  fail_closed("production mounted-utility array contains a nonliteral expression") \
    unless member_names.length == policy.fetch(:mounted).length &&
      %w[
        binary_expr call_expr closure_expr dictionary_expr if_expr integer_literal_expr
        nil_literal_expr string_literal_expr switch_expr tuple_expr unresolved_decl_ref_expr
      ].none? { |form| sexpression_nodes(initializer, form).any? }
  case_names = member_names
  fail_closed("production mounted-utility declaration must be sorted and unique") \
    unless !case_names.empty? && case_names == case_names.sort && case_names.uniq == case_names
  unknown_cases = case_names - UTILITY_CASES.keys
  fail_closed("unknown production utility case: #{unknown_cases.join(", ")}") unless unknown_cases.empty?
  declared = case_names.map { |name| UTILITY_CASES.fetch(name) }.sort
  fail_closed("typed production capability declaration differs from the reviewed allowlist") \
    unless declared == policy.fetch(:mounted)
end

def validate_privacy_declarations(plist, policy)
  fail_closed("Info.plist root must be a dictionary") unless plist.is_a?(Hash)
  observed = plist.keys.grep(/\ANS[A-Za-z0-9]+UsageDescription\z/).sort
  fail_closed(
    "privacy usage-description set differs from the reviewed allowlist (observed #{observed.join(", ")})"
  ) unless observed == policy.fetch(:privacy)
  observed.each do |key|
    value = plist.fetch(key)
    fail_closed("privacy usage description must be a nonempty string: #{key}") unless value.is_a?(String) && !value.strip.empty?
  end
end

def validate_entitlements(entitlements, policy, signed:)
  fail_closed("entitlements root must be a dictionary") unless entitlements.is_a?(Hash)
  allowed = policy.fetch(:entitlements)
  _ = signed
  unknown = entitlements.keys - allowed
  fail_closed("unreviewed entitlement present: #{unknown.sort.join(", ")}") unless unknown.empty?
  missing = allowed - entitlements.keys
  fail_closed("reviewed entitlement is missing: #{missing.sort.join(", ")}") unless missing.empty?

  allowed.each do |key|
    fail_closed("reviewed capability entitlement must be true: #{key}") unless entitlements.fetch(key) == true
  end
end

mode = ARGV.shift || fail_closed("missing validation mode")
root_argument = ARGV.shift || fail_closed("missing repository root")
root = Pathname.new(root_argument).realpath
fail_closed("repository root must be a directory") unless root.directory?
policy = load_policy(root)

case mode
when "repository"
  fail_closed("unexpected repository validation arguments") unless ARGV.empty?
  validate_composition(root, policy)
  validate_privacy_declarations(parse_plist(repository_file(root, INFO_TEMPLATE_PATH)), policy)
  validate_entitlements(
    parse_plist(repository_file(root, ENTITLEMENTS_PATH)),
    policy,
    signed: false
  )
when "bundle"
  plist_path = ARGV.shift || fail_closed("missing bundle Info.plist")
  fail_closed("unexpected bundle validation arguments") unless ARGV.empty?
  validate_composition(root, policy)
  validate_privacy_declarations(parse_plist(regular_file(plist_path, "bundle Info.plist")), policy)
  validate_entitlements(
    parse_plist(repository_file(root, ENTITLEMENTS_PATH)),
    policy,
    signed: false
  )
when "entitlements"
  entitlements_path = ARGV.shift || fail_closed("missing entitlements plist")
  signed_value = ARGV.shift || fail_closed("missing signed-entitlements mode")
  fail_closed("unexpected entitlement validation arguments") unless ARGV.empty?
  fail_closed("signed-entitlements mode must be true or false") unless %w[true false].include?(signed_value)
  validate_entitlements(
    parse_plist(regular_file(entitlements_path, "entitlements plist")),
    policy,
    signed: signed_value == "true"
  )
else
  fail_closed("unknown validation mode: #{mode}")
end

puts "Production composition and permission declarations match the reviewed allowlist."
