import EryloActivity
import Foundation

public actor CalendarGlanceProvider {
    private let broker: any GlanceActivityBroker
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
    private var boundaryRevision: UInt64 = 0
    private var currentStatus = GlanceProviderStatus.disabled

    public init(
        broker: any GlanceActivityBroker,
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
        let disableGeneration = generation
        refreshRevision &+= 1
        let boundary = takeBoundaryTask()
        let pendingActivation = activationTask
        activationTask = nil
        pendingActivation?.cancel()
        let consumer = finishEventRelay()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performDisable(
                pendingActivation: pendingActivation,
                consumer: consumer,
                boundary: boundary,
                generation: disableGeneration
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
                if granted {
                    authorization = .fullAccess
                } else {
                    authorization = await source.authorizationStatus()
                    guard enabled, self.generation == generation else { return }
                }
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
        consumer: Task<Void, Never>?,
        boundary: Task<Void, Never>?,
        generation: UInt64
    ) async {
        await pendingActivation?.value
        await source.stop()
        sourceActive = false
        await consumer?.value
        await boundary?.value
        guard !enabled, self.generation == generation else { return }
        _ = await broker.cancel(GlanceActivityIdentity.meeting)
        guard !enabled, self.generation == generation else { return }
        lastMeeting = nil
        currentStatus = .disabled
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
            guard enabled, self.generation == generation else { return }
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
        _ = await refresh(generation: generation, forceSubmission: true)
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
        _ = await refresh(generation: generation, forceSubmission: false)
    }

    /// Returns the query timestamp when the refresh completed for the current generation.
    private func refresh(
        generation: UInt64,
        forceSubmission: Bool,
        boundaryExecutionRevision: UInt64? = nil
    ) async -> Date? {
        refreshRevision &+= 1
        let queryRevision = refreshRevision
        let now = await clock.now()
        guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
            return nil
        }

        let meeting: CalendarMeeting?
        do {
            meeting = try await source.nextMeeting(
                after: now,
                until: now.addingTimeInterval(lookAhead.seconds)
            )
        } catch {
            guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
                return nil
            }
            if boundaryExecutionRevision == nil {
                await cancelBoundaryTask()
                guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
                    return nil
                }
            }
            _ = await broker.cancel(GlanceActivityIdentity.meeting)
            guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
                return nil
            }
            lastMeeting = nil
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .degraded(.sourceQueryFailed)
            )
            return now
        }

        guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
            return nil
        }

        guard let meeting else {
            let hadMeeting = lastMeeting != nil
            if boundaryExecutionRevision == nil {
                await cancelBoundaryTask()
                guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
                    return nil
                }
            }
            if hadMeeting {
                _ = await broker.cancel(GlanceActivityIdentity.meeting)
                guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
                    return nil
                }
            }
            lastMeeting = nil
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .healthy
            )
            return now
        }

        let changed = meeting != lastMeeting
        if changed || forceSubmission {
            do {
                _ = try await broker.submit(GlanceRequestFactory.meeting(meeting, now: now))
            } catch {
                guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
                    return nil
                }
                currentStatus = GlanceProviderStatus(
                    isEnabled: true,
                    capability: .available,
                    health: .degraded(.brokerRejected)
                )
                return nil
            }
            guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
                return nil
            }
        }

        lastMeeting = meeting
        if boundaryExecutionRevision == nil,
           changed || forceSubmission || boundaryTask == nil {
            await replaceBoundary(
                for: meeting,
                now: now,
                generation: generation,
                refreshRevision: queryRevision
            )
            guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
                return nil
            }
        }
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: .healthy
        )
        return now
    }

    private func isCurrentRefresh(generation: UInt64, revision: UInt64) -> Bool {
        enabled && self.generation == generation && refreshRevision == revision
    }

    private func replaceBoundary(
        for meeting: CalendarMeeting,
        now: Date,
        generation: UInt64,
        refreshRevision: UInt64
    ) async {
        let previous = takeBoundaryTask()
        await previous?.value
        guard isCurrentRefresh(generation: generation, revision: refreshRevision),
              lastMeeting == meeting else { return }
        startBoundary(for: meeting, now: now, generation: generation)
    }

    private func startBoundary(
        for meeting: CalendarMeeting,
        now: Date,
        generation: UInt64
    ) {
        let deadline = meeting.startDate > now ? meeting.startDate : meeting.endDate
        guard deadline > now else {
            boundaryTask = nil
            return
        }

        boundaryRevision &+= 1
        let revision = boundaryRevision
        let clock = self.clock
        boundaryTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                await self?.boundaryStopped(revision: revision)
                return
            }
            await self?.boundaryReached(
                meeting: meeting,
                generation: generation,
                revision: revision
            )
        }
    }

    private func boundaryReached(
        meeting: CalendarMeeting,
        generation: UInt64,
        revision: UInt64
    ) async {
        guard enabled,
              self.generation == generation,
              boundaryRevision == revision,
              lastMeeting == meeting else { return }
        let refreshDate = await refresh(
            generation: generation,
            forceSubmission: true,
            boundaryExecutionRevision: revision
        )
        guard enabled,
              self.generation == generation,
              boundaryRevision == revision else { return }
        boundaryTask = nil
        guard let refreshDate,
              let currentMeeting = lastMeeting else { return }
        startBoundary(
            for: currentMeeting,
            now: refreshDate,
            generation: generation
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

    private func cancelBoundaryTask() async {
        let task = takeBoundaryTask()
        await task?.value
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
