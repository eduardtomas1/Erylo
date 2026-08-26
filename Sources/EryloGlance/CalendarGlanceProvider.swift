import EryloActivity
import Foundation

private final class CalendarEventRelay: @unchecked Sendable {
    enum Trigger: Equatable, Sendable {
        case eventStore
        case system

        func merged(with other: Self) -> Self {
            if self == .system || other == .system { return .system }
            return .eventStore
        }
    }

    let stream: AsyncStream<Void>

    private let lock = NSLock()
    private let continuation: AsyncStream<Void>.Continuation
    private var pendingTrigger: Trigger?
    private var isFinished = false

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stream = stream
        self.continuation = continuation
    }

    func offer(_ event: CalendarSourceEvent) {
        let trigger: Trigger = switch event {
        case .eventStoreChanged:
            .eventStore
        case .wallClockChanged, .timeZoneChanged, .didWake:
            .system
        }

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        pendingTrigger = pendingTrigger.map { $0.merged(with: trigger) } ?? trigger
        lock.unlock()
        continuation.yield()
    }

    func takePendingTrigger() -> Trigger? {
        lock.lock()
        defer { lock.unlock() }
        let trigger = pendingTrigger
        pendingTrigger = nil
        return trigger
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        pendingTrigger = nil
        lock.unlock()
        continuation.finish()
    }
}

public actor CalendarGlanceProvider {
    private enum RefreshTrigger: Equatable {
        case activation
        case eventStore
        case system
        case boundary

        var forcesSubmission: Bool {
            switch self {
            case .activation, .system, .boundary:
                true
            case .eventStore:
                false
            }
        }

        var forcesBoundaryReplacement: Bool {
            switch self {
            case .activation, .system:
                true
            case .eventStore, .boundary:
                false
            }
        }
    }

    private enum BrokerMutationOutcome: Sendable {
        case submitted
        case submitFailed
        case cancelled
    }

    private let broker: any GlanceActivityBroker
    private let ownershipBroker: (any GlanceOwnershipActivityBroker)?
    private let source: any CalendarEventSource
    private let clock: any GlanceClock
    private let lookAhead: CalendarLookAhead
    private let presentationWindow: CalendarPresentationWindow
    private let releaseCleanupToken = GlanceReleaseCleanupToken()
    private let legacyActivityLease = GlanceBrokerActivityLease(
        identity: GlanceActivityIdentity.meeting
    )
    private var pendingOwnershipClaimIntent: ActivityOwnershipClaimIntent?
    private var brokerOwnershipLease: ActivityOwnershipLease?
    private var enabled = false
    private var generation: UInt64 = 0
    private var releaseCleanupGeneration: UInt64 = 0
    private var refreshRevision: UInt64 = 0
    private var sourceActive = false
    private var activationTask: Task<Void, Never>?
    private var deactivationTask: Task<Void, Never>?
    private var deactivationRevision: UInt64 = 0
    private var permissionTask: Task<
        Result<CalendarAuthorization, CalendarPermissionRequestError>,
        Never
    >?
    private var permissionRevision: UInt64 = 0
    private var eventRelay: CalendarEventRelay?
    private var eventConsumerTask: Task<Void, Never>?
    private var lastMeeting: CalendarMeeting?
    private var presentedMeeting: CalendarMeeting?
    private var boundaryTask: Task<Void, Never>?
    private var boundaryRevision: UInt64 = 0
    private var brokerMutationTask: Task<BrokerMutationOutcome, Never>?
    private var brokerMutationRevision: UInt64 = 0
    private var currentStatus = GlanceProviderStatus.disabled

    public init(
        broker: any GlanceActivityBroker,
        source: any CalendarEventSource,
        clock: any GlanceClock = SystemGlanceClock(),
        lookAhead: CalendarLookAhead = .sevenDays
    ) {
        self.init(
            broker: broker,
            source: source,
            clock: clock,
            lookAhead: lookAhead,
            presentationWindow: .standard
        )
    }

    public init(
        broker: any GlanceActivityBroker,
        source: any CalendarEventSource,
        clock: any GlanceClock = SystemGlanceClock(),
        lookAhead: CalendarLookAhead = .sevenDays,
        presentationWindow: CalendarPresentationWindow
    ) {
        self.broker = broker
        ownershipBroker = broker as? any GlanceOwnershipActivityBroker
        self.source = source
        self.clock = clock
        self.lookAhead = lookAhead
        self.presentationWindow = presentationWindow
    }

    deinit {
        guard releaseCleanupToken.claimFallback() else { return }

        let broker = broker
        let ownershipBroker = ownershipBroker
        let source = source
        let activation = activationTask
        let permission = permissionTask
        let relay = eventRelay
        let consumer = eventConsumerTask
        let boundary = boundaryTask
        let brokerMutation = brokerMutationTask
        let pendingOwnershipClaimIntent = pendingOwnershipClaimIntent
        let brokerOwnershipLease = brokerOwnershipLease
        let legacyActivityLease = legacyActivityLease

        pendingOwnershipClaimIntent?.retire()
        brokerOwnershipLease?.beginRetirement()

        relay?.finish()
        activation?.cancel()
        permission?.cancel()
        consumer?.cancel()
        boundary?.cancel()

        Task.detached {
            if let activation {
                await source.stop()
                await activation.value
            }
            await source.stop()
            await consumer?.value
            await boundary?.value
            _ = await brokerMutation?.value
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
            _ = await permission?.value
        }
    }

    /// Starts or restores the provider without ever requesting EventKit permission.
    /// If access is not determined, the provider stays enabled and idle with a
    /// `permissionRequired` capability until a contextual caller uses `requestFullAccess()`.
    public func enable() async {
        await awaitDeactivationTail()
        if enabled {
            await activationTask?.value
            guard enabled, !sourceActive, activationTask == nil else { return }
        } else {
            enabled = true
            generation &+= 1
            releaseCleanupGeneration = releaseCleanupToken.activate()
        }

        let activationGeneration = generation
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .unknownWhileDisabled,
            health: .starting
        )
        if let ownershipBroker, brokerOwnershipLease == nil {
            guard let claimIntent = ownershipBroker.ownershipCoordinator.prepareClaim(
                for: GlanceActivityIdentity.meeting
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
                of: GlanceActivityIdentity.meeting,
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

    /// Explicit permission seam for a contextual user action. Permission acquisition
    /// is independent of provider start; call `enable()` afterwards to start or resume.
    @discardableResult
    public func requestFullAccess() async throws(CalendarPermissionRequestError) -> CalendarAuthorization {
        await awaitDeactivationTail()

        let task: Task<
            Result<CalendarAuthorization, CalendarPermissionRequestError>,
            Never
        >
        let revision: UInt64
        if let permissionTask {
            task = permissionTask
            revision = permissionRevision
        } else {
            permissionRevision &+= 1
            revision = permissionRevision
            let source = self.source
            task = Task.detached {
                let authorization = await source.authorizationStatus()
                guard authorization == .notDetermined else {
                    return .success(authorization)
                }
                do {
                    let granted = try await source.requestFullAccess()
                    if granted { return .success(.fullAccess) }
                    return .success(await source.authorizationStatus())
                } catch {
                    return .failure(.requestFailed)
                }
            }
            permissionTask = task
        }

        let result = await task.value
        if permissionRevision == revision {
            permissionTask = nil
        }
        applyPermissionResultToStatus(result)
        return try result.get()
    }

    public func disable() async {
        if !enabled {
            await awaitDeactivationTail()
            let pendingPermission = permissionTask
            let revision = permissionRevision
            _ = await pendingPermission?.value
            if permissionRevision == revision {
                permissionTask = nil
            }
            await drainBrokerMutationTail()
            releaseCleanupToken.complete(generation: releaseCleanupGeneration)
            return
        }
        enabled = false
        generation &+= 1
        pendingOwnershipClaimIntent?.retire()
        pendingOwnershipClaimIntent = nil
        brokerOwnershipLease?.beginRetirement()
        let disableGeneration = generation
        refreshRevision &+= 1
        let boundary = takeBoundaryTask()
        let pendingActivation = activationTask
        activationTask = nil
        pendingActivation?.cancel()
        let pendingPermission = permissionTask
        let consumer = finishEventRelay()
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.performDisable(
                pendingActivation: pendingActivation,
                pendingPermission: pendingPermission,
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
            scheduledBoundaryCount: boundaryTask == nil ? 0 : 1,
            activeBrokerMutationCount: brokerMutationTask == nil ? 0 : 1
        )
    }

    private func performEnable(generation: UInt64) async {
        let authorization = await source.authorizationStatus()
        guard enabled, self.generation == generation else { return }
        guard authorization == .fullAccess else {
            applyUnavailableAuthorization(authorization)
            return
        }
        await beginObserving(generation: generation)
    }

    private func performDisable(
        pendingActivation: Task<Void, Never>?,
        pendingPermission: Task<
            Result<CalendarAuthorization, CalendarPermissionRequestError>,
            Never
        >?,
        consumer: Task<Void, Never>?,
        boundary: Task<Void, Never>?,
        generation: UInt64
    ) async {
        await pendingActivation?.value
        _ = await pendingPermission?.value
        await source.stop()
        sourceActive = false
        await consumer?.value
        await boundary?.value
        guard !enabled, self.generation == generation else { return }
        await cancelBrokerMeeting()
        guard !enabled, self.generation == generation else { return }
        if let brokerOwnershipLease {
            _ = await ownershipBroker?.releaseOwnership(brokerOwnershipLease)
        }
        brokerOwnershipLease = nil
        lastMeeting = nil
        presentedMeeting = nil
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

    private func beginObserving(generation: UInt64) async {
        let relay = installEventRelay(generation: generation)
        do {
            try await source.start { event in
                relay.offer(event)
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
        await refresh(generation: generation, trigger: .activation)
    }

    private func installEventRelay(
        generation: UInt64
    ) -> CalendarEventRelay {
        let relay = CalendarEventRelay()
        eventRelay = relay
        eventConsumerTask = Task { [weak self] in
            for await _ in relay.stream {
                guard !Task.isCancelled else { return }
                while let trigger = relay.takePendingTrigger() {
                    guard !Task.isCancelled else { return }
                    await self?.sourceChanged(trigger, generation: generation)
                }
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

    private func sourceChanged(
        _ trigger: CalendarEventRelay.Trigger,
        generation: UInt64
    ) async {
        guard enabled, self.generation == generation else { return }
        switch trigger {
        case .eventStore:
            await refresh(generation: generation, trigger: .eventStore)
        case .system:
            await refresh(generation: generation, trigger: .system)
        }
    }

    private func refresh(
        generation: UInt64,
        trigger: RefreshTrigger
    ) async {
        refreshRevision &+= 1
        let queryRevision = refreshRevision
        let now = await clock.now()
        guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
            return
        }

        let meeting: CalendarMeeting?
        do {
            meeting = try await source.nextMeeting(
                after: now,
                until: now.addingTimeInterval(lookAhead.seconds)
            )
        } catch {
            guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
                return
            }
            await clearPresentationAndBoundary(
                generation: generation,
                refreshRevision: queryRevision,
                cancelBoundary: trigger != .boundary
            )
            guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
                return
            }
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .degraded(.sourceQueryFailed)
            )
            return
        }

        guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
            return
        }
        guard let meeting else {
            await clearPresentationAndBoundary(
                generation: generation,
                refreshRevision: queryRevision,
                cancelBoundary: trigger != .boundary
            )
            guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
                return
            }
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .available,
                health: .healthy
            )
            return
        }

        let meetingChanged = meeting != lastMeeting
        let shouldPresent = presentationWindow.contains(meeting, at: now)
        if shouldPresent {
            if trigger.forcesSubmission || presentedMeeting != meeting {
                let submitted = await submitBrokerMeeting(
                    GlanceRequestFactory.meeting(meeting, now: now)
                )
                if !submitted {
                    guard isCurrentRefresh(
                        generation: generation,
                        revision: queryRevision
                    ) else { return }
                    currentStatus = GlanceProviderStatus(
                        isEnabled: true,
                        capability: .available,
                        health: .degraded(.brokerRejected)
                    )
                    lastMeeting = meeting
                    if trigger != .boundary {
                        await replaceBoundaryIfNeeded(
                            for: meeting,
                            now: now,
                            generation: generation,
                            refreshRevision: queryRevision,
                            force: trigger.forcesBoundaryReplacement || meetingChanged
                        )
                    }
                    return
                }
                guard isCurrentRefresh(
                    generation: generation,
                    revision: queryRevision
                ) else { return }
            }
            presentedMeeting = meeting
        } else {
            guard await clearBrokerPresentation(
                generation: generation,
                refreshRevision: queryRevision
            ) else { return }
        }

        lastMeeting = meeting
        if trigger != .boundary {
            await replaceBoundaryIfNeeded(
                for: meeting,
                now: now,
                generation: generation,
                refreshRevision: queryRevision,
                force: trigger.forcesBoundaryReplacement || meetingChanged
            )
        }
        guard isCurrentRefresh(generation: generation, revision: queryRevision) else {
            return
        }
        currentStatus = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: .healthy
        )
    }

    private func clearPresentationAndBoundary(
        generation: UInt64,
        refreshRevision: UInt64,
        cancelBoundary: Bool
    ) async {
        if cancelBoundary {
            let boundary = takeBoundaryTask()
            await boundary?.value
        }
        guard await clearBrokerPresentation(
            generation: generation,
            refreshRevision: refreshRevision
        ) else { return }
        lastMeeting = nil
    }

    private func clearBrokerPresentation(
        generation: UInt64,
        refreshRevision: UInt64
    ) async -> Bool {
        guard isCurrentRefresh(
            generation: generation,
            revision: refreshRevision
        ) else { return false }
        await cancelBrokerMeeting()
        guard isCurrentRefresh(
            generation: generation,
            revision: refreshRevision
        ) else { return false }
        presentedMeeting = nil
        return true
    }

    private func isCurrentRefresh(generation: UInt64, revision: UInt64) -> Bool {
        enabled && self.generation == generation && refreshRevision == revision
    }

    private func replaceBoundaryIfNeeded(
        for meeting: CalendarMeeting,
        now: Date,
        generation: UInt64,
        refreshRevision: UInt64,
        force: Bool
    ) async {
        guard force || boundaryTask == nil else { return }
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
        guard let deadline = presentationWindow.nextBoundary(for: meeting, at: now),
              deadline > now else {
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
        await refresh(generation: generation, trigger: .boundary)
        guard enabled,
              self.generation == generation,
              boundaryRevision == revision else { return }
        boundaryTask = nil
        guard let currentMeeting = lastMeeting else { return }
        let now = await clock.now()
        guard enabled,
              self.generation == generation,
              boundaryRevision == revision,
              lastMeeting == currentMeeting else { return }
        startBoundary(for: currentMeeting, now: now, generation: generation)
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

    private func submitBrokerMeeting(_ request: ActivityRequest) async -> Bool {
        let ownershipBroker = ownershipBroker
        let brokerOwnershipLease = brokerOwnershipLease
        let legacyActivityLease = legacyActivityLease
        let outcome = await enqueueBrokerMutation { broker in
            do {
                if let ownershipBroker {
                    guard let brokerOwnershipLease,
                          try await ownershipBroker.submit(
                            request,
                            ifOwnedBy: brokerOwnershipLease
                          ) != nil else {
                        return .submitFailed
                    }
                } else {
                    let snapshot = try await broker.submit(request)
                    legacyActivityLease.record(snapshot)
                }
                return .submitted
            } catch {
                return .submitFailed
            }
        }
        if case .submitted = outcome { return true }
        return false
    }

    private func cancelBrokerMeeting() async {
        let ownershipBroker = ownershipBroker
        let brokerOwnershipLease = brokerOwnershipLease
        let legacyActivityLease = legacyActivityLease
        _ = await enqueueBrokerMutation { broker in
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
            return .cancelled
        }
    }

    private func enqueueBrokerMutation(
        _ operation: @escaping @Sendable (
            any GlanceActivityBroker
        ) async -> BrokerMutationOutcome
    ) async -> BrokerMutationOutcome {
        brokerMutationRevision &+= 1
        let revision = brokerMutationRevision
        let previous = brokerMutationTask
        let broker = self.broker
        let task = Task.detached {
            _ = await previous?.value
            return await operation(broker)
        }
        brokerMutationTask = task
        let outcome = await task.value
        if brokerMutationRevision == revision {
            brokerMutationTask = nil
        }
        return outcome
    }

    private func drainBrokerMutationTail() async {
        while let task = brokerMutationTask {
            let revision = brokerMutationRevision
            _ = await task.value
            if brokerMutationRevision == revision {
                brokerMutationTask = nil
                return
            }
        }
    }

    private func applyPermissionResultToStatus(
        _ result: Result<CalendarAuthorization, CalendarPermissionRequestError>
    ) {
        guard enabled, !sourceActive else { return }
        switch result {
        case let .success(authorization):
            if authorization == .fullAccess {
                currentStatus = GlanceProviderStatus(
                    isEnabled: true,
                    capability: .available,
                    health: .starting
                )
            } else {
                applyUnavailableAuthorization(authorization)
            }
        case .failure:
            currentStatus = GlanceProviderStatus(
                isEnabled: true,
                capability: .permissionRequired,
                health: .unavailable(.permissionRequestFailed)
            )
        }
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
                health: .healthy
            )
        case .fullAccess:
            break
        }
    }
}
