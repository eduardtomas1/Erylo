# Sparkle 2 decision record

Reviewed on 2026-08-26 against Sparkle's official [setup](https://sparkle-project.org/documentation/), [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/), [customization](https://sparkle-project.org/documentation/customization/), [sandboxing/signing](https://sparkle-project.org/documentation/sandboxing/), and [2.9.6 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6) documentation.

## Decision

Integrate Sparkle 2.9.6 as an exact SwiftPM dependency. Version 2.9.6 was the current stable release at review time and includes recent installer security fixes. `Package.resolved` and `Config/ReleaseVersion.env` pin the same version; the release harness checks the pin, and bundle validation checks the embedded framework version.

This SwiftPM-only shape is supportable because Sparkle documents manual framework embedding, preserving symlinks, and the exact inside-out signing order for non-Xcode distribution workflows. `assemble-app.sh` embeds the framework with an app-relative rpath. Because Erylo is not sandboxed, it removes Sparkle's unused `Downloader.xpc` and `Installer.xpc` paths as permitted by the official guide. The app receives no sandbox, network-client/server, root, Full Disk Access, Accessibility, JIT, unsigned-code, or library-validation exception entitlement.

## Default-off behavior

The reviewed `Info.plist` template deliberately contains neither `SUFeedURL` nor `SUPublicEDKey`. It explicitly sets automatic checks, automatic download/install, automatic-update availability, system profiling, and both XPC-service flags to false.

`UpdateRuntime` does not instantiate Sparkle unless all of these conditions hold:

- a canonical lowercase `https://` feed URL is present with a DNS hostname, no authority userinfo (including empty `https://@...` userinfo), no explicit port, query, or fragment;
- a base64 public EdDSA key decodes to exactly 32 bytes;
- `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are true;
- automatic checks and automatic updates remain false.

The current app starts the configured updater but never initiates a check. An injected `UpdateDriving` seam exposes a future user-initiated check without coupling release infrastructure to settings or panel UI. The update harness proves that absent or invalid metadata creates no driver and performs no updater work.

The feed is intentionally a canonical static HTTPS origin/path. Sparkle does not require userinfo, an explicit port, a query string, or a fragment for this release design, so all four are rejected at assembly, bundle validation, update signing, and runtime. The shared shell validator rejects any `@` in the authority, including Ruby URI's otherwise ambiguous empty-userinfo form; `UpdateConfiguration` applies the same policy before Sparkle can start. This prevents credentials from being copied into public `Info.plist` metadata and avoids feed aliases whose bytes or cache behavior are harder to audit. If channels or a non-default port are added later, use Sparkle's reviewed mechanism and a new decision record rather than weakening this policy ad hoc.

`Config/Appcast.example.plist` is documentation only and is deliberately rejected. A real config may be committed because the feed URL and EdDSA public key are public metadata. Private EdDSA material is accepted only through Sparkle's Keychain lookup by `sign-update.sh`; the scripts have no private-key-file, environment-secret, or stdin-secret route.

## Publication gates still open

Integration does not make update publication ready. Every item below blocks enabling or publishing the feed:

- Create and back up the production EdDSA key using an approved Keychain/secret-storage procedure; commit only the public key.
- Publish the appcast, archives, and release notes over the final HTTPS origin and configure the real feed URL.
- Generate and sign the appcast/feed and release notes with the reviewed Sparkle tools; the repository intentionally contains no fabricated feed or signature.
- Add the user-initiated “Check for Updates” control in the owning settings/app-command feature branch. Automatic network work must remain opt-in and is not introduced here.
- Test a genuine older signed/notarized build updating to the candidate, signature rejection, an interrupted download/install, relaunch, version ordering, minimum-OS rejection, and a forward-fix rollback build.
- Verify the public download and appcast bytes match retained hashes and signature metadata after CDN publication.

Until those gates close, ship no appcast metadata in the assembled app. `release.sh` enforces the opposite for a production candidate: it requires a non-placeholder signed-feed config and will fail closed without one.
