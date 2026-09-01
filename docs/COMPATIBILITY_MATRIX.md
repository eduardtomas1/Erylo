# Compatibility matrix and manual evidence

Support policy is macOS 14 or newer on Apple Silicon. The generated executable is intentionally arm64-only; Intel and Rosetta are not supported by this release shape. Apple currently lists macOS Sonoma 14, Sequoia 15, and Tahoe 26 as maintained installable generations; re-check Apple's [current macOS versions](https://support.apple.com/en-gb/109033) before each release.

Automated checks prove deployment metadata and bundle structure, not real hardware behavior. As of 2026-08-26, this branch built and passed the release harness on an arm64 Mac17,9 running macOS 26.6.2 with Swift 6.3.3 Command Line Tools. No Developer ID signing, notarization, clean-install, updater, display, motion, permission, or energy hardware gate was executed by that automated run.

## OS and architecture

| Target | Build/metadata status | Required manual status |
|---|---|---|
| macOS 14 Sonoma, arm64 | `LSMinimumSystemVersion=14.0`; Mach-O minimum 14.0; automated validation passes | Not run; launch, permissions, displays, update, and clean install block release |
| macOS 15 Sequoia, arm64 | Compatible by deployment target; no local runtime evidence | Not run; full matrix blocks release |
| macOS 26 Tahoe, arm64 | Automated build/harness ran on 26.6.2; app UI was not launched as release evidence | Not run as a signed/notarized clean install; full matrix blocks release |
| Future macOS beta, arm64 | No claim | Required before declaring support |
| Intel / Rosetta | Deliberately absent from the artifact | Out of scope unless product policy and QA capacity change |

## Apple Silicon hardware checklist

Record at least one result for every row; “not available” needs a named owner and release-risk decision.

| Hardware/display scenario | Sonoma 14 | Sequoia 15 | Tahoe 26 | Evidence to capture |
|---|---:|---:|---:|---|
| M1 MacBook Air or 13-inch M1/M2 MacBook Pro, notchless internal display | Not run | Not run | Not run | Model, OS build, scaling, launch and morph video |
| M2/M3/M4/M5 MacBook Air with notch | Not run | Not run | Not run | Notch geometry, menu bar, fullscreen, 60 Hz motion |
| 14/16-inch MacBook Pro (2021 or newer) with notch | Not run | Not run | Not run | 120 Hz open/close, hit regions, fullscreen/Spaces |
| Apple Silicon Mac mini/Studio with one external display | Not run | Not run | Not run | Notchless pill, selected display, sleep/wake |
| Two external displays with mixed scale/refresh | Not run | Not run | Not run | Hot-plug, reorder, mirror/unmirror, selected display |
| Clamshell MacBook plus external display | Not run | Not run | Not run | Lid transitions, panel ownership, wake |
| Stage Manager and multiple Spaces | Not run | Not run | Not run | No focus theft, correct Space/fullscreen behavior |
| Menu-bar manager present | Not run | Not run | Not run | Geometry, clicks, no shortcut conflict |

## Manual release checklist

- Clean standard-user install from the real quarantined public download; validate hash, Developer ID, Hardened Runtime, Gatekeeper, notarization ticket, first offline launch, uninstall, and reinstall.
- Battery enable/disable/relaunch/reset at ordinary, charging, unplugged-low, and unavailable states; confirm the first ordinary snapshot stays quiet and no permission appears.
- Volume enable/disable/relaunch/reset across built-in, USB, HDMI, Bluetooth, AirPlay, muted, unsupported-volume, disconnect, and default-output switches; confirm the initial current-output snapshot stays quiet and every later acknowledgement is bounded.
- Focus Timer quit/relaunch before, at, and after its deadline; confirm the same absolute session restores, explicit cancel stays cancelled, offline expiry emits no late sound, and no tick polling appears.
- Sleep/wake and rapid audio-device-switch convergence with zero duplicate observers, stale HUD state, expiry tasks, or broker ownership after disable and quit.
- Confirm Calendar, Apple Music, Spotify, File Hold, and local-integration controls remain unavailable and initiate no permission or integration work; inspect the signed app to confirm it carries no privacy usage descriptions or capability entitlement for those dormant utilities.
- Disabled-provider zero-work check and collapsed idle Instruments Energy Log on a named reference Mac; record the internal CPU result without turning it into a public claim.
- 60 Hz and 120 Hz motion with Reduce Motion both off and on; capture dropped frames and main-thread thumbnail/artwork work.
- Fullscreen, Spaces, Stage Manager, scaling, mirroring, hot-plug, clamshell, screen lock, user switch, sleep/wake, and reboot.
- Stable display preference restoration across reboot, dock/undock, identical display models, Core Graphics ID reuse, and reconnect while Settings is open.
- Genuine old-to-new Sparkle update from every supported prior release, manual check, bad EdDSA archive rejection, bad signed-feed rejection, minimum-OS rejection, interrupted download/install, relaunch, and higher-version forward-fix rollback.
- Verify the downloaded archive, published appcast, release notes, EdDSA metadata, and retained SHA-256 evidence all describe the same version/build and bytes.

Unchecked rows are release blockers, not implied passes.

No Battery or Volume hardware row has been executed for this change. Deterministic
injected-source tests are evidence for lifecycle logic only, not a substitute for
the manual checks above.
