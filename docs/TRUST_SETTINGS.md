# Trust, settings, onboarding, and diagnostics foundation

This slice adds reusable trust-domain and SwiftUI library targets. It deliberately does not mount a settings window into `EryloApp` or change the activity panel.

## Safe defaults and persistence

`EryloSettings` is a versioned `Codable` value stored as one bounded JSON blob. `SettingsRepository` owns serialization and commits its in-memory value only after the injected `AtomicSettingsStorage` replaces the complete blob. The system adapter uses one `UserDefaults` value; tests can inject failures without touching process preferences.

The decoder rejects data above 64 KiB before JSON parsing. Enabled display IDs are deduplicated, sorted, and capped at 32 before encode and after decode. Corrupt, oversized, unreadable, and unsupported versions return safe defaults with distinct load reports. Version 1 migration is covered and is rewritten only through one whole-value replacement.

Safe defaults are:

- every activity module off;
- the display surface available on all non-mirrored displays with automatic main-display selection;
- motion following the macOS Reduce Motion setting;
- hidden-in-fullscreen preference;
- launch at login off;
- crash and diagnostic sharing consent off; and
- onboarding incomplete.

`DisplayPreferences.displayPolicy` is the integration boundary for `EryloCore.DisplayPolicy`. The stored fullscreen and motion choices are intentionally not wired into the existing panel in this branch.

## Lifecycle and permissions

`TrustSettingsCoordinator` is the serialized mutation boundary. Provider construction must be side-effect free, `start()` must not request access, and `stop()` must return only after CPU, timer, permission-dependent, and network work has ended. Enabling starts lazily; disabling awaits stop and releases the provider. Failed persistence performs a compensating rollback and records only closed diagnostic codes.

The operation queue is FIFO, capped at eight waiting operations, cancellation-aware, and coalesces a queued older change with the same setting key. Cancellation is rechecked after permission, factory, and provider-start suspension points. `stopAll()` is the explicit awaited, terminal shutdown boundary: it closes the coordinator before waiting for the active operation, rejects queued and future mutations, and completes independently of caller cancellation. An application integration must await it before releasing the coordinator or terminating.

Permission policy is closed and module-specific:

- Calendar may request Calendar access after its contextual enable action.
- Apple Music and Spotify may request Apple Events Automation control after their contextual enable actions.
- File Hold requests no permission when enabled; file access comes from a later user drop/open action.
- Local integrations request no system permission; enabling the validated local listener is the explicit action.

Opening or loading the settings view only reads settings and `SMAppService` status. It never constructs a provider, starts work, or asks permission.

## Launch at login

`SystemLaunchAtLoginController` uses public `SMAppService.mainApp` only. Its result distinguishes disabled, enabled, approval-required, and unavailable states and preserves typed registration/unregistration failure. Preference persistence is rolled back if the platform change cannot be saved. No launch agent files or shell commands are used.

## Diagnostics privacy boundary

`DiagnosticsExporter` requires an explicit file URL on every call and rejects network destinations. The SwiftUI button first asks the user for a destination. There is no uploader, analytics SDK, network client, or automatic export path.

The stable JSON schema includes only:

- app version/build tokens;
- macOS version and CPU architecture;
- non-identifying settings summaries;
- one closed health record per module; and
- recent closed-code events from the bounded in-memory ring.

The schema has no message, path, URL, file, media, meeting, attendee, payload, token, secret, or device-identifier field. Display preferences export counts and automatic/explicit modes, never `CGDirectDisplayID`. Metadata is allowlisted and re-sanitized after collection. Provider health and events are capped and deduplicated again after any injected collector returns, before JSON encoding; encoded output is capped at 64 KiB.

## Contained UI

`TrustSettingsView` and `TrustSettingsViewModel` live in `EryloSettingsUI`. They use native toggles, pickers, buttons, confirmation, and save panels with explicit accessibility labels and hints. No focus binding, application activation, custom keyboard interception, or permission work occurs during browsing. Display choices are deduplicated and bounded; names are stripped of controls and capped before `ForEach` and VoiceOver see them. Async results carry local sequence numbers so an older completion cannot overwrite newer UI intent.

The Ink, Mint, Graphite, Sky, Cloud, Mist, Amber, and Coral palette is scoped to this view. A later application branch can host it without rewriting the main panel.

## Verification boundary

`EryloTrustTests` is a deterministic standard-library harness covering migration, corrupt/oversized fallback, atomic persistence, display bounds and round trips, cancellation/coalescing/queue capacity, permission and start cancellation, lifecycle rollback, terminal/cancellation-insensitive awaited shutdown, reset, the `SMAppService` seam, diagnostics rebounding/redaction/schema/export failures, stale UI completions, and accessibility copy.

SwiftPM does not produce the signed `.app` bundle needed to manually verify Login Items approval, window-level keyboard traversal, VoiceOver announcements, the save panel, or final visual contrast. Those remain app-bundle/manual gates for the integration branch.
