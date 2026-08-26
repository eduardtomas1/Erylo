# Release safety checklist

Use this checklist for every Developer ID distribution candidate. Record evidence or an explicit owner for each incomplete item; unchecked release gates block publication.

Operational commands and artifact boundaries are in [`RELEASE_RUNBOOK.md`](RELEASE_RUNBOOK.md). Record manual hardware results in [`COMPATIBILITY_MATRIX.md`](COMPATIBILITY_MATRIX.md), and close every updater gate named in [`SPARKLE.md`](SPARKLE.md).

## Provenance and compatibility

- [ ] Release commit is reviewed, CI is green, the worktree is clean, and generated artifacts are outside Git.
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
- [ ] `dsymutil` ran before Swift build objects were cleaned, every dSYM UUID matches the release executable, and the private dSYM ZIP/checksum evidence is retained outside publishable artifacts.
- [ ] The app and every nested executable/framework pass `codesign --verify --deep --strict --verbose=2` and `spctl --assess --type execute --verbose=4`.
- [ ] The submitted artifact is notarized, stapled, and passes `xcrun stapler validate`; a clean Mac validates first launch offline after Gatekeeper assessment.
- [ ] Sparkle 2 feed URL, HTTPS transport, EdDSA signature, version ordering, minimum OS, phased behavior (if used), and release notes are verified from the published feed.
- [ ] The public appcast config requires a signed feed and pre-extraction verification; automatic checks, automatic installs, system profiling, and unused XPC services remain disabled.
- [ ] The appcast URL has canonical lowercase HTTPS metadata with no authority `@`/userinfo, credentials, explicit port, query, or fragment at assembly, validation, update signing, and runtime.
- [ ] Update, interrupted update, signature rejection, rollback, and compatibility-note paths pass from every supported prior version.
- [ ] Final DMG/PKG/ZIP hashes, notarization evidence, symbols, and release notes are retained in access-controlled release storage; symbols and diagnostics are not published accidentally.
- [ ] `.release/artifacts/` contains only the final stapled ZIP, its public Sparkle signature metadata, and checksums; no pre-staple/submission ZIP remains after success, failure, or resume.

## Publication and rollback

- [ ] The final artifact downloaded from the public endpoint matches the reviewed hash and passes clean-install, launch, update, and uninstall checks.
- [ ] Support and security reporting paths are reachable, and the release owner and rollback decision path are recorded.
- [ ] A known-good prior artifact/feed state is available, and rollback has been rehearsed without invalidating existing installations.
- [ ] Post-release health checks use aggregate or explicitly opted-in data only; no hidden telemetry or perpetual background work was introduced.
