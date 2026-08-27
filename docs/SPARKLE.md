# Sparkle 2 decision record

Reviewed on 2026-08-26 against Sparkle's official [setup](https://sparkle-project.org/documentation/), [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/), [customization](https://sparkle-project.org/documentation/customization/), [sandboxing/signing](https://sparkle-project.org/documentation/sandboxing/), and [2.9.6 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6) documentation.

## Decision

Integrate Sparkle 2.9.6 as an exact SwiftPM dependency. Version 2.9.6 was the current stable release at review time and includes recent installer security fixes. `Package.resolved` and `Config/ReleaseVersion.env` pin the same version; the release harness checks the pin, and bundle validation checks the embedded framework version.

This SwiftPM-only shape is supportable because Sparkle documents manual framework embedding, preserving symlinks, and the exact inside-out signing order for non-Xcode distribution workflows. `assemble-app.sh` embeds the framework with an app-relative rpath. Because Erylo is not sandboxed, it removes Sparkle's unused `Downloader.xpc` and `Installer.xpc` paths as permitted by the official guide. The app receives no sandbox, network-client/server, root, Full Disk Access, Accessibility, JIT, unsigned-code, or library-validation exception entitlement.

## Default-off behavior

The reviewed `Info.plist` template deliberately contains neither `SUFeedURL` nor `SUPublicEDKey`. It explicitly sets automatic checks, automatic download/install, automatic-update availability, system profiling, and both XPC-service flags to false.

`UpdateRuntime` does not instantiate Sparkle unless all of these conditions hold:

- a canonical lowercase `https://` feed URL is present with an ASCII DNS FQDN of at least two labels, no IP/legacy-numeric/IDNA/local hostname, no raw normalization, and no authority userinfo (including empty `https://@...` userinfo), percent encoding, explicit port, query, or fragment;
- a strict canonical Base64 public EdDSA key decodes to exactly 32 bytes and re-encodes byte-for-byte identically;
- `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are true;
- automatic checks, automatic downloads/installs, automatic-update availability, and system profiling remain false; and
- no custom `SUDefaultsDomain` redirects Sparkle to an unreviewed preference domain.

Sparkle gives effective `NSUserDefaults` values precedence over Info.plist and applies Objective-C `NSNumber`/`NSString` coercion. Before constructing or starting the updater, Erylo overwrites the effective automatic-check, interval, automatic-download, system-profile, and persisted-feed preferences with the closed policy, reads them back with the same coercion, and refuses to construct Sparkle when a managed or argument-domain value resists. It then applies and verifies the same policy on `SPUUpdater` immediately before and after `startUpdater()`, and again before a manual check. Thus a persisted `true`, `"YES"`, or `1` cannot silently schedule background work while a plist `false` is displayed as the policy.

The app starts the updater only for complete reviewed metadata and exposes `Check for Updates…` only when that startup succeeds. Selecting that menu command is the sole path that initiates a check. The tracked default app metadata remains disabled, so development builds omit the command and perform no update network work. The injected `UpdateDriving` seam keeps the command decoupled from Sparkle while the update and application-runtime harnesses cover policy variants, factory/start failure, availability, and manual routing. Automatic network work remains mechanically disabled.

The feed is intentionally one canonical static HTTPS origin/path. Sparkle does not require userinfo, ports, query strings, fragments, local/IP destinations, IDNA aliases, or raw-to-normalized URL rewriting for this release design, so they are rejected at assembly, bundle validation, update signing, and runtime. The tracked shared vector corpus covers empty userinfo, credentials, encoded authority characters, raw Unicode and Unicode-dot hosts/paths, spaces, punycode, host case, trailing dots, numeric/legacy IP forms, local names, ports, query/fragment, and valid percent-encoded paths. Runtime retains the original plist spelling and requires it to equal Foundation's serialization, preventing normalization from silently widening shell policy. If channels or a non-default port are added later, use Sparkle's reviewed mechanism and a new decision record rather than weakening this policy ad hoc.

`Config/Appcast.example.plist` is documentation only and is deliberately rejected. A real config may be committed because the feed URL and EdDSA public key are public metadata. Private EdDSA material is accepted only through Sparkle's Keychain lookup by `sign-update.sh`; the scripts have no private-key-file, environment-secret, or stdin-secret route.

## Publication gates still open

Integration does not make update publication ready. Every item below blocks enabling or publishing the feed:

- Create and back up the production EdDSA key using an approved Keychain/secret-storage procedure; commit only the public key.
- Publish the appcast, archives, and release notes over the final HTTPS origin and configure the real feed URL.
- Generate and sign the appcast/feed and release notes with the reviewed Sparkle tools; the repository intentionally contains no fabricated feed or signature.
- Test a genuine older signed/notarized build updating to the candidate, signature rejection, an interrupted download/install, relaunch, version ordering, minimum-OS rejection, and a forward-fix rollback build.
- Verify the public download and appcast bytes match retained hashes and signature metadata after CDN publication.

Until those gates close, ship no appcast metadata in the assembled app. `release.sh` enforces the opposite for a production candidate: it requires a non-placeholder signed-feed config and will fail closed without one.
