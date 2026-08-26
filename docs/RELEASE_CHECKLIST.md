# Release safety checklist

Use this checklist for every Developer ID distribution candidate. Record evidence or an explicit owner for each incomplete item; unchecked release gates block publication.

Operational commands and artifact boundaries are in [`RELEASE_RUNBOOK.md`](RELEASE_RUNBOOK.md). Record manual hardware results in [`COMPATIBILITY_MATRIX.md`](COMPATIBILITY_MATRIX.md), and close every updater gate named in [`SPARKLE.md`](SPARKLE.md).

## Provenance and compatibility

- [ ] Release commit is reviewed, CI is green, the worktree is clean, its upstream points to the exact commit in both outer and authenticated worker admission, and the read-only APFS source image commit/tree/config/compiler-input hashes plus the selected named-tool manifest hash match all bundle/public/private manifests. The exact Xcode/SDK/Swift values in `Config/ReleaseToolchain.env` are approved, the Xcode application passes Apple code-signature/system assessment, and the manifest does not claim to hash every SDK or compiler-spawned linker input.
- [ ] External snapshot/capability variables are rejected before lock-wrapper execution; outer-only `release-driver.sh` rejects source/worker state before any helper lookup; worker-only `release-worker.sh` uses the pipe/PID record only for replay/order, executes verifier/authenticator bytes from exact Git objects, and authenticates the recorded read-only APFS image/device/mount plus clean checkout and exact upstream before argument handling or candidate-root helper use. Direct outer/worker invocation, candidate-helper/verifier, chmod-copy, orphan-mount, concurrent-invocation, normal success/failure, and real SIGKILL settlement/restart harnesses leave zero publication/mount/device/temp ambiguity.
- [ ] Full-Xcode path selection uses only pinned system tools until the containing Xcode application passes `codesign`, Apple Team Identifier/signing-chain and `spctl` checks; no selected `xcrun`, `xcodebuild`, compiler, SDK or developer tool runs before authentication, and the same authentication precedes the final full toolchain assertion.
- [ ] `Scripts/release/validate-app.sh --require-updater .release/stage/Erylo.app` passes before stapling, and explicit post-staple validation passes afterward with exactly Apple's regular `Contents/CodeResources` ticket added.
- [ ] Dependencies, Erylo's actual Apache-2.0 license, Sparkle/bundled-component notices, and shipped helper provenance are reviewed and bundled exactly; no unreviewed license is invented.
- [ ] The compatibility matrix covers supported macOS versions, Apple Silicon models, displays/notchless displays, scaling, mirroring, clamshell, Spaces, fullscreen, Stage Manager, hot-plug, and sleep/wake.
- [ ] Accessibility, Reduce Motion, localization, clean-install, upgrade, downgrade/rollback, and settings-reset paths pass.

## Privacy, permissions, and integrations

- [ ] The app requires neither root nor Full Disk Access; entitlements and Hardened Runtime exceptions are minimal and reviewed.
- [ ] Each permission is requested contextually on first feature use, with an accurate explanation and a usable denial path.
- [ ] Disabled providers perform zero CPU/network work and retain no permission-dependent work.
- [ ] File Hold copy/reference semantics, bookmark scope, expiry, collision handling, failure cleanup, and deletion are verified without data loss.
- [ ] Diagnostics export is user-initiated and redacted; crash reporting is opt-in; the privacy/support text matches shipped behavior.
- [ ] URL schemes, App Intents, CLI, and per-user Unix-socket JSON inputs are authenticated or ownership-bounded, schema-validated, size/rate-bounded, and unable to execute arbitrary commands.

## Reliability and energy

- [ ] No P0/P1 lifecycle defects remain across the supported matrix.
- [ ] Collapsed idle has zero repeating timers, polling, or display links and meets the internal `<0.3% CPU` target after settling on the recorded reference M-series Mac.
- [ ] Open/close motion is verified at 120 Hz where available; artwork decoding and thumbnails remain off the main thread.
- [ ] Provider start/stop, preemption, expiry, cancellation, stale-state recovery, and unknown-event rejection pass stress and failure tests.
- [ ] Internal performance targets have not been presented as public claims without separately reviewed evidence.

## Signing, notarization, and Sparkle 2

- [ ] Developer ID identity, App Store Connect API key, Sparkle private key, notary credentials, and keychains come from approved secret storage and never enter source, logs, artifacts, or diagnostics.
- [ ] The archive is built from the tagged commit with the expected bundle ID, version, entitlements, Hardened Runtime, and designated requirement.
- [ ] `dsymutil` ran before Swift build objects were cleaned, every dSYM UUID matches the release executable, and the atomic `0600` dSYM/manifest/checksum set is retained under its immutable commit-qualified private directory outside publishable artifacts.
- [ ] The app and every nested executable/framework pass `codesign --verify --deep --strict --verbose=2` and `spctl --assess --type execute --verbose=4`.
- [ ] The submitted artifact is notarized, stapled, and passes `xcrun stapler validate`; a clean Mac validates first launch offline after Gatekeeper assessment.
- [ ] Sparkle 2 feed URL, HTTPS transport, EdDSA signature, version ordering, minimum OS, phased behavior (if used), and release notes are verified from the published feed.
- [ ] The public appcast config requires a signed feed and pre-extraction verification; effective Info.plist, persisted, argument-domain, and managed Sparkle preferences cannot enable automatic checks/downloads or system profiling; the manual check remains user-initiated; unused XPC services remain disabled.
- [ ] Shell and runtime pass the same tracked URL/key vector corpora: canonical ASCII FQDN HTTPS only (no IDNA/punycode, IP/legacy numeric/local host, authority encoding/userinfo/port, query/fragment, raw Unicode/space, or noncanonical percent spelling) and exact canonical Base64 for the 32-byte EdDSA public key.
- [ ] Update, interrupted update, signature rejection, rollback, and compatibility-note paths pass from every supported prior version.
- [ ] Final DMG/PKG/ZIP hashes, notarization evidence, symbols, and release notes are retained in access-controlled release storage; symbols and diagnostics are not published accidentally.
- [ ] `.release/artifacts/` contains only `current/`; that `0700` directory contains exactly the singular `0644` final stapled ZIP, matching source/config-bound Sparkle signature metadata, and verified two-entry checksum manifest. No stale/old final, orphan signature, extra entry, hardlink/symlink, partial output, or submission ZIP remains after success, failure, or resume.
- [ ] `.release`, temp, staging, notary, private, internal rollback, and publication directories are current-user-owned `0700`; private evidence is `0600`; link count is one; hostile `umask`/PATH, parent-swap, hardlink, source/toolchain mutation, post-check byte substitution, and planted caller rollback-leaf harnesses pass.
- [ ] Public-current replacement uses the Darwin crash-atomic directory exchange path and passes every pre-sync/post-sync/pre-exchange/post-exchange/post-directory-sync/post-retired-cleanup SIGKILL cut; bootstrap producer/read/hash failures and held-descriptor or caller-leaf replacement all fail closed, restore the exact prior current set when required, and recover with no ambiguous internal transaction.

## Publication and rollback

- [ ] The final artifact downloaded from the public endpoint matches the reviewed hash and passes clean-install, launch, update, and uninstall checks.
- [ ] Support and security reporting paths are reachable, and the release owner and rollback decision path are recorded.
- [ ] A known-good prior artifact/feed state is available, and rollback has been rehearsed without invalidating existing installations.
- [ ] Post-release health checks use aggregate or explicitly opted-in data only; no hidden telemetry or perpetual background work was introduced.
