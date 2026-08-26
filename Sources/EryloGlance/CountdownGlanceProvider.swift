import EryloActivity
import Foundation

public actor CountdownGlanceProvider {
    private let broker: any GlanceActivityBroker
    private let clock: any GlanceClock
    private var enabled = false
    private var generation: UInt64 = 0
    private var operationRevision: UInt64 = 0
    private var activationTask: Task<Void, Never>?
    private var deactivationTask: Task<Void, Never>?
    private var deactivationRevision: UInt64 = 0
    private var mutationTask: Task<Void, Never>?
    private var mutationTailRevision: UInt64 = 0
    private var activeCountdown: CountdownTimer?
    private var boundaryTask: Task<Void, Never>?
    private var boundaryRevision: UInt64 = 0
    private var currentStatus = GlanceProviderStatus.disabled

    public init(
        broker: any GlanceActivityBroker,
        clock: any GlanceClock = SystemGlanceClock()
    ) {
        self.broker = broker
        self.clock = clock
    }

    public func enable() async {
        await awaitDeactivationTail()
        if enabled {
            await activationTask?.value
            return
        }
        enabled = true
        generation &+= 1
        let activationGeneration = generation
        let activationOperationRevision = operationRevision
        let previousMutation = mutationTask
        mutationTailRevision &+= 1
        let activationTailRevision = mutationTailRevision
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: .starting
        )
        let task = Task { [weak self] in
            await previousMutation?.value
            guard let self else { return }
            await self.activateCurrentCountdown(
                generation: activationGeneration,
                operationRevision: activationOperationRevision
            )
        }
        mutationTask = task
        activationTask = task
        await task.value
        clearMutationTask(tailRevision: activationTailRevision)
        if enabled, generation == activationGeneration {
            activationTask = nil
        }
    }

    public func disable() async {
        if !enabled {
            await awaitDeactivationTail()
            return
        }
        enabled = false
        generation &+= 1
        let disableGeneration = generation
        operationRevision &+= 1
        let pendingActivation = activationTask
        activationTask = nil
        pendingActivation?.cancel()
        let pendingMutation = mutationTask
        let pendingMutationTailRevision = mutationTailRevision
        pendingMutation?.cancel()
        let boundary = takeBoundaryTask()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performDisable(
                pendingActivation: pendingActivation,
                pendingMutation: pendingMutation,
                pendingMutationTailRevision: pendingMutationTailRevision,
                boundary: boundary,
                generation: disableGeneration
            )
        }
        deactivationRevision &+= 1
        deactivationTask = task
        await task.value
    }

    /// Replaces the single active countdown. While disabled, this stores data but starts no work.
    public func setCountdown(_ countdown: CountdownTimer) async {
        operationRevision &+= 1
        let revision = operationRevision
        let previous = mutationTask
        mutationTailRevision &+= 1
        let tailRevision = mutationTailRevision
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.performSetCountdown(countdown, operationRevision: revision)
        }
        mutationTask = task
        await task.value
        clearMutationTask(tailRevision: tailRevision)
    }

    public func cancelCountdown() async {
        operationRevision &+= 1
        let revision = operationRevision
        let previous = mutationTask
        mutationTailRevision &+= 1
        let tailRevision = mutationTailRevision
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.performCancelCountdown(operationRevision: revision)
        }
        mutationTask = task
        await task.value
        clearMutationTask(tailRevision: tailRevision)
    }

    public func countdown() -> CountdownTimer? {
        activeCountdown
    }

    public func presentation(at date: Date) -> CountdownPresentation? {
        activeCountdown?.presentation(at: date)
    }

    public func status() -> GlanceProviderStatus {
        currentStatus
    }

    public func workState() -> GlanceProviderWorkState {
        GlanceProviderWorkState(
            activeObserverCount: 0,
            activeConsumerTaskCount: mutationTask == nil ? 0 : 1,
            scheduledBoundaryCount: boundaryTask == nil ? 0 : 1
        )
    }

    private func performSetCountdown(
        _ countdown: CountdownTimer,
        operationRevision: UInt64
    ) async {
        guard self.operationRevision == operationRevision else { return }
        let boundary = takeBoundaryTask()
        await boundary?.value
        guard self.operationRevision == operationRevision else { return }
        activeCountdown = countdown
        guard enabled else { return }
        await activateCountdown(
            countdown,
            generation: generation,
            operationRevision: operationRevision
        )
    }

    private func performCancelCountdown(operationRevision: UInt64) async {
        guard self.operationRevision == operationRevision else { return }
        let boundary = takeBoundaryTask()
        await boundary?.value
        guard self.operationRevision == operationRevision else { return }
        activeCountdown = nil
        guard enabled else { return }
        let lifecycleGeneration = generation
        _ = await broker.cancel(GlanceActivityIdentity.timer)
        guard isCurrent(
            generation: lifecycleGeneration,
            operationRevision: operationRevision,
            countdown: nil
        ) else { return }
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: .healthy
        )
    }

    private func activateCurrentCountdown(
        generation: UInt64,
        operationRevision: UInt64
    ) async {
        guard enabled,
              self.generation == generation,
              self.operationRevision == operationRevision else { return }
        guard let countdown = activeCountdown else {
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .healthy
            )
            return
        }
        await activateCountdown(
            countdown,
            generation: generation,
            operationRevision: operationRevision
        )
    }

    private func activateCountdown(
        _ countdown: CountdownTimer,
        generation: UInt64,
        operationRevision: UInt64
    ) async {
        guard isCurrent(
            generation: generation,
            operationRevision: operationRevision,
            countdown: countdown
        ) else { return }

        let now = await clock.now()
        guard isCurrent(
            generation: generation,
            operationRevision: operationRevision,
            countdown: countdown
        ) else { return }
        guard countdown.startedAt <= now else {
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .degraded(.invalidSourceData)
            )
            return
        }
        guard countdown.endsAt > now else {
            _ = await broker.cancel(GlanceActivityIdentity.timer)
            guard isCurrent(
                generation: generation,
                operationRevision: operationRevision,
                countdown: countdown
            ) else { return }
            activeCountdown = nil
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .healthy
            )
            return
        }

        let health: GlanceProviderHealth
        do {
            _ = try await broker.submit(GlanceRequestFactory.countdown(countdown, now: now))
            health = .healthy
        } catch {
            health = .degraded(.brokerRejected)
        }
        guard isCurrent(
            generation: generation,
            operationRevision: operationRevision,
            countdown: countdown
        ) else { return }
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: health
        )
        startExpiry(
            for: countdown,
            generation: generation,
            operationRevision: operationRevision
        )
    }

    private func performDisable(
        pendingActivation: Task<Void, Never>?,
        pendingMutation: Task<Void, Never>?,
        pendingMutationTailRevision: UInt64,
        boundary: Task<Void, Never>?,
        generation: UInt64
    ) async {
        await pendingActivation?.value
        await pendingMutation?.value
        await boundary?.value
        guard !enabled, self.generation == generation else { return }
        _ = await broker.cancel(GlanceActivityIdentity.timer)
        guard !enabled, self.generation == generation else { return }
        if mutationTailRevision == pendingMutationTailRevision {
            mutationTask = nil
        }
        currentStatus = .disabled
    }

    private func awaitDeactivationTail() async {
        while let task = deactivationTask {
            let revision = deactivationRevision
            await task.value
            if revision == deactivationRevision { return }
        }
    }

    private func clearMutationTask(tailRevision: UInt64) {
        guard mutationTailRevision == tailRevision else { return }
        mutationTask = nil
    }

    private func isCurrent(
        generation: UInt64,
        operationRevision: UInt64,
        countdown: CountdownTimer?
    ) -> Bool {
        enabled
            && self.generation == generation
            && self.operationRevision == operationRevision
            && activeCountdown == countdown
    }

    private func startExpiry(
        for countdown: CountdownTimer,
        generation: UInt64,
        operationRevision: UInt64
    ) {
        boundaryRevision &+= 1
        let revision = boundaryRevision
        let clock = self.clock
        boundaryTask = Task { [weak self] in
            do {
                try await clock.sleep(until: countdown.endsAt)
            } catch {
                await self?.boundaryStopped(revision: revision)
                return
            }
            await self?.expire(
                countdown,
                generation: generation,
                operationRevision: operationRevision,
                boundaryRevision: revision
            )
        }
    }

    private func expire(
        _ countdown: CountdownTimer,
        generation: UInt64,
        operationRevision: UInt64,
        boundaryRevision: UInt64
    ) async {
        guard isCurrent(
            generation: generation,
            operationRevision: operationRevision,
            countdown: countdown
        ), self.boundaryRevision == boundaryRevision else { return }
        _ = await broker.cancel(GlanceActivityIdentity.timer)
        guard isCurrent(
            generation: generation,
            operationRevision: operationRevision,
            countdown: countdown
        ), self.boundaryRevision == boundaryRevision else { return }
        boundaryTask = nil
        activeCountdown = nil
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: .healthy
        )
    }

    private func boundaryStopped(revision: UInt64) {
        guard boundaryRevision == revision else { return }
        boundaryTask = nil
    }

    private func takeBoundaryTask() -> Task<Void, Never>? {
        boundaryRevision &+= 1
        let task = boundaryTask
        boundaryTask = nil
        task?.cancel()
        return task
    }
}
