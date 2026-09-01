import EryloActivity
import EryloGlance
import EryloSurface
import EryloTrust
import Foundation

private enum FocusTimerPersistenceLoadResult {
    case missing
    case active(PersistedFocusTimerSession)
    case corrupt
    case unreadable
    case unsupportedSchema
}

private struct PersistedFocusTimerSession: Codable, Equatable, Sendable {
    let sessionID: UUID
    let startedAt: Date
    let endsAt: Date
}

private struct PersistedFocusTimerEnvelope: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let activeSession: PersistedFocusTimerSession?

    init(activeSession: PersistedFocusTimerSession?) {
        schemaVersion = Self.currentSchemaVersion
        self.activeSession = activeSession
    }
}

private struct PersistedFocusTimerVersionEnvelope: Decodable {
    let schemaVersion: Int
}

/// One atomically replaced deadline record. It deliberately stores no ticks and performs
/// no work until the owning runtime calls `load()` from its explicit startup lifecycle.
private struct FocusTimerPersistence: Sendable {
    static let maximumEncodedBytes = 1_024

    let storage: (any AtomicSettingsStorage)?
    let storageKey: String

    func load() -> FocusTimerPersistenceLoadResult {
        guard let storage else { return .missing }
        let data: Data
        do {
            guard let stored = try storage.data(forKey: storageKey) else {
                return .missing
            }
            data = stored
        } catch {
            return .unreadable
        }
        guard data.count <= Self.maximumEncodedBytes,
              let version = try? JSONDecoder().decode(
                PersistedFocusTimerVersionEnvelope.self,
                from: data
              ) else {
            return .corrupt
        }
        guard version.schemaVersion == PersistedFocusTimerEnvelope.currentSchemaVersion else {
            return .unsupportedSchema
        }
        guard let envelope = try? JSONDecoder().decode(
            PersistedFocusTimerEnvelope.self,
            from: data
        ) else { return .corrupt }
        guard let activeSession = envelope.activeSession else { return .missing }
        return .active(activeSession)
    }

    @discardableResult
    func replace(with session: PersistedFocusTimerSession?) -> Bool {
        guard let storage else { return true }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(
            PersistedFocusTimerEnvelope(activeSession: session)
        ), data.count <= Self.maximumEncodedBytes else {
            return false
        }
        do {
            try storage.replace(data, forKey: storageKey)
            return true
        } catch {
            return false
        }
    }

    func clear(ifMatching sessionID: UUID) -> Bool {
        // Erylo is the sole writer for this dedicated key. The identity check prevents stale
        // in-process callbacks from clearing a replacement; it is not a cross-process CAS.
        guard storage != nil else { return true }
        switch load() {
        case .missing:
            return true
        case .corrupt:
            return replace(with: nil)
        case .unreadable, .unsupportedSchema:
            return false
        case let .active(session):
            guard session.sessionID == sessionID else { return false }
            return replace(with: nil)
        }
    }
}

package enum FocusTimerPreset: Int, CaseIterable, Equatable, Sendable {
    case fifteenMinutes = 15
    case twentyFiveMinutes = 25
    case fiftyMinutes = 50

    package var duration: TimeInterval {
        TimeInterval(rawValue * 60)
    }
}

package enum FocusTimerRouteResult: Equatable, Sendable {
    case cancelled
    case stale
    case unavailable
}

package struct FocusTimerRuntimeWorkState: Equatable, Sendable {
    package let hasWorkerTask: Bool
    package let pendingOperationCount: Int
    package let isProviderEnabled: Bool

    package var isIdle: Bool {
        !hasWorkerTask && pendingOperationCount == 0 && !isProviderEnabled
    }
}

@MainActor
package final class FocusTimerRuntimeService: ApplicationRuntimeService {
    private enum Phase {
        case initialized
        case starting
        case running
        case shuttingDown
        case stopped
    }

    private enum Operation {
        case start(TimeInterval)
        case cancel
        case demand(CountdownPresentationDemand)
        case routedCancel(
            revision: UInt64,
            continuation: CheckedContinuation<FocusTimerRouteResult, Never>
        )
    }

    private struct SequencedOperation {
        let sequence: UInt64
        let operation: Operation
    }

    private struct ActiveTimer {
        let countdown: CountdownTimer
        let operationIdentity: CountdownOperationIdentity
        let sessionID: UUID
    }

    package let provider: CountdownGlanceProvider

    private let clock: any GlanceClock
    private let completionNotifier: @MainActor @Sendable () -> Void
    private let persistence: FocusTimerPersistence
    private var phase = Phase.initialized
    private var nextSequence: UInt64 = 0
    private var pendingUserOperation: SequencedOperation?
    private var pendingDemandOperation: SequencedOperation?
    private var pendingRoutedOperation: SequencedOperation?
    private var startupTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var isProviderEnabled = false
    private var isSurfaceVisible = false
    private var activeTimer: ActiveTimer?
    private var lastNotifiedCompletionOperationIdentity: CountdownOperationIdentity?

    package init(
        provider: CountdownGlanceProvider,
        clock: any GlanceClock = SystemGlanceClock(),
        persistenceStorage: (any AtomicSettingsStorage)? = nil,
        persistenceKey: String = "erylo.focus-timer.active-session",
        completionNotifier: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.provider = provider
        self.clock = clock
        persistence = FocusTimerPersistence(
            storage: persistenceStorage,
            storageKey: persistenceKey
        )
        self.completionNotifier = completionNotifier
    }

    package convenience init(
        broker: ActivityBroker,
        clock: any GlanceClock = SystemGlanceClock(),
        persistenceStorage: (any AtomicSettingsStorage)? = nil,
        persistenceKey: String = "erylo.focus-timer.active-session",
        completionNotifier: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.init(
            provider: CountdownGlanceProvider(broker: broker, clock: clock),
            clock: clock,
            persistenceStorage: persistenceStorage,
            persistenceKey: persistenceKey,
            completionNotifier: completionNotifier
        )
    }

    package func start() async {
        if let startupTask {
            _ = await startupTask.value
            return
        }
        guard phase == .initialized else { return }
        phase = .starting
        let task = Task { @MainActor [self] in
            await provider.setNaturalCompletionHandler { [weak self] completedTimer in
                await self?.naturalCompletionDidFinish(completedTimer)
            }
            guard phase == .starting else { return }
            await restorePersistedTimerIfNeeded()
            guard phase == .starting else { return }
            phase = .running
        }
        startupTask = task
        _ = await task.value
        startupTask = nil
    }

    @discardableResult
    package func requestStart(_ preset: FocusTimerPreset) -> Bool {
        requestStart(duration: preset.duration)
    }

    @discardableResult
    package func requestStart(duration: TimeInterval) -> Bool {
        guard phase == .running,
              duration.isFinite,
              duration >= 1,
              duration <= CountdownTimer.maximumDuration else {
            return false
        }
        pendingUserOperation = sequenced(.start(duration))
        startWorkerIfNeeded()
        return true
    }

    @discardableResult
    package func requestCancel() -> Bool {
        guard phase == .running,
              activeTimer != nil || pendingUserOperation != nil else { return false }
        pendingUserOperation = sequenced(.cancel)
        startWorkerIfNeeded()
        return true
    }

    package func setSurfaceVisible(_ isVisible: Bool) {
        guard phase == .running, isSurfaceVisible != isVisible else { return }
        isSurfaceVisible = isVisible
        guard isProviderEnabled else { return }
        pendingDemandOperation = sequenced(
            .demand(isVisible ? .visible : .hidden)
        )
        startWorkerIfNeeded()
    }

    package func routeCancel(activityRevision: UInt64) async -> FocusTimerRouteResult {
        guard phase == .running, pendingRoutedOperation == nil else {
            return .unavailable
        }
        return await withCheckedContinuation { continuation in
            pendingRoutedOperation = sequenced(
                .routedCancel(
                    revision: activityRevision,
                    continuation: continuation
                )
            )
            startWorkerIfNeeded()
        }
    }

    package func workState() -> FocusTimerRuntimeWorkState {
        FocusTimerRuntimeWorkState(
            hasWorkerTask: startupTask != nil || workerTask != nil,
            pendingOperationCount: [
                pendingUserOperation,
                pendingDemandOperation,
                pendingRoutedOperation,
            ].compactMap { $0 }.count,
            isProviderEnabled: isProviderEnabled
        )
    }

    package func menuContext(at date: Date) -> ApplicationFocusTimerMenuContext {
        guard phase == .running, let activeTimer else { return .idle }
        let rawRemaining = activeTimer.countdown.endsAt.timeIntervalSince(date)
        let seconds = rawRemaining.isFinite ? Int(max(rawRemaining, 0).rounded(.up)) : 0
        return .active(remainingText: Self.durationText(seconds: seconds))
    }

    package func shutdown() async {
        if let shutdownTask {
            _ = await shutdownTask.value
            return
        }
        guard phase != .stopped else { return }

        phase = .shuttingDown
        if let pendingUserOperation,
           case .cancel = pendingUserOperation.operation,
           let activeTimer = activeTimer {
            // A synchronously accepted Cancel is already the latest user intent even if its
            // worker has not started. Preserve that linearization across an immediate Quit.
            _ = persistence.clear(ifMatching: activeTimer.sessionID)
        }
        pendingUserOperation = nil
        pendingDemandOperation = nil
        if case let .routedCancel(_, continuation)? = pendingRoutedOperation?.operation {
            continuation.resume(returning: .unavailable)
        }
        pendingRoutedOperation = nil
        let startupTask = startupTask
        let workerTask = workerTask
        let task = Task { @MainActor [self] in
            _ = await startupTask?.value
            _ = await workerTask?.value
            await provider.setPresentationDemand(.hidden)
            await provider.cancelCountdown()
            await provider.disable()
            await provider.setNaturalCompletionHandler(nil)
            isProviderEnabled = false
            activeTimer = nil
            self.startupTask = nil
            self.workerTask = nil
            phase = .stopped
            shutdownTask = nil
        }
        shutdownTask = task
        _ = await task.value
    }

    private func sequenced(_ operation: Operation) -> SequencedOperation {
        precondition(nextSequence < UInt64.max, "Focus Timer operation sequence exhausted")
        nextSequence += 1
        return SequencedOperation(sequence: nextSequence, operation: operation)
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { @MainActor [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        while phase == .running, let next = takeNextOperation() {
            await perform(next.operation)
        }
        workerTask = nil
        if phase == .running, hasPendingOperation {
            startWorkerIfNeeded()
        }
    }

    private var hasPendingOperation: Bool {
        pendingUserOperation != nil
            || pendingDemandOperation != nil
            || pendingRoutedOperation != nil
    }

    private func takeNextOperation() -> SequencedOperation? {
        let candidates = [
            pendingUserOperation,
            pendingDemandOperation,
            pendingRoutedOperation,
        ].compactMap { $0 }
        guard let next = candidates.min(by: { $0.sequence < $1.sequence }) else {
            return nil
        }
        if pendingUserOperation?.sequence == next.sequence {
            pendingUserOperation = nil
        } else if pendingDemandOperation?.sequence == next.sequence {
            pendingDemandOperation = nil
        } else {
            pendingRoutedOperation = nil
        }
        return next
    }

    private func perform(_ operation: Operation) async {
        switch operation {
        case let .start(duration):
            await startTimer(duration: duration)
        case .cancel:
            await cancelTimer()
        case let .demand(demand):
            guard isProviderEnabled, await provider.countdown() != nil else { return }
            await provider.setPresentationDemand(demand)
        case let .routedCancel(revision, continuation):
            continuation.resume(returning: await cancelTimer(ifPublishedRevision: revision))
        }
    }

    private func startTimer(duration: TimeInterval) async {
        let now = await clock.now()
        let end = now.addingTimeInterval(duration)
        guard phase == .running,
              now.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              let timer = try? CountdownTimer(
                title: "Focus Timer",
                startedAt: now,
                endsAt: end
              ) else {
            return
        }

        let sessionID = UUID()
        let persisted = PersistedFocusTimerSession(
            sessionID: sessionID,
            startedAt: timer.startedAt,
            endsAt: timer.endsAt
        )
        // Replacement is ordered after the deadline-record write. A failed atomic write leaves
        // the previous live and persisted timer coherent instead of resurrecting stale state.
        guard persistence.replace(with: persisted) else { return }
        await activateTimer(timer, sessionID: sessionID)
    }

    private func restorePersistedTimerIfNeeded() async {
        switch persistence.load() {
        case .missing:
            return
        case .corrupt:
            _ = persistence.replace(with: nil)
            return
        case .unreadable, .unsupportedSchema:
            return
        case let .active(session):
            let now = await clock.now()
            // Teardown may be admitted while the clock is suspended. That lifecycle race must
            // leave a valid persisted session untouched for the next launch.
            guard phase == .starting else { return }
            guard now.timeIntervalSinceReferenceDate.isFinite,
                  session.startedAt <= now,
                  session.endsAt > now,
                  let timer = try? CountdownTimer(
                    title: "Focus Timer",
                    startedAt: session.startedAt,
                    endsAt: session.endsAt
                  ) else {
                _ = persistence.replace(with: nil)
                return
            }
            await activateTimer(timer, sessionID: session.sessionID)
        }
    }

    private func activateTimer(_ timer: CountdownTimer, sessionID: UUID) async {
        let demand: CountdownPresentationDemand = isSurfaceVisible ? .visible : .hidden
        let operationIdentity = CountdownOperationIdentity()
        activeTimer = ActiveTimer(
            countdown: timer,
            operationIdentity: operationIdentity,
            sessionID: sessionID
        )
        if await provider.status().isEnabled {
            await provider.setPresentationDemand(demand)
        }
        await provider.setCountdown(
            timer,
            operationIdentity: operationIdentity
        )
        if !(await provider.status().isEnabled) {
            await provider.enable()
        }
        isProviderEnabled = await provider.status().isEnabled
        if isProviderEnabled {
            await provider.setPresentationDemand(demand)
        }
        // The absolute deadline can pass between restore validation and provider activation.
        // Reconcile after the provider's own clock check so no persisted 00:00 ghost survives.
        await reconcileMissingProviderCountdown(sessionID: sessionID)
    }

    private func reconcileMissingProviderCountdown(sessionID: UUID) async {
        guard await provider.countdown() == nil,
              activeTimer?.sessionID == sessionID else { return }
        _ = persistence.clear(ifMatching: sessionID)
        activeTimer = nil
        if isProviderEnabled {
            await provider.disable()
            isProviderEnabled = false
        }
    }

    private func naturalCompletionDidFinish(
        _ completion: CountdownNaturalCompletion
    ) async {
        switch phase {
        case .starting, .running:
            break
        case .initialized, .shuttingDown, .stopped:
            return
        }
        guard let activeTimer,
              activeTimer.operationIdentity == completion.operationIdentity,
              lastNotifiedCompletionOperationIdentity != completion.operationIdentity else {
            return
        }
        lastNotifiedCompletionOperationIdentity = completion.operationIdentity
        completionNotifier()
        isProviderEnabled = await provider.status().isEnabled
        if !isProviderEnabled,
           self.activeTimer?.operationIdentity == completion.operationIdentity {
            _ = persistence.clear(ifMatching: activeTimer.sessionID)
            self.activeTimer = nil
        }
    }

    private func cancelTimer() async {
        guard let activeTimer else { return }
        // If the tombstone cannot be persisted, leave the live timer alone. Cancelling only
        // in memory would make a stale deadline reappear on the next launch.
        guard persistence.clear(ifMatching: activeTimer.sessionID) else { return }
        guard isProviderEnabled else {
            self.activeTimer = nil
            return
        }
        await provider.cancelCountdown()
        await provider.disable()
        isProviderEnabled = false
        self.activeTimer = nil
    }

    private func cancelTimer(ifPublishedRevision revision: UInt64) async -> FocusTimerRouteResult {
        guard isProviderEnabled, let activeTimer else { return .unavailable }
        let status = await provider.status()
        guard status.isEnabled, status.capability == .available else {
            return .unavailable
        }
        guard await provider.cancelCountdown(ifPublishedRevision: revision) else {
            return .stale
        }
        guard persistence.clear(ifMatching: activeTimer.sessionID) else {
            // The revision was current, but persisted cancellation failed. Restore the exact
            // deadline in-process so memory and the persisted session cannot diverge.
            await provider.setCountdown(
                activeTimer.countdown,
                operationIdentity: activeTimer.operationIdentity
            )
            await reconcileMissingProviderCountdown(sessionID: activeTimer.sessionID)
            return .unavailable
        }
        await provider.disable()
        isProviderEnabled = false
        self.activeTimer = nil
        return .cancelled
    }

    private static func durationText(seconds: Int) -> String {
        let bounded = max(seconds, 0)
        let hours = bounded / 3_600
        let minutes = (bounded % 3_600) / 60
        let seconds = bounded % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

@MainActor
package final class FocusTimerActionRouter: ActivityActionHandling {
    private let broker: ActivityBroker
    private let focusTimer: FocusTimerRuntimeService

    package init(broker: ActivityBroker, focusTimer: FocusTimerRuntimeService) {
        self.broker = broker
        self.focusTimer = focusTimer
    }

    package func handle(
        _ intent: ActivityActionIntent,
        identity: SurfaceActionIdentity
    ) async -> ActivityActionOutcome {
        guard identity.activityIdentity == CountdownActivityContract.identity else {
            return .unhandled
        }

        let snapshot = await broker.snapshot()
        guard let current = snapshot.current,
              current.activity.identity == identity.activityIdentity,
              current.revision == identity.activityRevision else {
            return .stale
        }
        guard current.activity.identity.source == CountdownActivityContract.source,
              current.activity.kind == CountdownActivityContract.kind else {
            return .unhandled
        }

        switch intent {
        case .cancel:
            guard identity.actionIdentifier
                    == CountdownActivityContract.cancelActionIdentifier,
                  current.activity.action?.identifier
                    == CountdownActivityContract.cancelActionIdentifier,
                  current.activity.action?.intent == .cancel else {
                return .unhandled
            }
            return switch await focusTimer.routeCancel(
                activityRevision: identity.activityRevision
            ) {
            case .cancelled:
                .handled
            case .stale:
                .stale
            case .unavailable:
                .unhandled
            }
        case .dismiss:
            guard identity.actionIdentifier
                    == CountdownActivityContract.dismissActionIdentifier,
                  current.activity.presentation.presentationRole
                    == .completionAcknowledgement,
                  current.activity.action?.identifier
                    == CountdownActivityContract.dismissActionIdentifier,
                  current.activity.action?.intent == .dismiss else {
                return .unhandled
            }
            let dismissed = await broker.cancelCurrentAction(
                identity: identity.activityIdentity,
                revision: identity.activityRevision,
                actionIdentifier: identity.actionIdentifier,
                intent: intent
            )
            return dismissed ? .handled : .stale
        case .pause, .resume, .openSource, .togglePlayback:
            return .unhandled
        }
    }
}
