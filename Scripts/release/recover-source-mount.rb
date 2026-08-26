#!/usr/bin/ruby

require "digest"
require "json"
require "open3"

repo = File.realpath(ARGV.fetch(0))
mount = File.expand_path(ARGV.fetch(1))
expected_commit = ARGV[2]
release_prefix = File.join(repo, ".release", "tmp") + File::SEPARATOR
relative = mount.delete_prefix(release_prefix)
match = /\A(source-snapshot\.\d+\.[0-9a-f]{12})\/mount\z/.match(relative)
abort("source snapshot mount path is outside one managed transaction") unless mount.start_with?(release_prefix) && match

transaction = File.join(repo, ".release", "tmp", match[1])
abort("source snapshot transaction path is unsafe") if File.symlink?(transaction) || !File.directory?(transaction)
image = File.join(transaction, "source.dmg")
journal_path = File.join(transaction, "SourceImage.json")
[image, journal_path].each do |path|
  stat = File.lstat(path)
  abort("source snapshot recovery input is not one private regular file") \
    unless stat.file? && stat.nlink == 1 && stat.uid == Process.euid && (stat.mode & 0o777) == 0o400
end

journal = JSON.parse(File.read(journal_path))
abort("source snapshot recovery journal is noncanonical") \
  unless journal.keys.sort == ["image", "imageSHA256", "mount", "sourceCommit"]
abort("source snapshot recovery journal names are invalid") \
  unless journal.fetch("image") == "source.dmg" && journal.fetch("mount") == "mount"
abort("source snapshot recovery commit is invalid") \
  unless /\A[0-9a-f]{40}\z/.match?(journal.fetch("sourceCommit"))
if expected_commit
  abort("expected source snapshot commit is invalid") unless /\A[0-9a-f]{40}\z/.match?(expected_commit)
  abort("source snapshot recovery commit does not match the release") \
    unless journal.fetch("sourceCommit") == expected_commit
end
actual_hash = Digest::SHA256.file(image).hexdigest
abort("source snapshot image no longer matches its recovery journal") \
  unless actual_hash == journal.fetch("imageSHA256")

info_plist, info_error, info_status = Open3.capture3("/usr/bin/hdiutil", "info", "-plist", binmode: true)
abort(info_error.empty? ? "could not inspect mounted disk images" : info_error) unless info_status.success?
info_output, convert_error, convert_status = Open3.capture3(
  "/usr/bin/plutil", "-convert", "json", "-o", "-", "--", "-",
  stdin_data: info_plist,
  binmode: true
)
abort(convert_error.empty? ? "could not parse mounted disk images" : convert_error) unless convert_status.success?
images = JSON.parse(info_output).fetch("images")
matches = images.select do |entry|
  begin
    File.realpath(entry.fetch("image-path")) == File.realpath(image) && entry.fetch("writeable") == false
  rescue Errno::ENOENT, KeyError
    false
  end
end
abort("managed source image is not attached exactly once") unless matches.length == 1
entities = matches.fetch(0).fetch("system-entities").select do |entity|
  entity["mount-point"] == mount
end
abort("managed source image is not mounted at its recorded path") unless entities.length == 1
device = entities.fetch(0).fetch("dev-entry")
abort("managed source image device is noncanonical") unless /\A\/dev\/disk[0-9]+s[0-9]+\z/.match?(device)
puts device
