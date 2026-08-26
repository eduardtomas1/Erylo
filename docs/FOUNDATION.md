# Native foundation spike

This Swift Package is the first technical feasibility slice, not an application bundle or a feature-complete product.

## Target boundaries

- `EryloCore`: display identity and selection policy, notch-aware geometry, conservative morph hit regions, cancellable one-shot scheduling, and the panel state reducer. It has no AppKit dependency.
- `EryloActivity`: validated declarative activity values and the actor-isolated priority, dedupe, expiry, cancellation, and snapshot broker. It has no UI or platform-framework dependency.
- `EryloFileHold`: bounded copy/reference ownership, app-owned storage, expiry, cleanup/recovery, coordinated public drag decoding, and narrow presentation-resource seams. It owns no application UI or panel lifecycle.
- `EryloGlance`: opt-in, event-driven battery, countdown, calendar, and volume providers. Public macOS adapters sit behind injectable `Sendable` seams; construction is inert and `disableAll()` awaits complete observer/task cleanup.
- `EryloIntegrations`: narrow display, activity-provider, and public desktop-media abstractions. Apple Music and Spotify use fixed, validated `osascript` routes on explicit refresh or command only; disabled adapters finish their streams and perform no work.
- `EryloLocalIntegrations`: the versioned strict schema, URL and command-line parsers, broker controller, and opt-in per-user Unix-domain-socket service for declarative submit/cancel/status requests.
- `EryloAppIntents`: public-SDK App Intent adapters for the same operations. It is an app-bundle wiring seam and is not linked into the current SwiftPM executable.
- `EryloSurface`: one morphing SwiftUI surface hosted inside the fixed maximum frame, with cancellable hover hysteresis and Reduce Motion crossfade/scale behavior.
- `EryloTrust`: bounded versioned preferences, serialized provider lifecycle, public launch-at-login capability state, and privacy-preserving diagnostics export.
- `EryloSettingsUI`: a contained native SwiftUI onboarding/settings surface that performs no provider or permission work while browsing.
- `EryloWindowing`: public-API AppKit display discovery, non-activating panels, event-driven pointer hit testing, removable workspace/display observers, and one controller keyed by `CGDirectDisplayID` per enabled non-mirrored display.
- `EryloApp`: the minimal accessory-process entry point.

The dependency direction remains one-way: app -> windowing -> surface/integrations -> core/activity; File Hold is an independent native boundary, Glance depends only on Activity, Trust only on Core, SettingsUI on Core/Trust, and AppIntents on LocalIntegrations on Activity. Platform types stay behind injectable seams, routes see only the narrow handling protocol, and no transport exposes the broker actor directly.

## Command Line Tools workflow

```sh
swift build
swift run EryloActivityTests
swift run EryloFileHoldTests
swift run EryloFoundationTests
swift run EryloGlanceTests
swift run EryloMediaTests
swift run EryloTrustTests
swift run EryloIntegrationTests
Scripts/ci.sh
swift run Erylo
```

`swift run Erylo` launches one feasibility panel for each display reported by AppKit. Quit the process from the invoking terminal.

The safe default enables every available non-mirrored display and selects the main display for one-at-a-time interactions. The policy also supports an in-memory enabled-display allowlist and selected display; persistence and its UI remain later work. Displays without a top-edge occlusion use a compact pill inset from the screen edge. `Control-Option-Command-E` toggles the selected panel through public hot-key registration, without a global key-event monitor or Accessibility permission.

The foundation, activity, File Hold, glance, media, trust, and integration harnesses intentionally use only the standard Swift toolchain. The current standalone Command Line Tools distribution does not expose `XCTest` or Swift Testing through SwiftPM, so `Scripts/ci.sh` builds every product and runs all dependency-free harnesses. A later Xcode project can add XCTest/XCUITest without changing the pure test seams.

Local verification uses the installed Swift 6 Command Line Tools. GitHub build/test verification uses the public `macos-15` runner because the `macos-14` runner defaults to Swift 5.10; `Scripts/ci.sh` retains a hard Swift 6 gate, while `Package.swift` keeps the deployment target at macOS 14.

## Secure local integration layer

`EryloLocalIntegrations` exposes API version 1 with a closed operation set. `submit` requires an activity and forbids an identity, `cancel` requires `{source, identifier}` and forbids an activity, and `status` forbids both. Payloads contain only bounded declarative activity fields and allowlisted action intents—never arbitrary URLs or paths, shell or AppleScript text, selectors, closures, plugins, or executable commands. `ActivityIntegrationController(broker:)` injects the one process-wide `ActivityBroker`, while all routes retain only `ActivityIntegrationHandling`.

The bounded entry forms are:

- URL: exactly `erylo://v1/{submit|cancel|status}` with an operation-specific query allowlist. Raw structure is checked before `URLComponents`, including encoded host, path, name, percent, and delimiter ambiguity rejection.
- Command-line library: arguments after a future executable name begin `v1 {submit|cancel|status}` and use closed `--name value` pairs. Count and aggregate UTF-8 size accounting are overflow-safe.
- Unix socket: a four-byte network-order length followed by strict JSON. Bodies, responses, buffered chunks, nesting, requests per client, and concurrent clients are bounded. A raw grammar pass rejects malformed JSON and duplicate decoded object keys before allowlisted `Codable` decoding.

The Unix socket service is opt-in and performs zero task or filesystem work while disabled. Its default endpoint is the current user's `~/Library/Application Support/Erylo-Integration/activity-v1.sock`. Startup opens and revalidates every directory component without following symlinks, requires safe ownership and POSIX modes, and rejects every nonempty extended allow ACL on ancestors, the final directory, lock, staged/published socket, or owned stale socket, including attribute, security, ownership, and future permission bits; deny-only ACL entries may remain when they do not prevent the required filesystem operation. It holds a 0600 lock in the 0700 final directory. The listener first binds under an unpredictable staging name and records that vnode's held-directory and absolute-path identity before ACL policy validation, so even an unsafe staged socket has identity authority for quarantine cleanup. It then permissions and revalidates that exact entry through the held directory descriptor without following symlinks and publishes it to the fixed public name with an exclusive atomic rename. Embedded NULs and unsafe, swapped, colliding, or replaced paths fail closed. Every accepted peer must match the current effective UID through public macOS `getpeereid`.

The listener and clients are nonblocking. One I/O owner performs each final descriptor close; stop uses lock-serialized shutdown only to wake client I/O. The accept owner waits indefinitely in `poll` over the listener and a nonblocking close-on-exec wake pipe, so stop writes one byte without idle timeout polling. Interrupted or zero-byte wake writes retry, a full pipe proves it is already readable, and a fatal write closes the owned pipe end so `poll` observes hangup. Per-frame receives and response sends use absolute monotonic deadlines. Admission and request counts are capped, rejected/busy peers use at most one immediate nonblocking write, and unexpected non-transient accept failures become an observable stopped health transition. Unique connection tokens prevent reused descriptor integers from aliasing lifecycle state. Stop cancels and drains connection tasks, invalidates broker-mutation leases, and generation-gates stale results. A dispatch is registered synchronously and its connection waits on an independently owned response awaitable, so a suspended handler does not retain the service actor through an instance-method continuation. Stale and teardown cleanup atomically move the public entry to an unpredictable quarantine name, verify the expected socket identity there, remove only a verified match, and restore or retain mismatches rather than deleting them. Darwin has no inode-conditional unlink, so this design deliberately makes no stronger claim across an adversarial pathname race. Deinitialization synchronously cancels work, invalidates leases, wakes I/O, and releases owned filesystem resources as a fail-safe; only explicit `stop()` provides a fully awaited drain contract and remains preferred.

`EryloAppIntents` compiles against the current public macOS SDK and supplies submit, cancel, and status intents plus an explicit dependency gateway. This repository is still a SwiftPM executable, not a final signed app bundle. It therefore does not yet claim App Intent discovery metadata, app-lifecycle gateway registration, URL-scheme registration, or launch/activation behavior. A future bundle owner must wire all adapters to the same shared broker. A future `eryloctl` can reuse the command-line parser and socket protocol; no CLI executable is included here.

The Integration harness deterministically covers strict schema and duplicate-key validation, malformed/oversized/unknown input, safe bounded diagnostics, URL percent-encoding ambiguities, overflow-safe CLI limits, partial/multiple/truncated frames, peer rejection, table-driven real-filesystem directory/ancestor, lock, stale-socket, staged-socket, and published-socket ACL permissions (including inherited metadata/bootstrap rights and deny-only acceptance), parent and bind/identity/permission/publication race seams, ACL-bearing published replacement preservation, stale and teardown replacement preservation, rejected-start descriptor stability, wake-write retries/fallback, capacity, descriptor reuse, absolute receive/send deadlines, idle and connect-flood stop/deinit hard deadlines, cancellation, fresh-task stale-lease denial after restart, suspended-dispatch deinit retention ordering, and shared-broker visibility.

## Deliberate limitations

- The foundation drop target still rejects transport until File Hold is mounted into the application. The File Hold library now owns and tests copy/reference semantics, expiry, cleanup/recovery, and coordinated public drag decoding; app wiring and cross-Space round trips remain later integration work.
- Glance providers are not connected to the feasibility UI or settings yet. They remain disabled until explicitly enabled; calendar permission is requested only from that explicit enable path. Persistence, updater, signing, and diagnostics pipelines are not claimed here.
- Battery, default-output volume/mute, and EventKit permission behavior compile against public macOS APIs but still require real-hardware, real-calendar-account, sleep/wake, device-switch, and Instruments energy validation.
- Apple Music and Spotify expose no reliable documented desktop change-notification surface to this package, so media refresh is on demand and adapter streams finish immediately rather than polling. Automation permission is requested only when the user first invokes a refresh or command. Artwork caching is opt-in, memory-bounded, purgeable, and retains no durable playback history.
- Trust persistence, contextual permission/lifecycle seams, and local diagnostics export now exist as unmounted library foundations. A settings-window host, updater, signing, and panel preference integration remain later work.
- Local integration routes are not enabled in the executable, and no integration permission flow is claimed here. The app still needs one process-wide broker wired to providers, UI, and these adapters.
- The socket has no settings/UI activation path and remains disabled. URL/App Intent bundle registration and a bundled `eryloctl` remain explicit wiring gaps rather than claimed working product features.
- Screen-parameter, active-Space, sleep/wake, pointer, and hot-key events drive reconciliation and interaction. Hover and motion completion use cancellable one-shot tasks; there are no repeating timers or display links at idle. Public APIs do not expose every phase of another application's fullscreen transition, so active-Space and screen-parameter notifications are the observable reconciliation boundaries.
- AppKit hit testing uses the intersection of source and destination regions while a morph is in flight, then installs the exact destination region at the scheduled animation completion. This is intentionally conservative: destination-only pixels cannot steal clicks before they are visible. SwiftUI does not expose the spring's presentation geometry to the hosting `NSPanel`, so the region is not a frame-by-frame mathematical match during the animation and spring settling may outlast the nominal completion by a small amount.
- The fixed-frame, policy, lifecycle ownership, hover cancellation, reducer interruption, and hit-region behavior have deterministic harness coverage. Fullscreen, Spaces, Stage Manager, hot-plug, mirroring, clamshell, sleep/wake, shortcut conflicts, 120 Hz motion, CPU usage, signing, and energy targets still require hardware, multi-display, and Instruments validation.
