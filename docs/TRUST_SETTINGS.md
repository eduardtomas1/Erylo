# Trust, settings, onboarding, and diagnostics foundation

The trust-domain and SwiftUI settings targets are mounted by `EryloAppRuntime` in one contained native settings window. First launch explains the passive top-edge/notch surface, deliberate click and `Control-Option-Command-E` interaction, safe defaults, and how to reopen Settings, quit, and relaunch. The window activates the accessory app only when it is intentionally presented; the passive panel remains nonactivating.

## Safe defaults and persistence

`EryloSettings` is a versioned `Codable` value stored as one bounded JSON blob. `SettingsRepository` owns serialization and commits its in-memory value only after the injected `AtomicSettingsStorage` replaces the complete blob. The system adapter uses one `UserDefaults` value; tests can inject failures without touching process preferences. The mounted application host disables automatic migration persistence while loading/browsing, so a legacy value is migrated in memory and is written only after an explicit settings action.

The decoder rejects data above 64 KiB before JSON parsing. Enabled display IDs are deduplicated, sorted, and capped at 32 before encode and after decode. Corrupt, oversized, unreadable, and unsupported versions return safe defaults with distinct load reports. Version 1 migration is covered and is rewritten only through one whole-value replacement.

Safe defaults are:

- every activity module off;
- the display surface available on all non-mirrored displays with automatic main-display selection;
- motion following the macOS Reduce Motion setting;
- hidden-in-fullscreen preference;
- launch at login off;
- crash and diagnostic sharing consent off; and
- onboarding incomplete.

`DisplayPreferences.displayPolicy` is the integration boundary for `EryloCore.DisplayPolicy`, and the runtime applies that proven preference at startup and after a successful settings change. Stored fullscreen and explicit motion choices remain intentionally unwired; their controls are disabled and described as unavailable rather than claiming an effect the current surface does not implement.

## Lifecycle and permissions

`TrustSettingsCoordinator` is the serialized mutation boundary. Provider construction must be side-effect free, `start()` must not request access, and `stop()` must return only after CPU, timer, permission-dependent, and network work has ended. Enabling starts lazily; disabling awaits stop and releases the provider. Failed persistence performs a compensating rollback and records only closed diagnostic codes.

The operation queue is FIFO, capped at eight waiting operations, cancellation-aware, and coalesces a queued older change with the same setting key. Cancellation is rechecked after permission, factory, and provider-start suspension points. `stopAll()` is the explicit awaited, terminal shutdown boundary: it closes the coordinator before waiting for the active operation, rejects queued and future mutations, and completes independently of caller cancellation. An application integration must await it before releasing the coordinator or terminating.

Permission policy is closed and module-specific:

- Mounted Battery and Volume request no permission.
- The unmounted Calendar foundation defines a contextual Calendar-access policy.
- The unmounted Apple Music and Spotify foundations define contextual Apple Events policies.
- File Hold and local integrations remain unmounted; their library-level policies do not make them product features.

Opening or loading the settings view only reads settings and `SMAppService` status. It never constructs a provider, starts work, or asks permission.

The application control plane mounts only Battery and Volume through package-only
lifecycle adapters backed by the one application `ActivityBroker`. Factory and
source construction are inert. `startEnabledModules()` runs once at application
startup with `.doNotRequest`, while opening/loading Settings remains read-only.
Battery and Volume toggles are live; synchronous initial unavailability retains
enabled intent with honest unavailable health, while disable and reset await full
provider and retired-expiry cleanup. An explicit successful Volume enable reports
**Volume is on — adjust it to see Erylo** beside that row; provider/start failures
also stay row-local, while persisted startup restore produces no feedback banner.
Focus Timer is owned separately by `ApplicationRuntime` and starts only from a
deliberate menu command. Calendar, media, File Hold, and local-integration rows
remain visibly unavailable and defensively rejected, so they cannot request
permission, open a socket or file, invoke media automation, or perform network work.

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

`TrustSettingsView` and `TrustSettingsViewModel` live in `EryloSettingsUI`. They use native toggles, pickers, buttons, confirmation, and save panels with explicit accessibility labels and hints. Module enable guidance and failures render beside the row that caused them. No focus binding, application activation, custom keyboard interception, or permission work occurs during browsing. Display choices are deduplicated and bounded; names are stripped of controls and capped before `ForEach` and VoiceOver see them. Async results carry local sequence numbers so an older completion cannot overwrite newer UI intent.

`EryloAppRuntime` owns a native status item and exactly one reusable settings window. The menu exposes Show/Hide Erylo, Settings, a shortcut reminder, Quit, and Check for Updates only when the signed-feed updater has safely started. Menu actions route back through the runtime, repeated Quit requests collapse to one termination request, and shutdown removes the status item/window and terminally drains trust settings before the panel, broker, and updater are released. The Ink, Mint, Graphite, Sky, Cloud, Mist, Amber, and Coral palette remains scoped to the contained view.

## Verification boundary

`EryloTrustTests` is a deterministic standard-library harness covering migration, corrupt/oversized fallback, atomic persistence, prompt-free persisted restore, display bounds and round trips, cancellation/coalescing/queue capacity, permission and start cancellation, lifecycle rollback, terminal/cancellation-insensitive awaited shutdown, reset, the `SMAppService` seam, diagnostics rebounding/redaction/schema/export failures, stale UI completions, and accessibility copy. `EryloAppRuntimeTests` adds the injected Battery/Volume factory and source slice, quiet synchronous Volume activation, gated initial-unavailable settlement for both providers, and cancellation-ignoring retired-expiry drain across reset, provider disable, and terminal shutdown in both entry orderings, plus shared-broker publication, exact available controls, menu routing, first-launch presentation, unavailable controls, repeated control requests, update availability, display-policy application, lifecycle overlap, and resource release without launching a real user session.

SwiftPM does not produce the signed `.app` bundle needed to manually verify Battery and Volume on real hardware, sleep/wake and audio-device switching, Instruments energy, Login Items approval, window-level keyboard traversal, VoiceOver announcements, the save panel, or final visual contrast. Those remain app-bundle/manual gates; none is claimed by the deterministic harnesses.
