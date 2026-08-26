import CoreGraphics
import Darwin
import EryloActivity
import EryloCore
import EryloIntegrations
import EryloSurface
import EryloWindowing

@main
@MainActor
enum PublicSurfaceProbeMain {
    static func main() async {
        var probe = PublicSurfaceProbe()
        await probe.verifySynchronousStopAdmission()
        await probe.verifySynchronousDisableAdmission()
        await probe.verifyRapidReopenAdmission()
        await probe.verifyRetiredEpochWorkCannotReopen()
        await probe.verifyQueuedWorkCannotBeginAfterStopIntent()
        await probe.verifyImmediateStartStopCreatesNoSubscription()
        probe.finish()
    }
}

@MainActor
private struct PublicSurfaceProbe {
    private var checkCount = 0
    private var failures: [String] = []

    mutating func verifySynchronousStopAdmission() async {
        let fixture = Fixture(identity: 101)
        guard let action = await loadAction(fixture, identifier: "external-stop") else {
            await fixture.coordinator.stopAndWait()
            return
        }

        fixture.coordinator.stop()
        check(!fixture.coordinator.isRunning, "stop records coordinator intent synchronously")
        check(
            fixture.model.isRunning && fixture.model.phase == .active,
            "external probe reproduces stop intent before physical model drain"
        )
        check(!fixture.model.dispatch(action), "stop intent immediately rejects saved public action")
        check(
            fixture.model.workState.unsettledActionTaskCount == 0
                && fixture.handler.invocationCount == 0,
            "stop intent creates no action task or handler"
        )

        await fixture.coordinator.stopAndWait()
        check(fixture.model.workState == .stopped, "awaited stop settles zero model work")
        check(await fixture.broker.workState().subscriberCount == 0, "awaited stop settles zero subscribers")
        check(!fixture.events.isRunning && fixture.panels.openCount == 0, "awaited stop settles zero events and panels")
    }

    mutating func verifySynchronousDisableAdmission() async {
        let fixture = Fixture(identity: 102)
        guard let action = await loadAction(fixture, identifier: "external-disable") else {
            await fixture.coordinator.stopAndWait()
            return
        }

        fixture.coordinator.update(policy: DisplayPolicy(isEnabled: false))
        check(!fixture.coordinator.policy.isEnabled, "disable records policy intent synchronously")
        check(
            fixture.model.isRunning && fixture.model.phase == .active,
            "external probe reproduces disable intent before physical model drain"
        )
        check(!fixture.model.dispatch(action), "disable intent immediately rejects saved public action")
        check(
            fixture.model.workState.unsettledActionTaskCount == 0
                && fixture.handler.invocationCount == 0,
            "disable intent creates no action task or handler"
        )

        await fixture.coordinator.updateAndWait(policy: DisplayPolicy(isEnabled: false))
        check(fixture.model.workState == .stopped, "awaited disable settles zero model work")
        check(await fixture.broker.workState().subscriberCount == 0, "awaited disable settles zero subscribers")
        check(!fixture.events.isRunning && fixture.panels.openCount == 0, "awaited disable settles zero events and panels")
    }

    mutating func verifyRapidReopenAdmission() async {
        let fixture = Fixture(identity: 103)
        guard let action = await loadAction(fixture, identifier: "external-reopen") else {
            await fixture.coordinator.stopAndWait()
            return
        }

        fixture.coordinator.stop()
        check(!fixture.model.dispatch(action), "rapid stop closes admission immediately")
        fixture.coordinator.start()
        check(!fixture.model.dispatch(action), "rapid start cannot revive retired action content")
        await fixture.coordinator.startAndWait()
        check(
            await waitUntil { fixture.model.currentAction != nil && fixture.model.phase == .active },
            "rapid start receives fresh successor content"
        )
        guard let restartedAction = fixture.model.currentAction else {
            check(false, "rapid start exposes a fresh successor action")
            await fixture.coordinator.stopAndWait()
            return
        }
        check(fixture.model.dispatch(restartedAction), "fresh post-start content reopens admission")
        check(
            await waitUntil {
                fixture.handler.invocationCount == 1
                    && !fixture.model.workState.hasActionTask
            },
            "rapid stop-start runs one post-start handler"
        )
        check(await fixture.broker.workState().subscriberCount == 1, "rapid stop-start retains one subscriber")

        fixture.coordinator.update(policy: DisplayPolicy(isEnabled: false))
        check(!fixture.model.dispatch(restartedAction), "rapid disable closes admission immediately")
        fixture.coordinator.update(policy: .safeDefault)
        check(!fixture.model.dispatch(restartedAction), "rapid enable cannot revive retired action content")
        await fixture.coordinator.updateAndWait(policy: .safeDefault)
        check(
            await waitUntil { fixture.model.currentAction != nil && fixture.model.phase == .active },
            "rapid enable receives fresh successor content"
        )
        guard let reenabledAction = fixture.model.currentAction else {
            check(false, "rapid enable exposes a fresh successor action")
            await fixture.coordinator.stopAndWait()
            return
        }
        check(fixture.model.dispatch(reenabledAction), "fresh post-enable content reopens admission")
        check(
            await waitUntil {
                fixture.handler.invocationCount == 2
                    && !fixture.model.workState.hasActionTask
            },
            "rapid disable-enable runs one post-enable handler"
        )
        check(
            fixture.events.isRunning && fixture.events.runningCount == 1
                && fixture.panels.openCount == 1,
            "rapid reopen retains one event source and panel"
        )
        check(await fixture.broker.workState().subscriberCount == 1, "rapid reopen retains one subscriber")

        await fixture.coordinator.stopAndWait()
        check(fixture.model.workState == .stopped, "rapid reopen settles zero model work")
        check(await fixture.broker.workState().subscriberCount == 0, "rapid reopen settles zero subscribers")
        check(!fixture.events.isRunning && fixture.panels.openCount == 0, "rapid reopen settles zero events and panels")
    }

    mutating func verifyQueuedWorkCannotBeginAfterStopIntent() async {
        let fixture = Fixture(identity: 104)
        guard let action = await loadAction(fixture, identifier: "external-queued-action") else {
            await fixture.coordinator.stopAndWait()
            return
        }

        check(fixture.model.dispatch(action), "action is accepted before stop intent")
        fixture.coordinator.stop()
        check(
            fixture.model.workState.unsettledActionTaskCount == 1,
            "pre-stop action remains owned until its queued task settles"
        )
        await fixture.coordinator.stopAndWait()
        check(fixture.handler.invocationCount == 0, "queued action handler cannot begin after stop intent")
        check(fixture.model.workState == .stopped, "queued-action stop settles zero model work")
        check(await fixture.broker.workState().subscriberCount == 0, "queued-action stop settles zero subscribers")
    }

    mutating func verifyRetiredEpochWorkCannotReopen() async {
        await verifyRetiredEpochWorkCannotReopen(
            fixture: GatedFixture(identity: 106),
            identifier: "external-epoch-stop",
            lifecycleName: "stop-start",
            stop: { fixture in
                fixture.coordinator.stop()
                fixture.coordinator.start()
            },
            settle: { fixture in
                await fixture.coordinator.startAndWait()
            }
        )
        await verifyRetiredEpochWorkCannotReopen(
            fixture: GatedFixture(identity: 107),
            identifier: "external-epoch-disable",
            lifecycleName: "disable-enable",
            stop: { fixture in
                fixture.coordinator.update(policy: DisplayPolicy(isEnabled: false))
                fixture.coordinator.update(policy: .safeDefault)
            },
            settle: { fixture in
                await fixture.coordinator.updateAndWait(policy: .safeDefault)
            }
        )
    }

    private mutating func verifyRetiredEpochWorkCannotReopen(
        fixture: GatedFixture,
        identifier: String,
        lifecycleName: String,
        stop: (GatedFixture) -> Void,
        settle: (GatedFixture) async -> Void
    ) async {
        await fixture.coordinator.startAndWait()
        do {
            let first = try await fixture.broker.submit(
                activityRequest(identifier: identifier, title: "Epoch action A")
            )
            check(
                await waitUntil {
                    fixture.model.snapshotVersion == first.version
                        && fixture.model.currentAction != nil
                },
                "\(lifecycleName) exposes action A"
            )
            guard let actionA = fixture.model.currentAction else {
                check(false, "\(lifecycleName) saves action A")
                await fixture.coordinator.stopAndWait()
                return
            }
            check(fixture.model.dispatch(actionA), "\(lifecycleName) starts action A")
            check(
                await waitUntil { fixture.handler.startCount == 1 },
                "\(lifecycleName) action A is physically active"
            )

            let replacement = try await fixture.broker.submit(
                activityRequest(identifier: identifier, title: "Epoch action B")
            )
            check(
                await waitUntil {
                    fixture.model.snapshotVersion == replacement.version
                        && fixture.handler.isFirstBlockedAfterCancellation
                },
                "\(lifecycleName) replacement cancels and gates action A"
            )
            guard let actionB = fixture.model.currentAction else {
                check(false, "\(lifecycleName) exposes replacement action B")
                fixture.handler.releaseFirst()
                await fixture.coordinator.stopAndWait()
                return
            }
            check(fixture.model.dispatch(actionB), "\(lifecycleName) queues pre-stop action B")
            check(
                fixture.model.workState.unsettledActionTaskCount == 2,
                "\(lifecycleName) owns active A and queued B before retirement"
            )

            stop(fixture)
            check(!fixture.model.dispatch(actionB), "\(lifecycleName) immediately rejects retired action B")
            check(
                await waitUntil {
                    await fixture.broker.workState().subscriberCount == 0
                        && fixture.model.current == nil
                },
                "\(lifecycleName) retires the old subscriber while action cleanup is gated"
            )

            let newest = try await fixture.broker.submit(
                activityRequest(identifier: identifier, title: "Successor epoch")
            )
            for _ in 0..<50 { await Task.yield() }
            check(
                fixture.model.snapshotVersion != newest.version && fixture.model.current == nil,
                "\(lifecycleName) cannot reauthorize the retired snapshot path"
            )

            fixture.handler.releaseFirst()
            await settle(fixture)
            check(
                await waitUntil {
                    let subscriberCount = await fixture.broker.workState().subscriberCount
                    return fixture.model.snapshotVersion == newest.version
                        && fixture.model.currentAction != nil
                        && subscriberCount == 1
                },
                "\(lifecycleName) creates one fresh subscriber for the successor epoch"
            )
            check(
                fixture.handler.startCount == 1,
                "\(lifecycleName) never invokes queued pre-stop action B"
            )
            guard let successorAction = fixture.model.currentAction else {
                check(false, "\(lifecycleName) exposes a successor-epoch action")
                await fixture.coordinator.stopAndWait()
                return
            }
            check(
                fixture.model.dispatch(successorAction),
                "\(lifecycleName) admits action work only from fresh successor content"
            )
            check(
                await waitUntil {
                    fixture.handler.startCount == 2
                        && fixture.model.workState.unsettledActionTaskCount == 0
                },
                "\(lifecycleName) restores bounded new-work reuse"
            )
        } catch {
            fixture.handler.releaseFirst()
            failures.append("\(lifecycleName) epoch fixture failed: \(error)")
            checkCount += 1
        }

        await fixture.coordinator.stopAndWait()
        check(fixture.model.workState == .stopped, "\(lifecycleName) ends with zero model work")
        check(await fixture.broker.workState().subscriberCount == 0, "\(lifecycleName) ends with zero subscribers")
        check(!fixture.events.isRunning && fixture.panels.openCount == 0, "\(lifecycleName) ends with zero events and panels")
    }

    private func activityRequest(identifier: String, title: String) -> ActivityRequest {
        ActivityRequest(
            identifier: identifier,
            source: ActivitySource.timer.rawValue,
            kind: ActivityKind.timer.rawValue,
            priority: 50,
            title: title,
            detail: nil,
            progress: nil,
            actionIdentifier: "\(identifier).cancel",
            actionLabel: "Cancel",
            actionIntent: ActivityActionIntent.cancel.rawValue,
            ttlMilliseconds: nil
        )
    }

    mutating func verifyImmediateStartStopCreatesNoSubscription() async {
        let fixture = Fixture(identity: 105)
        fixture.coordinator.start()
        fixture.coordinator.stop()
        var maximumSubscriberCount = 0
        for _ in 0..<100 {
            maximumSubscriberCount = max(
                maximumSubscriberCount,
                await fixture.broker.workState().subscriberCount
            )
            await Task.yield()
        }
        await fixture.coordinator.stopAndWait()
        check(maximumSubscriberCount == 0, "stop intent prevents queued snapshot registration")
        check(fixture.model.workState == .stopped, "immediate start-stop settles zero model work")
        check(await fixture.broker.workState().subscriberCount == 0, "immediate start-stop settles zero subscribers")
        check(!fixture.events.isRunning && fixture.panels.openCount == 0, "immediate start-stop settles zero events and panels")
    }

    private mutating func loadAction(
        _ fixture: Fixture,
        identifier: String
    ) async -> SurfaceActivityAction? {
        await fixture.coordinator.startAndWait()
        do {
            _ = try await fixture.broker.submit(
                ActivityRequest(
                    identifier: identifier,
                    source: ActivitySource.timer.rawValue,
                    kind: ActivityKind.timer.rawValue,
                    priority: 50,
                    title: "External admission probe",
                    detail: nil,
                    progress: nil,
                    actionIdentifier: "\(identifier).cancel",
                    actionLabel: "Cancel",
                    actionIntent: ActivityActionIntent.cancel.rawValue,
                    ttlMilliseconds: nil
                )
            )
        } catch {
            failures.append("\(identifier) submit failed: \(error)")
            checkCount += 1
            return nil
        }
        check(
            await waitUntil {
                fixture.model.currentAction != nil && fixture.model.phase == .active
            },
            "\(identifier) exposes one public action"
        )
        return fixture.model.currentAction
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    private mutating func check(_ condition: Bool, _ name: String) {
        checkCount += 1
        if !condition {
            failures.append(name)
        }
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("Public surface admission probe passed: \(checkCount) checks.")
            exit(EXIT_SUCCESS)
        }
        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        fputs("Public surface admission probe failed: \(failures.count) of \(checkCount) checks.\n", stderr)
        exit(EXIT_FAILURE)
    }
}

@MainActor
private final class Fixture {
    let broker = ActivityBroker()
    let handler = ImmediateActionHandler()
    let model: SurfaceActivityModel
    let events = FakeEventSource()
    let panels = FakePanelRegistry()
    let coordinator: PanelCoordinator

    init(identity: UInt32) {
        model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        let display = DisplaySnapshot(
            identity: DisplayIdentity(rawValue: identity),
            geometry: DisplayGeometry(
                frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 875),
                backingScaleFactor: 2,
                topEdgeOcclusion: nil
            ),
            isMain: true
        )
        let provider = FakeDisplayProvider(display: display)
        coordinator = PanelCoordinator(
            displayProvider: provider,
            policy: .safeDefault,
            lifecycleEventSource: events,
            activityModel: model,
            panelFactory: { [panels] snapshot, _ in
                panels.makePanel(identity: snapshot.identity)
            }
        )
    }
}

@MainActor
private final class GatedFixture {
    let broker = ActivityBroker()
    let handler = EpochGatedActionHandler()
    let model: SurfaceActivityModel
    let events = FakeEventSource()
    let panels = FakePanelRegistry()
    let coordinator: PanelCoordinator

    init(identity: UInt32) {
        model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        let display = DisplaySnapshot(
            identity: DisplayIdentity(rawValue: identity),
            geometry: DisplayGeometry(
                frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 875),
                backingScaleFactor: 2,
                topEdgeOcclusion: nil
            ),
            isMain: true
        )
        coordinator = PanelCoordinator(
            displayProvider: FakeDisplayProvider(display: display),
            policy: .safeDefault,
            lifecycleEventSource: events,
            activityModel: model,
            panelFactory: { [panels] snapshot, _ in
                panels.makePanel(identity: snapshot.identity)
            }
        )
    }
}

@MainActor
private final class ImmediateActionHandler: ActivityActionHandling {
    private(set) var invocationCount = 0

    func handle(
        _ intent: ActivityActionIntent,
        identity: SurfaceActionIdentity
    ) async -> ActivityActionOutcome {
        _ = intent
        _ = identity
        invocationCount += 1
        return .unhandled
    }
}

@MainActor
private final class EpochGatedActionHandler: ActivityActionHandling {
    private(set) var startCount = 0
    private(set) var isFirstBlockedAfterCancellation = false
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?
    private var firstReleaseWasRequested = false

    func handle(
        _ intent: ActivityActionIntent,
        identity: SurfaceActionIdentity
    ) async -> ActivityActionOutcome {
        _ = intent
        _ = identity
        let invocation = startCount
        startCount += 1
        guard invocation == 0 else { return .unhandled }

        while !Task.isCancelled {
            await Task.yield()
        }
        await withCheckedContinuation { continuation in
            isFirstBlockedAfterCancellation = true
            if firstReleaseWasRequested {
                continuation.resume()
            } else {
                firstReleaseContinuation = continuation
            }
        }
        return .unhandled
    }

    func releaseFirst() {
        firstReleaseWasRequested = true
        let continuation = firstReleaseContinuation
        firstReleaseContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class FakeDisplayProvider: EnabledDisplayProviding {
    let display: DisplaySnapshot

    init(display: DisplaySnapshot) {
        self.display = display
    }

    func enabledDisplays() -> [DisplaySnapshot] {
        [display]
    }
}

@MainActor
private final class FakeEventSource: PanelLifecycleEventSourcing {
    private(set) var isRunning = false
    private(set) var runningCount = 0

    func start(handler: @escaping @MainActor @Sendable (PanelLifecycleEvent) -> Void) {
        _ = handler
        guard !isRunning else { return }
        isRunning = true
        runningCount += 1
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        runningCount -= 1
    }
}

@MainActor
private final class FakePanelRegistry {
    private var panels: [FakePanel] = []

    var openCount: Int {
        panels.lazy.filter { !$0.isClosed }.count
    }

    func makePanel(identity: DisplayIdentity) -> any PanelPresenting {
        let panel = FakePanel(displayIdentity: identity)
        panels.append(panel)
        return panel
    }
}

@MainActor
private final class FakePanel: PanelPresenting {
    let displayIdentity: DisplayIdentity
    private(set) var isClosed = false

    init(displayIdentity: DisplayIdentity) {
        self.displayIdentity = displayIdentity
    }

    func show() {}
    func hide() {}
    func close() { isClosed = true }
    func update(snapshot: DisplaySnapshot) { _ = snapshot }
    func updatePointer(screenPoint: CGPoint) { _ = screenPoint }
    func performPrimaryAction() {}
    func cancelPendingInteractions() {}
}
