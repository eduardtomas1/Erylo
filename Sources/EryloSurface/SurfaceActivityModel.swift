import EryloActivity
import Foundation
import Observation

package protocol SurfaceActivitySnapshotStreaming: Sendable {
    func snapshotSubscription(
        subscriberID: UUID
    ) async throws -> ActivityBrokerSnapshotSubscription
    func cancelSnapshotSubscription(_ token: ActivityBrokerSubscriptionToken) async
}

extension ActivityBroker: SurfaceActivitySnapshotStreaming {}

@MainActor
public protocol ActivityActionHandling: AnyObject {
    /// Receives only a closed intent and validated identity metadata from the activity domain.
    /// Implementations must cooperate with task cancellation so terminal stop can join their work.
    func handle(
        _ intent: ActivityActionIntent,
        identity: SurfaceActionIdentity
    ) async -> ActivityActionOutcome
}

@MainActor
public final class BrokerActivityActionHandler: ActivityActionHandling {
    private let broker: ActivityBroker

    public init(broker: ActivityBroker) {
        self.broker = broker
    }

    public func handle(
        _ intent: ActivityActionIntent,
        identity: SurfaceActionIdentity
    ) async -> ActivityActionOutcome {
        // No provider command route exists in this slice. Dismiss is the only complete local intent.
        guard intent == .dismiss else { return .unhandled }
        return await broker.cancelCurrentAction(
            identity: identity.activityIdentity,
            revision: identity.activityRevision,
            actionIdentifier: identity.actionIdentifier,
            intent: intent
        ) ? .handled : .stale
    }
}

@MainActor
public final class UnavailableActivityActionHandler: ActivityActionHandling {
    public init() {}

    public func handle(
        _ intent: ActivityActionIntent,
        identity: SurfaceActionIdentity
    ) async -> ActivityActionOutcome {
        _ = intent
        _ = identity
        return .unhandled
    }
}

@MainActor
@Observable
public final class SurfaceActivityModel {
    /// One handler may execute while one successor waits for physical settlement.
    public static let maximumUnsettledActionTaskCount = 2
    public static let maximumConcurrentActionHandlerCount = 1

    public private(set) var phase: SurfaceActivityPhase = .stopped
    public private(set) var snapshotVersion: UInt64 = 0
    public private(set) var current: PresentedActivity?
    public private(set) var queueContext: ActivityQueueContext = .empty
    public private(set) var handoff: ActivityHandoff?
    public private(set) var currentAction: SurfaceActivityAction?
    public private(set) var actionDispatchState: ActivityActionDispatchState = .idle
    public private(set) var isRunning = false

    public var workState: SurfaceActivityWorkState {
        SurfaceActivityWorkState(
            hasSnapshotTask: snapshotTask != nil,
            hasActionTask: !actionTasks.isEmpty,
            ownsSubscriberIdentity: snapshotSubscriberID != nil,
            unsettledActionTaskCount: actionTasks.count
        )
    }

    package var observerCount: Int {
        observers.count
    }

    package var lifecycleRequestTaskCount: Int {
        stopRequestTask == nil ? 0 : 1
    }

    @ObservationIgnored
    private var admitsNewWork: Bool {
        wantsRunning && !isShutdown && isRunning
    }

    @ObservationIgnored
    private let snapshotSource: (any SurfaceActivitySnapshotStreaming)?

    @ObservationIgnored
    private let actionHandler: any ActivityActionHandling

    @ObservationIgnored
    private let maximumVisibleQueueItems: Int

    @ObservationIgnored
    private var snapshotTask: Task<Void, Never>?

    @ObservationIgnored
    private var stopRequestTask: Task<Void, Never>?

    @ObservationIgnored
    private var stopRequestToken: UUID?

    @ObservationIgnored
    private var actionTasks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var actionTaskOrder: [UUID] = []

    @ObservationIgnored
    private var currentActionTaskID: UUID?

    @ObservationIgnored
    private var snapshotSubscriberID: UUID?

    @ObservationIgnored
    private var snapshotSubscriptionToken: ActivityBrokerSubscriptionToken?

    @ObservationIgnored
    private var subscriptionGeneration: UInt64 = 0

    @ObservationIgnored
    private var actionGeneration: UInt64 = 0

    @ObservationIgnored
    private var admissionEpoch: UInt64 = 0

    @ObservationIgnored
    private var visibleAdmissionEpoch: UInt64?

    @ObservationIgnored
    private var hasReceivedSnapshot = false

    @ObservationIgnored
    private var wantsRunning = false

    @ObservationIgnored
    private var stopDrainCount = 0

    @ObservationIgnored
    private var isShutdown = false

    @ObservationIgnored
    private var isTerminalDrainInProgress = false

    @ObservationIgnored
    private var terminalDrainWaiters: [CheckedContinuation<Void, Never>] = []

    @ObservationIgnored
    private var observers: [UUID: @MainActor @Sendable () -> Void] = [:]

    public init(
        broker: ActivityBroker,
        actionHandler: any ActivityActionHandling,
        maximumVisibleQueueItems: Int = ActivityQueueContext.maximumVisibleItems
    ) {
        snapshotSource = broker
        self.actionHandler = actionHandler
        self.maximumVisibleQueueItems = min(
            max(maximumVisibleQueueItems, 0),
            ActivityQueueContext.maximumVisibleItems
        )
    }

    public convenience init(
        broker: ActivityBroker,
        maximumVisibleQueueItems: Int = ActivityQueueContext.maximumVisibleItems
    ) {
        self.init(
            broker: broker,
            actionHandler: BrokerActivityActionHandler(broker: broker),
            maximumVisibleQueueItems: maximumVisibleQueueItems
        )
    }

    public init(
        previewSnapshot: ActivityBrokerSnapshot,
        maximumVisibleQueueItems: Int = ActivityQueueContext.maximumVisibleItems
    ) {
        snapshotSource = nil
        actionHandler = UnavailableActivityActionHandler()
        self.maximumVisibleQueueItems = min(
            max(maximumVisibleQueueItems, 0),
            ActivityQueueContext.maximumVisibleItems
        )
        phase = .active
        apply(previewSnapshot)
    }

    /// Package compatibility paths use a stopped model with no stream source or action route.
    /// It owns no tasks, broker subscriptions, timers, or permission-dependent work.
    package init(inert: Void) {
        _ = inert
        snapshotSource = nil
        actionHandler = UnavailableActivityActionHandler()
        maximumVisibleQueueItems = ActivityQueueContext.maximumVisibleItems
    }

    package init(
        snapshotSource: any SurfaceActivitySnapshotStreaming,
        actionHandler: any ActivityActionHandling,
        maximumVisibleQueueItems: Int = ActivityQueueContext.maximumVisibleItems
    ) {
        self.snapshotSource = snapshotSource
        self.actionHandler = actionHandler
        self.maximumVisibleQueueItems = min(
            max(maximumVisibleQueueItems, 0),
            ActivityQueueContext.maximumVisibleItems
        )
    }

    deinit {
        stopRequestTask?.cancel()
        snapshotTask?.cancel()
        actionTasks.values.forEach { $0.cancel() }
    }

    public func start() {
        guard snapshotSource != nil, !isShutdown else { return }
        wantsRunning = true
        startSubscriptionIfNeeded()
    }

    public func stop() async {
        if isTerminalDrainInProgress {
            await waitForTerminalDrain()
            return
        }
        guard !isShutdown else { return }
        requestStop()
        await waitForRequestedLifecycleSettlement()
        if isTerminalDrainInProgress {
            await waitForTerminalDrain()
        }
    }

    /// Records a nonterminal stop synchronously and owns its physical drain task.
    /// A later `start()` updates the same intent before or during that drain, so stale
    /// compatibility calls cannot leave a successor stopped.
    package func requestStop() {
        guard !isShutdown else { return }
        if wantsRunning {
            wantsRunning = false
            retireAdmissionEpoch()
            snapshotTask?.cancel()
            cancelAllActionTasks()
        }
        startStopRequestIfNeeded()
    }

    /// Cancellation-insensitive barrier for the latest requested model lifecycle.
    package func waitForRequestedLifecycleSettlement() async {
        while let task = stopRequestTask {
            _ = await task.value
        }
        if isTerminalDrainInProgress {
            await waitForTerminalDrain()
        }
    }

    /// Irreversibly stops this model for process termination or final owner teardown.
    /// Concurrent `stop()` and `shutdown()` callers join the same physical drain.
    public func shutdown() async {
        if isTerminalDrainInProgress {
            await waitForTerminalDrain()
            return
        }
        guard !isShutdown else { return }
        isShutdown = true
        if wantsRunning {
            wantsRunning = false
            retireAdmissionEpoch()
        }
        snapshotTask?.cancel()
        cancelAllActionTasks()
        isTerminalDrainInProgress = true
        if let stopRequestTask {
            _ = await stopRequestTask.value
        } else {
            await drainCurrentWork()
        }
        finishTerminalDrain()
    }

    private func startStopRequestIfNeeded() {
        guard stopRequestTask == nil else { return }
        guard isRunning || snapshotTask != nil || !actionTasks.isEmpty else {
            phase = .stopped
            resetSnapshotState()
            return
        }

        let token = UUID()
        stopRequestToken = token
        stopRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainCurrentWork()
            self.stopRequestSettled(token: token)
        }
    }

    private func stopRequestSettled(token: UUID) {
        guard stopRequestToken == token else { return }
        stopRequestTask = nil
        stopRequestToken = nil
    }

    private func startSubscriptionIfNeeded() {
        guard wantsRunning, !isShutdown, stopDrainCount == 0,
              let snapshotSource, snapshotTask == nil else {
            return
        }
        advanceSubscriptionGeneration()
        let generation = subscriptionGeneration
        let epoch = admissionEpoch
        let subscriberID = UUID()
        snapshotSubscriberID = subscriberID
        isRunning = true
        phase = .waiting
        resetSnapshotState()

        snapshotTask = Task { [weak self, snapshotSource] in
            guard !Task.isCancelled,
                  self?.admitsSnapshotWork(
                      subscriberID: subscriberID,
                      generation: generation,
                      admissionEpoch: epoch
                  ) == true else {
                return
            }
            do {
                let subscription = try await snapshotSource.snapshotSubscription(
                    subscriberID: subscriberID
                )
                guard !Task.isCancelled,
                      self?.registerSnapshotSubscription(
                          subscription.token,
                          subscriberID: subscriberID,
                          generation: generation,
                          admissionEpoch: epoch
                      ) == true else {
                    await snapshotSource.cancelSnapshotSubscription(subscription.token)
                    return
                }
                for await snapshot in subscription.stream {
                    guard !Task.isCancelled else { break }
                    self?.receive(
                        snapshot,
                        subscriberID: subscriberID,
                        generation: generation,
                        admissionEpoch: epoch
                    )
                }
                await snapshotSource.cancelSnapshotSubscription(subscription.token)
                guard !Task.isCancelled else { return }
                self?.streamEnded(
                    token: subscription.token,
                    subscriberID: subscriberID,
                    generation: generation,
                    admissionEpoch: epoch
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.streamEnded(
                    subscriberID: subscriberID,
                    generation: generation,
                    admissionEpoch: epoch
                )
            }
        }
    }

    private func drainCurrentWork() async {
        guard isRunning || snapshotTask != nil || !actionTasks.isEmpty else {
            phase = .stopped
            resetSnapshotState()
            return
        }
        stopDrainCount += 1
        advanceSubscriptionGeneration()
        advanceActionGeneration()
        isRunning = false
        let taskToStop = snapshotTask
        let actionTasksToStop = actionTaskOrder.compactMap { token in
            actionTasks[token].map { (token, $0) }
        }
        let subscriberID = snapshotSubscriberID
        let subscriptionToken = snapshotSubscriptionToken
        taskToStop?.cancel()
        cancelAllActionTasks()
        phase = .stopped
        resetSnapshotState()
        notifyObservers()

        if let snapshotSource, let subscriptionToken {
            await snapshotSource.cancelSnapshotSubscription(subscriptionToken)
        }
        _ = await taskToStop?.value
        for (_, task) in actionTasksToStop {
            _ = await task.value
        }

        if snapshotSubscriberID == subscriberID {
            snapshotTask = nil
            snapshotSubscriberID = nil
            snapshotSubscriptionToken = nil
        }
        stopDrainCount -= 1
        if stopDrainCount == 0 {
            startSubscriptionIfNeeded()
        }
    }

    private func registerSnapshotSubscription(
        _ token: ActivityBrokerSubscriptionToken,
        subscriberID: UUID,
        generation: UInt64,
        admissionEpoch: UInt64
    ) -> Bool {
        guard admitsSnapshotWork(
            subscriberID: subscriberID,
            generation: generation,
            admissionEpoch: admissionEpoch
        ) else {
            return false
        }
        snapshotSubscriptionToken = token
        return true
    }

    private func admitsSnapshotWork(
        subscriberID: UUID,
        generation: UInt64,
        admissionEpoch: UInt64
    ) -> Bool {
        admitsNewWork
            && self.admissionEpoch == admissionEpoch
            && generation == subscriptionGeneration
            && snapshotSubscriberID == subscriberID
    }

    package func addObserver(
        _ observer: @escaping @MainActor @Sendable () -> Void
    ) -> UUID {
        let identifier = UUID()
        observers[identifier] = observer
        return identifier
    }

    package func removeObserver(_ identifier: UUID) {
        observers.removeValue(forKey: identifier)
    }

    @discardableResult
    public func dispatch(_ action: SurfaceActivityAction) -> Bool {
        guard admitsNewWork else {
            actionDispatchState = .unhandled
            return false
        }
        guard currentAction == action else {
            actionDispatchState = .stale
            return false
        }
        guard visibleAdmissionEpoch == admissionEpoch else {
            actionDispatchState = .stale
            return false
        }
        guard actionDispatchState != .inProgress else { return false }
        guard actionTasks.count < Self.maximumUnsettledActionTaskCount else { return false }

        advanceActionGeneration()
        let generation = actionGeneration
        let epoch = admissionEpoch
        actionDispatchState = .inProgress
        let handler = actionHandler
        let token = UUID()
        let predecessor = actionTaskOrder.last.flatMap { actionTasks[$0] }
        currentActionTaskID = token
        let task = Task { [weak self] in
            if let predecessor {
                _ = await predecessor.value
            }
            let outcome: ActivityActionOutcome?
            if Task.isCancelled || self?.admitsActionWork(
                generation: generation,
                admissionEpoch: epoch
            ) != true {
                outcome = nil
            } else {
                outcome = await handler.handle(action.intent, identity: action.identity)
            }
            let wasCancelled = Task.isCancelled
            self?.actionTaskSettled(
                token: token,
                outcome: outcome,
                wasCancelled: wasCancelled,
                action: action,
                generation: generation,
                admissionEpoch: epoch
            )
        }
        actionTasks[token] = task
        actionTaskOrder.append(token)
        return true
    }

    private func receive(
        _ snapshot: ActivityBrokerSnapshot,
        subscriberID: UUID,
        generation: UInt64,
        admissionEpoch: UInt64
    ) {
        guard admitsSnapshotWork(
            subscriberID: subscriberID,
            generation: generation,
            admissionEpoch: admissionEpoch
        ) else { return }
        apply(snapshot, admissionEpoch: admissionEpoch)
    }

    private func apply(
        _ snapshot: ActivityBrokerSnapshot,
        admissionEpoch: UInt64? = nil
    ) {
        guard !hasReceivedSnapshot || snapshot.version > snapshotVersion else { return }
        let previousIdentity = current?.activity.identity
        let nextIdentity = snapshot.current?.activity.identity
        if hasReceivedSnapshot, previousIdentity != nextIdentity {
            handoff = ActivityHandoff(
                from: previousIdentity,
                to: nextIdentity,
                snapshotVersion: snapshot.version
            )
        } else {
            handoff = nil
        }

        let nextAction = SurfaceActivityAction(presented: snapshot.current)
        if currentAction?.identity != nextAction?.identity {
            advanceActionGeneration()
            cancelCurrentActionTask()
            actionDispatchState = .idle
        }

        snapshotVersion = snapshot.version
        current = snapshot.current
        queueContext = ActivityQueueContext(
            snapshot: snapshot,
            maximumVisibleItems: maximumVisibleQueueItems
        )
        currentAction = nextAction
        visibleAdmissionEpoch = admissionEpoch
        hasReceivedSnapshot = true
        phase = .active
        notifyObservers()
    }

    private func streamEnded(
        token: ActivityBrokerSubscriptionToken? = nil,
        subscriberID: UUID,
        generation: UInt64,
        admissionEpoch: UInt64
    ) {
        guard admitsSnapshotWork(
                  subscriberID: subscriberID,
                  generation: generation,
                  admissionEpoch: admissionEpoch
              ),
              snapshotSubscriptionToken == token else {
            return
        }
        snapshotTask = nil
        phase = .degraded
        current = nil
        queueContext = .empty
        handoff = nil
        currentAction = nil
        advanceActionGeneration()
        cancelCurrentActionTask()
        actionDispatchState = .idle
        snapshotSubscriberID = nil
        snapshotSubscriptionToken = nil
        notifyObservers()
    }

    private func actionTaskSettled(
        token: UUID,
        outcome: ActivityActionOutcome?,
        wasCancelled: Bool,
        action: SurfaceActivityAction,
        generation: UInt64,
        admissionEpoch: UInt64
    ) {
        guard actionTasks.removeValue(forKey: token) != nil else { return }
        actionTaskOrder.removeAll { $0 == token }
        guard currentActionTaskID == token else { return }
        currentActionTaskID = nil
        guard admitsActionWork(
                  generation: generation,
                  admissionEpoch: admissionEpoch
              ),
              !wasCancelled,
              currentAction == action, let outcome else {
            return
        }
        switch outcome {
        case .handled:
            actionDispatchState = .handled
        case .unhandled:
            actionDispatchState = currentAction == action ? .unhandled : .stale
        case .stale:
            actionDispatchState = .stale
        }
    }

    private func cancelCurrentActionTask() {
        guard let token = currentActionTaskID else { return }
        currentActionTaskID = nil
        actionTasks[token]?.cancel()
    }

    private func cancelAllActionTasks() {
        currentActionTaskID = nil
        actionTasks.values.forEach { $0.cancel() }
    }

    private func admitsActionWork(
        generation: UInt64,
        admissionEpoch: UInt64
    ) -> Bool {
        admitsNewWork
            && self.admissionEpoch == admissionEpoch
            && actionGeneration == generation
    }

    private func waitForTerminalDrain() async {
        guard isTerminalDrainInProgress else { return }
        await withCheckedContinuation { continuation in
            terminalDrainWaiters.append(continuation)
        }
    }

    private func finishTerminalDrain() {
        isTerminalDrainInProgress = false
        let waiters = terminalDrainWaiters
        terminalDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func resetSnapshotState() {
        snapshotVersion = 0
        current = nil
        queueContext = .empty
        handoff = nil
        currentAction = nil
        visibleAdmissionEpoch = nil
        actionDispatchState = .idle
        hasReceivedSnapshot = false
    }

    private func notifyObservers() {
        let callbacks = Array(observers.values)
        callbacks.forEach { $0() }
    }

    private func advanceSubscriptionGeneration() {
        precondition(subscriptionGeneration < UInt64.max, "surface subscription generation exhausted")
        subscriptionGeneration += 1
    }

    private func advanceActionGeneration() {
        precondition(actionGeneration < UInt64.max, "surface action generation exhausted")
        actionGeneration += 1
    }

    private func retireAdmissionEpoch() {
        precondition(admissionEpoch < UInt64.max, "surface admission epoch exhausted")
        admissionEpoch += 1
    }
}

public struct SurfaceActivityWorkState: Equatable, Sendable {
    public let hasSnapshotTask: Bool
    public let hasActionTask: Bool
    public let ownsSubscriberIdentity: Bool
    public let unsettledActionTaskCount: Int

    public init(
        hasSnapshotTask: Bool,
        hasActionTask: Bool,
        ownsSubscriberIdentity: Bool,
        unsettledActionTaskCount: Int
    ) {
        self.hasSnapshotTask = hasSnapshotTask
        self.hasActionTask = hasActionTask
        self.ownsSubscriberIdentity = ownsSubscriberIdentity
        self.unsettledActionTaskCount = unsettledActionTaskCount
    }

    public static let stopped = SurfaceActivityWorkState(
        hasSnapshotTask: false,
        hasActionTask: false,
        ownsSubscriberIdentity: false,
        unsettledActionTaskCount: 0
    )
}
