# Direct-download release runbook

The release path produces an Apple-Silicon-only macOS 14+ `.app` and ZIP under ignored `.release/` staging. It never creates an ad-hoc signature, unlocks a Keychain, stores credentials, accepts private-key files, or publishes artifacts. Publication is always a separate approval.

## Tracked inputs

- `Config/ReleaseVersion.env`: product, bundle ID, marketing/build versions, minimum OS, architecture, and Sparkle version.
- `Resources/App/Info.plist.in`: reviewed bundle, category, agent-app, permission, and default-off updater metadata.
- `Resources/App/Erylo.entitlements`: the single Apple Events Hardened Runtime capability.
- `LICENSE` and `Resources/App/ThirdPartyNotices.txt`: Erylo's actual Apache-2.0 license and the reviewed Sparkle 2.9.6/bundled-component redistribution notices copied into every app.
- `Package.resolved`: exact Sparkle dependency resolution.
- `Config/ReleaseCompilerInputs.txt`: the sorted, deny-by-default set of Git blobs that Swift may compile into the production executable. Any transient, nested, unusual-path, or otherwise unreviewed in-image Swift input aborts the build.
- `Config/ReleaseToolchain.env`: the reviewed exact Xcode version/build, macOS SDK version/build, and SHA-256 of the exact Swift compiler identity text. Its tracked `UNCONFIRMED` values deliberately block production release until a release owner approves one Apple toolchain.
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

The release harness additionally exercises metadata, entitlement minimality, architecture/version consistency, exact license/notices, placeholder rejection, path containment, descriptor-anchored parent-swap resistance, symlink/hardlink denial, owner/mode enforcement under hostile umasks, missing-tool behavior, dSYM UUID matching, immutable source/config binding, transactional public/private failure recovery, and byte-reproducible app/dSYM archiving for identical input and epoch.

## Production prerequisites

- Clean reviewed release commit, green `Scripts/ci.sh`, and an upstream ref pointing at that exact commit. The wrapper exports that commit with `git archive`, verifies every regular file against its Git object, rejects all source-tree symlinks, creates and attaches a read-only APFS image, and runs all tracked source, package, script, plist, notice, entitlement, appcast, and icon inputs from that image.
- Full Xcode selected at an `Xcode.app/Contents/Developer` path whose exact identifiers match `Config/ReleaseToolchain.env`; `codesign` and system policy assessment must authenticate the application as Apple's Xcode distribution. Command Line Tools remain validation-only.
- Available `Developer ID Application: ...` identity in the current Keychain.
- Existing `notarytool` Keychain profile that authenticates noninteractively. Store it outside this repository using Apple's supported procedure.
- Existing Sparkle EdDSA private key in Keychain under the named account; never pass a private key file or secret environment variable.
- Reviewed `.icns` artwork.
- Reviewed appcast plist containing the final canonical lowercase-`https` URL for an ASCII DNS FQDN (at least two labels; no IP/legacy-numeric, IDNA/punycode, local, userinfo, explicit port, query, fragment, raw Unicode/space, or noncanonical percent spelling), a strict canonical Base64 32-byte public EdDSA key, `SURequireSignedFeed=true`, and `SUVerifyUpdateBeforeExtraction=true`.

Run the fail-closed wrapper:

```sh
Scripts/release/release.sh \
  --identity "Developer ID Application: ORGANIZATION (TEAMID)" \
  --keychain-profile NOTARY_PROFILE \
  --appcast-config Config/Appcast.plist \
  --icon Resources/App/AppIcon.icns
```

The identity and profile names are selectors, not credentials. The wrapper rejects a dirty or unpushed/untracked source state, any mid-run live-worktree mutation, missing inputs, Command Line Tools-only environments, missing identities/profiles/tools, invalid public feed/key metadata, signing failures, non-accepted notarization, stapling failures, Gatekeeper failures, and missing Sparkle Keychain keys. Production scripts use `/bin/bash`, reset to a closed system PATH, and resolve every Apple developer tool through `/usr/bin/xcrun` under one exported, revalidated `DEVELOPER_DIR`. Bundle and public/private manifests bind the source commit, source tree, appcast-config SHA-256, and canonical toolchain-manifest SHA-256.

## Stage order and evidence

1. `release.sh` first fixes `umask` to `077` and rejects every caller-supplied internal snapshot/worker variable before acquiring the repository release lock. The lock helper scrubs those variables again and mints a two-stage one-use pipe capability; the outer process must consume its stage before admission continues. The wrapper then verifies `.release` ownership, enforces private directory mode `0700`, and exports the exact clean upstream commit into a read-only APFS source image. The image journal binds the exact image hash, commit, mount path, and attachment. Startup recovery runs only while holding that lock, authenticates the exact abandoned image/device/mount relationship, detaches by device, and refuses an unrelated or path-replaced mount.
2. `Scripts/release/release.sh` is the only public entry and the only script that implements `--help`. Fixed tracked `100755` roles follow: outer-only `release-driver.sh` rejects every snapshot/source-root/supervisor variable before its first lock/helper resolution, then always performs recovery, clean/upstream admission, authenticated-toolchain capture, image creation and supervisor handoff; worker-only `release-worker.sh` never selects a shorter role from environment state. Pre-authentication source-control and Git-object reads use the fixed system Git route with caller `DEVELOPER_DIR` removed, including the exact-blob verifier's child processes. The worker consumes the inherited pipe/PID record only as a replay/order check, then—before argument handling or candidate-root helper use—executes the verifier and mount authenticator from exact expected Git blobs, proves the source is the recorded read-only APFS image/device/mount, and checks the clean live checkout and exact upstream. Those content and system invariants, not a caller-reproducible same-user token, are the worker trust boundary and are repeated before build and publication. The supervisor waits for the worker to exit before detaching. The supervisor, filesystem helper, and mount authenticator are loaded from exact Git blobs into held, hash-verified descriptors, unlinked without a pathname reopen, and inherited as one pinned executable closure. The bootstrap synchronously checks producer status and the Git object hash before process replacement. The lock remains held by the supervisor/watchdog/worker process family, so another invocation cannot reclaim active state; if the supervisor is killed, the watchdog terminates the mounted worker before releasing ownership, and the next exclusive owner performs recovery.
3. Before any selected `xcrun`, `xcodebuild`, compiler, SDK, or developer-tool execution, the release path canonicalizes the full-Xcode path using system tools and authenticates the containing Xcode application with system `codesign`, Apple's Team Identifier/signing chain, and `spctl`; it repeats that authentication immediately before the final full toolchain assertion. `build-app.sh` then builds the read-only image as arm64 Release with Swift warnings as errors through a verified compiler wrapper. The wrapper substitutes exact Git-blob bytes for every reviewed source, denies unreviewed in-image source arguments, and emits an exact commit/tree/compiler-input manifest. Canonical `Toolchain.json` records the selected Xcode build, macOS SDK build and relative path, Swift compiler version, and relative path plus SHA-256 for the ten developer executables explicitly resolved by the release scripts. The reviewed policy, Apple application signature/system assessment, named executable hashes, and Xcode/SDK/compiler identifiers are checked before build and again before publication. This is an auditable selected-tool manifest, not an exhaustive hash of every SDK file or compiler-spawned linker input; release review must therefore approve the tracked policy for the authenticated Apple Xcode installation. The script then runs `dsymutil` while Swift object files still exist, proves the dSYM UUID set exactly matches the executable, and stages the executable, dSYM, Sparkle framework, and reviewed Sparkle release tools.
4. `archive-symbols.sh` creates a reproducible dSYM ZIP inside a unique private transaction directory. The ZIP, toolchain-bound `ReleaseManifest.json`, and exact two-entry `SHA256SUMS` are validated through held descriptors and atomically installed at `.release/private/<40-character-source-commit>/`; files are `0600`, directories are `0700`, and an existing same-commit set must be byte-identical. Symbols are never embedded in or published with the app/update.
5. `assemble-app.sh` creates the fixed bundle layout, embeds Sparkle and the canonical toolchain provenance, copies the exact reviewed licenses/notices, removes unused XPC services, routes a real icon only when supplied, and injects public signed-feed metadata and its pinned config hash only when complete.
6. `validate-app.sh --require-updater` checks plist values, permissions text, source/config/version/architecture consistency, exact licenses/notices, rpaths, Sparkle version/layout, symlink containment, entitlements, and secret/placeholders.
7. `sign-app.sh` uses Sparkle's documented inner-to-outer signing order with secure timestamps and Hardened Runtime. It never signs with `--deep` or `-`.
8. `verify-signature.sh --pre-notarization` verifies every nested component, the app, Developer ID authority, runtime flag, and signed entitlements.
9. `archive-app.sh` copies the bundle, normalizes timestamps to the pinned commit epoch, writes entries in sorted order, preserves framework symlinks, and rejects unsafe entries. The sealed, link-count-one pre-staple ZIP has a commit-qualified name under `.release/notarization/submissions/`, never `.release/artifacts/`.
10. `notarize-archive.sh` captures and rechecks the exact archive inode/length/hash before and after validation/submission, verifies that the Keychain profile works, waits for a terminal result, and atomically publishes result metadata from a private temporary file. It accepts only `Accepted`; a pre-existing result symlink is replaced as an exact anchored leaf and is never followed.
11. `staple-app.sh` staples and validates the ticket, then runs Gatekeeper and notarization verification. Post-staple structure validation permits exactly the regular, non-symlink `Contents/CodeResources` ticket that Apple adds, while pre-staple validation and all other `Contents` allowlisting stay strict.
12. A fresh final ZIP is created in a unique private publication directory and sealed read-only. `sign-update.sh` applies the shared canonical URL/key policy, looks up—but never generates—the existing Sparkle Keychain key, proves its public key matches the pinned appcast config, and binds signature/length metadata to the archive, source commit/tree, config hash, and toolchain hash. `verify-update.sh` verifies that signature against the exact staged inode; `checksums.sh` rechecks file identities around each hash.
13. The wrapper validates the live worktree/source-image/compiler-input/toolchain invariant, then atomically installs the complete private set and crash-atomically exchanges the complete public directory with `renameatx_np(RENAME_SWAP)` when a prior current set exists. Before either publication, the descriptor-anchored helper moves the caller's candidate into an unpredictable internal rollback transaction. The public predecessor therefore never lands at a caller-controlled leaf, and a failed private install returns to and is removed from the internal transaction instead of trusting a recreated source pathname. The helper keeps every exact artifact descriptor open, revalidates digest, identity, and release binding before rollback and after rename/sync, uses public `openat`/`unlinkat` operations with `O_NOFOLLOW`, rejects non-owner, special, symlink, and multi-link files, and fsyncs artifact files/directories at persistence boundaries.

After success, `.release/artifacts/` contains only the `current/` directory. That directory is the singular publication surface: exactly the final stapled `Erylo-<marketing>-<build>-arm64.zip`, its matching `.sparkle-signature.json`, and `SHA256SUMS`, all `0644` only after validation. Boundary validation requires three owner-controlled, link-count-one regular files, requires signature metadata to name the ZIP and record its exact length and release binding, and recomputes both hashes from a canonical two-line checksum manifest. Stale/old finals, orphan signatures, extra checksum lines or entries, directories, aliases, and special files fail closed.

At release start, only explicitly named legacy current-version leaves are eligible for anchored cleanup; an existing `artifacts/current` must already be a complete valid set and remains visible across every replacement crash cut. Any unrelated root entry blocks the release for operator review. Notarization material remains under `.release/notarization/`; immutable private sets remain under `.release/private/<commit>/`. A failure at bootstrap, signing, hashing, verification, final validation, source-invariant checking, or any injected exchange point leaves either the prior complete public set or no first-release `current`, never a partial/mixed set. Abandoned source images are recovered only after the old lock-holding worker/watchdog has fully settled.

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
