import EryloActivity
import Foundation

/// Captures the newest callback delivered before `start()` returns, then hands
/// later callbacks to the bounded async relay. This makes synchronous platform
/// baselines part of activation settlement instead of racing the caller's status read.
package final class GlanceActivationEventRelay<Event: Sendable>: @unchecked Sendable {
    private enum State {
        case capturing(Event?)
        case settling(Event?)
        case live
        case finished
    }

    private let lock = NSLock()
    private let continuation: AsyncStream<Event>.Continuation
    private let beforePendingDelivery: (@Sendable () -> Void)?
    private var state: State = .capturing(nil)

    package init(
        continuation: AsyncStream<Event>.Continuation,
        beforePendingDelivery: (@Sendable () -> Void)? = nil
    ) {
        self.continuation = continuation
        self.beforePendingDelivery = beforePendingDelivery
    }

    package func yield(_ event: Event) {
        let shouldYield = lock.withLock {
            switch state {
            case .capturing:
                state = .capturing(event)
                return false
            case .settling:
                state = .settling(event)
                return false
            case .live:
                return true
            case .finished:
                return false
            }
        }
        if shouldYield {
            continuation.yield(event)
        }
    }

    /// Atomically extracts the synchronous baseline while retaining the newest
    /// callback that arrives while the provider awaits baseline processing.
    package func beginActivationSettlement() -> Event? {
        lock.withLock {
            switch state {
            case let .capturing(event):
                state = .settling(nil)
                return event
            case .settling, .live, .finished:
                return nil
            }
        }
    }

    /// Opens the live relay only after the initial event has settled. A callback
    /// captured during settlement is yielded afterward, preserving source order.
    package func completeActivation() {
        lock.withLock {
            switch state {
            case let .settling(event):
                if let event {
                    beforePendingDelivery?()
                    continuation.yield(event)
                }
                state = .live
            case .capturing, .live, .finished:
                return
            }
        }
    }

    package func finish() {
        let shouldFinish = lock.withLock {
            guard case .finished = state else {
                state = .finished
                return true
            }
            return false
        }
        if shouldFinish {
            continuation.finish()
        }
    }
}

public actor PowerGlanceProvider {
    private let broker: any GlanceActivityBroker
    private let source: any PowerEventSource
    private let presentationPolicy: BatteryPresentationPolicy
    private var enabled = false
    private var generation: UInt64 = 0
    private var sourceActive = false
    private var activationTask: Task<Void, Never>?
    private var deactivationTask: Task<Void, Never>?
    private var deactivationRevision: UInt64 = 0
    private var eventRelay: GlanceActivationEventRelay<PowerSourceEvent>?
    private var eventConsumerTask: Task<Void, Never>?
    private var lastEvent: PowerSourceEvent?
    private var lastSnapshot: PowerSnapshot?
    private var currentStatus = GlanceProviderStatus.disabled

    public init(
        broker: any GlanceActivityBroker,
        source: any PowerEventSource
    ) {
        self.init(
            broker: broker,
            source: source,
            presentationPolicy: .standard
        )
    }

    public init(
        broker: any GlanceActivityBroker,
        source: any PowerEventSource,
        presentationPolicy: BatteryPresentationPolicy
    ) {
        self.broker = broker
        self.source = source
        self.presentationPolicy = presentationPolicy
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
        let relay = installEventRelay(generation: activationGeneration)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.activate(
                generation: activationGeneration,
                relay: relay
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
        let task = Task.detached { [weak self] in
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

    /// Deterministic package seam for proving that the quiet first snapshot was
    /// consumed before a later change is injected. It performs no source work.
    package func latestProcessedSnapshot() -> PowerSnapshot? {
        lastSnapshot
    }

    private func activate(
        generation: UInt64,
        relay: GlanceActivationEventRelay<PowerSourceEvent>
    ) async {
        do {
            try await source.start { event in
                relay.yield(event)
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
            relay.finish()
            await source.stop()
            return
        }
        if let initialEvent = relay.beginActivationSettlement() {
            await receive(initialEvent, generation: generation)
        }
        guard enabled, self.generation == generation else {
            relay.finish()
            await source.stop()
            return
        }
        relay.completeActivation()
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
        lastSnapshot = nil
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
    ) -> GlanceActivationEventRelay<PowerSourceEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PowerSourceEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let relay = GlanceActivationEventRelay(continuation: continuation)
        eventRelay = relay
        eventConsumerTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(event, generation: generation)
            }
        }
        return relay
    }

    private func finishEventRelay() -> Task<Void, Never>? {
        eventRelay?.finish()
        eventRelay = nil
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
            let lifetime = presentationPolicy.lifetime(
                for: snapshot,
                previous: lastSnapshot
            )
            lastSnapshot = snapshot
            guard let request = GlanceRequestFactory.power(
                snapshot,
                lifetime: lifetime
            ) else {
                currentStatus = GlanceProviderStatus(
                    isEnabled: true,
                    capability: .available,
                    health: .healthy
                )
                return
            }
            do {
                _ = try await broker.submit(request)
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
    private let broker: any GlanceActivityBroker
    private let source: any VolumeEventSource
    private var enabled = false
    private var generation: UInt64 = 0
    private var sourceActive = false
    private var activationTask: Task<Void, Never>?
    private var deactivationTask: Task<Void, Never>?
    private var deactivationRevision: UInt64 = 0
    private var eventRelay: GlanceActivationEventRelay<VolumeSourceEvent>?
    private var eventConsumerTask: Task<Void, Never>?
    private var lastEvent: VolumeSourceEvent?
    private var lastSnapshot: VolumeSnapshot?
    private var currentStatus = GlanceProviderStatus.disabled

    public init(broker: any GlanceActivityBroker, source: any VolumeEventSource) {
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
        let relay = installEventRelay(generation: activationGeneration)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.activate(
                generation: activationGeneration,
                relay: relay
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
        let task = Task.detached { [weak self] in
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
        relay: GlanceActivationEventRelay<VolumeSourceEvent>
    ) async {
        do {
            try await source.start { event in
                relay.yield(event)
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
            relay.finish()
            await source.stop()
            return
        }
        if let initialEvent = relay.beginActivationSettlement() {
            await receive(initialEvent, generation: generation)
        }
        guard enabled, self.generation == generation else {
            relay.finish()
            await source.stop()
            return
        }
        relay.completeActivation()
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
        lastSnapshot = nil
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
    ) -> GlanceActivationEventRelay<VolumeSourceEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: VolumeSourceEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let relay = GlanceActivationEventRelay(continuation: continuation)
        eventRelay = relay
        eventConsumerTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(event, generation: generation)
            }
        }
        return relay
    }

    private func finishEventRelay() -> Task<Void, Never>? {
        eventRelay?.finish()
        eventRelay = nil
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
            guard let previous = lastSnapshot else {
                lastSnapshot = snapshot
                currentStatus = GlanceProviderStatus(
                    isEnabled: true,
                    capability: .available,
                    health: .healthy
                )
                return
            }
            lastSnapshot = snapshot
            guard let change = VolumePresentationChange.classify(
                previous: previous,
                current: snapshot
            ) else {
                currentStatus = GlanceProviderStatus(
                    isEnabled: true,
                    capability: .available,
                    health: .healthy
                )
                return
            }
            do {
                _ = try await broker.submit(
                    GlanceRequestFactory.volume(snapshot, change: change)
                )
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
