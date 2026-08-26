# Direct-download release runbook

The release path produces an Apple-Silicon-only macOS 14+ `.app` and ZIP under ignored `.release/` staging. It never creates an ad-hoc signature, unlocks a Keychain, stores credentials, accepts private-key files, or publishes artifacts. Publication is always a separate approval.

## Tracked inputs

- `Config/ReleaseVersion.env`: product, bundle ID, marketing/build versions, minimum OS, architecture, and Sparkle version.
- `Resources/App/Info.plist.in`: reviewed bundle, category, agent-app, permission, and default-off updater metadata.
- `Resources/App/Erylo.entitlements`: the single Apple Events Hardened Runtime capability.
- `LICENSE` and `Resources/App/ThirdPartyNotices.txt`: Erylo's actual Apache-2.0 license and the reviewed Sparkle 2.9.6/bundled-component redistribution notices copied into every app.
- `Package.resolved`: exact Sparkle dependency resolution.
- A reviewed `.icns` asset and real public appcast plist when they are ready. Both are normal trackable inputs; neither exists as a fake release value.

`com.erylo.Erylo` must be confirmed against the shipping Developer ID/account and URL ownership before 1.0. Change bundle identity only through review because it affects permissions, preferences, Keychain identity, Sparkle continuity, and rollback.

## Command Line Tools verification

These stages do not sign or notarize and are safe to run with Apple's Command Line Tools:

```sh
Scripts/release/build-app.sh
Scripts/release/validate-symbols.sh
Scripts/release/archive-symbols.sh
Scripts/release/assemble-app.sh
Scripts/release/validate-app.sh .release/stage/Erylo.app
Scripts/release/archive-app.sh --app .release/stage/Erylo.app
Scripts/release/checksums.sh .release/artifacts/Erylo-0.1.0-1-arm64.zip
```

The release harness additionally exercises metadata, entitlement minimality, architecture/version consistency, exact license/notices, placeholder rejection, path containment, symlink escape denial, missing-tool behavior, dSYM UUID matching, and byte-reproducible app/dSYM archiving for identical input and epoch.

## Production prerequisites

- Clean reviewed release commit and green `Scripts/ci.sh`.
- Full Xcode selected at an `Xcode.app/Contents/Developer` path.
- Available `Developer ID Application: ...` identity in the current Keychain.
- Existing `notarytool` Keychain profile that authenticates noninteractively. Store it outside this repository using Apple's supported procedure.
- Existing Sparkle EdDSA private key in Keychain under the named account; never pass a private key file or secret environment variable.
- Reviewed `.icns` artwork.
- Reviewed appcast plist containing the final canonical lowercase HTTPS feed URL with no userinfo, explicit port, query, or fragment; the public EdDSA key; `SURequireSignedFeed=true`; and `SUVerifyUpdateBeforeExtraction=true`.

Run the fail-closed wrapper:

```sh
Scripts/release/release.sh \
  --identity "Developer ID Application: ORGANIZATION (TEAMID)" \
  --keychain-profile NOTARY_PROFILE \
  --appcast-config Config/Appcast.plist \
  --icon Resources/App/AppIcon.icns
```

The identity and profile names are selectors, not credentials. The wrapper rejects a dirty tree, missing inputs, Command Line Tools-only environments, missing identities/profiles/tools, invalid public feed metadata, signing failures, non-accepted notarization, stapling failures, Gatekeeper failures, and missing Sparkle Keychain keys.

## Stage order and evidence

1. `build-app.sh` builds arm64 Release with Swift warnings as errors into `.release/swift-build`, runs `dsymutil` while Swift object files still exist, proves the dSYM UUID set exactly matches the executable, and stages the executable, dSYM, Sparkle framework, and reviewed Sparkle release tools. `archive-symbols.sh` creates a reproducible private `.release/private/*.dSYM.zip`; its separate SHA-256 manifest is retained privately and never embedded in or published with the app/update.
2. `assemble-app.sh` creates the fixed bundle layout, embeds Sparkle, copies the exact reviewed licenses/notices, removes unused XPC services, routes a real icon only when supplied, and injects public signed-feed metadata only when complete.
3. `validate-app.sh --require-updater` checks plist values, permissions text, source/version/architecture consistency, exact licenses/notices, rpaths, Sparkle version/layout, symlink containment, entitlements, and secret/placeholders.
4. `sign-app.sh` uses Sparkle's documented inner-to-outer signing order with secure timestamps and Hardened Runtime. It never signs with `--deep` or `-`.
5. `verify-signature.sh --pre-notarization` verifies every nested component, the app, Developer ID authority, runtime flag, and signed entitlements.
6. `archive-app.sh` copies the bundle, normalizes timestamps to the release commit epoch, writes entries in sorted order, preserves framework symlinks, and rejects unsafe entries. The pre-staple submission ZIP is kept under `.release/notarization/submissions/`, never `.release/artifacts/`; release startup safely removes the exact legacy artifact path and rejects any other non-publishable entry in the artifact directory.
7. `notarize-archive.sh` verifies that the Keychain profile works, submits the ZIP, waits for a terminal result, atomically publishes result metadata from a private temporary file under `.release/notarization`, and accepts only `Accepted`. A pre-existing result symlink is removed as an exact in-root leaf and is never followed.
8. `staple-app.sh` staples and validates the ticket, then runs Gatekeeper and notarization verification. Post-staple structure validation permits exactly the regular, non-symlink `Contents/CodeResources` ticket that Apple adds, while pre-staple validation and all other `Contents` allowlisting stay strict.
9. A fresh final ZIP is created from the stapled app using post-staple validation. `sign-update.sh` applies the same canonical feed-URL policy as assembly/runtime, looks up—but never generates—the existing Sparkle Keychain key, proves its public key matches the committed appcast config, and writes public signature/length metadata. `checksums.sh` writes SHA-256 evidence.

After success, `.release/artifacts/` is an intentionally narrow publication surface: final stapled `Erylo-…-arm64.zip`, its `.sparkle-signature.json`, and `SHA256SUMS` only. Notarization upload/result material remains under `.release/notarization/`; private dSYM ZIP/hash evidence remains under `.release/private/`. A failed or resumed release cannot leave the plausible pre-staple `*-submission.zip` in the publishable directory.

Signing and notarization are intentionally not reproducible byte-for-byte because secure timestamps and service tickets are external evidence. Archiving the same already-built app with the same source epoch is reproducible and covered by the harness.

## Clean-install and notarization gate

Do this on a clean standard-user Apple Silicon Mac that has never built Erylo:

1. Download the final artifact from the actual public endpoint; do not copy it from the build Mac.
2. Compare its SHA-256 with separately retained release evidence.
3. Confirm the download retains quarantine, expand it, and run `codesign --verify --deep --strict --verbose=2`, `spctl --assess --type execute --verbose=4`, and `xcrun stapler validate` on the app.
4. Copy to `/Applications`, disconnect the network, and launch. Confirm first launch succeeds offline, the app is an agent with no Dock icon, no unrelated permission prompt appears, and no updater request occurs.
5. Enable Calendar and media automation separately. Confirm each explanation is contextual, denial is usable, and disabled modules retain no work.
6. Quit, relaunch, reboot, uninstall, and reinstall. Confirm no orphan helper/XPC service, launch item, cache, or protected user data remains unexpectedly.
7. Record Mac model, chip, OS build, displays, scaling, test operator, artifact hash, and results in the compatibility evidence.

## Rollback

Retain the previous notarized app, appcast/feed, release notes, private dSYM archive and hash evidence, and public hashes in access-controlled storage before publication. Never upload the dSYM archive with the app/update. Never attempt an updater “rollback” by decreasing `CFBundleVersion`; Sparkle and macOS version ordering make that unsafe. If a shipped build must be reverted, create a reviewed forward-fix build with a higher build number containing the known-good code, sign/notarize it normally, test the affected upgrade path, and publish it through the signed feed.

Restoring the previous feed may stop not-yet-updated users from receiving a bad release, but it does not downgrade installations that already advanced. The release owner must decide whether to pause the feed, publish a forward fix, or remove the download, and must verify CDN state and hashes after every change.
