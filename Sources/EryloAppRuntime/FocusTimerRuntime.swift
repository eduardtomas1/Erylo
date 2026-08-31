import EryloActivity
import EryloGlance
import EryloSurface
import Foundation

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
    }

    package let provider: CountdownGlanceProvider

    private let clock: any GlanceClock
    private var phase = Phase.initialized
    private var nextSequence: UInt64 = 0
    private var pendingUserOperation: SequencedOperation?
    private var pendingDemandOperation: SequencedOperation?
    private var pendingRoutedOperation: SequencedOperation?
    private var workerTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var isProviderEnabled = false
    private var isSurfaceVisible = false
    private var activeTimer: ActiveTimer?

    package init(
        provider: CountdownGlanceProvider,
        clock: any GlanceClock = SystemGlanceClock()
    ) {
        self.provider = provider
        self.clock = clock
    }

    package convenience init(
        broker: ActivityBroker,
        clock: any GlanceClock = SystemGlanceClock()
    ) {
        self.init(
            provider: CountdownGlanceProvider(broker: broker, clock: clock),
            clock: clock
        )
    }

    package func start() async {
        guard phase == .initialized else { return }
        await provider.setNaturalCompletionHandler { [weak self] completedTimer in
            await self?.naturalCompletionDidFinish(completedTimer)
        }
        phase = .running
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
            hasWorkerTask: workerTask != nil,
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
        pendingUserOperation = nil
        pendingDemandOperation = nil
        if case let .routedCancel(_, continuation)? = pendingRoutedOperation?.operation {
            continuation.resume(returning: .unavailable)
        }
        pendingRoutedOperation = nil
        let workerTask = workerTask
        let task = Task { @MainActor [self] in
            _ = await workerTask?.value
            await provider.setPresentationDemand(.hidden)
            await provider.cancelCountdown()
            await provider.disable()
            await provider.setNaturalCompletionHandler(nil)
            isProviderEnabled = false
            activeTimer = nil
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
        guard now.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              let timer = try? CountdownTimer(
                title: "Focus Timer",
                startedAt: now,
                endsAt: end
              ) else {
            return
        }

        let demand: CountdownPresentationDemand = isSurfaceVisible ? .visible : .hidden
        let operationIdentity = CountdownOperationIdentity()
        activeTimer = ActiveTimer(
            countdown: timer,
            operationIdentity: operationIdentity
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
    }

    private func naturalCompletionDidFinish(
        _ completion: CountdownNaturalCompletion
    ) async {
        guard phase == .running else { return }
        isProviderEnabled = await provider.status().isEnabled
        if !isProviderEnabled,
           activeTimer?.operationIdentity == completion.operationIdentity {
            activeTimer = nil
        }
    }

    private func cancelTimer() async {
        guard isProviderEnabled else {
            activeTimer = nil
            return
        }
        await provider.cancelCountdown()
        await provider.disable()
        isProviderEnabled = false
        activeTimer = nil
    }

    private func cancelTimer(ifPublishedRevision revision: UInt64) async -> FocusTimerRouteResult {
        guard isProviderEnabled else { return .unavailable }
        let status = await provider.status()
        guard status.isEnabled, status.capability == .available else {
            return .unavailable
        }
        guard await provider.cancelCountdown(ifPublishedRevision: revision) else {
            return .stale
        }
        await provider.disable()
        isProviderEnabled = false
        activeTimer = nil
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
        guard intent == .cancel,
              identity.activityIdentity == CountdownActivityContract.identity,
              identity.actionIdentifier == CountdownActivityContract.cancelActionIdentifier else {
            return .unhandled
        }

        let snapshot = await broker.snapshot()
        guard let current = snapshot.current,
              current.activity.identity == identity.activityIdentity,
              current.revision == identity.activityRevision else {
            return .stale
        }
        guard current.activity.identity.source == CountdownActivityContract.source,
              current.activity.kind == CountdownActivityContract.kind,
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
    }
}
