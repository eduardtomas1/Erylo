# Native foundation spike

This Swift Package is the first technical feasibility slice, not an application bundle or a feature-complete product.

## Target boundaries

- `EryloCore`: display identity and selection policy, notch-aware geometry, conservative morph hit regions, cancellable one-shot scheduling, and the panel state reducer. It has no AppKit dependency.
- `EryloActivity`: validated declarative activity values and the actor-isolated priority, dedupe, expiry, cancellation, and snapshot broker. It has no UI or platform-framework dependency.
- `EryloIntegrations`: narrow display and activity-provider abstractions. The disabled provider is explicit and immediately finishes its stream.
- `EryloSurface`: one morphing SwiftUI surface hosted inside the fixed maximum frame, with cancellable hover hysteresis and Reduce Motion crossfade/scale behavior.
- `EryloWindowing`: public-API AppKit display discovery, non-activating panels, event-driven pointer hit testing, removable workspace/display observers, and one controller keyed by `CGDirectDisplayID` per enabled non-mirrored display.
- `EryloApp`: the minimal accessory-process entry point.

The dependency direction is app -> windowing -> surface/integrations -> core/activity. The two domain targets are leaves; platform types do not leak into either model.

## Command Line Tools workflow

```sh
swift build
swift run EryloActivityTests
swift run EryloFoundationTests
Scripts/ci.sh
swift run Erylo
```

`swift run Erylo` launches one feasibility panel for each display reported by AppKit. Quit the process from the invoking terminal.

The safe default enables every available non-mirrored display and selects the main display for one-at-a-time interactions. The policy also supports an in-memory enabled-display allowlist and selected display; persistence and its UI remain later work. Displays without a top-edge occlusion use a compact pill inset from the screen edge. `Control-Option-Command-E` toggles the selected panel through public hot-key registration, without a global key-event monitor or Accessibility permission.

The foundation and activity harnesses intentionally use only the standard Swift toolchain. The current standalone Command Line Tools distribution does not expose `XCTest` or Swift Testing through SwiftPM, so `Scripts/ci.sh` builds every product and runs both dependency-free unit harnesses. A later Xcode project can add XCTest/XCUITest without changing the pure test seams.

Local verification uses the installed Swift 6 Command Line Tools. GitHub build/test verification uses the public `macos-15` runner because the `macos-14` runner defaults to Swift 5.10; `Scripts/ci.sh` retains a hard Swift 6 gate, while `Package.swift` keeps the deployment target at macOS 14.

## Deliberate limitations

- File drops expose and test the drop-target state, but intentionally reject transport. File ownership, copy/reference semantics, expiry, cleanup, and cross-Space round trips belong to a later feature branch.
- No activity providers are enabled, and no permission flow, persistence, updater, signing, or diagnostics pipeline is claimed here. The activity broker is a domain seam only and is not connected to the feasibility UI yet.
- Screen-parameter, active-Space, sleep/wake, pointer, and hot-key events drive reconciliation and interaction. Hover and motion completion use cancellable one-shot tasks; there are no repeating timers or display links at idle. Public APIs do not expose every phase of another application's fullscreen transition, so active-Space and screen-parameter notifications are the observable reconciliation boundaries.
- AppKit hit testing uses the intersection of source and destination regions while a morph is in flight, then installs the exact destination region at the scheduled animation completion. This is intentionally conservative: destination-only pixels cannot steal clicks before they are visible. SwiftUI does not expose the spring's presentation geometry to the hosting `NSPanel`, so the region is not a frame-by-frame mathematical match during the animation and spring settling may outlast the nominal completion by a small amount.
- The fixed-frame, policy, lifecycle ownership, hover cancellation, reducer interruption, and hit-region behavior have deterministic harness coverage. Fullscreen, Spaces, Stage Manager, hot-plug, mirroring, clamshell, sleep/wake, shortcut conflicts, 120 Hz motion, CPU usage, signing, and energy targets still require hardware, multi-display, and Instruments validation.
