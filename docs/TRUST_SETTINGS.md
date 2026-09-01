# Trust, settings, onboarding, and diagnostics foundation

The trust-domain and SwiftUI settings targets are mounted by `EryloAppRuntime` in one contained native settings window. First launch presents a focused welcome surface with a truthful compact-signal preview, explains the three shipping utility categories, makes no permission request, and performs no utility work. Its single Get Started action completes setup and reveals the grouped Settings form only after persistence succeeds. The window activates the accessory app only when it is intentionally presented; the passive panel remains nonactivating.

## Safe defaults and persistence

`EryloSettings` is a versioned `Codable` value stored as one bounded JSON blob. `SettingsRepository` owns serialization and commits its in-memory value only after the injected `AtomicSettingsStorage` replaces the complete blob. The system adapter uses one `UserDefaults` value; tests can inject failures without touching process preferences. The mounted application host disables automatic migration persistence while loading/browsing, so a legacy value is migrated in memory and is written only after an explicit settings action.

The decoder rejects data above 64 KiB before JSON parsing. Stable display UUIDs are deduplicated, sorted, and capped at 32 before encode and after decode. Corrupt, oversized, unreadable, and unsupported versions return temporary safe defaults with distinct load reports. Those recovery states are write-protected: ordinary edits, provider toggles, onboarding, and Login Item changes perform no side effect and cannot replace the opaque saved value. Settings presents a dedicated recovery screen, where Reset remains a non-default destructive action behind explicit confirmation; only that confirmed action may cross the recovery boundary. A failed Reset preserves both the original bytes and recovery report. Version 1 and 2 migrations discard unsafe session-scoped display IDs, preserve an intentional empty scope, and are rewritten only through one whole-value replacement.

Safe defaults are:

- every activity module off;
- the display surface available on one automatic display, preferring the current main display;
- motion following the macOS Reduce Motion setting;
- hidden-in-fullscreen preference;
- launch at login off;
- crash and diagnostic sharing consent off; and
- onboarding incomplete.

`EryloSettings.displayPolicy` is the integration boundary for `EryloCore.DisplayPolicy`, and the runtime applies that complete preference at startup and after a successful settings change. Automatic scope enables one deterministic display, All Displays is an explicit opt-in, and Custom enables only its stable Core Graphics display UUIDs. `CGDirectDisplayID` remains a live panel key and is never persisted. The public `CGDisplayCreateUUIDFromDisplayID` mapping reconnects a saved UUID to the current session ID. A disconnected custom display remains unavailable instead of silently targeting different hardware. The separate preferred UUID targets only menu and keyboard-shortcut actions; if it is disconnected or disabled, those actions fail closed until it returns or the user chooses an enabled, connected display. Fullscreen defaults to excluded: only the explicit Remain Available preference adds public AppKit `.fullScreenAuxiliary` participation. Opting back out contracts Peek/Expanded before every existing panel drops that collection behavior. Erylo does not use Accessibility or private APIs to infer another application's fullscreen phase. The stored explicit-motion choice remains intentionally unwired, so Settings omits it rather than presenting a control that cannot work.

## Lifecycle and permissions

`TrustSettingsCoordinator` is the serialized mutation boundary. Provider construction must be side-effect free, `start()` must not request access, and `stop()` must return only after CPU, timer, permission-dependent, and network work has ended. Enabling starts lazily; disabling awaits stop and releases the provider. Failed persistence performs a compensating rollback and records only closed diagnostic codes.

The operation queue is FIFO, capped at eight waiting operations, cancellation-aware, and coalesces a queued older change with the same setting key. Cancellation is rechecked after permission, factory, and provider-start suspension points. `stopAll()` is the explicit awaited, terminal shutdown boundary: it closes the coordinator before waiting for the active operation, rejects queued and future mutations, and completes independently of caller cancellation. An application integration must await it before releasing the coordinator or terminating.

Permission policy is closed and module-specific:

- Mounted Battery and Volume request no permission.
- The unmounted Calendar foundation defines a contextual Calendar-access policy.
- The unmounted Apple Music and Spotify foundations define contextual Apple Events policies.
- File Hold and local integrations remain unmounted; their library-level policies do not make them product features.

`Config/ProductionCapabilities.json` closes the shipping permission surface over
the actual Focus Timer, Battery, and Volume composition. The production
`Info.plist` has no privacy usage-description key and the reviewed entitlement
file is empty. Repository, assembly, bundle, and signed-entitlement validation
reject declaration drift. The policy also binds canonical source-tree hashes for
the complete production composition and the capability-bearing Glance and media
modules; a helper, consumer, or source addition therefore requires an explicit
policy review. Mounting Calendar or media requires an allowlist, declaration,
and reviewed-source hash update in the same change. Production composition must
use the reviewed media adapters; direct script request, executor, runner, or
protocol seams are rejected even though the media module exposes them for library
clients.

Opening or loading the settings view only reads settings and `SMAppService` status. It never constructs a provider, starts work, or asks permission.

The application control plane mounts only Battery and Volume through package-only
lifecycle adapters backed by the one application `ActivityBroker`. Factory and
source construction are inert. `startEnabledModules()` runs once at application
startup with `.doNotRequest`, while opening/loading Settings remains read-only. A
transient provider factory/start failure records failed health but preserves the
saved enabled intent without a settings write, so a later retry can recover.
Battery and Volume toggles are live; synchronous initial unavailability retains
enabled intent with honest unavailable health, while disable and reset await full
provider and retired-expiry cleanup. An explicit successful Volume enable reports
**Volume is on — adjust it to see Erylo** beside that row; provider/start failures
also stay row-local. A failed persisted startup restore keeps its Toggle On,
explains that the preference was retained, and stays in needs-attention state
until a successful retry or a deliberate Off action resolves it.
Focus Timer is owned separately by `ApplicationRuntime` and starts only from a
deliberate menu choice or the Settings timer action. Settings presents it without a dead
module toggle. Calendar, media, File Hold, and local-integration rows are omitted
and remain defensively rejected by the model, so they cannot request
permission, open a socket or file, invoke media automation, or perform network work.

## Launch at login

`SystemLaunchAtLoginController` uses public `SMAppService.mainApp` only. Its result distinguishes disabled, enabled, approval-required, and unavailable states and preserves typed registration/unregistration failure. Preference persistence is rolled back if the platform change cannot be saved. No launch agent files or shell commands are used.

## Diagnostics privacy boundary

`DiagnosticsExporter` requires an explicit file URL on every call and rejects network destinations. The SwiftUI button first asks the user for a destination. There is no uploader, analytics SDK, network client, or automatic export path. The historical consent value remains in the versioned settings model for decoding and source compatibility, but Settings presents no sharing toggle while no sharing transport exists.

The stable JSON schema includes only:

- app version/build tokens;
- macOS version and CPU architecture;
- non-identifying settings summaries;
- one closed health record per module; and
- recent closed-code events from the bounded in-memory ring.

The schema has no message, path, URL, file, media, meeting, attendee, payload, token, secret, or device-identifier field. Display preferences export counts and automatic/explicit modes, never a session display ID, stable UUID, or display name. Metadata is allowlisted and re-sanitized after collection. Provider health and events are capped and deduplicated again after any injected collector returns, before JSON encoding; encoded output is capped at 64 KiB.

## Contained UI

`TrustSettingsView` and `TrustSettingsViewModel` live in `EryloSettingsUI`. The view uses a grouped native `Form`, semantic macOS colors, native toggles, pickers, buttons, confirmation, and save panels with explicit accessibility labels and hints. It presents only Battery and Volume as configurable modules, hides unsupported behavior controls, and removes roadmap and diagnostic-consent rows. Module enable guidance and failures render beside the row that caused them. Each native Toggle exposes its On/Off state, row result, error, and per-module busy state through one dynamic VoiceOver value; row-local copy never erases the global failure. No focus binding, application activation, custom keyboard interception, or permission work occurs during browsing. Display choices use `NSScreen.localizedName`, are keyed by stable UUID, deduplicated, and bounded; names are stripped of controls and capped before `ForEach` and VoiceOver see them. Preferred choices include only enabled, connected displays. A saved unavailable preference remains a visible, valid picker state with explicit fail-closed copy. Async results carry local sequence numbers so an older completion cannot overwrite newer UI intent.

`EryloAppRuntime` owns a native status item and exactly one reusable settings window. The compact menu exposes Show/Hide Erylo, one stateful Focus Timer submenu, Settings, Quit, and Check for Updates only when the signed-feed updater has safely started. Inapplicable Cancel and instructional shortcut rows are omitted. Menu and Settings actions route back through the runtime, repeated Quit requests collapse to one termination request, and shutdown removes the status item/window and terminally drains trust settings before the panel, broker, and updater are released.

## Verification boundary

`EryloTrustTests` is a deterministic standard-library harness covering migration, corrupt/oversized fallback, atomic persistence, prompt-free persisted restore, display bounds and round trips, cancellation/coalescing/queue capacity, permission and start cancellation, lifecycle rollback, terminal/cancellation-insensitive awaited shutdown, reset, the `SMAppService` seam, diagnostics rebounding/redaction/schema/export failures, stale UI completions, and accessibility copy. `EryloAppRuntimeTests` adds the injected Battery/Volume factory and source slice, quiet synchronous Volume activation, gated initial-unavailable settlement for both providers, and cancellation-ignoring retired-expiry drain across reset, provider disable, and terminal shutdown in both entry orderings, plus shared-broker publication, exact available controls, menu routing, first-launch presentation, unavailable controls, repeated control requests, update availability, display-policy application, lifecycle overlap, and resource release without launching a real user session.

SwiftPM does not produce the signed `.app` bundle needed to manually verify Battery and Volume on real hardware, sleep/wake and audio-device switching, Instruments energy, Login Items approval, window-level keyboard traversal, VoiceOver announcements, the save panel, or final visual contrast. Those remain app-bundle/manual gates; none is claimed by the deterministic harnesses.
