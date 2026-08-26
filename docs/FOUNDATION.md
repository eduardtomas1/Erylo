# Native foundation spike

This Swift Package is the first technical feasibility slice, not an application bundle or a feature-complete product.

## Target boundaries

- `EryloCore`: display identity, notch-aware geometry, exact content hit regions, and the panel state reducer. It has no AppKit dependency.
- `EryloActivity`: validated declarative activity values and the actor-isolated priority, dedupe, expiry, cancellation, and snapshot broker. It has no UI or platform-framework dependency.
- `EryloIntegrations`: narrow display and activity-provider abstractions. The disabled provider is explicit and immediately finishes its stream.
- `EryloSurface`: one morphing SwiftUI surface hosted inside the fixed maximum frame.
- `EryloWindowing`: public-API AppKit display discovery, non-activating panels, event-driven pointer hit testing, and one controller keyed by `CGDirectDisplayID` per enabled `NSScreen`.
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

The foundation and activity harnesses intentionally use only the standard Swift toolchain. The current standalone Command Line Tools distribution does not expose `XCTest` or Swift Testing through SwiftPM, so `Scripts/ci.sh` builds every product and runs both dependency-free unit harnesses. A later Xcode project can add XCTest/XCUITest without changing the pure test seams.

Local verification uses the installed Swift 6 Command Line Tools. GitHub build/test verification uses the public `macos-15` runner because the `macos-14` runner defaults to Swift 5.10; `Scripts/ci.sh` retains a hard Swift 6 gate, while `Package.swift` keeps the deployment target at macOS 14.

## Deliberate limitations

- File drops expose and test the drop-target state, but intentionally reject transport. File ownership, copy/reference semantics, expiry, cleanup, and cross-Space round trips belong to a later feature branch.
- No activity providers are enabled, and no permission flow, persistence, updater, signing, or diagnostics pipeline is claimed here. The activity broker is a domain seam only and is not connected to the feasibility UI yet.
- Screen-parameter notifications and mouse events drive reconciliation and hit testing; there are no repeating timers or display links in this slice.
- The fixed-frame and exact-region behavior has unit coverage at the pure geometry boundary. Fullscreen, Spaces, Stage Manager, hot-plug, clamshell, sleep/wake, 120 Hz motion, CPU usage, signing, and energy targets still require hardware and Instruments validation.
