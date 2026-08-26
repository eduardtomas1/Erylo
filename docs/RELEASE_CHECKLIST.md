# Release safety checklist

Use this checklist for every Developer ID distribution candidate. Record evidence or an explicit owner for each incomplete item; unchecked release gates block publication.

## Provenance and compatibility

- [ ] Release commit is reviewed, CI is green, the worktree is clean, and generated artifacts are outside Git.
- [ ] Dependencies, licenses, notices, and shipped helper provenance are reviewed; no GPL implementation was copied into the proprietary build.
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
- [ ] The app and every nested executable/framework pass `codesign --verify --deep --strict --verbose=2` and `spctl --assess --type execute --verbose=4`.
- [ ] The submitted artifact is notarized, stapled, and passes `xcrun stapler validate`; a clean Mac validates first launch offline after Gatekeeper assessment.
- [ ] Sparkle 2 feed URL, HTTPS transport, EdDSA signature, version ordering, minimum OS, phased behavior (if used), and release notes are verified from the published feed.
- [ ] Update, interrupted update, signature rejection, rollback, and compatibility-note paths pass from every supported prior version.
- [ ] Final DMG/PKG/ZIP hashes, notarization evidence, symbols, and release notes are retained in access-controlled release storage; symbols and diagnostics are not published accidentally.

## Publication and rollback

- [ ] The final artifact downloaded from the public endpoint matches the reviewed hash and passes clean-install, launch, update, and uninstall checks.
- [ ] Support and security reporting paths are reachable, and the release owner and rollback decision path are recorded.
- [ ] A known-good prior artifact/feed state is available, and rollback has been rehearsed without invalidating existing installations.
- [ ] Post-release health checks use aggregate or explicitly opted-in data only; no hidden telemetry or perpetual background work was introduced.
