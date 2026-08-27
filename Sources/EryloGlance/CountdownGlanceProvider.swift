import EryloActivity
import Foundation

public actor CountdownGlanceProvider {
    private enum BrokerMutationError: Error {
        case rejected
    }

    private let broker: any GlanceActivityBroker
    private let ownershipBroker: (any GlanceOwnershipActivityBroker)?
    private let clock: any GlanceClock
    private let releaseCleanupToken = GlanceReleaseCleanupToken()
    private let legacyActivityLease = GlanceBrokerActivityLease(
        identity: GlanceActivityIdentity.timer
    )
    private var pendingOwnershipClaimIntent: ActivityOwnershipClaimIntent?
    private var brokerOwnershipLease: ActivityOwnershipLease?
    private var enabled = false
    private var generation: UInt64 = 0
    private var releaseCleanupGeneration: UInt64 = 0
    private var operationRevision: UInt64 = 0
    private var presentationDemandRevision: UInt64 = 0
    private var activationTask: Task<Void, Never>?
    private var deactivationTask: Task<Void, Never>?
    private var deactivationRevision: UInt64 = 0
    private var mutationTask: Task<Void, Never>?
    private var mutationTailRevision: UInt64 = 0
    private var activeCountdown: CountdownTimer?
    private var publishedActivityRevision: UInt64?
    private var currentPresentationDemand: CountdownPresentationDemand = .hidden
    private var boundaryTask: Task<Void, Never>?
    private var boundaryRevision: UInt64 = 0
    private var currentStatus = GlanceProviderStatus.disabled

    public init(
        broker: any GlanceActivityBroker,
        clock: any GlanceClock = SystemGlanceClock()
    ) {
        self.broker = broker
        ownershipBroker = broker as? any GlanceOwnershipActivityBroker
        self.clock = clock
    }

    deinit {
        guard releaseCleanupToken.claimFallback() else { return }

        let broker = broker
        let ownershipBroker = ownershipBroker
        let activation = activationTask
        let mutation = mutationTask
        let boundary = boundaryTask
        let pendingOwnershipClaimIntent = pendingOwnershipClaimIntent
        let brokerOwnershipLease = brokerOwnershipLease
        let legacyActivityLease = legacyActivityLease

        pendingOwnershipClaimIntent?.retire()
        brokerOwnershipLease?.beginRetirement()

        activation?.cancel()
        mutation?.cancel()
        boundary?.cancel()

        Task.detached {
            await activation?.value
            await mutation?.value
            await boundary?.value
            if let ownershipBroker, let brokerOwnershipLease {
                _ = await ownershipBroker.cancel(
                    brokerOwnershipLease.identity,
                    ifOwnedBy: brokerOwnershipLease
                )
                _ = await ownershipBroker.releaseOwnership(brokerOwnershipLease)
            } else if ownershipBroker == nil,
                      let revision = legacyActivityLease.ownedRevision() {
                if let revisionBroker = broker as? any GlanceRevisionActivityBroker {
                    _ = await revisionBroker.cancel(
                        legacyActivityLease.identity,
                        ifRevision: revision
                    )
                } else {
                    _ = await broker.cancel(legacyActivityLease.identity)
                }
                legacyActivityLease.retire(revision: revision)
            }
        }
    }

    public func enable() async {
        await awaitDeactivationTail()
        if enabled {
            await activationTask?.value
            return
        }
        enabled = true
        generation &+= 1
        releaseCleanupGeneration = releaseCleanupToken.activate()
        let activationGeneration = generation
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: .starting
        )
        if let ownershipBroker {
            guard let claimIntent = ownershipBroker.ownershipCoordinator.prepareClaim(
                for: GlanceActivityIdentity.timer
            ) else {
                currentStatus = GlanceProviderStatus(
                    isEnabled: true,
                    capability: .available,
                    health: .degraded(.brokerRejected)
                )
                return
            }
            pendingOwnershipClaimIntent = claimIntent
            let claimedLease = await ownershipBroker.claimOwnership(
                of: GlanceActivityIdentity.timer,
                admitting: claimIntent
            )
            if pendingOwnershipClaimIntent === claimIntent {
                pendingOwnershipClaimIntent = nil
            }
            guard enabled, generation == activationGeneration else {
                if let claimedLease {
                    claimedLease.beginRetirement()
                    _ = await ownershipBroker.releaseOwnership(claimedLease)
                }
                return
            }
            guard let claimedLease else {
                currentStatus = GlanceProviderStatus(
                    isEnabled: true,
                    capability: .available,
                    health: .degraded(.brokerRejected)
                )
                return
            }
            brokerOwnershipLease = claimedLease
        }
        let activationOperationRevision = operationRevision
        let previousMutation = mutationTask
        mutationTailRevision &+= 1
        let activationTailRevision = mutationTailRevision
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
            releaseCleanupToken.complete(generation: releaseCleanupGeneration)
            return
        }
        enabled = false
        generation &+= 1
        pendingOwnershipClaimIntent?.retire()
        pendingOwnershipClaimIntent = nil
        brokerOwnershipLease?.beginRetirement()
        let disableGeneration = generation
        operationRevision &+= 1
        publishedActivityRevision = nil
        presentationDemandRevision &+= 1
        let pendingActivation = activationTask
        activationTask = nil
        pendingActivation?.cancel()
        let pendingMutation = mutationTask
        let pendingMutationTailRevision = mutationTailRevision
        pendingMutation?.cancel()
        let boundary = takeBoundaryTask()
        let task = Task.detached { [weak self] in
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
        publishedActivityRevision = nil
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
        publishedActivityRevision = nil
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

    /// Cancels only when the caller still refers to the exact activity revision
    /// most recently published by this provider. Replacement and progress
    /// publication invalidate older revisions before cancellation can begin.
    @discardableResult
    public func cancelCountdown(ifPublishedRevision revision: UInt64) async -> Bool {
        guard enabled,
              activeCountdown != nil,
              publishedActivityRevision == revision else {
            return false
        }
        operationRevision &+= 1
        publishedActivityRevision = nil
        let operationRevision = operationRevision
        let previous = mutationTask
        mutationTailRevision &+= 1
        let tailRevision = mutationTailRevision
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.performCancelCountdown(operationRevision: operationRevision)
        }
        mutationTask = task
        await task.value
        clearMutationTask(tailRevision: tailRevision)
        return activeCountdown == nil
    }

    /// Controls second-level broker updates. Hidden timers retain only their expiry
    /// one-shot; visible timers schedule one successor one-shot at a time.
    public func setPresentationDemand(_ demand: CountdownPresentationDemand) async {
        presentationDemandRevision &+= 1
        let demandRevision = presentationDemandRevision
        let countdownRevision = operationRevision
        let previous = mutationTask
        mutationTailRevision &+= 1
        let tailRevision = mutationTailRevision
        let task = Task { [weak self] in
            await previous?.value
            await self?.performSetPresentationDemand(
                demand,
                operationRevision: countdownRevision,
                presentationDemandRevision: demandRevision
            )
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

    public func presentationDemand() -> CountdownPresentationDemand {
        currentPresentationDemand
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

    /// Deterministic package seam for observing mutation admission without
    /// waiting on a broker side effect that an earlier mutation may own.
    package func mutationQueueRevision() -> UInt64 {
        mutationTailRevision
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
        await cancelBrokerCountdown()
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

    private func performSetPresentationDemand(
        _ demand: CountdownPresentationDemand,
        operationRevision: UInt64,
        presentationDemandRevision: UInt64
    ) async {
        guard self.presentationDemandRevision == presentationDemandRevision else {
            return
        }
        let boundary = takeBoundaryTask()
        await boundary?.value
        guard self.presentationDemandRevision == presentationDemandRevision else {
            return
        }
        currentPresentationDemand = enabled ? demand : .hidden
        guard enabled, let countdown = activeCountdown else { return }

        if demand == .visible {
            await activateCountdown(
                countdown,
                generation: generation,
                operationRevision: operationRevision,
                requiredPresentationDemandRevision: presentationDemandRevision
            )
            return
        }

        let now = await clock.now()
        guard isCurrent(
            generation: generation,
            operationRevision: operationRevision,
            countdown: countdown,
            requiredPresentationDemandRevision: presentationDemandRevision
        ) else { return }
        if now >= countdown.endsAt {
            await expire(
                countdown,
                generation: generation,
                operationRevision: operationRevision,
                boundaryRevision: boundaryRevision,
                presentationDemandRevision: presentationDemandRevision
            )
        } else {
            startBoundary(
                for: countdown,
                now: now,
                generation: generation,
                operationRevision: operationRevision
            )
        }
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
        operationRevision: UInt64,
        requiredPresentationDemandRevision: UInt64? = nil
    ) async {
        guard isCurrent(
            generation: generation,
            operationRevision: operationRevision,
            countdown: countdown,
            requiredPresentationDemandRevision: requiredPresentationDemandRevision
        ) else { return }

        let now = await clock.now()
        guard isCurrent(
            generation: generation,
            operationRevision: operationRevision,
            countdown: countdown,
            requiredPresentationDemandRevision: requiredPresentationDemandRevision
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
            await cancelBrokerCountdown()
            guard isCurrent(
                generation: generation,
                operationRevision: operationRevision,
                countdown: countdown,
                requiredPresentationDemandRevision: requiredPresentationDemandRevision
            ) else { return }
            activeCountdown = nil
            publishedActivityRevision = nil
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .healthy
            )
            return
        }

        let result: Result<UInt64, any Error>
        do {
            result = .success(try await submitBrokerCountdown(
                GlanceRequestFactory.countdown(countdown, now: now)
            ))
        } catch {
            result = .failure(error)
        }
        guard isCurrent(
            generation: generation,
            operationRevision: operationRevision,
            countdown: countdown,
            requiredPresentationDemandRevision: requiredPresentationDemandRevision
        ) else { return }
        let health: GlanceProviderHealth
        switch result {
        case let .success(revision):
            publishedActivityRevision = revision
            health = .healthy
        case .failure:
            publishedActivityRevision = nil
            health = .degraded(.brokerRejected)
        }
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: health
        )
        startBoundary(
            for: countdown,
            now: now,
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
        await cancelBrokerCountdown()
        guard !enabled, self.generation == generation else { return }
        if let brokerOwnershipLease {
            _ = await ownershipBroker?.releaseOwnership(brokerOwnershipLease)
        }
        brokerOwnershipLease = nil
        if mutationTailRevision == pendingMutationTailRevision {
            mutationTask = nil
        }
        currentPresentationDemand = .hidden
        publishedActivityRevision = nil
        currentStatus = .disabled
        releaseCleanupToken.complete(generation: releaseCleanupGeneration)
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
        countdown: CountdownTimer?,
        requiredPresentationDemandRevision: UInt64? = nil
    ) -> Bool {
        guard enabled,
              self.generation == generation,
              self.operationRevision == operationRevision,
              activeCountdown == countdown else {
            return false
        }
        guard let requiredPresentationDemandRevision else { return true }
        return presentationDemandRevision == requiredPresentationDemandRevision
    }

    private func startBoundary(
        for countdown: CountdownTimer,
        now: Date,
        generation: UInt64,
        operationRevision: UInt64
    ) {
        let deadline: Date
        if currentPresentationDemand == .visible {
            let nextSecond = Date(
                timeIntervalSinceReferenceDate:
                    floor(now.timeIntervalSinceReferenceDate) + 1
            )
            deadline = min(
                nextSecond > now ? nextSecond : now.addingTimeInterval(1),
                countdown.endsAt
            )
        } else {
            deadline = countdown.endsAt
        }
        guard deadline > now else { return }

        boundaryRevision &+= 1
        let revision = boundaryRevision
        let demandRevision = presentationDemandRevision
        let clock = self.clock
        boundaryTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                await self?.boundaryStopped(revision: revision)
                return
            }
            await self?.boundaryReached(
                countdown,
                generation: generation,
                operationRevision: operationRevision,
                boundaryRevision: revision,
                presentationDemandRevision: demandRevision
            )
        }
    }

    private func boundaryReached(
        _ countdown: CountdownTimer,
        generation: UInt64,
        operationRevision: UInt64,
        boundaryRevision: UInt64,
        presentationDemandRevision: UInt64
    ) async {
        guard isCurrent(
            generation: generation,
            operationRevision: operationRevision,
            countdown: countdown,
            requiredPresentationDemandRevision: presentationDemandRevision
        ), self.boundaryRevision == boundaryRevision else { return }

        let now = await clock.now()
        guard isCurrent(
            generation: generation,
            operationRevision: operationRevision,
            countdown: countdown,
            requiredPresentationDemandRevision: presentationDemandRevision
        ), self.boundaryRevision == boundaryRevision else { return }
        if now >= countdown.endsAt {
            await expire(
                countdown,
                generation: generation,
                operationRevision: operationRevision,
                boundaryRevision: boundaryRevision,
                presentationDemandRevision: presentationDemandRevision
            )
            return
        }

        if currentPresentationDemand == .visible {
            let result: Result<UInt64, any Error>
            do {
                result = .success(try await submitBrokerCountdown(
                    GlanceRequestFactory.countdown(countdown, now: now)
                ))
            } catch {
                result = .failure(error)
            }
            guard isCurrent(
                generation: generation,
                operationRevision: operationRevision,
                countdown: countdown,
                requiredPresentationDemandRevision: presentationDemandRevision
            ), self.boundaryRevision == boundaryRevision else { return }
            let health: GlanceProviderHealth
            switch result {
            case let .success(revision):
                publishedActivityRevision = revision
                health = .healthy
            case .failure:
                publishedActivityRevision = nil
                health = .degraded(.brokerRejected)
            }
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: health
            )
        }
        boundaryTask = nil
        startBoundary(
            for: countdown,
            now: now,
            generation: generation,
            operationRevision: operationRevision
        )
    }

    private func expire(
        _ countdown: CountdownTimer,
        generation: UInt64,
        operationRevision: UInt64,
        boundaryRevision: UInt64,
        presentationDemandRevision: UInt64
    ) async {
        guard isCurrent(
            generation: generation,
            operationRevision: operationRevision,
            countdown: countdown,
            requiredPresentationDemandRevision: presentationDemandRevision
        ), self.boundaryRevision == boundaryRevision else { return }
        await cancelBrokerCountdown()
        guard isCurrent(
            generation: generation,
            operationRevision: operationRevision,
            countdown: countdown,
            requiredPresentationDemandRevision: presentationDemandRevision
        ), self.boundaryRevision == boundaryRevision else { return }
        boundaryTask = nil
        activeCountdown = nil
        publishedActivityRevision = nil
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: .healthy
        )
    }

    private func submitBrokerCountdown(_ request: ActivityRequest) async throws -> UInt64 {
        let snapshot: ActivityBrokerSnapshot
        if let ownershipBroker {
            guard let brokerOwnershipLease else {
                throw BrokerMutationError.rejected
            }
            guard let submitted = try await ownershipBroker.submit(
                request,
                ifOwnedBy: brokerOwnershipLease
            ) else {
                throw BrokerMutationError.rejected
            }
            snapshot = submitted
        } else {
            snapshot = try await broker.submit(request)
            legacyActivityLease.record(snapshot)
        }
        guard let published = snapshot.ordered.first(where: {
            $0.activity.identity == GlanceActivityIdentity.timer
        }) else {
            throw BrokerMutationError.rejected
        }
        return published.revision
    }

    private func cancelBrokerCountdown() async {
        if let ownershipBroker, let brokerOwnershipLease {
            _ = await ownershipBroker.cancel(
                brokerOwnershipLease.identity,
                ifOwnedBy: brokerOwnershipLease
            )
        } else if ownershipBroker == nil,
                  let revision = legacyActivityLease.ownedRevision() {
            if let revisionBroker = broker as? any GlanceRevisionActivityBroker {
                _ = await revisionBroker.cancel(
                    legacyActivityLease.identity,
                    ifRevision: revision
                )
            } else {
                _ = await broker.cancel(legacyActivityLease.identity)
            }
            legacyActivityLease.retire(revision: revision)
        }
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
