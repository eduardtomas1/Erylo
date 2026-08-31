# Development and continuous verification

## Current state

This repository contains a Swift 6, macOS 14+ SwiftPM foundation. `Scripts/ci.sh` is the complete canonical local entry point: it builds with warnings as errors, checks the activity, media, and system-Glance API surfaces, runs the activity, foundation, File Hold, Glance, Media, Trust, Local Integrations, surface, updater, application-runtime, and release harnesses, and uses `shellcheck` when that optional local tool is installed.

Pull-request CI runs the build, API-surface controls, and each Swift executable
test target as independent fast jobs. The exhaustive deterministic release
harness and AddressSanitizer/ThreadSanitizer coverage run nightly, separately
from signing and notarization. See [Continuous verification](CONTINUOUS_VERIFICATION.md)
for the exact check contract, protected-main ruleset, and measured budgets.

The historical generic workflow used the following discovery order:

1. Add an executable `Scripts/ci.sh` for an Xcode workspace/project. It must select a shared scheme and an explicit macOS destination and must run the project's real build and test commands.
2. If `Scripts/ci.sh` is absent and the repository remains SwiftPM-only, the workflow falls back to `swift test --parallel` and requires Swift 6 or newer.
3. Record the chosen Xcode/toolchain version in a tracked project file and update the runner only when that requirement differs from the public `macos-14` runner image.

The current SwiftPM workflow no longer performs runtime discovery: its explicit
build, API, and target matrix is the reviewed contract. A future migration to an
Xcode project must update both `Scripts/ci.sh` and the workflow with a shared
scheme and explicit macOS destination; CI must not guess either value.

## Local checks

Run:

```sh
.github/scripts/check-repository.sh
Scripts/ci.sh
```

To regenerate the native Focus Timer and Volume visual-QA set on representative
notched and notchless geometry while running the deterministic surface harness. The renderer hosts
the production SwiftUI view on a fixed dark desktop backdrop so the notch's
transparent outer curls are composited as product geometry, not an alpha matte:

```sh
ERYLO_VISUAL_QA_DIRECTORY="$PWD/docs/images" swift run EryloSurfaceTests
```

The script fails for tracked files hidden by `.gitignore`, common private signing/credential filenames, private-key markers, high-confidence GitHub/AWS token patterns, invalid tracked shell syntax, or invalid GitHub YAML syntax. A false positive should receive a narrow reviewed exception; do not weaken the repository-wide rule or add a broad ignore pattern.

Use `git check-ignore -v <path>` when changing `.gitignore`, and confirm that collaboration inputs such as `Package.resolved`, project/workspace metadata, entitlements, documentation assets, and sanitized test fixtures remain visible to Git.

The unsigned development bundle path is:

```sh
Scripts/release/build-app.sh
Scripts/release/assemble-app.sh
Scripts/release/validate-app.sh .release/stage/Erylo.app
```

It works with Command Line Tools and never claims distribution readiness. Developer ID signing and notarization deliberately require full Xcode and external Keychain state; see `docs/RELEASE_RUNBOOK.md`.

## Verification expectations

Code changes should add proportionate XCTest/XCUITest coverage and manual lifecycle evidence. Relevant changes must exercise display changes, Spaces/fullscreen, sleep/wake, cancellation, failures, cleanup, permissions, disabled-state behavior, Reduce Motion, and main-thread work.

Energy claims require an Instruments Energy Log or equivalent measurement after settling on a named reference Mac. The internal collapsed-idle target is below 0.3% CPU with zero repeating work; it is an engineering gate, not a public performance claim.

Local Unix-socket and CLI integrations are later work. Their eventual tests must cover per-user ownership/permissions, schema validation, size/rate bounds, malformed and unknown events, cancellation/expiry, cross-user denial, and confirmation that no payload can invoke an arbitrary command.
