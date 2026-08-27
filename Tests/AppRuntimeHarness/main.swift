import CoreGraphics
import Darwin
import EryloActivity
import EryloAppRuntime
import EryloCore
import EryloIntegrations
import EryloSurface
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

    init(events: EventLog) {
        self.events = events
    }

    func startWithAutomaticNetworkWorkDisabled() -> Bool {
        events.append("update.start")
        return true
    }

    func checkForUpdates() -> Bool {
        true
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
    func performPrimaryAction() {}
    func cancelPendingInteractions() {}
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
