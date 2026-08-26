#!/usr/bin/ruby

require "base64"
require "digest"
require "fiddle/import"
require "json"
require "open3"
require "securerandom"

module ReleaseFSSystem
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern "int openat(int, const char *, int, int)"
  extern "int mkdirat(int, const char *, int)"
  extern "int unlinkat(int, const char *, int)"
  extern "int renameat(int, const char *, int, const char *)"
  extern "int renameatx_np(int, const char *, int, const char *, unsigned int)"
  extern "int dup(int)"
  extern "int fchmod(int, int)"
  extern "int fsync(int)"
  extern "void *fdopendir(int)"
  extern "void *readdir(void *)"
  extern "int closedir(void *)"
end

class ReleaseFS
  class EntryInfo
    attr_reader :stat

    def initialize(stat = nil, symlink: false)
      @stat = stat
      @symlink = symlink
    end

    def symlink?
      @symlink
    end

    def file?
      !@symlink && @stat.file?
    end

    def directory?
      !@symlink && @stat.directory?
    end

    def dev
      @stat.dev
    end

    def ino
      @stat.ino
    end
  end

  O_RDONLY = 0x00000000
  O_RDWR = 0x00000002
  O_NONBLOCK = 0x00000004
  O_NOFOLLOW = 0x00000100
  O_DIRECTORY = 0x00100000
  O_CLOEXEC = 0x01000000
  O_CREAT = 0x00000200
  O_EXCL = 0x00000800
  AT_REMOVEDIR = 0x0080
  RENAME_SWAP = 0x00000002

  def initialize(repo_input)
    @repo = File.realpath(repo_input)
    @repo_io = File.open(@repo, File::RDONLY)
    @release_io = open_or_create_dir(@repo_io.fileno, ".release", 0o700)
    secure_directory(@release_io, ".release")
  end

  def output_path(input)
    parent, leaf = resolve_parent(input, true)
    stat = lstat_entry(parent.fileno, leaf)
    if stat
      abort("release output leaf may not be a symlink") if stat.symlink?
      abort("release output leaf has an unsupported type") unless stat.file? || stat.directory?
    end
    puts logical_path(input)
  ensure
    parent&.close
  end

  def existing_path(input, kind)
    abort("invalid existing-path kind") unless ["any", "file", "directory"].include?(kind)
    parent, leaf = resolve_parent(input, false)
    stat = lstat_entry(parent.fileno, leaf)
    abort("release input is missing") unless stat
    abort("release input may not be a symlink") if stat.symlink?
    case kind
    when "file"
      file = open_regular(parent.fileno, leaf, require_single_link: true)
      abort("release input is not owned by the current user") unless file.stat.uid == Process.euid
    when "directory"
      directory = open_dir_entry(parent.fileno, leaf)
      secure_directory(directory, leaf)
    else
      abort("release input has an unsupported type") unless stat.file? || stat.directory?
      if stat.file?
        file = open_regular(parent.fileno, leaf, require_single_link: true)
        abort("release input is not owned by the current user") unless file.stat.uid == Process.euid
      else
        directory = open_dir_entry(parent.fileno, leaf)
        secure_directory(directory, leaf)
      end
    end
    puts logical_path(input)
  ensure
    file&.close
    directory&.close
    parent&.close
  end

  def make_temp(label)
    abort("invalid temporary-directory label") unless /\A[A-Za-z0-9._-]+\z/.match?(label)
    tmp = open_dirs(["tmp"], true)
    test_pause("make-temp")
    64.times do
      name = "#{label}.#{Process.pid}.#{SecureRandom.hex(6)}"
      next unless mkdirat(tmp.fileno, name, 0o700, allow_exists: true)
      puts File.join(@repo, ".release", "tmp", name)
      return
    end
    abort("could not create a unique release temporary directory")
  ensure
    tmp&.close
  end

  def make_directory(input)
    directory = open_path_dir(input, create: true)
    test_pause("make-directory")
    secure_directory(directory, input)
    puts logical_path(input)
  ensure
    directory&.close
  end

  def run_locked(arguments)
    abort("release lock command is missing") if arguments.empty?
    command = File.realpath(arguments.fetch(0))
    abort("release lock command is not executable") unless File.file?(command) && File.executable?(command)
    locks = open_dirs(["locks"], true)
    fd = ReleaseFSSystem.openat(
      locks.fileno,
      "production-release.lock",
      O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
      0o600
    )
    raise_errno("could not open the repository release lock") if fd.negative?
    lock = File.for_fd(fd, "r+", autoclose: true)
    secure_private_file(lock, "production-release.lock")
    abort("another release operation owns this repository") \
      unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    internal_state = %w[
      ERYLO_RELEASE_SNAPSHOT_ACTIVE
      ERYLO_RELEASE_SOURCE_ROOT
      ERYLO_RELEASE_SOURCE_COMMIT
      ERYLO_RELEASE_SOURCE_TREE
      ERYLO_RELEASE_SOURCE_EPOCH
      ERYLO_RELEASE_SOURCE_DEVICE
      ERYLO_RELEASE_SOURCE_IMAGE
      ERYLO_RELEASE_SOURCE_IMAGE_SHA256
      ERYLO_RELEASE_SOURCE_DISK_DEVICE
      ERYLO_RELEASE_SNAPSHOT_TEMP
      ERYLO_RELEASE_SNAPSHOT_MANIFEST_SHA256
      ERYLO_RELEASE_OUTER_CAPABILITY_SHA256
      ERYLO_RELEASE_WORKER_CAPABILITY_FD
      ERYLO_RELEASE_WORKER_CAPABILITY_SHA256
      ERYLO_RELEASE_OUTER_AUTHENTICATED
      ERYLO_RELEASE_SUPERVISOR_HANDOFF
      ERYLO_RELEASE_WORKER_AUTHENTICATED
    ]
    internal_state.each { |name| ENV.delete(name) }
    capability_read, capability_write = IO.pipe
    outer_token = SecureRandom.random_bytes(32)
    worker_token = SecureRandom.random_bytes(32)
    capability_write.write(outer_token + worker_token)
    capability_write.close
    capability_read.close_on_exec = false
    outer_digest = Digest::SHA256.hexdigest(outer_token)
    worker_digest = Digest::SHA256.hexdigest(worker_token)
    lock.rewind
    lock.truncate(0)
    lock.write("ERYLO_RELEASE_CAPABILITY_V1\t#{Process.pid}\t#{outer_digest}\t#{worker_digest}\n")
    lock.flush
    lock.fsync
    lock.rewind
    lock.close_on_exec = false
    ENV["ERYLO_RELEASE_LOCK_HELD"] = "1"
    ENV["ERYLO_RELEASE_LOCK_FD"] = lock.fileno.to_s
    ENV["ERYLO_RELEASE_WORKER_CAPABILITY_FD"] = capability_read.fileno.to_s
    exec(command, *arguments.drop(1), close_others: false)
  ensure
    capability_write&.close unless capability_write&.closed?
    capability_read&.close unless capability_read&.closed?
    lock&.close
    locks&.close
  end

  def assert_lock
    abort("repository release lock is not declared") unless ENV["ERYLO_RELEASE_LOCK_HELD"] == "1"
    lock_fd = Integer(ENV.fetch("ERYLO_RELEASE_LOCK_FD"), 10)
    inherited = File.for_fd(lock_fd, "r+", autoclose: false)
    locks = open_dirs(["locks"], false)
    recorded = open_regular(locks.fileno, "production-release.lock", require_single_link: true)
    abort("repository release lock descriptor was replaced") unless same_inode?(inherited.stat, recorded.stat)
    abort("repository release lock is not held") unless inherited.flock(File::LOCK_EX | File::LOCK_NB)
  rescue ArgumentError, Errno::EBADF
    abort("repository release lock descriptor is invalid")
  ensure
    recorded&.close
    locks&.close
  end

  def exec_supervisor(arguments)
    source_commit = arguments.shift || abort("missing pinned supervisor commit")
    snapshot_temp = arguments.shift || abort("missing source snapshot transaction")
    snapshot_mount = arguments.shift || abort("missing source snapshot mount")
    worker = arguments.shift || abort("missing mounted release worker")
    abort("invalid pinned supervisor commit") unless /\A[0-9a-f]{40}\z/.match?(source_commit)
    assert_lock

    programs = {}
    [
      "Scripts/release/release-worker-supervisor.rb",
      "Scripts/release/fs-helper.rb",
      "Scripts/release/recover-source-mount.rb"
    ].each do |path|
      bytes = pinned_git_executable(source_commit, path)
      programs[path] = anonymous_executable(bytes, File.basename(path))
    end
    programs.each_value { |program| program.close_on_exec = false }
    supervisor = programs.fetch("Scripts/release/release-worker-supervisor.rb")
    helper = programs.fetch("Scripts/release/fs-helper.rb")
    recovery = programs.fetch("Scripts/release/recover-source-mount.rb")
    environment = ENV.to_h.merge(
      "ERYLO_RELEASE_PINNED_FS_HELPER" => "/dev/fd/#{helper.fileno}",
      "ERYLO_RELEASE_PINNED_MOUNT_RECOVERY" => "/dev/fd/#{recovery.fileno}"
    )
    exec(
      environment,
      "/usr/bin/ruby", "/dev/fd/#{supervisor.fileno}",
      @repo, source_commit, snapshot_temp, snapshot_mount, worker, *arguments,
      close_others: false
    )
  ensure
    programs&.each_value { |program| program.close unless program.closed? }
  end

  def recover_temporaries
    tmp = open_dirs(["tmp"], true)
    managed = /\A(?:archive-app|archive-symbols|assemble-app|build-app|checksums|final-publication|notarize|private-publication|private-rollback|publication-rollback|sign-update|source-snapshot|validate-archive|validate-symbols|verify-signature|verify-update)\.\d+\.[0-9a-f]{12}\z/
    anonymous_program = /\A\.pinned-executable\.\d+\.[0-9a-f]{24}\.[A-Za-z0-9._-]+\z/
    children(tmp.fileno).sort.each do |name|
      next unless managed.match?(name) || anonymous_program.match?(name)
      remove_entry(tmp.fileno, name, "any")
    end
    sync_fd(tmp.fileno, "recovered release temporary directory")
  ensure
    tmp&.close
  end

  def snapshot_mounts
    tmp = open_dirs(["tmp"], true)
    pattern = /\Asource-snapshot\.\d+\.[0-9a-f]{12}\z/
    children(tmp.fileno).sort.each do |name|
      next unless pattern.match?(name)
      snapshot = open_dir_entry(tmp.fileno, name)
      mount_info = lstat_entry(snapshot.fileno, "mount")
      next unless mount_info&.directory? && !mount_info.symlink?
      puts File.join(@repo, ".release", "tmp", name, "mount") if mount_info.dev != snapshot.stat.dev
    ensure
      snapshot&.close
      snapshot = nil
    end
  ensure
    tmp&.close
  end

  def file_identity(input, seal_mode = nil)
    parent, leaf = resolve_parent(input, false)
    file = open_regular(parent.fileno, leaf, require_single_link: true)
    abort("release file is not owned by the current user") unless file.stat.uid == Process.euid
    if seal_mode
      mode = Integer(seal_mode, 8)
      abort("invalid release file seal mode") unless [0o400, 0o600].include?(mode)
      fchmod(file.fileno, mode)
      sync_fd(file.fileno, "sealed release file")
      sync_fd(parent.fileno, "sealed release file parent")
    end
    puts identity_for(file)
  ensure
    file&.close
    parent&.close
  end

  def assert_identity(input, expected)
    parent, leaf = resolve_parent(input, false)
    file = open_regular(parent.fileno, leaf, require_single_link: true)
    abort("release file identity changed") unless identity_for(file) == expected
  ensure
    file&.close
    parent&.close
  end

  def remove(input, kind)
    abort("invalid removal kind") unless ["any", "file"].include?(kind)
    parent, leaf = resolve_parent(input, false, allow_missing: true)
    return unless parent
    test_pause("remove")
    remove_entry(parent.fileno, leaf, kind)
  ensure
    parent&.close
  end

  def publish_file(source_input, destination_input)
    source_parent, source_leaf = resolve_parent(source_input, false)
    destination_parent, destination_leaf = resolve_parent(destination_input, true)
    source = open_regular(source_parent.fileno, source_leaf, require_single_link: true)
    secure_private_file(source, source_leaf)
    destination_stat = lstat_entry(destination_parent.fileno, destination_leaf)
    if destination_stat
      abort("file publication destination has an unsupported type") unless destination_stat.file? || destination_stat.symlink?
    end
    test_pause("publish-file")
    renameat(source_parent.fileno, source_leaf, destination_parent.fileno, destination_leaf)
    installed = open_regular(destination_parent.fileno, destination_leaf, require_single_link: true)
    abort("published file changed during anchored rename") unless same_inode?(source.stat, installed.stat)
  ensure
    installed&.close
    source&.close
    source_parent&.close
    destination_parent&.close
  end

  def publish_directory(source_input, destination_input)
    source_parent, source_leaf = resolve_parent(source_input, false)
    destination_parent, destination_leaf = resolve_parent(destination_input, true)
    source = open_dir_entry(source_parent.fileno, source_leaf)
    secure_directory(source, source_leaf)
    remove_entry(destination_parent.fileno, destination_leaf, "any") if lstat_entry(destination_parent.fileno, destination_leaf)
    test_pause("publish-directory")
    renameat(source_parent.fileno, source_leaf, destination_parent.fileno, destination_leaf)
    installed = open_dir_entry(destination_parent.fileno, destination_leaf)
    abort("published directory changed during anchored rename") unless same_inode?(source.stat, installed.stat)
  ensure
    installed&.close
    source&.close
    source_parent&.close
    destination_parent&.close
  end

  def validate_set(input, marketing_version, build_version, state, source_commit = nil, source_tree = nil, appcast_hash = nil, toolchain_hash = nil)
    validate_version(marketing_version, build_version)
    abort("invalid publishable artifact state") unless ["empty", "complete"].include?(state)
    validate_release_binding(source_commit, source_tree, appcast_hash, toolchain_hash) \
      if source_commit || source_tree || appcast_hash || toolchain_hash
    directory = open_path_dir(input, create: state == "empty")
    validate_set_fd(
      directory.fileno, marketing_version, build_version, state, nil,
      [source_commit, source_tree, appcast_hash, toolchain_hash]
    )
  ensure
    directory&.close
  end

  def validate_private_set(input, marketing_version, build_version, source_commit, source_tree, appcast_hash, toolchain_hash)
    validate_version(marketing_version, build_version)
    validate_release_binding(source_commit, source_tree, appcast_hash, toolchain_hash)
    directory = open_path_dir(input, create: false)
    validate_private_set_fd(
      directory.fileno,
      marketing_version,
      build_version,
      source_commit,
      source_tree,
      appcast_hash,
      toolchain_hash
    )
  ensure
    directory&.close
  end

  def publish_private_set(source_input, marketing_version, build_version, source_commit, source_tree, appcast_hash, toolchain_hash)
    validate_version(marketing_version, build_version)
    validate_release_binding(source_commit, source_tree, appcast_hash, toolchain_hash)
    source_parent, source_leaf = resolve_parent(source_input, false)
    source = open_dir_entry(source_parent.fileno, source_leaf)
    validate_private_set_fd(
      source.fileno, marketing_version, build_version, source_commit, source_tree, appcast_hash, toolchain_hash
    )
    held_files = open_private_set_files_fd(source.fileno, marketing_version, build_version, source_commit)
    held_identities = held_files.map { |file| identity_for(file) }
    assert_held_private_set_fd(
      source.fileno, marketing_version, build_version, source_commit, source_tree, appcast_hash, toolchain_hash,
      held_files, held_identities
    )
    test_pause("after-private-publication-validation")
    assert_held_private_set_fd(
      source.fileno, marketing_version, build_version, source_commit, source_tree, appcast_hash, toolchain_hash,
      held_files, held_identities
    )
    held_files.each { |file| sync_fd(file.fileno, "held private release artifact") }
    sync_fd(source.fileno, "private release artifact set")
    sync_fd(source_parent.fileno, "private publication source parent")
    private_root = open_dirs(["private"], true)
    destination_name = source_commit
    existing_info = lstat_entry(private_root.fileno, destination_name)
    if existing_info
      abort("private release destination is not one real directory") unless existing_info.directory? && !existing_info.symlink?
      existing = open_dir_entry(private_root.fileno, destination_name)
      validate_private_set_fd(
        existing.fileno, marketing_version, build_version,
        source_commit, source_tree, appcast_hash, toolchain_hash
      )
      abort("existing immutable private release set differs") \
        unless directory_digest(source.fileno) == directory_digest(existing.fileno)
      remove_entry(source_parent.fileno, source_leaf, "any")
      return
    end

    # Move the caller-owned pathname into an unpredictable, descriptor-anchored
    # rollback slot before publishing it. A caller can recreate source_leaf,
    # but that replacement can never become the destination of a rollback.
    tmp = open_dirs(["tmp"], true)
    rollback_name = create_unique_dir(tmp.fileno, "private-rollback")
    rollback = open_dir_entry(tmp.fileno, rollback_name)
    renameat(source_parent.fileno, source_leaf, rollback.fileno, "candidate")
    staged = open_dir_entry(rollback.fileno, "candidate")
    abort("private release source changed during internal staging") unless same_inode?(source.stat, staged.stat)
    assert_held_private_set_fd(
      staged.fileno, marketing_version, build_version, source_commit, source_tree, appcast_hash, toolchain_hash,
      held_files, held_identities
    )
    sync_fd(rollback.fileno, "private rollback transaction")
    sync_fd(tmp.fileno, "private rollback transaction parent")
    sync_fd(source_parent.fileno, "private publication caller parent after internal staging")
    rollback_ready = true

    renameat(rollback.fileno, "candidate", private_root.fileno, destination_name)
    renamed = true
    test_pause("after-private-publication-rename")
    installed = open_dir_entry(private_root.fileno, destination_name)
    abort("private release source changed during anchored rename") unless same_inode?(source.stat, installed.stat)
    assert_held_private_set_fd(
      installed.fileno, marketing_version, build_version, source_commit, source_tree, appcast_hash, toolchain_hash,
      held_files, held_identities
    )
    sync_fd(private_root.fileno, "private release root")
    sync_fd(source_parent.fileno, "private publication source parent after rename")
    test_pause("after-private-publication-sync")
    assert_held_private_set_fd(
      installed.fileno, marketing_version, build_version, source_commit, source_tree, appcast_hash, toolchain_hash,
      held_files, held_identities
    )
    committed = true
    cleanup_swap(tmp.fileno, rollback.fileno, rollback_name)
    rollback_ready = false
    sync_fd(tmp.fileno, "completed private rollback transaction cleanup")
  rescue StandardError, SystemExit => publication_error
    if renamed && !committed
      rollback_installed = open_dir_entry(private_root.fileno, destination_name)
      abort("private rollback destination no longer names the published directory") \
        unless same_inode?(source.stat, rollback_installed.stat)
      renameat(private_root.fileno, destination_name, rollback.fileno, "candidate")
      renamed = false
      sync_fd(private_root.fileno, "rolled-back private release root")
      sync_fd(rollback.fileno, "rolled-back private release transaction")
    end
    if rollback_ready && !renamed
      cleanup_swap(tmp.fileno, rollback.fileno, rollback_name)
      rollback_ready = false
      sync_fd(tmp.fileno, "rolled-back private transaction cleanup")
    end
    raise publication_error
  ensure
    rollback_installed&.close
    staged&.close
    rollback&.close
    tmp&.close
    held_files&.each { |file| file.close unless file.closed? }
    installed&.close
    existing&.close
    private_root&.close
    source&.close
    source_parent&.close
  end

  def validate_private_root
    directory = nil
    manifest_io = nil
    private_root = open_dirs(["private"], true)
    children(private_root.fileno).sort.each do |name|
      abort("private release root contains a non-commit entry") unless /\A[0-9a-f]{40}\z/.match?(name)
      directory = open_dir_entry(private_root.fileno, name)
      manifest_io = open_regular(directory.fileno, "ReleaseManifest.json", require_single_link: true)
      manifest = JSON.parse(manifest_io.read)
      abort("private release directory name does not match its manifest") unless manifest.fetch("sourceCommit") == name
      validate_private_set_fd(
        directory.fileno,
        manifest.fetch("marketingVersion"),
        manifest.fetch("buildVersion"),
        manifest.fetch("sourceCommit"),
        manifest.fetch("sourceTree"),
        manifest.fetch("appcastConfigSHA256"),
        manifest.fetch("toolchainSHA256")
      )
      manifest_io.close
      directory.close
    end
  ensure
    manifest_io&.close unless manifest_io&.closed?
    directory&.close unless directory&.closed?
    private_root&.close
  end

  def validate_root(expected_marketing_version = nil, expected_build_version = nil)
    if expected_marketing_version || expected_build_version
      validate_version(expected_marketing_version, expected_build_version)
    end
    artifacts = open_dirs(["artifacts"], true)
    detected = validate_root_fd(artifacts.fileno)
    if expected_marketing_version
      abort("expected publishable current set is missing") unless detected
      abort("publishable current version does not match the release") \
        unless detected == [expected_marketing_version, expected_build_version]
    end
  ensure
    artifacts&.close
  end

  def swap_current(source_input, marketing_version, build_version, injection, source_commit = nil, source_tree = nil, appcast_hash = nil, toolchain_hash = nil, archive_identity = nil, signature_identity = nil, checksum_identity = nil)
    validate_version(marketing_version, build_version)
    validate_release_binding(source_commit, source_tree, appcast_hash, toolchain_hash) \
      if source_commit || source_tree || appcast_hash || toolchain_hash
    abort("invalid publication failure injection") \
      unless ["none", "before-swap", "after-quarantine", "after-install"].include?(injection)

    source_parent, source_leaf = resolve_parent(source_input, false)
    source = open_dir_entry(source_parent.fileno, source_leaf)
    expected_binding = [source_commit, source_tree, appcast_hash, toolchain_hash]
    seal_public_set_fd(source.fileno, marketing_version, build_version, expected_binding)
    expected_identities = [archive_identity, signature_identity, checksum_identity]
    abort("partial publication identity binding") if expected_identities.any? && !expected_identities.all?
    held_files = open_public_set_files_fd(source.fileno, marketing_version, build_version)
    held_identities = held_files.map { |file| identity_for(file) }
    abort("publishable artifact byte identity differs from the verified release inputs") \
      if expected_identities.all? && held_identities != expected_identities
    assert_held_public_set_fd(
      source.fileno, marketing_version, build_version, held_files, held_identities, expected_binding
    )
    artifacts = open_dirs(["artifacts"], true)
    validate_root_fd(artifacts.fileno)
    test_pause("swap-current")
    assert_held_public_set_fd(
      source.fileno, marketing_version, build_version, held_files, held_identities, expected_binding
    )
    abort("injected publication failure before swap") if injection == "before-swap"
    had_previous = !lstat_entry(artifacts.fileno, "current").nil?
    if had_previous
      previous = open_dir_entry(artifacts.fileno, "current")
      derive_and_validate_set(previous.fileno)
      previous_digest = directory_digest(previous.fileno)
    end

    test_pause("before-publication-sync")
    held_files.each { |file| sync_fd(file.fileno, "held publishable artifact") }
    sync_fd(source.fileno, "publishable artifact set")
    sync_fd(source_parent.fileno, "publication source parent")
    test_pause("after-publication-sync")
    assert_held_public_set_fd(
      source.fileno, marketing_version, build_version, held_files, held_identities, expected_binding
    )

    if injection == "after-quarantine"
      abort("injected publication failure after durable source preparation")
    end

    # The atomic exchange must never leave the predecessor at the caller's
    # mutable source pathname. First move the candidate into a private,
    # unpredictable rollback directory owned by this helper. After exchange,
    # that internal leaf holds the exact prior current directory.
    tmp = open_dirs(["tmp"], true)
    rollback_name = create_unique_dir(tmp.fileno, "publication-rollback")
    rollback = open_dir_entry(tmp.fileno, rollback_name)
    renameat(source_parent.fileno, source_leaf, rollback.fileno, "candidate")
    staged = open_dir_entry(rollback.fileno, "candidate")
    abort("publication source changed during internal staging") unless same_inode?(source.stat, staged.stat)
    assert_held_public_set_fd(
      staged.fileno, marketing_version, build_version, held_files, held_identities, expected_binding
    )
    sync_fd(rollback.fileno, "publication rollback transaction")
    sync_fd(tmp.fileno, "publication rollback transaction parent")
    sync_fd(source_parent.fileno, "publication caller parent after internal staging")
    rollback_ready = true

    test_pause("before-current-exchange")
    if had_previous
      rename_swap(rollback.fileno, "candidate", artifacts.fileno, "current")
    else
      renameat(rollback.fileno, "candidate", artifacts.fileno, "current")
    end
    exchanged = true
    test_pause("after-current-exchange")

    assert_installed_public_set_fd(
      artifacts.fileno, source, marketing_version, build_version,
      held_files, held_identities, expected_binding
    )
    abort("injected publication failure after install") if injection == "after-install"

    sync_fd(artifacts.fileno, "published artifact directory")
    sync_fd(rollback.fileno, "publication rollback transaction after exchange")
    test_pause("after-publication-directory-sync")
    assert_installed_public_set_fd(
      artifacts.fileno, source, marketing_version, build_version,
      held_files, held_identities, expected_binding
    )
    test_pause("after-retired-publication-cleanup")
    assert_installed_public_set_fd(
      artifacts.fileno, source, marketing_version, build_version,
      held_files, held_identities, expected_binding
    )

    # This is the commit boundary. Until the exact installed identity/binding
    # assertion above succeeds, the previous directory remains available for
    # an atomic rollback.
    remove_entry(rollback.fileno, "candidate", "any") if had_previous
    committed = true
    sync_fd(rollback.fileno, "retired publication cleanup")
    cleanup_swap(tmp.fileno, rollback.fileno, rollback_name)
    rollback_ready = false
    sync_fd(tmp.fileno, "completed publication rollback transaction cleanup")
  rescue StandardError, SystemExit => publication_error
    if exchanged && !committed
      if had_previous
        rollback_previous = open_dir_entry(rollback.fileno, "candidate")
        abort("publication rollback slot no longer names the prior current directory") \
          unless same_inode?(previous.stat, rollback_previous.stat)
        abort("publication rollback slot changed the prior complete set") \
          unless directory_digest(rollback_previous.fileno) == previous_digest
        derive_and_validate_set(rollback_previous.fileno)
        rename_swap(rollback.fileno, "candidate", artifacts.fileno, "current")
      else
        rollback_current = open_dir_entry(artifacts.fileno, "current")
        abort("publication rollback current no longer names the installed release") \
          unless same_inode?(source.stat, rollback_current.stat)
        renameat(artifacts.fileno, "current", rollback.fileno, "candidate")
      end
      sync_fd(artifacts.fileno, "rolled-back artifact directory")
      sync_fd(rollback.fileno, "rolled-back publication transaction")
      if had_previous
        restored = open_dir_entry(artifacts.fileno, "current")
        abort("publication rollback restored a different directory") unless same_inode?(previous.stat, restored.stat)
        abort("publication rollback changed the prior complete set") \
          unless directory_digest(restored.fileno) == previous_digest
        derive_and_validate_set(restored.fileno)
      end
      exchanged = false
    end
    if rollback_ready && !exchanged
      cleanup_swap(tmp.fileno, rollback.fileno, rollback_name)
      rollback_ready = false
      sync_fd(tmp.fileno, "rolled-back publication transaction cleanup")
    end
    raise publication_error
  ensure
    rollback_current&.close
    rollback_previous&.close
    restored&.close
    previous&.close
    staged&.close
    rollback&.close
    tmp&.close
    held_files&.each { |file| file.close unless file.closed? }
    source&.close
    source_parent&.close
    artifacts&.close
  end

  private

  def logical_path(input)
    components(input)
    File.expand_path(input, @repo)
  end

  def components(input)
    absolute = File.expand_path(input, @repo)
    root = File.join(@repo, ".release")
    prefix = root + File::SEPARATOR
    abort("release path must be below staging") unless absolute.start_with?(prefix)
    relative = absolute.delete_prefix(prefix)
    values = relative.split(File::SEPARATOR)
    abort("invalid release path component") if values.empty? || values.any? { |value| value.empty? || value == "." || value == ".." }
    values
  end

  def resolve_parent(input, create, allow_missing: false)
    values = components(input)
    leaf = values.pop
    [open_dirs(values, create, allow_missing: allow_missing), leaf]
  end

  def open_path_dir(input, create: false)
    open_dirs(components(input), create)
  end

  def open_dirs(values, create, allow_missing: false)
    current = duplicate_io(@release_io.fileno)
    values.each do |value|
      next_io = begin
        open_dir_entry(current.fileno, value)
      rescue Errno::ENOENT
        unless create
          current.close
          return nil if allow_missing
          raise
        end
        mkdirat(current.fileno, value, 0o700)
        open_dir_entry(current.fileno, value)
      end
      secure_directory(next_io, value)
      current.close
      current = next_io
    end
    current
  end

  def open_or_create_dir(parent_fd, name, mode)
    directory = open_dir_entry(parent_fd, name)
    secure_directory(directory, name)
    directory
  rescue Errno::ENOENT
    mkdirat(parent_fd, name, mode)
    directory = open_dir_entry(parent_fd, name)
    secure_directory(directory, name)
    directory
  end

  def open_dir_entry(parent_fd, name)
    fd = ReleaseFSSystem.openat(parent_fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0)
    raise_errno("could not open release directory component: #{name}") if fd.negative?
    IO.for_fd(fd, autoclose: true)
  end

  def secure_directory(io, name)
    stat = io.stat
    abort("release directory is not owned by the current user: #{name}") unless stat.uid == Process.euid
    fchmod(io.fileno, 0o700) unless (stat.mode & 0o777) == 0o700
    refreshed = io.stat
    abort("release directory mode is not 0700: #{name}") unless (refreshed.mode & 0o777) == 0o700
  end

  def secure_private_file(io, name)
    stat = io.stat
    abort("release file is not owned by the current user: #{name}") unless stat.uid == Process.euid
    abort("release file may not be hardlinked: #{name}") unless stat.nlink == 1
    fchmod(io.fileno, 0o600) unless (stat.mode & 0o777) == 0o600
    abort("release file mode is not 0600: #{name}") unless (io.stat.mode & 0o777) == 0o600
  end

  def fchmod(fd, mode)
    result = ReleaseFSSystem.fchmod(fd, mode)
    raise_errno("could not enforce release entry permissions") unless result.zero?
  end

  def same_inode?(left, right)
    left.dev == right.dev && left.ino == right.ino
  end

  def identity_for(io)
    before = io.stat
    io.rewind
    digest = Digest::SHA256.hexdigest(io.read)
    after = io.stat
    abort("release file changed while its identity was captured") \
      unless same_inode?(before, after) && before.size == after.size && before.mtime == after.mtime
    [after.dev, after.ino, after.size, digest].join(":")
  end

  def open_regular(parent_fd, name, require_single_link: false)
    fd = ReleaseFSSystem.openat(parent_fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0)
    raise_errno("could not open regular release file: #{name}") if fd.negative?
    io = IO.for_fd(fd, autoclose: true)
    stat = io.stat
    abort("release file is not regular") unless stat.file?
    abort("release file may not be hardlinked") if require_single_link && stat.nlink != 1
    io
  rescue StandardError, SystemExit
    io&.close
    raise
  end

  def duplicate_io(fd)
    duplicate = ReleaseFSSystem.dup(fd)
    raise_errno("could not duplicate release directory descriptor") if duplicate.negative?
    IO.for_fd(duplicate, autoclose: true)
  end

  def lstat_entry(parent_fd, name)
    fd = ReleaseFSSystem.openat(parent_fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0)
    if fd.negative?
      error = Fiddle.last_error
      return nil if error == Errno::ENOENT::Errno
      return EntryInfo.new(nil, symlink: true) if error == Errno::ELOOP::Errno
      raise SystemCallError.new("could not inspect anchored release entry: #{name}", error)
    end
    io = IO.for_fd(fd, autoclose: true)
    EntryInfo.new(io.stat)
  ensure
    io&.close
  end

  def mkdirat(parent_fd, name, mode, allow_exists: false)
    result = ReleaseFSSystem.mkdirat(parent_fd, name, mode)
    return true if result.zero?
    return false if allow_exists && Fiddle.last_error == Errno::EEXIST::Errno
    raise_errno("could not create anchored release directory: #{name}")
  end

  def unlinkat(parent_fd, name, flags)
    result = ReleaseFSSystem.unlinkat(parent_fd, name, flags)
    raise_errno("could not remove anchored release entry: #{name}") unless result.zero?
  end

  def renameat(source_fd, source_name, destination_fd, destination_name)
    result = ReleaseFSSystem.renameat(source_fd, source_name, destination_fd, destination_name)
    raise_errno("could not rename anchored release entry") unless result.zero?
  end

  def rename_swap(source_fd, source_name, destination_fd, destination_name)
    result = ReleaseFSSystem.renameatx_np(
      source_fd,
      source_name,
      destination_fd,
      destination_name,
      RENAME_SWAP
    )
    raise_errno("could not atomically exchange anchored release directories") unless result.zero?
  end

  def sync_fd(fd, description)
    result = ReleaseFSSystem.fsync(fd)
    raise_errno("could not durably synchronize #{description}") unless result.zero?
  end

  def remove_entry(parent_fd, name, kind)
    stat = lstat_entry(parent_fd, name)
    return unless stat
    if stat.directory? && !stat.symlink?
      abort("release file cleanup target has an unsupported type") if kind == "file"
      abort("release cleanup may not cross a filesystem boundary") if stat.dev != descriptor_stat(parent_fd).dev
      directory = open_dir_entry(parent_fd, name)
      secure_directory(directory, name)
      children(directory.fileno).each do |child|
        remove_entry(directory.fileno, child, "any")
      end
      current = lstat_entry(parent_fd, name)
      opened = directory.stat
      abort("release directory leaf changed during cleanup") \
        unless current&.directory? && !current.symlink? && current.dev == opened.dev && current.ino == opened.ino
      directory.close
      unlinkat(parent_fd, name, AT_REMOVEDIR)
    else
      abort("release file cleanup target has an unsupported type") \
        if kind == "file" && !(stat.file? || stat.symlink?)
      unlinkat(parent_fd, name, 0)
    end
  end

  def descriptor_stat(fd)
    duplicate = duplicate_io(fd)
    duplicate.stat
  ensure
    duplicate&.close
  end

  def validate_version(marketing_version, build_version)
    abort("invalid publishable marketing version") \
      unless /\A[0-9]+\.[0-9]+(?:\.[0-9]+)?\z/.match?(marketing_version.to_s)
    abort("invalid publishable build version") unless /\A[1-9][0-9]{0,17}\z/.match?(build_version.to_s)
  end

  def validate_release_binding(source_commit, source_tree, appcast_hash, toolchain_hash)
    abort("invalid release source commit") unless /\A[0-9a-f]{40}\z/.match?(source_commit.to_s)
    abort("invalid release source tree") unless /\A[0-9a-f]{40}\z/.match?(source_tree.to_s)
    abort("invalid release appcast hash") unless /\A[0-9a-f]{64}\z/.match?(appcast_hash.to_s)
    abort("invalid release toolchain hash") unless /\A[0-9a-f]{64}\z/.match?(toolchain_hash.to_s)
  end

  def validate_private_set_fd(directory_fd, marketing_version, build_version, source_commit, source_tree, appcast_hash, toolchain_hash)
    archive_name = "Erylo-#{marketing_version}-#{build_version}-#{source_commit[0, 12]}-arm64.dSYM.zip"
    manifest_name = "ReleaseManifest.json"
    checksum_name = "SHA256SUMS"
    expected = [archive_name, manifest_name, checksum_name].sort
    actual = children(directory_fd).sort
    abort("private release artifact set mismatch: #{actual.inspect}") unless actual == expected

    archive = open_regular(directory_fd, archive_name, require_single_link: true)
    manifest_io = open_regular(directory_fd, manifest_name, require_single_link: true)
    checksums_io = open_regular(directory_fd, checksum_name, require_single_link: true)
    [archive, manifest_io, checksums_io].each do |io|
      abort("private release artifact is not owned by the current user") unless io.stat.uid == Process.euid
      abort("private release artifact mode is not 0600") unless (io.stat.mode & 0o777) == 0o600
    end

    manifest = JSON.parse(manifest_io.read)
    abort("private release manifest fields are noncanonical") unless manifest.keys.sort == [
      "appcastConfigSHA256", "archive", "buildVersion", "marketingVersion", "sourceCommit", "sourceTree",
      "toolchainSHA256"
    ]
    expected_manifest = {
      "archive" => archive_name,
      "marketingVersion" => marketing_version,
      "buildVersion" => build_version,
      "sourceCommit" => source_commit,
      "sourceTree" => source_tree,
      "appcastConfigSHA256" => appcast_hash,
      "toolchainSHA256" => toolchain_hash
    }
    abort("private release manifest does not match the pinned release") unless manifest == expected_manifest

    lines = checksums_io.read.lines(chomp: true)
    expected_names = [archive_name, manifest_name].sort
    abort("private checksum manifest must contain exactly two lines") unless lines.length == 2
    parsed = {}
    names = []
    lines.each do |line|
      match = /\A([0-9a-f]{64})  ([A-Za-z0-9._-]+)\z/.match(line)
      abort("private checksum manifest line is noncanonical") unless match
      hash, name = match.captures
      abort("private checksum manifest contains a duplicate filename") if parsed.key?(name)
      parsed[name] = hash
      names << name
    end
    abort("private checksum manifest does not cover the exact private pair") unless names == expected_names
    archive.rewind
    manifest_io.rewind
    hashes = {
      archive_name => Digest::SHA256.hexdigest(archive.read),
      manifest_name => Digest::SHA256.hexdigest(manifest_io.read)
    }
    expected_names.each do |name|
      abort("private checksum mismatch for #{name}") unless parsed.fetch(name) == hashes.fetch(name)
    end
  ensure
    archive&.close
    manifest_io&.close
    checksums_io&.close
  end

  def open_private_set_files_fd(directory_fd, marketing_version, build_version, source_commit)
    archive_name = "Erylo-#{marketing_version}-#{build_version}-#{source_commit[0, 12]}-arm64.dSYM.zip"
    [archive_name, "ReleaseManifest.json", "SHA256SUMS"].map do |name|
      open_regular(directory_fd, name, require_single_link: true)
    end
  end

  def assert_held_private_set_fd(directory_fd, marketing_version, build_version, source_commit, source_tree, appcast_hash, toolchain_hash, held_files, expected_identities)
    abort("held private artifact set is incomplete") unless held_files.length == 3 && expected_identities.length == 3
    actual_held_identities = held_files.map { |file| identity_for(file) }
    abort("held private artifact bytes changed after validation") unless actual_held_identities == expected_identities
    path_files = open_private_set_files_fd(directory_fd, marketing_version, build_version, source_commit)
    actual_path_identities = path_files.map { |file| identity_for(file) }
    abort("private artifact pathname no longer names the validated byte identity") \
      unless actual_path_identities == expected_identities
    validate_private_set_fd(
      directory_fd, marketing_version, build_version, source_commit, source_tree, appcast_hash, toolchain_hash
    )
  ensure
    path_files&.each { |file| file.close unless file.closed? }
  end

  def directory_digest(directory_fd)
    digest = Digest::SHA256.new
    children(directory_fd).sort.each do |name|
      file = open_regular(directory_fd, name, require_single_link: true)
      digest << name << "\0" << identity_for(file).split(":", 4).fetch(3) << "\0"
      file.close
    end
    digest.hexdigest
  end

  def validate_set_fd(directory_fd, marketing_version, build_version, state, required_mode = nil, expected_binding = nil)
    final_name = "Erylo-#{marketing_version}-#{build_version}-arm64.zip"
    signature_name = "#{final_name}.sparkle-signature.json"
    expected = [final_name, signature_name, "SHA256SUMS"].sort
    actual = children(directory_fd).sort
    if state == "empty"
      abort("publishable artifact directory is not empty: #{actual.inspect}") unless actual.empty?
      return
    end
    abort("publishable artifact set mismatch: #{actual.inspect}") unless actual == expected

    final_io = open_regular(directory_fd, final_name, require_single_link: true)
    signature_io = open_regular(directory_fd, signature_name, require_single_link: true)
    checksums_io = open_regular(directory_fd, "SHA256SUMS", require_single_link: true)
    [final_io, signature_io, checksums_io].each do |io|
      abort("publishable artifact is not owned by the current user") unless io.stat.uid == Process.euid
      abort("publishable artifact mode is noncanonical") if required_mode && (io.stat.mode & 0o777) != required_mode
    end
    signature = JSON.parse(signature_io.read)
    abort("signature metadata fields are noncanonical") \
      unless signature.keys.sort == [
        "appcastConfigSHA256", "archive", "length", "sourceCommit", "sourceTree", "sparkleEdSignature",
        "toolchainSHA256"
      ]
    abort("signature metadata references the wrong archive") unless signature.fetch("archive") == final_name
    abort("signature metadata length does not match the archive") unless signature.fetch("length") == final_io.stat.size
    abort("signature metadata source commit is invalid") unless /\A[0-9a-f]{40}\z/.match?(signature.fetch("sourceCommit"))
    abort("signature metadata source tree is invalid") unless /\A[0-9a-f]{40}\z/.match?(signature.fetch("sourceTree"))
    abort("signature metadata appcast hash is invalid") unless /\A[0-9a-f]{64}\z/.match?(signature.fetch("appcastConfigSHA256"))
    abort("signature metadata toolchain hash is invalid") unless /\A[0-9a-f]{64}\z/.match?(signature.fetch("toolchainSHA256"))
    if expected_binding && expected_binding.all?
      abort("signature metadata does not match the pinned release binding") unless [
        signature.fetch("sourceCommit"), signature.fetch("sourceTree"), signature.fetch("appcastConfigSHA256"),
        signature.fetch("toolchainSHA256")
      ] == expected_binding
    end
    encoded_signature = signature.fetch("sparkleEdSignature")
    decoded_signature = Base64.strict_decode64(encoded_signature)
    abort("signature metadata contains no canonical structural EdDSA value") \
      unless decoded_signature.bytesize == 64 && Base64.strict_encode64(decoded_signature) == encoded_signature

    lines = checksums_io.read.lines(chomp: true)
    abort("checksum manifest must contain exactly two lines") unless lines.length == 2
    expected_names = [final_name, signature_name].sort
    checksums = {}
    names = []
    lines.each do |line|
      match = /\A([0-9a-f]{64})  ([A-Za-z0-9._-]+)\z/.match(line)
      abort("checksum manifest line is noncanonical") unless match
      hash, name = match.captures
      abort("checksum manifest contains a duplicate filename") if checksums.key?(name)
      checksums[name] = hash
      names << name
    end
    abort("checksum manifest does not cover the exact artifact pair") unless names == expected_names
    final_io.rewind
    signature_io.rewind
    actual_hashes = {
      final_name => Digest::SHA256.hexdigest(final_io.read),
      signature_name => Digest::SHA256.hexdigest(signature_io.read)
    }
    expected_names.each do |name|
      abort("checksum mismatch for #{name}") unless checksums.fetch(name) == actual_hashes.fetch(name)
    end
  ensure
    final_io&.close
    signature_io&.close
    checksums_io&.close
  end

  def seal_public_set_fd(directory_fd, marketing_version, build_version, expected_binding = nil)
    validate_set_fd(directory_fd, marketing_version, build_version, "complete", nil, expected_binding)
    final_name = "Erylo-#{marketing_version}-#{build_version}-arm64.zip"
    [final_name, "#{final_name}.sparkle-signature.json", "SHA256SUMS"].each do |name|
      io = open_regular(directory_fd, name, require_single_link: true)
      fchmod(io.fileno, 0o644)
      io.close
    end
  end

  def sync_public_set_fd(directory_fd, marketing_version, build_version)
    final_name = "Erylo-#{marketing_version}-#{build_version}-arm64.zip"
    [final_name, "#{final_name}.sparkle-signature.json", "SHA256SUMS"].each do |name|
      io = open_regular(directory_fd, name, require_single_link: true)
      sync_fd(io.fileno, "publishable artifact #{name}")
      io.close
    end
    sync_fd(directory_fd, "publishable artifact set")
  end

  def open_public_set_files_fd(directory_fd, marketing_version, build_version)
    final_name = "Erylo-#{marketing_version}-#{build_version}-arm64.zip"
    [final_name, "#{final_name}.sparkle-signature.json", "SHA256SUMS"].map do |name|
      open_regular(directory_fd, name, require_single_link: true)
    end
  end

  def assert_held_public_set_fd(directory_fd, marketing_version, build_version, held_files, expected_identities, expected_binding)
    abort("held publishable artifact set is incomplete") unless held_files.length == 3 && expected_identities.length == 3
    actual_held_identities = held_files.map { |file| identity_for(file) }
    abort("held publishable artifact bytes changed after verification") \
      unless actual_held_identities == expected_identities
    assert_set_identities_fd(directory_fd, marketing_version, build_version, expected_identities)
    validate_set_fd(directory_fd, marketing_version, build_version, "complete", 0o644, expected_binding)
  end

  def assert_installed_public_set_fd(artifacts_fd, source, marketing_version, build_version, held_files, expected_identities, expected_binding)
    installed = open_dir_entry(artifacts_fd, "current")
    abort("publication source directory changed during anchored rename") \
      unless same_inode?(source.stat, installed.stat)
    assert_held_public_set_fd(
      installed.fileno, marketing_version, build_version, held_files, expected_identities, expected_binding
    )
  ensure
    installed&.close
  end

  def assert_set_identities_fd(directory_fd, marketing_version, build_version, expected_identities)
    final_name = "Erylo-#{marketing_version}-#{build_version}-arm64.zip"
    names = [final_name, "#{final_name}.sparkle-signature.json", "SHA256SUMS"]
    actual = names.map do |name|
      file = open_regular(directory_fd, name, require_single_link: true)
      identity = identity_for(file)
      file.close
      identity
    end
    abort("publishable artifact pathname no longer names the verified byte identity") unless actual == expected_identities
  end

  def derive_and_validate_set(directory_fd)
    names = children(directory_fd)
    matches = names.map do |name|
      /\AErylo-([0-9]+\.[0-9]+(?:\.[0-9]+)?)-([1-9][0-9]{0,17})-arm64\.zip\z/.match(name)
    end.compact
    abort("publishable current directory has no singular final ZIP") unless matches.length == 1
    version = [matches[0][1], matches[0][2]]
    validate_set_fd(directory_fd, version[0], version[1], "complete", 0o644)
    version
  end

  def validate_root_fd(artifacts_fd, expected = nil)
    entries = children(artifacts_fd).sort
    return nil if entries.empty?
    abort("publishable root must contain only current") unless entries == ["current"]
    current = open_dir_entry(artifacts_fd, "current")
    detected = derive_and_validate_set(current.fileno)
    abort("publishable current version does not match the release") if expected && detected != expected
    detected
  ensure
    current&.close
  end

  def create_unique_dir(parent_fd, label)
    64.times do
      name = "#{label}.#{Process.pid}.#{SecureRandom.hex(6)}"
      return name if mkdirat(parent_fd, name, 0o700, allow_exists: true)
    end
    abort("could not create unique anchored swap directory")
  end

  def cleanup_swap(tmp_fd, swap_fd, swap_name)
    children(swap_fd).each { |name| remove_entry(swap_fd, name, "any") }
    unlinkat(tmp_fd, swap_name, AT_REMOVEDIR)
  end

  def children(directory_fd)
    enumeration_fd = ReleaseFSSystem.openat(
      directory_fd,
      ".",
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
      0
    )
    raise_errno("could not open release directory for enumeration") if enumeration_fd.negative?
    stream = ReleaseFSSystem.fdopendir(enumeration_fd)
    if stream.to_i.zero?
      IO.for_fd(enumeration_fd, autoclose: true).close
      raise_errno("could not enumerate anchored release directory")
    end
    names = []
    loop do
      entry = ReleaseFSSystem.readdir(stream)
      break if entry.to_i.zero?
      name_length = entry[18, 2].unpack1("S")
      name = entry[21, name_length]
      names << name unless name == "." || name == ".."
    end
    names
  ensure
    ReleaseFSSystem.closedir(stream) if stream && !stream.to_i.zero?
  end

  def raise_errno(message)
    raise SystemCallError.new(message, Fiddle.last_error)
  end

  def pinned_git_executable(source_commit, path)
    listing, listing_error, listing_status = Open3.capture3(
      { "DEVELOPER_DIR" => nil },
      "/usr/bin/git", "-C", @repo, "ls-tree", "-z", source_commit, "--", path,
      binmode: true
    )
    abort(listing_error.empty? ? "could not inspect pinned release executable" : listing_error) \
      unless listing_status.success?
    match = /\A100755 blob ([0-9a-f]+)\t#{Regexp.escape(path)}\0\z/.match(listing)
    abort("pinned release executable is missing or has a non-executable Git mode: #{path}") unless match
    object = match[1]
    bytes, blob_error, blob_status = Open3.capture3(
      { "DEVELOPER_DIR" => nil },
      "/usr/bin/git", "-C", @repo, "cat-file", "blob", object,
      binmode: true
    )
    abort(blob_error.empty? ? "could not read pinned release executable" : blob_error) \
      unless blob_status.success?
    actual_object, hash_error, hash_status = Open3.capture3(
      { "DEVELOPER_DIR" => nil },
      "/usr/bin/git", "-C", @repo, "hash-object", "--stdin",
      stdin_data: bytes,
      binmode: true
    )
    abort(hash_error.empty? ? "could not authenticate pinned release executable" : hash_error) \
      unless hash_status.success?
    abort("pinned release executable Git object mismatch: #{path}") unless actual_object.strip == object
    bytes
  end

  def anonymous_executable(bytes, label)
    writable = nil
    name = nil
    tmp = open_dirs(["tmp"], true)
    64.times do
      name = ".pinned-executable.#{Process.pid}.#{SecureRandom.hex(12)}.#{label}"
      fd = ReleaseFSSystem.openat(
        tmp.fileno, name,
        O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        0o600
      )
      if fd.negative?
        next if Fiddle.last_error == Errno::EEXIST::Errno
        raise_errno("could not create pinned release executable")
      end
      writable = File.for_fd(fd, "w+", autoclose: true)
      written = 0
      written += writable.write(bytes.byteslice(written, bytes.bytesize - written)) while written < bytes.bytesize
      writable.flush
      sync_fd(writable.fileno, "pinned release executable")
      writable.rewind
      actual_digest = Digest::SHA256.hexdigest(writable.read)
      expected_digest = Digest::SHA256.hexdigest(bytes)
      abort("held pinned release executable bytes changed before unlink") \
        unless actual_digest == expected_digest
      writable.rewind
      secure_private_file(writable, name)
      test_pause("anonymous-executable-before-unlink")
      writable.rewind
      abort("held pinned release executable bytes changed during unlink boundary") \
        unless Digest::SHA256.hexdigest(writable.read) == expected_digest
      writable.rewind
      current = lstat_entry(tmp.fileno, name)
      abort("pinned release executable leaf changed before unlink") \
        unless current && !current.symlink? && same_inode?(current.stat, writable.stat)
      unlinkat(tmp.fileno, name, 0)
      sync_fd(tmp.fileno, "anonymous pinned executable directory")
      writable.close_on_exec = false
      program = writable
      writable = nil
      return program
    end
    abort("could not create a unique pinned release executable")
  ensure
    writable&.close unless writable&.closed?
    if name && tmp
      remaining = lstat_entry(tmp.fileno, name)
      unlinkat(tmp.fileno, name, remaining.directory? ? AT_REMOVEDIR : 0) if remaining
    end
    tmp&.close
  end

  def test_pause(stage)
    return unless ENV["ERYLO_RELEASE_FS_TESTING"] == "1"
    return unless ENV["ERYLO_RELEASE_FS_TEST_PAUSE_STAGE"] == stage
    delay = Float(ENV.fetch("ERYLO_RELEASE_FS_TEST_DELAY", "0.5"))
    abort("invalid release filesystem test delay") unless delay.positive? && delay <= 5
    STDERR.puts("RELEASE_FS_TEST_READY:#{stage}")
    STDERR.flush
    sleep(delay)
  end
end

command = ARGV.shift || abort("missing release filesystem command")
repo = ARGV.shift || abort("missing repository root")
fs = ReleaseFS.new(repo)

case command
when "output-path"
  fs.output_path(ARGV.fetch(0))
when "existing-path"
  fs.existing_path(ARGV.fetch(0), ARGV.fetch(1, "any"))
when "make-temp"
  fs.make_temp(ARGV.fetch(0))
when "make-directory"
  fs.make_directory(ARGV.fetch(0))
when "run-locked"
  fs.run_locked(ARGV)
when "assert-lock"
  fs.assert_lock
when "assert-lock-supervisor"
  fs.assert_lock
  puts "ERYLO_PINNED_LOCK_OK"
when "exec-supervisor"
  fs.exec_supervisor(ARGV)
when "recover-temporaries"
  fs.recover_temporaries
when "snapshot-mounts"
  fs.snapshot_mounts
when "file-identity"
  fs.file_identity(ARGV.fetch(0))
when "seal-file"
  fs.file_identity(ARGV.fetch(0), ARGV.fetch(1, "0400"))
when "assert-identity"
  fs.assert_identity(ARGV.fetch(0), ARGV.fetch(1))
when "remove"
  fs.remove(ARGV.fetch(0), ARGV.fetch(1, "any"))
when "publish-file"
  fs.publish_file(ARGV.fetch(0), ARGV.fetch(1))
when "publish-directory"
  fs.publish_directory(ARGV.fetch(0), ARGV.fetch(1))
when "validate-set"
  fs.validate_set(
    ARGV.fetch(0), ARGV.fetch(1), ARGV.fetch(2), ARGV.fetch(3), ARGV[4], ARGV[5], ARGV[6], ARGV[7]
  )
when "validate-private-set"
  fs.validate_private_set(
    ARGV.fetch(0), ARGV.fetch(1), ARGV.fetch(2), ARGV.fetch(3), ARGV.fetch(4), ARGV.fetch(5), ARGV.fetch(6)
  )
when "publish-private-set"
  fs.publish_private_set(
    ARGV.fetch(0), ARGV.fetch(1), ARGV.fetch(2), ARGV.fetch(3), ARGV.fetch(4), ARGV.fetch(5), ARGV.fetch(6)
  )
when "validate-private-root"
  fs.validate_private_root
when "validate-root"
  fs.validate_root(ARGV[0], ARGV[1])
when "swap-current"
  fs.swap_current(
    ARGV.fetch(0), ARGV.fetch(1), ARGV.fetch(2), ARGV.fetch(3, "none"),
    ARGV[4], ARGV[5], ARGV[6], ARGV[7], ARGV[8], ARGV[9], ARGV[10]
  )
else
  abort("unknown release filesystem command: #{command}")
end
