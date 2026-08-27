# Development and continuous verification

## Current state

This repository contains a Swift 6, macOS 14+ SwiftPM foundation. `Scripts/ci.sh` is the canonical entry point: it builds with warnings as errors, runs the activity, foundation, File Hold, Glance, Media, Trust, Local Integrations, surface, updater, application-runtime, and release harnesses, and uses `shellcheck` when that optional local tool is installed.

Continuous verification uses the following discovery order:

1. Add an executable `Scripts/ci.sh` for an Xcode workspace/project. It must select a shared scheme and an explicit macOS destination and must run the project's real build and test commands.
2. If `Scripts/ci.sh` is absent and the repository remains SwiftPM-only, the workflow falls back to `swift test --parallel` and requires Swift 6 or newer.
3. Record the chosen Xcode/toolchain version in a tracked project file and update the runner only when that requirement differs from the public `macos-14` runner image.

An Xcode project without `Scripts/ci.sh` fails CI deliberately. This avoids a green check based on a guessed scheme, destination, or incomplete test set.

## Local checks

Run:

```sh
.github/scripts/check-repository.sh
Scripts/ci.sh
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
