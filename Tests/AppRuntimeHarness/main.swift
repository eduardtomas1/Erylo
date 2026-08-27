import CoreGraphics
import Darwin
import EryloActivity
import EryloAppRuntime
import EryloCore
import EryloGlance
import EryloIntegrations
import EryloSettingsUI
import EryloSurface
import EryloTrust
import EryloUpdates
import EryloWindowing
import Foundation

@main
@MainActor
enum AppRuntimeHarnessMain {
    static func main() async {
        var harness = AppRuntimeHarness()
        await harness.verifyDeterministicLifecycleAndResourceRelease()
        await harness.verifyStartShutdownOverlapAndRepeatedTermination()
        await harness.verifyCallerCancellationDoesNotAbandonStartup()
        await harness.verifyControlPlanePresentationAndSafeSettings()
        await harness.verifyMenuCommandRoutingAndUpdateAvailability()
        await harness.verifyFocusTimerVerticalSlice()
        harness.finish()
    }
}

@MainActor
private struct AppRuntimeHarness {
    private var checkCount = 0
    private var failures: [String] = []

    mutating func verifyDeterministicLifecycleAndResourceRelease() async {
        let events = EventLog()
        let scheduler = ManualExpirationScheduler()
        let broker = ActivityBroker(expirationScheduler: scheduler)
        let model = SurfaceActivityModel(broker: broker)
        let eventSource = RecordingLifecycleEventSource(events: events)
        let panelReference = WeakReference<RecordingPanel>()
        let coordinator = PanelCoordinator(
            displayProvider: FixedDisplayProvider(),
            policy: .safeDefault,
            lifecycleEventSource: eventSource,
            activityModel: model,
            panelFactory: { snapshot, _ in
                let panel = RecordingPanel(
                    displayIdentity: snapshot.identity,
                    events: events
                )
                panelReference.value = panel
                return panel
            }
        )

        let driverBox = UpdateDriverBox(
            driver: RecordingUpdateDriver(events: events)
        )
        let driverReference = WeakReference<RecordingUpdateDriver>()
        driverReference.value = driverBox.driver
        let updateRuntime = UpdateRuntime(
            configuration: Self.readyUpdateConfiguration(),
            enforcePreferencePolicy: { true },
            makeDriver: {
                guard let driver = driverBox.driver else {
                    fatalError("test update driver released before construction")
                }
                return driver
            }
        )
        let runtime = ApplicationRuntime(
            activityBroker: broker,
            activityModel: model,
            panelCoordinator: coordinator,
            updateRuntime: updateRuntime
        )

        var first: RecordingService? = RecordingService(name: "first", events: events)
        var second: RecordingService? = RecordingService(name: "second", events: events)
        let firstReference = WeakReference<RecordingService>()
        let secondReference = WeakReference<RecordingService>()
        firstReference.value = first
        secondReference.value = second
        if let first, let second {
            check(runtime.register(first), "first service registers during composition")
            check(runtime.register(second), "second service registers during composition")
            check(!runtime.register(first), "duplicate service registration is rejected")
        } else {
            check(false, "first service fixture exists")
            check(false, "second service fixture exists")
            check(false, "duplicate fixture exists")
        }

        do {
            _ = try await broker.submit(Self.expiringRequest())
        } catch {
            recordUnexpected(error, context: "runtime expiry fixture")
        }
        check(
            await waitUntil { await scheduler.pendingCount == 1 },
            "runtime owns one broker expiry before startup"
        )

        check(await runtime.start(), "runtime starts successfully")
        check(await runtime.start(), "repeated start is idempotent")
        check(runtime.phase == .running, "runtime reaches running phase")
        check(!runtime.register(RecordingService(name: "late", events: events)), "startup freezes service registration")
        check(
            await waitUntil { await broker.workState().subscriberCount == 1 },
            "surface owns one shared broker subscription"
        )

        first = nil
        second = nil
        driverBox.driver = nil
        await runtime.shutdown()
        await runtime.shutdown()

        check(runtime.phase == .stopped, "repeated shutdown leaves one terminal phase")
        check(model.workState == .stopped, "surface model releases all work")
        check(await broker.workState() == .stopped, "broker releases all terminal work")
        check(await scheduler.cancellationCount == 1, "broker shutdown joins expiry cancellation")
        check(!eventSource.isRunning, "panel event source is stopped")
        check(eventSource.stopCount == 1, "panel event source stops exactly once")
        check(panelReference.value == nil, "closed panel is released")
        check(
            firstReference.value == nil && secondReference.value == nil,
            "registered services are released"
        )
        check(driverReference.value == nil, "updater driver is released")
        check(
            events.values == [
                "update.start",
                "panel-events.start",
                "panel.show",
                "first.start",
                "second.start",
                "second.shutdown",
                "first.shutdown",
                "panel-events.stop",
                "panel.close",
            ],
            "startup and reverse-dependency shutdown order is deterministic"
        )

        do {
            _ = try await broker.submit(Self.expiringRequest())
            check(false, "terminal broker rejects later submission")
        } catch let error {
            check(error == .brokerShutDown, "terminal broker reports closed admission")
        }
        check(
            broker.ownershipCoordinator.prepareClaim(for: Self.testIdentity()) == nil,
            "terminal broker closes synchronous ownership admission"
        )
    }

    mutating func verifyStartShutdownOverlapAndRepeatedTermination() async {
        let events = EventLog()
        let fixture = Self.makeRuntime(events: events)
        let service = GatedService(events: events)
        check(fixture.runtime.register(service), "overlap service registers")

        let startCaller = Task { @MainActor in
            await fixture.runtime.start()
        }
        check(
            await waitUntil { service.startCount == 1 },
            "overlap fixture reaches suspended service start"
        )

        let firstCompletion = CompletionFlag()
        let firstTermination = Task { @MainActor in
            await fixture.runtime.shutdown()
            firstCompletion.isComplete = true
        }
        let secondTermination = Task { @MainActor in
            await fixture.runtime.shutdown()
        }
        let thirdTermination = Task { @MainActor in
            await fixture.runtime.shutdown()
        }
        firstTermination.cancel()

        check(
            await waitUntil { fixture.runtime.phase == .shuttingDown && service.cancellationCount == 1 },
            "shutdown closes admission and cancels overlapping startup"
        )
        check(
            !fixture.runtime.register(RecordingService(name: "rejected", events: events)),
            "shutdown rejects new lifecycle registration before its drain"
        )
        check(!(await fixture.runtime.start()), "shutdown rejects a new start request")
        check(!firstCompletion.isComplete, "shutdown waits for noncooperative startup settlement")

        service.releaseStart()
        _ = await startCaller.value
        _ = await firstTermination.value
        _ = await secondTermination.value
        _ = await thirdTermination.value

        check(firstCompletion.isComplete, "cancelled termination caller still observes physical completion")
        check(service.shutdownCount == 1, "overlapped service is shut down exactly once")
        check(fixture.runtime.phase == .stopped, "overlap settles terminally")
        check(fixture.model.workState == .stopped, "overlap releases surface work")
        check(await fixture.broker.workState() == .stopped, "overlap releases broker work")
        check(fixture.eventSource.stopCount == 1, "overlap releases panel event work once")
    }

    mutating func verifyCallerCancellationDoesNotAbandonStartup() async {
        let events = EventLog()
        let fixture = Self.makeRuntime(events: events)
        let service = GatedService(events: events)
        check(fixture.runtime.register(service), "caller-cancellation service registers")

        let completion = StartCompletion()
        let caller = Task { @MainActor in
            completion.result = await fixture.runtime.start()
        }
        check(
            await waitUntil { service.startCount == 1 },
            "caller-cancellation fixture reaches suspended startup"
        )
        caller.cancel()
        await Task.yield()
        check(service.cancellationCount == 0, "caller cancellation does not cancel owned startup")

        service.releaseStart()
        _ = await caller.value
        check(completion.result == true, "cancelled caller joins successful startup")
        check(fixture.runtime.phase == .running, "owned startup reaches running phase")

        await fixture.runtime.shutdown()
        check(service.shutdownCount == 1, "caller-cancellation fixture shuts down once")
        check(await fixture.broker.workState() == .stopped, "caller-cancellation fixture releases broker work")
    }

    mutating func verifyControlPlanePresentationAndSafeSettings() async {
        let settingsOwner = RecordingApplicationSettingsOwner(settings: .safeDefaults)
        let presenter = RecordingControlPresenter()
        let plane = ApplicationControlPlane(
            settingsOwner: settingsOwner,
            diagnosticsExporter: DiagnosticsExporter(
                collector: PrivacyPreservingDiagnosticsCollector(
                    eventSource: InMemoryDiagnosticEventBuffer()
                ),
                writer: RejectingDiagnosticsWriter()
            ),
            presenter: presenter,
            makeDisplayChoices: {
                [DisplayChoice(identity: DisplayIdentity(rawValue: 1), name: "Main display")]
            }
        )

        let initialPolicy = await plane.prepareForStartup()
        check(initialPolicy == .safeDefault, "control plane loads the safe display policy without presenting UI")
        check(presenter.statusItemCount == 0 && presenter.settingsWindowCount == 0, "control-plane preparation creates no menu or window resource")

        var routedCommands: [ApplicationControlCommand] = []
        var appliedPolicies: [DisplayPolicy] = []
        await plane.start(
            canCheckForUpdates: true,
            commandHandler: { routedCommands.append($0) },
            displayPolicyHandler: { appliedPolicies.append($0) }
        )
        await plane.start(
            canCheckForUpdates: true,
            commandHandler: { routedCommands.append($0) },
            displayPolicyHandler: { appliedPolicies.append($0) }
        )

        check(presenter.statusItemCount == 1, "repeated control-plane start installs one status item")
        check(presenter.settingsWindowCount == 1, "first launch presents one contained settings window")
        check(presenter.presentationCount == 1, "first-launch presentation occurs once")
        check(
            presenter.menu?.items.contains(where: { $0.kind == .command(.checkForUpdates) }) == true,
            "ready updater includes the manual update command"
        )
        check(
            presenter.menu?.items.contains(where: { $0.title == ApplicationControlCopy.shortcutReminder }) == true,
            "status menu includes the keyboard shortcut reminder"
        )

        plane.presentSettings()
        plane.presentSettings()
        check(presenter.settingsWindowCount == 1, "repeated Settings requests reuse one contained window")
        check(presenter.presentationCount == 3, "repeated Settings requests bring the same window forward")

        let modelReference = WeakReference<TrustSettingsViewModel>()
        modelReference.value = presenter.presentedModel
        if let model = presenter.presentedModel {
            await model.setModuleEnabled(.timer, enabled: true)
            check(await settingsOwner.moduleMutationCount == 0, "unavailable timer control cannot reach provider mutation")
            check(
                model.statusMessage?.contains("not connected") == true,
                "unavailable utility reports that no work was started"
            )

            await model.setMotion(.reduce)
            check(model.settings.motion == .systemDefault, "unwired motion preference cannot be persisted")
            await model.setFullscreen(.remainAvailable)
            check(model.settings.fullscreenBehavior == .hide, "unwired fullscreen preference cannot be persisted")

            await model.setDisplaySurfaceEnabled(false)
            check(appliedPolicies.last == DisplayPolicy(isEnabled: false), "display preference applies the proven panel policy")
        } else {
            check(false, "first-launch presenter receives a settings model")
            check(false, "unavailable utility fixture has a model")
            check(false, "unavailable utility status fixture has a model")
            check(false, "motion availability fixture has a model")
            check(false, "fullscreen availability fixture has a model")
            check(false, "display-policy fixture has a model")
        }

        presenter.commandHandler?(.showSettings)
        check(routedCommands == [.showSettings], "native presenter routes menu selections through the injected handler")

        check(
            ApplicationControlCopy.statusItemLabel == "Erylo controls"
                && ApplicationControlCopy.statusItemHint.contains("surface")
                && TrustAccessibilityCopy.onboardingSurfaceExplanation.contains("top edge")
                && TrustAccessibilityCopy.onboardingInteractionExplanation.contains("Control–Option–Command–E")
                && TrustAccessibilityCopy.onboardingSafetyExplanation.contains("Browsing Settings")
                && TrustAccessibilityCopy.onboardingControlExplanation.contains("Focus Timer")
                && TrustAccessibilityCopy.onboardingControlExplanation.contains("quit"),
            "control and onboarding accessibility copy explains the complete daily-use path"
        )

        await plane.shutdown()
        await plane.shutdown()
        check(await settingsOwner.stopCount == 1, "repeated control-plane shutdown drains settings ownership once")
        check(presenter.shutdownCount == 1, "repeated control-plane shutdown releases native resources once")
        check(presenter.statusItemCount == 0 && presenter.settingsWindowCount == 0, "control-plane shutdown leaves no menu or window resource")
        check(modelReference.value == nil, "control-plane shutdown releases the settings model")
        plane.presentSettings()
        check(presenter.presentationCount == 3, "settings cannot reopen after terminal shutdown")

        var completedSettings = EryloSettings.safeDefaults
        completedSettings.onboardingCompleted = true
        let returningOwner = RecordingApplicationSettingsOwner(settings: completedSettings)
        let returningPresenter = RecordingControlPresenter()
        let returningPlane = ApplicationControlPlane(
            settingsOwner: returningOwner,
            diagnosticsExporter: DiagnosticsExporter(
                collector: PrivacyPreservingDiagnosticsCollector(
                    eventSource: InMemoryDiagnosticEventBuffer()
                ),
                writer: RejectingDiagnosticsWriter()
            ),
            presenter: returningPresenter,
            makeDisplayChoices: { [] }
        )
        _ = await returningPlane.prepareForStartup()
        await returningPlane.start(
            canCheckForUpdates: false,
            commandHandler: { _ in },
            displayPolicyHandler: { _ in }
        )
        check(returningPresenter.presentationCount == 0, "completed onboarding does not reopen Settings on launch")
        returningPlane.presentSettings()
        check(returningPresenter.presentationCount == 1, "returning users can reopen Settings deliberately")
        await returningPlane.shutdown()
    }

    mutating func verifyMenuCommandRoutingAndUpdateAvailability() async {
        let events = EventLog()
        let broker = ActivityBroker()
        let model = SurfaceActivityModel(broker: broker)
        let eventSource = RecordingLifecycleEventSource(events: events)
        let panel = RecordingPanel(
            displayIdentity: DisplayIdentity(rawValue: 1),
            events: events
        )
        let coordinator = PanelCoordinator(
            displayProvider: FixedDisplayProvider(),
            policy: .safeDefault,
            lifecycleEventSource: eventSource,
            activityModel: model,
            panelFactory: { _, _ in panel }
        )
        let updateDriver = RecordingUpdateDriver(events: events)
        let controlPlane = RecordingControlPlane()
        let termination = Counter()
        let runtime = ApplicationRuntime(
            activityBroker: broker,
            activityModel: model,
            panelCoordinator: coordinator,
            updateRuntime: UpdateRuntime(
                configuration: Self.readyUpdateConfiguration(),
                enforcePreferencePolicy: { true },
                makeDriver: { updateDriver }
            ),
            controlPlane: controlPlane,
            requestApplicationTermination: { termination.value += 1 }
        )

        check(await runtime.start(), "command-routing runtime starts")
        check(controlPlane.lastCanCheckForUpdates == true, "ready updater is advertised to the control plane")
        check(runtime.handle(.toggleSurface), "first menu show/hide request reaches the selected surface")
        check(runtime.handle(.toggleSurface), "repeated menu show/hide request remains routable")
        check(panel.visibilityToggleCount == 2, "repeated show/hide commands target one selected panel")
        check(runtime.handle(.showSettings) && runtime.handle(.showSettings), "repeated Settings commands are accepted")
        check(controlPlane.presentationCount == 2, "repeated Settings commands route to the settings owner")
        check(runtime.handle(.checkForUpdates) && runtime.handle(.checkForUpdates), "manual update requests route only when available")
        check(updateDriver.checkCount == 2, "each deliberate update command reaches the updater seam")
        check(runtime.handle(.quit) && runtime.handle(.quit), "repeated Quit commands are handled idempotently")
        check(termination.value == 1, "repeated Quit commands request application termination once")

        await runtime.shutdown()
        check(controlPlane.shutdownCount == 1, "runtime shutdown releases its control-plane resources")
        check(!runtime.handle(.toggleSurface) && !runtime.handle(.showSettings) && !runtime.handle(.checkForUpdates), "terminal runtime rejects later control commands")

        let disabledEvents = EventLog()
        let disabledBroker = ActivityBroker()
        let disabledModel = SurfaceActivityModel(broker: disabledBroker)
        let disabledControlPlane = RecordingControlPlane()
        let disabledRuntime = ApplicationRuntime(
            activityBroker: disabledBroker,
            activityModel: disabledModel,
            panelCoordinator: PanelCoordinator(
                displayProvider: FixedDisplayProvider(),
                policy: .safeDefault,
                lifecycleEventSource: RecordingLifecycleEventSource(events: disabledEvents),
                activityModel: disabledModel,
                panelFactory: { snapshot, _ in
                    RecordingPanel(displayIdentity: snapshot.identity, events: disabledEvents)
                }
            ),
            updateRuntime: UpdateRuntime(configuration: Self.disabledUpdateConfiguration()),
            controlPlane: disabledControlPlane
        )
        check(await disabledRuntime.start(), "disabled-update runtime starts")
        check(disabledControlPlane.lastCanCheckForUpdates == false, "disabled updater is not advertised")
        check(!disabledRuntime.handle(.checkForUpdates), "disabled updater rejects a manual check command")
        check(
            !ApplicationMenuDescriptor(canCheckForUpdates: false).items.contains(where: {
                $0.kind == .command(.checkForUpdates)
            }),
            "disabled updater omits Check for Updates from the menu"
        )
        await disabledRuntime.shutdown()
    }

    mutating func verifyFocusTimerVerticalSlice() async {
        let now = Date(timeIntervalSinceReferenceDate: 90_000.25)
        let clock = ManualFocusClock(now: now)
        let broker = ActivityBroker()
        let focusTimer = FocusTimerRuntimeService(broker: broker, clock: clock)
        let router = FocusTimerActionRouter(broker: broker, focusTimer: focusTimer)
        let model = SurfaceActivityModel(broker: broker, actionHandler: router)
        let events = EventLog()
        let eventSource = RecordingLifecycleEventSource(events: events)
        let panel = VisibilityReportingPanel(
            displayIdentity: DisplayIdentity(rawValue: 1),
            events: events
        )
        let coordinator = PanelCoordinator(
            displayProvider: FixedDisplayProvider(),
            policy: .safeDefault,
            lifecycleEventSource: eventSource,
            activityModel: model,
            panelFactory: { _, _ in panel }
        )
        coordinator.setActivityVisibilityHandler { [weak focusTimer] isVisible in
            focusTimer?.setSurfaceVisible(isVisible)
        }
        let termination = Counter()
        let controlPlane = RecordingControlPlane()
        let runtime = ApplicationRuntime(
            activityBroker: broker,
            activityModel: model,
            panelCoordinator: coordinator,
            updateRuntime: UpdateRuntime(configuration: Self.disabledUpdateConfiguration()),
            controlPlane: controlPlane,
            focusTimer: focusTimer,
            requestApplicationTermination: { termination.value += 1 }
        )
        check(runtime.register(focusTimer), "Focus Timer registers with the application lifecycle owner")

        check(!runtime.handle(.startFocusTimer25), "Focus Timer commands fail closed before startup")
        check(await focusTimer.provider.status() == .disabled, "Focus Timer construction is inert")
        check(await focusTimer.provider.workState().isIdle, "inert Focus Timer owns no task or timer")
        check(
            await broker.workState().activeOwnershipCount == 0,
            "inert Focus Timer claims no broker ownership"
        )

        check(await runtime.start(), "Focus Timer application runtime starts")
        check(await focusTimer.provider.status() == .disabled, "application startup does not enable the timer provider")
        check(await focusTimer.provider.workState().isIdle, "application startup creates no countdown boundary")
        check(
            await broker.workState().activeOwnershipCount == 0,
            "application startup creates no timer ownership side effect"
        )
        check(runtime.handle(.showSettings), "Settings remains available before any timer starts")
        check(controlPlane.presentationCount == 1, "Settings browsing routes without timer ownership")
        check(await focusTimer.provider.status() == .disabled, "Settings browsing does not enable the timer provider")
        check(await focusTimer.provider.workState().isIdle, "Settings browsing creates no timer work")
        check(
            await broker.workState().activeOwnershipCount == 0,
            "Settings browsing creates no timer broker ownership"
        )

        let menu = ApplicationMenuDescriptor(canCheckForUpdates: false)
        let timerItems = menu.items.filter {
            switch $0.kind {
            case .command(.startFocusTimer15), .command(.startFocusTimer25),
                 .command(.startFocusTimer50), .command(.cancelFocusTimer):
                true
            default:
                false
            }
        }
        check(timerItems.count == 4, "status menu exposes three Focus Timer presets and Cancel")
        check(
            timerItems.map(\.keyEquivalent) == ["1", "2", "5", "."],
            "Focus Timer menu commands provide keyboard equivalents"
        )
        check(
            timerItems.allSatisfy {
                $0.accessibilityHint?.isEmpty == false
                    && $0.accessibilityIdentifier?.hasPrefix("erylo.focus-timer.") == true
            },
            "Focus Timer menu commands provide accurate accessibility metadata"
        )
        check(
            !menu.items.map(\.title).joined(separator: " ").lowercased().contains("pause")
                && !menu.items.map(\.title).joined(separator: " ").lowercased().contains("resume"),
            "Focus Timer menu makes no unsupported pause or resume claim"
        )

        check(runtime.handle(.startFocusTimer25), "25-minute Focus Timer command is accepted")
        check(
            await waitUntil {
                let countdown = await focusTimer.provider.countdown()
                let snapshot = await broker.snapshot()
                return countdown != nil
                    && snapshot.current?.activity.identity == CountdownActivityContract.identity
            },
            "Focus Timer command publishes through the shared broker"
        )
        if let timer = await focusTimer.provider.countdown() {
            check(timer.title == "Focus Timer", "Focus Timer uses the daily-use title")
            check(
                timer.endsAt.timeIntervalSince(timer.startedAt) == 25 * 60,
                "25-minute preset creates the exact requested duration"
            )
        } else {
            check(false, "25-minute preset creates a countdown")
            check(false, "25-minute preset duration is observable")
        }
        check(
            await focusTimer.provider.presentationDemand() == .hidden,
            "hidden notch retains expiry-only timer demand"
        )
        check(
            await waitUntil { await clock.pendingCount == 1 },
            "hidden Focus Timer owns one bounded expiry one-shot"
        )

        panel.setContentVisible(true)
        check(
            await waitUntil { await focusTimer.provider.presentationDemand() == .visible },
            "visible notch starts live Focus Timer demand"
        )
        let firstTick = Date(timeIntervalSinceReferenceDate: 90_001)
        check(
            await waitUntil { await clock.pendingDeadlines == [firstTick] },
            "visible Focus Timer owns one aligned progress boundary"
        )
        let originalRevision = await broker.snapshot().current?.revision
        await clock.advance(to: firstTick)
        check(
            await waitUntil {
                guard let current = await broker.snapshot().current else { return false }
                return current.revision != originalRevision
                    && (current.activity.presentation.progress?.fractionCompleted ?? 0) > 0
            },
            "visible Focus Timer publishes timestamp-derived live progress"
        )

        panel.setContentVisible(false)
        check(
            await waitUntil { await focusTimer.provider.presentationDemand() == .hidden },
            "hiding the notch stops live Focus Timer demand"
        )
        check(
            await waitUntil {
                await clock.pendingDeadlines
                    == [Date(timeIntervalSinceReferenceDate: 91_500.25)]
            },
            "hidden Focus Timer returns to one expiry-only boundary"
        )

        guard let staleAction = model.currentAction else {
            check(false, "live Focus Timer exposes its typed cancel action")
            await runtime.shutdown()
            return
        }
        check(runtime.handle(.startFocusTimer15), "starting a new preset replaces the running Focus Timer")
        check(
            await waitUntil {
                guard let timer = await focusTimer.provider.countdown() else { return false }
                return timer.endsAt.timeIntervalSince(timer.startedAt) == 15 * 60
                    && model.currentAction?.identity.activityRevision
                        != staleAction.identity.activityRevision
            },
            "replacement publishes a fresh activity revision"
        )
        check(
            !model.dispatch(staleAction),
            "saved notch action fails closed after Focus Timer replacement"
        )
        check(await focusTimer.provider.countdown() != nil, "stale action cannot cancel the replacement timer")

        guard let replacementAction = model.currentAction else {
            check(false, "replacement Focus Timer exposes a fresh cancel action")
            await runtime.shutdown()
            return
        }
        let wrongAction = SurfaceActionIdentity(
            activityIdentity: replacementAction.identity.activityIdentity,
            activityRevision: replacementAction.identity.activityRevision,
            actionIdentifier: "timer.pause"
        )
        check(
            await router.handle(.cancel, identity: wrongAction) == .unhandled,
            "typed router rejects a mismatched action identifier"
        )
        check(
            await router.handle(.pause, identity: replacementAction.identity) == .unhandled,
            "typed router rejects a mismatched action intent"
        )
        let wrongSource = SurfaceActionIdentity(
            activityIdentity: ActivityIdentity(
                source: .external,
                identifier: try! ActivityIdentifier(
                    validating: CountdownActivityContract.identifier
                )
            ),
            activityRevision: replacementAction.identity.activityRevision,
            actionIdentifier: CountdownActivityContract.cancelActionIdentifier
        )
        check(
            await router.handle(.cancel, identity: wrongSource) == .unhandled,
            "typed router rejects a mismatched activity source"
        )
        let wrongIdentifier = SurfaceActionIdentity(
            activityIdentity: ActivityIdentity(
                source: .timer,
                identifier: try! ActivityIdentifier(validating: "another-countdown")
            ),
            activityRevision: replacementAction.identity.activityRevision,
            actionIdentifier: CountdownActivityContract.cancelActionIdentifier
        )
        check(
            await router.handle(.cancel, identity: wrongIdentifier) == .unhandled,
            "typed router rejects a mismatched activity identifier"
        )
        check(await focusTimer.provider.countdown() != nil, "mismatched actions never cancel the current timer")

        check(
            await router.handle(.cancel, identity: replacementAction.identity) == .handled,
            "fresh typed Focus Timer action cancels through its provider"
        )
        check(
            await waitUntil {
                let countdown = await focusTimer.provider.countdown()
                let snapshot = await broker.snapshot()
                return countdown == nil
                    && snapshot.current == nil
                    && focusTimer.workState().isIdle
            },
            "notch cancellation drains timer, broker activity, and command work"
        )
        check(await focusTimer.provider.status() == .disabled, "successful cancel releases timer capability ownership")

        check(runtime.handle(.startFocusTimer25), "surface-routing Focus Timer starts")
        check(
            await waitUntil {
                let countdown = await focusTimer.provider.countdown()
                return countdown != nil && model.currentAction != nil
            },
            "surface-routing Focus Timer exposes a current action"
        )
        if let surfaceAction = model.currentAction {
            check(model.dispatch(surfaceAction), "application surface dispatches the typed timer action")
            check(
                await waitUntil {
                    let countdown = await focusTimer.provider.countdown()
                    let snapshot = await broker.snapshot()
                    return countdown == nil
                        && snapshot.current == nil
                        && !model.workState.hasActionTask
                },
                "application surface action drains through router and provider"
            )
        } else {
            check(false, "application surface exposes an action to dispatch")
            check(false, "application surface action can settle")
        }

        let wrongKindBroker = ActivityBroker()
        let wrongKindFocus = FocusTimerRuntimeService(broker: wrongKindBroker, clock: clock)
        let wrongKindRouter = FocusTimerActionRouter(broker: wrongKindBroker, focusTimer: wrongKindFocus)
        await wrongKindFocus.start()
        do {
            let snapshot = try await wrongKindBroker.submit(
                ActivityRequest(
                    identifier: CountdownActivityContract.identifier,
                    source: ActivitySource.timer.rawValue,
                    kind: ActivityKind.generic.rawValue,
                    priority: ActivityPriority.normal.rawValue,
                    title: "Not a countdown",
                    actionIdentifier: CountdownActivityContract.cancelActionIdentifier,
                    actionLabel: "Cancel",
                    actionIntent: ActivityActionIntent.cancel.rawValue
                )
            )
            if let presented = snapshot.current {
                let identity = SurfaceActionIdentity(
                    activityIdentity: presented.activity.identity,
                    activityRevision: presented.revision,
                    actionIdentifier: CountdownActivityContract.cancelActionIdentifier
                )
                check(
                    await wrongKindRouter.handle(.cancel, identity: identity) == .unhandled,
                    "typed router validates activity kind"
                )
                check(
                    await wrongKindBroker.snapshot().current?.revision == presented.revision,
                    "kind mismatch fails closed without removing broker state"
                )
            } else {
                check(false, "wrong-kind fixture publishes an action")
                check(false, "wrong-kind fixture remains present")
            }
        } catch {
            recordUnexpected(error, context: "wrong-kind action route")
            check(false, "wrong-kind fixture remains inspectable")
        }
        do {
            let snapshot = try await wrongKindBroker.submit(
                ActivityRequest(
                    identifier: CountdownActivityContract.identifier,
                    source: ActivitySource.timer.rawValue,
                    kind: ActivityKind.timer.rawValue,
                    priority: ActivityPriority.normal.rawValue,
                    title: "Wrong action contract",
                    actionIdentifier: "timer.pause",
                    actionLabel: "Pause",
                    actionIntent: ActivityActionIntent.pause.rawValue
                )
            )
            if let presented = snapshot.current {
                let forgedCanonicalAction = SurfaceActionIdentity(
                    activityIdentity: presented.activity.identity,
                    activityRevision: presented.revision,
                    actionIdentifier: CountdownActivityContract.cancelActionIdentifier
                )
                check(
                    await wrongKindRouter.handle(.cancel, identity: forgedCanonicalAction)
                        == .unhandled,
                    "typed router validates the activity's declared action contract"
                )
            } else {
                check(false, "wrong-action fixture publishes an activity")
            }

            let capabilitySnapshot = try await wrongKindBroker.submit(
                ActivityRequest(
                    identifier: CountdownActivityContract.identifier,
                    source: ActivitySource.timer.rawValue,
                    kind: ActivityKind.timer.rawValue,
                    priority: ActivityPriority.normal.rawValue,
                    title: "Unavailable provider",
                    actionIdentifier: CountdownActivityContract.cancelActionIdentifier,
                    actionLabel: "Cancel",
                    actionIntent: ActivityActionIntent.cancel.rawValue
                )
            )
            if let presented = capabilitySnapshot.current {
                let action = SurfaceActionIdentity(
                    activityIdentity: presented.activity.identity,
                    activityRevision: presented.revision,
                    actionIdentifier: CountdownActivityContract.cancelActionIdentifier
                )
                check(
                    await wrongKindRouter.handle(.cancel, identity: action) == .unhandled,
                    "typed router rejects unavailable timer capability"
                )
                check(
                    await wrongKindBroker.snapshot().current?.revision == presented.revision,
                    "unavailable capability fails closed without removing broker state"
                )
            } else {
                check(false, "unavailable-capability fixture publishes an activity")
                check(false, "unavailable-capability fixture remains present")
            }
        } catch {
            recordUnexpected(error, context: "action-contract and capability routes")
            check(false, "action-contract fixture remains inspectable")
            check(false, "capability fixture remains inspectable")
            check(false, "capability fixture remains present")
        }
        await wrongKindFocus.shutdown()
        await wrongKindBroker.shutdown()

        for _ in 0..<20 {
            check(runtime.handle(.startFocusTimer50), "repeated Focus Timer start remains bounded")
            check(runtime.handle(.cancelFocusTimer), "repeated Focus Timer cancel remains bounded")
        }
        check(
            await waitUntil {
                let status = await focusTimer.provider.status()
                let snapshot = await broker.snapshot()
                return focusTimer.workState().isIdle
                    && status == .disabled
                    && snapshot.current == nil
            },
            "repeated start/cancel converges with no orphan command or timer work"
        )

        panel.setContentVisible(false)
        check(runtime.handle(.startFocusTimer15), "natural-completion Focus Timer starts")
        check(
            await waitUntil { await focusTimer.provider.countdown() != nil },
            "natural-completion timer becomes active"
        )
        guard let completionDeadline = await focusTimer.provider.countdown()?.endsAt else {
            check(false, "natural-completion timer exposes its deadline")
            await runtime.shutdown()
            return
        }
        await clock.advance(to: completionDeadline)
        check(
            await waitUntil {
                let countdown = await focusTimer.provider.countdown()
                let snapshot = await broker.snapshot()
                let providerWork = await focusTimer.provider.workState()
                return countdown == nil && snapshot.current == nil && providerWork.isIdle
            },
            "natural completion clears activity and owns zero timer tasks"
        )

        check(runtime.handle(.startFocusTimer50), "shutdown-overlap Focus Timer starts")
        check(
            await waitUntil { await focusTimer.provider.countdown() != nil },
            "shutdown-overlap timer reaches provider state"
        )
        check(runtime.handle(.quit) && runtime.handle(.quit), "Quit remains idempotent with timer work active")
        check(termination.value == 1, "timer-active Quit requests termination exactly once")
        let firstShutdown = Task { @MainActor in await runtime.shutdown() }
        let secondShutdown = Task { @MainActor in await runtime.shutdown() }
        firstShutdown.cancel()
        _ = await firstShutdown.value
        _ = await secondShutdown.value

        check(runtime.phase == .stopped, "overlapping timer shutdown reaches terminal runtime state")
        check(await focusTimer.provider.workState().isIdle, "terminal shutdown drains provider timers and mutations")
        check(focusTimer.workState().isIdle, "terminal shutdown drains app-owned command work")
        check(model.workState == .stopped, "terminal shutdown drains surface timer actions and subscription")
        check(await broker.workState() == .stopped, "terminal shutdown drains broker timers, subscribers, and ownership")
        check(await clock.pendingCount == 0, "terminal shutdown leaves no countdown clock waiter")
        check(!runtime.handle(.startFocusTimer15), "Focus Timer commands fail closed after terminal shutdown")
    }

    private static func makeRuntime(events: EventLog) -> RuntimeFixture {
        let broker = ActivityBroker()
        let model = SurfaceActivityModel(broker: broker)
        let eventSource = RecordingLifecycleEventSource(events: events)
        let coordinator = PanelCoordinator(
            displayProvider: FixedDisplayProvider(),
            policy: .safeDefault,
            lifecycleEventSource: eventSource,
            activityModel: model,
            panelFactory: { snapshot, _ in
                RecordingPanel(displayIdentity: snapshot.identity, events: events)
            }
        )
        let runtime = ApplicationRuntime(
            activityBroker: broker,
            activityModel: model,
            panelCoordinator: coordinator,
            updateRuntime: UpdateRuntime(configuration: disabledUpdateConfiguration())
        )
        return RuntimeFixture(
            runtime: runtime,
            broker: broker,
            model: model,
            eventSource: eventSource
        )
    }

    private static func readyUpdateConfiguration() -> UpdateConfiguration {
        UpdateConfiguration(infoDictionary: [
            "SUFeedURL": "https://updates.erylo.app/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
            "SURequireSignedFeed": true,
            "SUVerifyUpdateBeforeExtraction": true,
            "SUEnableAutomaticChecks": false,
            "SUAllowsAutomaticUpdates": false,
            "SUAutomaticallyUpdate": false,
            "SUEnableSystemProfiling": false,
        ])
    }

    private static func disabledUpdateConfiguration() -> UpdateConfiguration {
        UpdateConfiguration(
            feedURL: nil,
            publicEdKey: nil,
            requiresSignedFeed: false,
            verifiesBeforeExtraction: false,
            automaticChecksEnabled: false,
            automaticUpdatesAllowed: false
        )
    }

    private static func expiringRequest() -> ActivityRequest {
        ActivityRequest(
            identifier: "runtime.expiry",
            source: ActivitySource.timer.rawValue,
            kind: ActivityKind.timer.rawValue,
            priority: ActivityPriority.normal.rawValue,
            title: "Runtime expiry",
            ttlMilliseconds: 60_000
        )
    }

    private static func testIdentity() -> ActivityIdentity {
        ActivityIdentity(
            source: .timer,
            identifier: try! ActivityIdentifier(validating: "runtime.identity")
        )
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    private mutating func check(_ condition: Bool, _ message: String) {
        checkCount += 1
        if !condition {
            failures.append(message)
        }
    }

    private mutating func recordUnexpected(_ error: any Error, context: String) {
        checkCount += 1
        failures.append("\(context) produced unexpected error: \(error)")
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("Application runtime harness passed \(checkCount) checks.")
            exit(EXIT_SUCCESS)
        }
        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        fputs("Application runtime harness failed \(failures.count) of \(checkCount) checks.\n", stderr)
        exit(EXIT_FAILURE)
    }
}

@MainActor
private final class RuntimeFixture {
    let runtime: ApplicationRuntime
    let broker: ActivityBroker
    let model: SurfaceActivityModel
    let eventSource: RecordingLifecycleEventSource

    init(
        runtime: ApplicationRuntime,
        broker: ActivityBroker,
        model: SurfaceActivityModel,
        eventSource: RecordingLifecycleEventSource
    ) {
        self.runtime = runtime
        self.broker = broker
        self.model = model
        self.eventSource = eventSource
    }
}

@MainActor
private final class EventLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
private final class RecordingControlPlane: ApplicationControlPlaneOwning {
    private(set) var lastCanCheckForUpdates: Bool?
    private(set) var presentationCount = 0
    private(set) var shutdownCount = 0
    private var isShutDown = false

    func prepareForStartup() async -> DisplayPolicy {
        .safeDefault
    }

    func start(
        canCheckForUpdates: Bool,
        commandHandler: @escaping @MainActor (ApplicationControlCommand) -> Void,
        displayPolicyHandler: @escaping @MainActor (DisplayPolicy) -> Void
    ) async {
        _ = commandHandler
        _ = displayPolicyHandler
        lastCanCheckForUpdates = canCheckForUpdates
    }

    func presentSettings() {
        guard !isShutDown else { return }
        presentationCount += 1
    }

    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        shutdownCount += 1
    }
}

@MainActor
private final class RecordingControlPresenter: ApplicationControlPresenting {
    private(set) var statusItemCount = 0
    private(set) var settingsWindowCount = 0
    private(set) var presentationCount = 0
    private(set) var shutdownCount = 0
    private(set) var menu: ApplicationMenuDescriptor?
    private(set) var commandHandler: (@MainActor (ApplicationControlCommand) -> Void)?
    private(set) var presentedModel: TrustSettingsViewModel?

    func installStatusMenu(
        _ descriptor: ApplicationMenuDescriptor,
        commandHandler: @escaping @MainActor (ApplicationControlCommand) -> Void
    ) {
        statusItemCount = 1
        menu = descriptor
        self.commandHandler = commandHandler
    }

    func presentSettings(model: TrustSettingsViewModel) {
        settingsWindowCount = 1
        presentationCount += 1
        presentedModel = model
    }

    func shutdown() {
        guard shutdownCount == 0 else { return }
        shutdownCount = 1
        statusItemCount = 0
        settingsWindowCount = 0
        menu = nil
        commandHandler = nil
        presentedModel = nil
    }
}

private actor RecordingApplicationSettingsOwner: ApplicationSettingsOwning {
    private var settings: EryloSettings
    private(set) var moduleMutationCount = 0
    private(set) var stopCount = 0

    init(settings: EryloSettings) {
        self.settings = settings
    }

    func currentSettings() -> EryloSettings {
        settings
    }

    func launchAtLoginSnapshot() -> LaunchAtLoginSnapshot {
        .unavailable
    }

    func setModuleEnabled(
        _ module: EryloModule,
        enabled: Bool,
        permissionPolicy: PermissionRequestPolicy
    ) -> TrustSettingsUpdateResult {
        _ = permissionPolicy
        moduleMutationCount += 1
        settings.modules[module] = enabled
        return TrustSettingsUpdateResult(settings: settings, outcome: .applied)
    }

    func apply(_ change: TrustSettingsChange) -> TrustSettingsUpdateResult {
        switch change {
        case let .displays(displays):
            settings.displays = displays
        case let .motion(motion):
            settings.motion = motion
        case let .fullscreen(fullscreen):
            settings.fullscreenBehavior = fullscreen
        case let .crashAndDiagnosticSharingConsent(consent):
            settings.crashAndDiagnosticSharingConsent = consent
        case let .onboardingCompleted(completed):
            settings.onboardingCompleted = completed
        }
        return TrustSettingsUpdateResult(settings: settings, outcome: .applied)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) -> TrustSettingsUpdateResult {
        settings.launchAtLogin = enabled
        return TrustSettingsUpdateResult(settings: settings, outcome: .applied)
    }

    func resetToSafeDefaults() -> TrustSettingsUpdateResult {
        settings = .safeDefaults
        return TrustSettingsUpdateResult(settings: settings, outcome: .applied)
    }

    func diagnosticsContext() -> DiagnosticsContext {
        DiagnosticsContext(settings: settings, providerHealth: [])
    }

    func stopAll() -> StopAllResult {
        stopCount += 1
        return StopAllResult(stoppedModules: [])
    }
}

private struct RejectingDiagnosticsWriter: DiagnosticsWriting {
    func write(_ data: Data, to destination: URL) async throws {
        _ = data
        _ = destination
    }
}

@MainActor
private final class RecordingService: ApplicationRuntimeService {
    private let name: String
    private let events: EventLog

    init(name: String, events: EventLog) {
        self.name = name
        self.events = events
    }

    func start() async {
        events.append("\(name).start")
    }

    func shutdown() async {
        events.append("\(name).shutdown")
    }
}

@MainActor
private final class GatedService: ApplicationRuntimeService {
    private let events: EventLog
    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0
    private(set) var cancellationCount = 0
    private(set) var shutdownCount = 0

    init(events: EventLog) {
        self.events = events
    }

    func start() async {
        startCount += 1
        events.append("gated.start")
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancellationCount += 1
            }
        }
        events.append("gated.start-settled")
    }

    func releaseStart() {
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume()
    }

    func shutdown() async {
        shutdownCount += 1
        events.append("gated.shutdown")
    }
}

@MainActor
private final class StartCompletion {
    var result: Bool?
}

@MainActor
private final class CompletionFlag {
    var isComplete = false
}

@MainActor
private final class WeakReference<Value: AnyObject> {
    weak var value: Value?
}

@MainActor
private final class RecordingUpdateDriver: UpdateDriving {
    private let events: EventLog
    private(set) var checkCount = 0

    init(events: EventLog) {
        self.events = events
    }

    func startWithAutomaticNetworkWorkDisabled() -> Bool {
        events.append("update.start")
        return true
    }

    func checkForUpdates() -> Bool {
        checkCount += 1
        return true
    }
}

@MainActor
private final class UpdateDriverBox {
    var driver: RecordingUpdateDriver?

    init(driver: RecordingUpdateDriver) {
        self.driver = driver
    }
}

@MainActor
private final class FixedDisplayProvider: EnabledDisplayProviding {
    func enabledDisplays() -> [DisplaySnapshot] {
        [
            DisplaySnapshot(
                identity: DisplayIdentity(rawValue: 1),
                geometry: DisplayGeometry(
                    frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 875),
                    backingScaleFactor: 2,
                    topEdgeOcclusion: nil
                ),
                isMain: true
            ),
        ]
    }
}

@MainActor
private final class RecordingLifecycleEventSource: PanelLifecycleEventSourcing {
    private let events: EventLog
    private(set) var isRunning = false
    private(set) var stopCount = 0
    private var handler: (@MainActor @Sendable (PanelLifecycleEvent) -> Void)?

    init(events: EventLog) {
        self.events = events
    }

    func start(handler: @escaping @MainActor @Sendable (PanelLifecycleEvent) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        self.handler = handler
        events.append("panel-events.start")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopCount += 1
        handler = nil
        events.append("panel-events.stop")
    }
}

@MainActor
private final class RecordingPanel: PanelPresenting {
    let displayIdentity: DisplayIdentity
    private let events: EventLog
    private(set) var primaryActionCount = 0
    private(set) var visibilityToggleCount = 0

    init(displayIdentity: DisplayIdentity, events: EventLog) {
        self.displayIdentity = displayIdentity
        self.events = events
    }

    func show() {
        events.append("panel.show")
    }

    func hide() {}

    func close() {
        events.append("panel.close")
    }

    func update(snapshot: DisplaySnapshot) {}
    func updatePointer(screenPoint: CGPoint) {}
    func performPrimaryAction() {
        primaryActionCount += 1
    }
    func performVisibilityToggle() {
        visibilityToggleCount += 1
    }
    func cancelPendingInteractions() {}
}

@MainActor
private final class VisibilityReportingPanel: PanelPresenting, PanelActivityVisibilityReporting {
    let displayIdentity: DisplayIdentity
    private let events: EventLog
    private var isWindowVisible = false
    private var isContentVisible = false
    private var lastReportedVisibility = false
    private var visibilityHandler: (@MainActor @Sendable (Bool) -> Void)?

    var isActivitySurfaceVisible: Bool {
        isWindowVisible && isContentVisible
    }

    init(displayIdentity: DisplayIdentity, events: EventLog) {
        self.displayIdentity = displayIdentity
        self.events = events
    }

    func setActivityVisibilityHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        visibilityHandler = handler
        reportVisibility(force: true)
    }

    func setContentVisible(_ visible: Bool) {
        isContentVisible = visible
        reportVisibility()
    }

    func show() {
        isWindowVisible = true
        events.append("panel.show")
        reportVisibility()
    }

    func hide() {
        isWindowVisible = false
        reportVisibility()
    }

    func close() {
        isWindowVisible = false
        events.append("panel.close")
        reportVisibility()
    }

    func update(snapshot: DisplaySnapshot) {}
    func updatePointer(screenPoint: CGPoint) {}
    func performPrimaryAction() {}

    func performVisibilityToggle() {
        isContentVisible.toggle()
        reportVisibility()
    }

    func cancelPendingInteractions() {}

    private func reportVisibility(force: Bool = false) {
        let visible = isActivitySurfaceVisible
        guard force || visible != lastReportedVisibility else { return }
        lastReportedVisibility = visible
        visibilityHandler?(visible)
    }
}

private actor ManualFocusClock: GlanceClock {
    private struct Waiter {
        let identifier: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var currentDate: Date
    private var waiters: [Waiter] = []
    private var cancelledBeforeRegistration: Set<UUID> = []

    init(now: Date) {
        currentDate = now
    }

    var pendingCount: Int { waiters.count }
    var pendingDeadlines: [Date] { waiters.map(\.deadline).sorted() }

    func now() async -> Date {
        currentDate
    }

    func sleep(until deadline: Date) async throws {
        if deadline <= currentDate { return }
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledBeforeRegistration.remove(identifier) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(
                        Waiter(
                            identifier: identifier,
                            deadline: deadline,
                            continuation: continuation
                        )
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(identifier) }
        }
    }

    func advance(to date: Date) {
        currentDate = date
        let ready = waiters.filter { $0.deadline <= date }
        waiters.removeAll { $0.deadline <= date }
        ready.forEach { $0.continuation.resume() }
    }

    private func cancel(_ identifier: UUID) {
        guard let index = waiters.firstIndex(where: { $0.identifier == identifier }) else {
            cancelledBeforeRegistration.insert(identifier)
            return
        }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private actor ManualExpirationScheduler: ActivityExpirationScheduling {
    private struct Waiter {
        let identifier: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Waiter] = []
    private var cancelledBeforeRegistration: Set<UUID> = []
    private(set) var cancellationCount = 0

    var pendingCount: Int {
        waiters.count
    }

    func sleep(for duration: Duration) async throws {
        _ = duration
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledBeforeRegistration.remove(identifier) != nil {
                    cancellationCount += 1
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(identifier: identifier, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(identifier) }
        }
    }

    private func cancel(_ identifier: UUID) {
        guard let index = waiters.firstIndex(where: { $0.identifier == identifier }) else {
            cancelledBeforeRegistration.insert(identifier)
            return
        }
        cancellationCount += 1
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private extension ActivityBrokerWorkState {
    static let stopped = ActivityBrokerWorkState(
        scheduledExpiryCount: 0,
        subscriberCount: 0,
        activeOwnershipCount: 0,
        pendingOwnershipIntentCount: 0
    )
}
