import EryloActivity
import Foundation

public actor CalendarGlanceProvider {
    private let broker: ActivityBroker
    private let source: any CalendarEventSource
    private let clock: any GlanceClock
    private let lookAhead: CalendarLookAhead
    private var enabled = false
    private var generation: UInt64 = 0
    private var refreshRevision: UInt64 = 0
    private var sourceActive = false
    private var activationTask: Task<Void, Never>?
    private var deactivationTask: Task<Void, Never>?
    private var deactivationRevision: UInt64 = 0
    private var eventContinuation: AsyncStream<Void>.Continuation?
    private var eventConsumerTask: Task<Void, Never>?
    private var lastMeeting: CalendarMeeting?
    private var boundaryTask: Task<Void, Never>?
    private var currentStatus = GlanceProviderStatus.disabled

    public init(
        broker: ActivityBroker,
        source: any CalendarEventSource,
        clock: any GlanceClock = SystemGlanceClock(),
        lookAhead: CalendarLookAhead = .sevenDays
    ) {
        self.broker = broker
        self.source = source
        self.clock = clock
        self.lookAhead = lookAhead
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
            capability: .unknownWhileDisabled,
            health: .starting
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performEnable(generation: activationGeneration)
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
        refreshRevision &+= 1
        boundaryTask?.cancel()
        boundaryTask = nil
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
            scheduledBoundaryCount: boundaryTask == nil ? 0 : 1
        )
    }

    private func performEnable(generation: UInt64) async {
        var authorization = await source.authorizationStatus()
        guard enabled, self.generation == generation else { return }

        if authorization == .notDetermined {
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .permissionRequired,
                health: .starting
            )
            do {
                let granted = try await source.requestFullAccess()
                guard enabled, self.generation == generation else { return }
                authorization = granted ? .fullAccess : await source.authorizationStatus()
            } catch {
                guard enabled, self.generation == generation else { return }
                currentStatus = GlanceProviderStatus(
                    isEnabled: true,
                    capability: .permissionRequired,
                    health: .unavailable(.permissionRequestFailed)
                )
                return
            }
        }

        guard authorization == .fullAccess else {
            applyUnavailableAuthorization(authorization)
            return
        }
        await beginObserving(generation: generation)
    }

    private func performDisable(
        pendingActivation: Task<Void, Never>?,
        consumer: Task<Void, Never>?
    ) async {
        await pendingActivation?.value
        await source.stop()
        sourceActive = false
        await consumer?.value
        lastMeeting = nil
        currentStatus = .disabled
        _ = await broker.cancel(GlanceActivityIdentity.meeting)
    }

    private func awaitDeactivationTail() async {
        while let task = deactivationTask {
            let revision = deactivationRevision
            await task.value
            if revision == deactivationRevision { return }
        }
    }

    private func beginObserving(generation: UInt64) async {
        let continuation = installEventRelay(generation: generation)
        do {
            try await source.start {
                continuation.yield()
            }
        } catch {
            await source.stop()
            guard enabled, self.generation == generation else { return }
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
            let consumer = finishEventRelay()
            await consumer?.value
            return
        }
        sourceActive = true
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: .healthy
        )
        await refresh(generation: generation, forceSubmission: true)
    }

    private func installEventRelay(
        generation: UInt64
    ) -> AsyncStream<Void>.Continuation {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        eventContinuation = continuation
        eventConsumerTask = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await self?.sourceChanged(generation: generation)
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

    private func sourceChanged(generation: UInt64) async {
        guard enabled, self.generation == generation else { return }
        await refresh(generation: generation, forceSubmission: false)
    }

    private func refresh(generation: UInt64, forceSubmission: Bool) async {
        refreshRevision &+= 1
        let queryRevision = refreshRevision
        let now = await clock.now()
        guard enabled,
              self.generation == generation,
              refreshRevision == queryRevision else { return }

        let meeting: CalendarMeeting?
        do {
            meeting = try await source.nextMeeting(
                after: now,
                until: now.addingTimeInterval(lookAhead.seconds)
            )
        } catch {
            guard enabled,
                  self.generation == generation,
                  refreshRevision == queryRevision else { return }
            boundaryTask?.cancel()
            boundaryTask = nil
            lastMeeting = nil
            _ = await broker.cancel(GlanceActivityIdentity.meeting)
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .degraded(.sourceQueryFailed)
            )
            return
        }

        guard enabled,
              self.generation == generation,
              refreshRevision == queryRevision else { return }

        guard let meeting else {
            let hadMeeting = lastMeeting != nil
            lastMeeting = nil
            boundaryTask?.cancel()
            boundaryTask = nil
            if hadMeeting {
                _ = await broker.cancel(GlanceActivityIdentity.meeting)
            }
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .healthy
            )
            return
        }

        let changed = meeting != lastMeeting
        if changed || forceSubmission {
            do {
                _ = try await broker.submit(GlanceRequestFactory.meeting(meeting, now: now))
            } catch {
                currentStatus = GlanceProviderStatus(
                    isEnabled: true,
                    capability: .available,
                    health: .degraded(.brokerRejected)
                )
                return
            }
        }

        lastMeeting = meeting
        if changed || forceSubmission || boundaryTask == nil {
            scheduleBoundary(for: meeting, now: now, generation: generation)
        }
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: .healthy
        )
    }

    private func scheduleBoundary(
        for meeting: CalendarMeeting,
        now: Date,
        generation: UInt64
    ) {
        boundaryTask?.cancel()
        let deadline = meeting.startDate > now ? meeting.startDate : meeting.endDate
        guard deadline > now else {
            boundaryTask = nil
            return
        }

        let clock = self.clock
        boundaryTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            await self?.boundaryReached(
                meeting: meeting,
                generation: generation
            )
        }
    }

    private func boundaryReached(meeting: CalendarMeeting, generation: UInt64) async {
        guard enabled,
              self.generation == generation,
              lastMeeting == meeting else { return }
        boundaryTask = nil
        await refresh(generation: generation, forceSubmission: true)
    }

    private func applyUnavailableAuthorization(_ authorization: CalendarAuthorization) {
        switch authorization {
        case .denied, .writeOnly:
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .permissionDenied,
                health: .unavailable(.permissionDenied)
            )
        case .restricted:
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .restricted,
                health: .unavailable(.permissionRestricted)
            )
        case .notDetermined:
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .permissionRequired,
                health: .unavailable(.permissionRequestFailed)
            )
        case .fullAccess:
            break
        }
    }
}
