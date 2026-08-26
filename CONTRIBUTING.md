# Contributing to Erylo

Erylo is a native macOS 14+ utility whose quality bar is defined by reliability at the display edge, negligible idle work, and narrow permissions. Keep changes small enough to review and test across their full lifecycle.

## Before opening a pull request

1. Work on a focused branch and do not mix generated artifacts or local diagnostics with source changes.
2. Run `.github/scripts/check-repository.sh`.
3. Run the repository build/test entry point when present:
   - `Scripts/ci.sh` is canonical when it exists and is executable.
   - Until then, a root `Package.swift` is verified with `swift test --parallel`.
   - An Xcode project must provide `Scripts/ci.sh`; CI deliberately will not guess a shared scheme or destination.
4. Describe exact verification, untested hardware/lifecycle cases, permissions, background work, and rollback impact in the pull request.

The repository is currently pre-foundation. On revisions without a package, project, or CI script, the workflow reports that build/tests were not run; only repository controls are verified.

## Engineering expectations

- Use Swift 6 strict concurrency and the macOS 14 deployment target once source is present.
- Prefer event-driven providers. Collapsed or disabled features must not leave polling, display links, network requests, or permission-dependent work active.
- Do not steal focus. Test window, hit-testing, fullscreen, Spaces, display hot-plug, clamshell, and sleep/wake behavior affected by the change.
- Treat file references, security-scoped bookmarks, diagnostics, calendar data, media state, and local IPC payloads as sensitive.
- Validate every URL-scheme, App Intent, CLI, and per-user Unix-socket input. Never turn external input into arbitrary command execution.
- Keep private API out of core functionality. Optional fragile helpers must remain isolated, health-checked, and killable.
- Include Reduce Motion, accessibility, localization, cancellation, failure, and cleanup paths in relevant tests.

Do not copy code from reference projects without confirming license compatibility and recording required attribution. GPL-licensed implementations may inform issue research but must not be copied into a proprietary build.

Report vulnerabilities using [SECURITY.md](SECURITY.md), not a public issue or pull request.
