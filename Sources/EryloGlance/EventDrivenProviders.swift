import EryloActivity
import Foundation

public actor PowerGlanceProvider {
    private let broker: ActivityBroker
    private let source: any PowerEventSource
    private var enabled = false
    private var generation: UInt64 = 0
    private var sourceActive = false
    private var activationTask: Task<Void, Never>?
    private var deactivationTask: Task<Void, Never>?
    private var deactivationRevision: UInt64 = 0
    private var eventContinuation: AsyncStream<PowerSourceEvent>.Continuation?
    private var eventConsumerTask: Task<Void, Never>?
    private var lastEvent: PowerSourceEvent?
    private var currentStatus = GlanceProviderStatus.disabled

    public init(broker: ActivityBroker, source: any PowerEventSource) {
        self.broker = broker
        self.source = source
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
        let continuation = installEventRelay(generation: activationGeneration)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.activate(
                generation: activationGeneration,
                continuation: continuation
            )
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
        let consumer = finishEventRelay()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performDisable(
                pendingActivation: pendingActivation,
                consumer: consumer
            )
        }
        deactivationRevision &+= 1
        deactivationTask = task
        await task.value
    }

    public func status() -> GlanceProviderStatus {
        currentStatus
    }

    public func workState() -> GlanceProviderWorkState {
        GlanceProviderWorkState(
            activeObserverCount: sourceActive ? 1 : 0,
            activeConsumerTaskCount: eventConsumerTask == nil ? 0 : 1,
            scheduledBoundaryCount: 0
        )
    }

    private func activate(
        generation: UInt64,
        continuation: AsyncStream<PowerSourceEvent>.Continuation
    ) async {
        do {
            try await source.start { event in
                continuation.yield(event)
            }
        } catch {
            await source.stop()
            guard enabled, self.generation == generation else { return }
            sourceActive = false
            let consumer = finishEventRelay()
            await consumer?.value
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .unavailable,
                health: .unavailable(.eventSourceUnavailable)
            )
            return
        }

        guard enabled, self.generation == generation else {
            await source.stop()
            return
        }
        sourceActive = true
        if currentStatus.health == .starting {
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .healthy
            )
        }
    }

    private func performDisable(
        pendingActivation: Task<Void, Never>?,
        consumer: Task<Void, Never>?
    ) async {
        await pendingActivation?.value
        await source.stop()
        sourceActive = false
        await consumer?.value
        lastEvent = nil
        currentStatus = .disabled
        _ = await broker.cancel(GlanceActivityIdentity.battery)
    }

    private func awaitDeactivationTail() async {
        while let task = deactivationTask {
            let revision = deactivationRevision
            await task.value
            if revision == deactivationRevision { return }
        }
    }

    private func installEventRelay(
        generation: UInt64
    ) -> AsyncStream<PowerSourceEvent>.Continuation {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PowerSourceEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        eventContinuation = continuation
        eventConsumerTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(event, generation: generation)
            }
        }
        return continuation
    }

    private func finishEventRelay() -> Task<Void, Never>? {
        eventContinuation?.finish()
        eventContinuation = nil
        let consumer = eventConsumerTask
        eventConsumerTask = nil
        consumer?.cancel()
        return consumer
    }

    private func receive(_ event: PowerSourceEvent, generation: UInt64) async {
        guard enabled, self.generation == generation else { return }
        guard event != lastEvent else { return }
        lastEvent = event

        switch event {
        case let .snapshot(snapshot):
            do {
                _ = try await broker.submit(GlanceRequestFactory.power(snapshot))
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
        case .unavailable:
            _ = await broker.cancel(GlanceActivityIdentity.battery)
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .unavailable,
                health: .unavailable(.eventSourceUnavailable)
            )
        }
    }
}

public actor VolumeGlanceProvider {
    private let broker: ActivityBroker
    private let source: any VolumeEventSource
    private var enabled = false
    private var generation: UInt64 = 0
    private var sourceActive = false
    private var activationTask: Task<Void, Never>?
    private var deactivationTask: Task<Void, Never>?
    private var deactivationRevision: UInt64 = 0
    private var eventContinuation: AsyncStream<VolumeSourceEvent>.Continuation?
    private var eventConsumerTask: Task<Void, Never>?
    private var lastEvent: VolumeSourceEvent?
    private var currentStatus = GlanceProviderStatus.disabled

    public init(broker: ActivityBroker, source: any VolumeEventSource) {
        self.broker = broker
        self.source = source
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
        let continuation = installEventRelay(generation: activationGeneration)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.activate(
                generation: activationGeneration,
                continuation: continuation
            )
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
        let consumer = finishEventRelay()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performDisable(
                pendingActivation: pendingActivation,
                consumer: consumer
            )
        }
        deactivationRevision &+= 1
        deactivationTask = task
        await task.value
    }

    public func status() -> GlanceProviderStatus {
        currentStatus
    }

    public func workState() -> GlanceProviderWorkState {
        GlanceProviderWorkState(
            activeObserverCount: sourceActive ? 1 : 0,
            activeConsumerTaskCount: eventConsumerTask == nil ? 0 : 1,
            scheduledBoundaryCount: 0
        )
    }

    private func activate(
        generation: UInt64,
        continuation: AsyncStream<VolumeSourceEvent>.Continuation
    ) async {
        do {
            try await source.start { event in
                continuation.yield(event)
            }
        } catch {
            await source.stop()
            guard enabled, self.generation == generation else { return }
            sourceActive = false
            let consumer = finishEventRelay()
            await consumer?.value
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .unavailable,
                health: .unavailable(.eventSourceUnavailable)
            )
            return
        }

        guard enabled, self.generation == generation else {
            await source.stop()
            return
        }
        sourceActive = true
        if currentStatus.health == .starting {
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .healthy
            )
        }
    }

    private func performDisable(
        pendingActivation: Task<Void, Never>?,
        consumer: Task<Void, Never>?
    ) async {
        await pendingActivation?.value
        await source.stop()
        sourceActive = false
        await consumer?.value
        lastEvent = nil
        currentStatus = .disabled
        _ = await broker.cancel(GlanceActivityIdentity.volume)
    }

    private func awaitDeactivationTail() async {
        while let task = deactivationTask {
            let revision = deactivationRevision
            await task.value
            if revision == deactivationRevision { return }
        }
    }

    private func installEventRelay(
        generation: UInt64
    ) -> AsyncStream<VolumeSourceEvent>.Continuation {
        let (stream, continuation) = AsyncStream.makeStream(
            of: VolumeSourceEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        eventContinuation = continuation
        eventConsumerTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(event, generation: generation)
            }
        }
        return continuation
    }

    private func finishEventRelay() -> Task<Void, Never>? {
        eventContinuation?.finish()
        eventContinuation = nil
        let consumer = eventConsumerTask
        eventConsumerTask = nil
        consumer?.cancel()
        return consumer
    }

    private func receive(_ event: VolumeSourceEvent, generation: UInt64) async {
        guard enabled, self.generation == generation else { return }
        guard event != lastEvent else { return }
        lastEvent = event

        switch event {
        case let .snapshot(snapshot):
            do {
                _ = try await broker.submit(GlanceRequestFactory.volume(snapshot))
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
        case .unavailable:
            _ = await broker.cancel(GlanceActivityIdentity.volume)
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .unavailable,
                health: .unavailable(.eventSourceUnavailable)
            )
        }
    }
}
