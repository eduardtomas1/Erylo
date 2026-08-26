import EryloActivity
import Foundation

public actor CountdownGlanceProvider {
    private let broker: ActivityBroker
    private let clock: any GlanceClock
    private var enabled = false
    private var generation: UInt64 = 0
    private var activationTask: Task<Void, Never>?
    private var deactivationTask: Task<Void, Never>?
    private var deactivationRevision: UInt64 = 0
    private var activeCountdown: CountdownTimer?
    private var boundaryTask: Task<Void, Never>?
    private var currentStatus = GlanceProviderStatus.disabled

    public init(
        broker: ActivityBroker,
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
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: .starting
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.activateCurrentCountdown(generation: activationGeneration)
        }
        activationTask = task
        await task.value
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
        let pendingActivation = activationTask
        activationTask = nil
        pendingActivation?.cancel()
        boundaryTask?.cancel()
        boundaryTask = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performDisable(pendingActivation: pendingActivation)
        }
        deactivationRevision &+= 1
        deactivationTask = task
        await task.value
    }

    /// Replaces the single active countdown. While disabled, this stores data but starts no work.
    public func setCountdown(_ countdown: CountdownTimer) async {
        generation &+= 1
        boundaryTask?.cancel()
        boundaryTask = nil
        activeCountdown = countdown
        guard enabled else { return }
        await activateCurrentCountdown(generation: generation)
    }

    public func cancelCountdown() async {
        generation &+= 1
        boundaryTask?.cancel()
        boundaryTask = nil
        activeCountdown = nil
        if enabled {
            _ = await broker.cancel(GlanceActivityIdentity.timer)
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .healthy
            )
        }
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
            activeConsumerTaskCount: 0,
            scheduledBoundaryCount: boundaryTask == nil ? 0 : 1
        )
    }

    private func activateCurrentCountdown(generation: UInt64) async {
        guard enabled, self.generation == generation else { return }
        guard let countdown = activeCountdown else {
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .healthy
            )
            return
        }

        let now = await clock.now()
        guard enabled,
              self.generation == generation,
              activeCountdown == countdown else { return }
        guard countdown.startedAt <= now else {
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .degraded(.invalidSourceData)
            )
            return
        }
        guard countdown.endsAt > now else {
            activeCountdown = nil
            _ = await broker.cancel(GlanceActivityIdentity.timer)
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .healthy
            )
            return
        }

        do {
            _ = try await broker.submit(GlanceRequestFactory.countdown(countdown, now: now))
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .healthy
            )
        } catch {
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .degraded(.brokerRejected)
            )
        }
        guard enabled,
              self.generation == generation,
              activeCountdown == countdown else { return }
        scheduleExpiry(for: countdown, generation: generation)
    }

    private func performDisable(pendingActivation: Task<Void, Never>?) async {
        await pendingActivation?.value
        boundaryTask?.cancel()
        boundaryTask = nil
        currentStatus = .disabled
        _ = await broker.cancel(GlanceActivityIdentity.timer)
    }

    private func awaitDeactivationTail() async {
        while let task = deactivationTask {
            let revision = deactivationRevision
            await task.value
            if revision == deactivationRevision { return }
        }
    }

    private func scheduleExpiry(for countdown: CountdownTimer, generation: UInt64) {
        boundaryTask?.cancel()
        let clock = self.clock
        boundaryTask = Task { [weak self] in
            do {
                try await clock.sleep(until: countdown.endsAt)
            } catch {
                return
            }
            await self?.expire(countdown, generation: generation)
        }
    }

    private func expire(_ countdown: CountdownTimer, generation: UInt64) async {
        guard enabled,
              self.generation == generation,
              activeCountdown == countdown else { return }
        boundaryTask = nil
        activeCountdown = nil
        _ = await broker.cancel(GlanceActivityIdentity.timer)
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: .healthy
        )
    }
}
