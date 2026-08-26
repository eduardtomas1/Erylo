#!/usr/bin/env bash

# Shared release helpers. Caller scripts enable strict mode before sourcing.

release_die() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

release_require_command() {
    command -v "$1" >/dev/null 2>&1 || release_die "required tool is unavailable: $1"
}

release_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null || release_die "run this script from an Erylo Git worktree"
}

release_output_path() {
    local repo_root="$1"
    local requested="$2"

    /usr/bin/ruby -e '
        repo = File.realpath(ARGV.fetch(0))
        root = File.join(repo, ".release")
        candidate = File.expand_path(ARGV.fetch(1), repo)
        prefix = root + File::SEPARATOR

        abort("release output must be below #{root}") unless candidate.start_with?(prefix)
        abort("release staging root may not be a symlink") if File.symlink?(root)
        if File.exist?(root)
          abort("release staging root is not a directory") unless File.directory?(root)
        else
          Dir.mkdir(root, 0o755)
        end

        parent = File.dirname(candidate)
        relative_parent = parent.delete_prefix(prefix)
        current = root
        unless parent == root
          relative_parent.split(File::SEPARATOR).each do |component|
            abort("invalid release output component") if component.empty? || component == "." || component == ".."
            current = File.join(current, component)
            abort("release output parent may not contain symlinks: #{current}") if File.symlink?(current)
            if File.exist?(current)
              abort("release output parent is not a directory: #{current}") unless File.directory?(current)
            else
              Dir.mkdir(current, 0o755)
            end
          end
        end

        abort("release output leaf may not be a symlink") if File.symlink?(candidate)
        if File.exist?(candidate)
          abort("release output leaf has an unsupported type") unless File.file?(candidate) || File.directory?(candidate)
        end

        puts candidate
    ' "$repo_root" "$requested" || release_die "unsafe release output path: $requested"
}

release_existing_path() {
    local repo_root="$1"
    local requested="$2"

    /usr/bin/ruby -e '
        repo = File.realpath(ARGV.fetch(0))
        root = File.join(repo, ".release")
        abort("release staging root is missing") unless File.directory?(root) && !File.symlink?(root)
        root = File.realpath(root)
        candidate = File.realpath(File.expand_path(ARGV.fetch(1), repo))
        prefix = root + File::SEPARATOR
        abort("path is outside release staging") unless candidate.start_with?(prefix)
        puts candidate
    ' "$repo_root" "$requested" || release_die "release input is missing or outside .release: $requested"
}

release_repo_file() {
    local repo_root="$1"
    local requested="$2"

    /usr/bin/ruby -e '
        repo = File.realpath(ARGV.fetch(0))
        requested = File.expand_path(ARGV.fetch(1), repo)
        abort("tracked release input may not be a symlink") if File.symlink?(requested)
        candidate = File.realpath(requested)
        prefix = repo + File::SEPARATOR
        abort("release input is outside the repository") unless candidate.start_with?(prefix)
        abort("release input is not a regular file") unless File.file?(candidate)
        puts candidate
    ' "$repo_root" "$requested" || release_die "invalid repository release input: $requested"
}

release_metadata_value() {
    local metadata_file="$1"
    local key="$2"
    local value

    value="$({
        /usr/bin/awk -F= -v wanted="$key" '
            $0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/ { next }
            $1 == wanted { count += 1; print substr($0, length($1) + 2) }
            END { if (count != 1) exit 2 }
        ' "$metadata_file"
    } || true)"
    [[ -n "$value" ]] || release_die "metadata key is missing, duplicated, or empty: $key"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || release_die "metadata value contains a line break: $key"
    printf '%s\n' "$value"
}

release_plist_value() {
    local plist="$1"
    local key="$2"
    local value

    # Older plutil versions write missing-key diagnostics to stdout. Capture
    # first and emit only after a successful extraction so optional keys cannot
    # be mistaken for configured metadata.
    if ! value="$(/usr/bin/plutil -extract "$key" raw -o - "$plist" 2>/dev/null)"; then
        return 1
    fi
    printf '%s\n' "$value"
}

release_validate_feed_url() {
    local feed_url="$1"

    /usr/bin/ruby -ruri -e '
        raw = ARGV.fetch(0)
        match = /\Ahttps:\/\/([^\/?#]+)(?:\/[^?#]*)?\z/.match(raw)
        abort("feed URL must use canonical lowercase HTTPS") unless match

        authority = match[1]
        abort("feed authority may not contain userinfo") if authority.include?("@")
        abort("feed authority may not contain an explicit port") if authority.include?(":")

        url = URI.parse(raw)
        host = url.host.to_s.downcase
        abort("feed URL must use canonical lowercase HTTPS") unless url.is_a?(URI::HTTPS) && url.scheme == "https"
        abort("feed host is missing or noncanonical") unless authority.downcase == host
        abort("feed host is a placeholder") if host.empty? || host.end_with?(".invalid") || host.include?("example")
        abort("feed URL may not contain userinfo") unless url.userinfo.nil?
        abort("feed URL may not contain a query") unless url.query.nil?
        abort("feed URL may not contain a fragment") unless url.fragment.nil?

        labels = host.split(".", -1)
        valid_label = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
        abort("feed host is missing or noncanonical") if host.bytesize > 253 || labels.any? { |label| !valid_label.match?(label) }
    ' "$feed_url"
}

release_submission_archive_path() {
    local marketing_version="$1"
    local build_version="$2"

    [[ "$marketing_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || release_die "invalid submission marketing version"
    [[ "$build_version" =~ ^[1-9][0-9]{0,17}$ ]] || release_die "invalid submission build version"
    printf '.release/notarization/submissions/Erylo-%s-%s-arm64-submission.zip\n' \
        "$marketing_version" "$build_version"
}

release_validate_publishable_artifacts() {
    local repo_root="$1"
    local artifacts

    artifacts="$(release_output_path "$repo_root" ".release/artifacts/placeholder")"
    artifacts="$(dirname "$artifacts")"
    /usr/bin/ruby -e '
        root = ARGV.fetch(0)
        final_archive = /\AErylo-[0-9]+\.[0-9]+(?:\.[0-9]+)?-[1-9][0-9]{0,17}-arm64\.zip\z/
        signature = /\AErylo-[0-9]+\.[0-9]+(?:\.[0-9]+)?-[1-9][0-9]{0,17}-arm64\.zip\.sparkle-signature\.json\z/
        Dir.children(root).each do |name|
          path = File.join(root, name)
          abort("publishable artifact is a symlink or non-regular entry: #{name}") unless File.file?(path) && !File.symlink?(path)
          next if name == "SHA256SUMS" || final_archive.match?(name) || signature.match?(name)
          abort("non-publishable entry in release artifacts: #{name}")
        end
      ' "$artifacts" || release_die "publishable artifact boundary validation failed"
}

release_publish_file() {
    local repo_root="$1"
    local source_input="$2"
    local destination_input="$3"
    local source
    local destination

    source="$(release_existing_path "$repo_root" "$source_input")"
    [[ -f "$source" && ! -L "$source" ]] || release_die "publication source must be a regular staged file"

    # Remove the exact validated leaf first. The atomic rename below never
    # follows a replacement symlink at the final component and fails if a
    # directory or unexpected entry appears before publication.
    release_remove_path "$repo_root" "$destination_input"
    destination="$(release_output_path "$repo_root" "$destination_input")"
    /usr/bin/ruby -e '
        source = ARGV.fetch(0)
        destination = ARGV.fetch(1)
        abort("publication source is unsafe") unless File.file?(source) && !File.symlink?(source)
        abort("publication destination appeared unexpectedly") if File.exist?(destination) || File.symlink?(destination)
        File.rename(source, destination)
    ' "$source" "$destination" || release_die "could not publish staged file safely"
    [[ -f "$destination" && ! -L "$destination" ]] || release_die "published file is missing or unsafe"
}

release_make_temp_dir() {
    local repo_root="$1"
    local label="$2"
    local temp_parent

    [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || release_die "invalid temporary-directory label"
    temp_parent="$(release_output_path "$repo_root" ".release/tmp/placeholder")"
    temp_parent="$(dirname "$temp_parent")"
    /usr/bin/mktemp -d "$temp_parent/${label}.XXXXXX" || release_die "could not create a release temporary directory"
}

release_remove_path() {
    local repo_root="$1"
    local requested="$2"
    local target

    target="$(/usr/bin/ruby -e '
        repo = File.realpath(ARGV.fetch(0))
        root = File.join(repo, ".release")
        candidate = File.expand_path(ARGV.fetch(1), repo)
        prefix = root + File::SEPARATOR

        abort("release removal must be below staging") unless candidate.start_with?(prefix)
        abort("release staging root may not be a symlink") if File.symlink?(root)
        if File.exist?(root)
          abort("release staging root is not a directory") unless File.directory?(root)
        else
          Dir.mkdir(root, 0o755)
        end

        parent = File.dirname(candidate)
        relative_parent = parent.delete_prefix(prefix)
        current = root
        unless parent == root
          relative_parent.split(File::SEPARATOR).each do |component|
            abort("invalid release removal component") if component.empty? || component == "." || component == ".."
            current = File.join(current, component)
            abort("release removal parent may not contain symlinks") if File.symlink?(current)
            if File.exist?(current)
              abort("release removal parent is not a directory") unless File.directory?(current)
            else
              Dir.mkdir(current, 0o755)
            end
          end
        end
        puts candidate
    ' "$repo_root" "$requested")" || release_die "unsafe release removal path: $requested"
    /bin/rm -rf -- "$target"
}

release_require_full_xcode() {
    local developer_path

    release_require_command xcode-select
    if [[ -n "${DEVELOPER_DIR:-}" ]]; then
        developer_path="$DEVELOPER_DIR"
    else
        developer_path="$(xcode-select -p 2>/dev/null)" || release_die "full Xcode is required"
    fi
    case "$developer_path" in
        *.app/Contents/Developer) ;;
        *) release_die "full Xcode is required; Command Line Tools alone are insufficient" ;;
    esac
    [[ -d "$developer_path" ]] || release_die "selected Xcode developer directory does not exist"
    DEVELOPER_DIR="$developer_path" /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1 \
        || release_die "selected Xcode does not provide xcodebuild"
}

release_require_notary_tools() {
    release_require_full_xcode
    /usr/bin/xcrun --find notarytool >/dev/null 2>&1 || release_die "selected Xcode does not provide notarytool"
    /usr/bin/xcrun --find stapler >/dev/null 2>&1 || release_die "selected Xcode does not provide stapler"
}
