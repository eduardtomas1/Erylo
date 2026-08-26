import Foundation

public protocol ActivityExpirationScheduling: Sendable {
    /// Suspends once for the supplied duration. Implementations must not repeat or poll.
    func sleep(for duration: Duration) async throws
}

public struct ContinuousActivityExpirationScheduler: ActivityExpirationScheduling {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

public struct PresentedActivity: Equatable, Sendable {
    public let activity: Activity
    public let submissionSequence: UInt64
    public let revision: UInt64

    public init(activity: Activity, submissionSequence: UInt64, revision: UInt64) {
        self.activity = activity
        self.submissionSequence = submissionSequence
        self.revision = revision
    }
}

public struct ActivityBrokerSnapshot: Equatable, Sendable {
    public let version: UInt64
    public let current: PresentedActivity?
    public let queued: [PresentedActivity]

    public init(version: UInt64, current: PresentedActivity?, queued: [PresentedActivity]) {
        self.version = version
        self.current = current
        self.queued = queued
    }

    public var ordered: [PresentedActivity] {
        if let current { [current] + queued } else { queued }
    }
}

public struct ActivityBrokerWorkState: Equatable, Sendable {
    public let scheduledExpiryCount: Int
    public let subscriberCount: Int
    public let activeOwnershipCount: Int
    public let pendingOwnershipIntentCount: Int

    public init(scheduledExpiryCount: Int, subscriberCount: Int) {
        self.scheduledExpiryCount = scheduledExpiryCount
        self.subscriberCount = subscriberCount
        activeOwnershipCount = 0
        pendingOwnershipIntentCount = 0
    }

    public init(
        scheduledExpiryCount: Int,
        subscriberCount: Int,
        activeOwnershipCount: Int
    ) {
        self.scheduledExpiryCount = scheduledExpiryCount
        self.subscriberCount = subscriberCount
        self.activeOwnershipCount = activeOwnershipCount
        pendingOwnershipIntentCount = 0
    }

    public init(
        scheduledExpiryCount: Int,
        subscriberCount: Int,
        activeOwnershipCount: Int,
        pendingOwnershipIntentCount: Int
    ) {
        self.scheduledExpiryCount = scheduledExpiryCount
        self.subscriberCount = subscriberCount
        self.activeOwnershipCount = activeOwnershipCount
        self.pendingOwnershipIntentCount = pendingOwnershipIntentCount
    }
}

public struct ActivityOwnershipWorkState: Equatable, Sendable {
    public let retainedIdentityCount: Int
    public let pendingIntentCount: Int
    public let activeLeaseCount: Int

    public init(
        retainedIdentityCount: Int,
        pendingIntentCount: Int,
        activeLeaseCount: Int
    ) {
        self.retainedIdentityCount = retainedIdentityCount
        self.pendingIntentCount = pendingIntentCount
        self.activeLeaseCount = activeLeaseCount
    }
}

public final class ActivityOwnershipClaimIntent: @unchecked Sendable {
    public let identity: ActivityIdentity
    fileprivate let sequence: UInt64
    fileprivate let coordinator: ActivityOwnershipCoordinator

    private let lock = NSLock()
    private var consumed = false

    fileprivate init(
        identity: ActivityIdentity,
        sequence: UInt64,
        coordinator: ActivityOwnershipCoordinator
    ) {
        self.identity = identity
        self.sequence = sequence
        self.coordinator = coordinator
    }

    deinit {
        lock.lock()
        let shouldAbandon = !consumed
        consumed = true
        lock.unlock()
        if shouldAbandon {
            coordinator.abandon(identity: identity, sequence: sequence)
        }
    }

    fileprivate func consume(by coordinator: ActivityOwnershipCoordinator) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed, self.coordinator === coordinator else { return false }
        consumed = true
        return true
    }

    /// Retires a not-yet-forwarded claim synchronously. A wrapper may still
    /// deliver the token later, but admission will reject it without mutation.
    package func retire() {
        guard consume(by: coordinator) else { return }
        coordinator.abandon(identity: identity, sequence: sequence)
    }
}

public final class ActivityOwnershipCoordinator: @unchecked Sendable {
    private struct Lane {
        var nextSequence: UInt64 = 0
        var latestSequence: UInt64 = 0
        var pendingSequences: Set<UInt64> = []
        var activeSequences: Set<UInt64> = []
    }

    private let lock = NSLock()
    private var lanes: [ActivityIdentity: Lane] = [:]
    private var pendingIntentCount = 0

    public init() {}

    /// Establishes caller order synchronously, before a claim crosses an async
    /// broker or wrapper boundary. The returned intent cannot be forged or reused.
    public func prepareClaim(
        for identity: ActivityIdentity
    ) -> ActivityOwnershipClaimIntent? {
        lock.lock()
        defer { lock.unlock() }
        guard lanes[identity] != nil
                || lanes.count < ActivityLimits.maximumOwnershipCount else {
            return nil
        }
        guard pendingIntentCount < ActivityLimits.maximumOwnershipIntentCount else {
            return nil
        }
        var lane = lanes[identity] ?? Lane()
        precondition(
            lane.nextSequence < UInt64.max,
            "ActivityBroker ownership intent space exhausted"
        )
        lane.nextSequence += 1
        lane.latestSequence = lane.nextSequence
        lane.pendingSequences.insert(lane.nextSequence)
        pendingIntentCount += 1
        lanes[identity] = lane
        return ActivityOwnershipClaimIntent(
            identity: identity,
            sequence: lane.nextSequence,
            coordinator: self
        )
    }

    public func workState() -> ActivityOwnershipWorkState {
        lock.lock()
        defer { lock.unlock() }
        return ActivityOwnershipWorkState(
            retainedIdentityCount: lanes.count,
            pendingIntentCount: pendingIntentCount,
            activeLeaseCount: lanes.values.reduce(0) {
                $0 + $1.activeSequences.count
            }
        )
    }

    fileprivate func admit(
        _ intent: ActivityOwnershipClaimIntent,
        for identity: ActivityIdentity
    ) -> UInt64? {
        guard intent.consume(by: self) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let intentIdentity = intent.identity
        guard var lane = lanes[intentIdentity],
              lane.pendingSequences.remove(intent.sequence) != nil else {
            return nil
        }
        pendingIntentCount -= 1
        guard intentIdentity == identity,
              lane.latestSequence == intent.sequence else {
            storeOrPrune(lane, for: intentIdentity)
            return nil
        }
        lane.activeSequences.removeAll(keepingCapacity: true)
        lane.activeSequences.insert(intent.sequence)
        lanes[intentIdentity] = lane
        return intent.sequence
    }

    fileprivate func release(identity: ActivityIdentity, sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard var lane = lanes[identity] else { return }
        lane.activeSequences.remove(sequence)
        storeOrPrune(lane, for: identity)
    }

    fileprivate func invalidateClaims(for identity: ActivityIdentity) {
        lock.lock()
        defer { lock.unlock() }
        guard var lane = lanes[identity] else { return }
        precondition(
            lane.nextSequence < UInt64.max,
            "ActivityBroker ownership intent space exhausted"
        )
        lane.nextSequence += 1
        lane.latestSequence = lane.nextSequence
        lane.activeSequences.removeAll(keepingCapacity: true)
        storeOrPrune(lane, for: identity)
    }

    fileprivate func abandon(identity: ActivityIdentity, sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard var lane = lanes[identity],
              lane.pendingSequences.remove(sequence) != nil else { return }
        pendingIntentCount -= 1
        storeOrPrune(lane, for: identity)
    }

    private func storeOrPrune(_ lane: Lane, for identity: ActivityIdentity) {
        if lane.pendingSequences.isEmpty, lane.activeSequences.isEmpty {
            lanes.removeValue(forKey: identity)
        } else {
            lanes[identity] = lane
        }
    }
}

public final class ActivityOwnershipLease: @unchecked Sendable {
    private enum State: Equatable {
        case active
        case retiring
        case finished
    }

    public let identity: ActivityIdentity
    fileprivate let generation: UInt64
    fileprivate let admissionSequence: UInt64
    fileprivate let coordinator: ActivityOwnershipCoordinator

    private let lock = NSLock()
    private var state = State.active

    fileprivate init(
        identity: ActivityIdentity,
        generation: UInt64,
        admissionSequence: UInt64,
        coordinator: ActivityOwnershipCoordinator
    ) {
        self.identity = identity
        self.generation = generation
        self.admissionSequence = admissionSequence
        self.coordinator = coordinator
    }

    /// Synchronously closes admission for future submissions. Cleanup may still
    /// conditionally remove this generation until `finishRetirement()` is called.
    package func beginRetirement() {
        lock.lock()
        if state == .active { state = .retiring }
        lock.unlock()
    }

    package func finishRetirement() {
        lock.lock()
        state = .finished
        lock.unlock()
    }

    fileprivate func withSubmissionAdmission(
        _ operation: () throws(ActivityBrokerError) -> ActivityBrokerSnapshot
    ) throws(ActivityBrokerError) -> ActivityBrokerSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else { return nil }
        return try operation()
    }

    fileprivate func withCleanupAdmission<Result>(_ operation: () -> Result) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard state != .finished else { return nil }
        return operation()
    }
}

/// Package-scoped ownership token for a single snapshot-stream registration.
/// The generation prevents a retired stream from removing a later reuse of the same identifier.
package struct ActivityBrokerSubscriptionToken: Equatable, Hashable, Sendable {
    package let subscriberID: UUID
    package let generation: UInt64

    package init(subscriberID: UUID, generation: UInt64) {
        self.subscriberID = subscriberID
        self.generation = generation
    }
}

package struct ActivityBrokerSnapshotSubscription: Sendable {
    package let token: ActivityBrokerSubscriptionToken
    package let stream: AsyncStream<ActivityBrokerSnapshot>

    package init(
        token: ActivityBrokerSubscriptionToken,
        stream: AsyncStream<ActivityBrokerSnapshot>
    ) {
        self.token = token
        self.stream = stream
    }
}

package enum ActivityBrokerSubscriptionError: Error, Equatable, Sendable {
    case duplicateSubscriberIdentifier
    case capacityExceeded(maximum: Int)
}

/// Owns validation, identity-based dedupe, ordering, preemption, expiry, and cancellation.
///
/// Ordering is deterministic: higher priority first, then original submission sequence (FIFO),
/// then canonical `source:identifier` lexical order as a defensive final tie-breaker.
/// Replacing an existing identity preserves that sequence, so a same-priority update keeps its place.
/// Each expiring identity owns exactly one cancellable one-shot task. A revision token prevents a
/// cancelled or delayed task from expiring a newer replacement.
public actor ActivityBroker {
    private struct Record: Sendable {
        var presented: PresentedActivity
        var expiryRevision: UInt64?
        var ownershipGeneration: UInt64?
    }

    private struct Subscriber: Sendable {
        let token: ActivityBrokerSubscriptionToken
        let continuation: AsyncStream<ActivityBrokerSnapshot>.Continuation
    }

    private let expirationScheduler: any ActivityExpirationScheduling
    public nonisolated let ownershipCoordinator: ActivityOwnershipCoordinator
    private var records: [ActivityIdentity: Record] = [:]
    private var expiryTasks: [ActivityIdentity: Task<Void, Never>] = [:]
    private var subscribers: [UUID: Subscriber] = [:]
    private var nextSubmissionSequence: UInt64 = 0
    private var nextActivityRevision: UInt64 = 0
    private var nextSubscriberGeneration: UInt64 = 0
    private var nextOwnershipGeneration: UInt64 = 0
    private var ownershipGenerations: [ActivityIdentity: UInt64] = [:]
    private var version: UInt64 = 0

    public init(
        expirationScheduler: any ActivityExpirationScheduling = ContinuousActivityExpirationScheduler()
    ) {
        self.expirationScheduler = expirationScheduler
        ownershipCoordinator = ActivityOwnershipCoordinator()
    }

    deinit {
        expiryTasks.values.forEach { $0.cancel() }
        subscribers.values.forEach { $0.continuation.finish() }
    }

    /// Validates and atomically inserts or replaces a request. Identity is the dedupe key.
    @discardableResult
    public func submit(_ request: ActivityRequest) throws(ActivityBrokerError) -> ActivityBrokerSnapshot {
        let activity: Activity
        do {
            activity = try Activity(validating: request)
        } catch {
            throw .invalid(error)
        }
        if records[activity.identity] == nil,
           records.count >= ActivityLimits.maximumActivityCount {
            throw .activityCapacityExceeded(maximum: ActivityLimits.maximumActivityCount)
        }
        ownershipCoordinator.invalidateClaims(for: activity.identity)
        ownershipGenerations.removeValue(forKey: activity.identity)
        return try submit(activity, ownershipGeneration: nil)
    }

    /// Claims the next cross-instance generation for one identity. Takeover also
    /// removes any predecessor presentation in this actor turn, so an unavailable
    /// successor cannot strand the old generation's record. Unique live claims
    /// are bounded and must be released when their owner retires.
    public func claimOwnership(
        of identity: ActivityIdentity,
        admitting intent: ActivityOwnershipClaimIntent
    ) -> ActivityOwnershipLease? {
        guard let admissionSequence = ownershipCoordinator.admit(
            intent,
            for: identity
        ) else { return nil }
        precondition(
            nextOwnershipGeneration < UInt64.max,
            "ActivityBroker ownership generation space exhausted"
        )
        nextOwnershipGeneration += 1
        ownershipGenerations[identity] = nextOwnershipGeneration
        if records.removeValue(forKey: identity) != nil {
            expiryTasks.removeValue(forKey: identity)?.cancel()
            _ = publishMutation()
        }
        return ActivityOwnershipLease(
            identity: identity,
            generation: nextOwnershipGeneration,
            admissionSequence: admissionSequence,
            coordinator: ownershipCoordinator
        )
    }

    /// Releases only the exact current generation. A stale owner can finish its
    /// local lease but cannot prune a successor's admission state.
    @discardableResult
    public func releaseOwnership(_ lease: ActivityOwnershipLease) -> Bool {
        lease.beginRetirement()
        defer { lease.finishRetirement() }
        guard lease.coordinator === ownershipCoordinator else { return false }
        ownershipCoordinator.release(
            identity: lease.identity,
            sequence: lease.admissionSequence
        )
        guard ownershipGenerations[lease.identity] == lease.generation else {
            return false
        }
        ownershipGenerations.removeValue(forKey: lease.identity)
        return true
    }

    /// Submits only while this lease is active and remains the latest generation.
    /// Lease admission is held through the mutation, so concurrent retirement
    /// cannot pass the check and then race the record replacement.
    public func submit(
        _ request: ActivityRequest,
        ifOwnedBy lease: ActivityOwnershipLease
    ) throws(ActivityBrokerError) -> ActivityBrokerSnapshot? {
        let activity: Activity
        do {
            activity = try Activity(validating: request)
        } catch {
            throw .invalid(error)
        }
        guard activity.identity == lease.identity,
              ownershipGenerations[lease.identity] == lease.generation else {
            return nil
        }
        return try lease.withSubmissionAdmission {
            () throws(ActivityBrokerError) -> ActivityBrokerSnapshot in
            try submit(activity, ownershipGeneration: lease.generation)
        }
    }

    private func submit(
        _ activity: Activity,
        ownershipGeneration: UInt64?
    ) throws(ActivityBrokerError) -> ActivityBrokerSnapshot {
        let identity = activity.identity
        let submissionSequence: UInt64

        if let existing = records[identity] {
            submissionSequence = existing.presented.submissionSequence
        } else {
            guard records.count < ActivityLimits.maximumActivityCount else {
                throw .activityCapacityExceeded(maximum: ActivityLimits.maximumActivityCount)
            }
            submissionSequence = allocateSubmissionSequence()
        }

        let revision = allocateActivityRevision()
        expiryTasks.removeValue(forKey: identity)?.cancel()
        records[identity] = Record(
            presented: PresentedActivity(
                activity: activity,
                submissionSequence: submissionSequence,
                revision: revision
            ),
            expiryRevision: nil,
            ownershipGeneration: ownershipGeneration
        )

        if case let .expires(ttl) = activity.lifecycle {
            records[identity]?.expiryRevision = revision
            scheduleExpiry(for: identity, ttl: ttl, revision: revision)
        }

        return publishMutation()
    }

    /// Removes one identity explicitly. Returns false and publishes nothing when it is absent.
    @discardableResult
    public func cancel(_ identity: ActivityIdentity) -> Bool {
        ownershipCoordinator.invalidateClaims(for: identity)
        ownershipGenerations.removeValue(forKey: identity)
        return removeRecord(identity)
    }

    /// Removes one identity only when it still has the caller-owned revision.
    /// The comparison and removal occur in this single actor-isolated operation,
    /// with no suspension point between them.
    @discardableResult
    public func cancel(_ identity: ActivityIdentity, ifRevision revision: UInt64) -> Bool {
        guard records[identity]?.presented.revision == revision else { return false }
        ownershipCoordinator.invalidateClaims(for: identity)
        ownershipGenerations.removeValue(forKey: identity)
        return removeRecord(identity)
    }

    /// Removes the identity only while this lease remains the latest generation.
    /// A retiring lease may clean up its own generation, but a successor claim
    /// makes the older cleanup fail closed before it can touch shared state.
    @discardableResult
    public func cancel(_ identity: ActivityIdentity, ifOwnedBy lease: ActivityOwnershipLease) -> Bool {
        guard identity == lease.identity,
              ownershipGenerations[identity] == lease.generation,
              records[identity]?.ownershipGeneration == lease.generation else {
            return false
        }
        return lease.withCleanupAdmission {
            removeRecord(identity)
        } ?? false
    }

    /// Atomically rejects an action that no longer belongs to the current broker revision.
    @discardableResult
    public func cancelCurrentAction(
        identity: ActivityIdentity,
        revision: UInt64,
        actionIdentifier: String,
        intent: ActivityActionIntent
    ) -> Bool {
        guard let current = makeSnapshot().current,
              current.activity.identity == identity,
              current.revision == revision,
              current.activity.action?.identifier == actionIdentifier,
              current.activity.action?.intent == intent else {
            return false
        }
        ownershipCoordinator.invalidateClaims(for: identity)
        ownershipGenerations.removeValue(forKey: identity)
        records.removeValue(forKey: identity)
        expiryTasks.removeValue(forKey: identity)?.cancel()
        _ = publishMutation()
        return true
    }

    public func snapshot() -> ActivityBrokerSnapshot {
        makeSnapshot()
    }

    /// Newest-only buffering bounds each slow subscriber to one pending snapshot.
    public func snapshots() throws(ActivityBrokerError) -> AsyncStream<ActivityBrokerSnapshot> {
        guard subscribers.count < ActivityLimits.maximumSubscriberCount else {
            throw .subscriberCapacityExceeded(maximum: ActivityLimits.maximumSubscriberCount)
        }
        var subscriberID = UUID()
        while subscribers[subscriberID] != nil {
            subscriberID = UUID()
        }
        return registerSnapshotSubscription(subscriberID: subscriberID).stream
    }

    /// Package owners receive an immutable token so cancellation and stream termination cannot
    /// affect a later registration that reuses the same logical identifier.
    package func snapshotSubscription(
        subscriberID: UUID
    ) throws(ActivityBrokerSubscriptionError) -> ActivityBrokerSnapshotSubscription {
        guard subscribers[subscriberID] == nil else {
            throw .duplicateSubscriberIdentifier
        }
        guard subscribers.count < ActivityLimits.maximumSubscriberCount else {
            throw .capacityExceeded(maximum: ActivityLimits.maximumSubscriberCount)
        }
        return registerSnapshotSubscription(subscriberID: subscriberID)
    }

    private func registerSnapshotSubscription(
        subscriberID: UUID
    ) -> ActivityBrokerSnapshotSubscription {
        let token = ActivityBrokerSubscriptionToken(
            subscriberID: subscriberID,
            generation: allocateSubscriberGeneration()
        )
        let (stream, continuation) = AsyncStream.makeStream(
            of: ActivityBrokerSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(token) }
        }
        subscribers[subscriberID] = Subscriber(token: token, continuation: continuation)
        continuation.yield(makeSnapshot())
        return ActivityBrokerSnapshotSubscription(token: token, stream: stream)
    }

    package func cancelSnapshotSubscription(_ token: ActivityBrokerSubscriptionToken) {
        guard subscribers[token.subscriberID]?.token == token else { return }
        subscribers.removeValue(forKey: token.subscriberID)?.continuation.finish()
    }

    public func workState() -> ActivityBrokerWorkState {
        let ownershipWork = ownershipCoordinator.workState()
        return ActivityBrokerWorkState(
            scheduledExpiryCount: expiryTasks.count,
            subscriberCount: subscribers.count,
            activeOwnershipCount: ownershipWork.retainedIdentityCount,
            pendingOwnershipIntentCount: ownershipWork.pendingIntentCount
        )
    }

    private func scheduleExpiry(for identity: ActivityIdentity, ttl: ActivityTTL, revision: UInt64) {
        let scheduler = expirationScheduler
        expiryTasks[identity] = Task { [weak self] in
            do {
                try await scheduler.sleep(for: ttl.duration)
            } catch {
                await self?.expiryStopped(identity, revision: revision)
                return
            }
            await self?.expire(identity, revision: revision)
        }
    }

    private func expire(_ identity: ActivityIdentity, revision: UInt64) {
        guard records[identity]?.expiryRevision == revision else { return }
        if let ownershipGeneration = records[identity]?.ownershipGeneration,
           ownershipGenerations[identity] == ownershipGeneration {
            ownershipCoordinator.invalidateClaims(for: identity)
            ownershipGenerations.removeValue(forKey: identity)
        }
        records.removeValue(forKey: identity)
        expiryTasks.removeValue(forKey: identity)
        _ = publishMutation()
    }

    @discardableResult
    private func removeRecord(_ identity: ActivityIdentity) -> Bool {
        guard records.removeValue(forKey: identity) != nil else { return false }
        expiryTasks.removeValue(forKey: identity)?.cancel()
        _ = publishMutation()
        return true
    }

    private func expiryStopped(_ identity: ActivityIdentity, revision: UInt64) {
        guard records[identity]?.expiryRevision == revision else { return }
        records[identity]?.expiryRevision = nil
        expiryTasks.removeValue(forKey: identity)
    }

    private func publishMutation() -> ActivityBrokerSnapshot {
        precondition(version < UInt64.max, "ActivityBroker snapshot version space exhausted")
        version += 1
        let snapshot = makeSnapshot()
        var terminatedSubscribers: [ActivityBrokerSubscriptionToken] = []
        for subscriber in subscribers.values {
            if case .terminated = subscriber.continuation.yield(snapshot) {
                terminatedSubscribers.append(subscriber.token)
            }
        }
        terminatedSubscribers.forEach { removeSubscriber($0) }
        return snapshot
    }

    private func makeSnapshot() -> ActivityBrokerSnapshot {
        let ordered = records.values.map(\.presented).sorted(by: Self.isOrderedBefore)
        return ActivityBrokerSnapshot(
            version: version,
            current: ordered.first,
            queued: Array(ordered.dropFirst())
        )
    }

    private static func isOrderedBefore(_ lhs: PresentedActivity, _ rhs: PresentedActivity) -> Bool {
        if lhs.activity.priority != rhs.activity.priority {
            return lhs.activity.priority > rhs.activity.priority
        }
        if lhs.submissionSequence != rhs.submissionSequence {
            return lhs.submissionSequence < rhs.submissionSequence
        }
        let lhsKey = lhs.activity.identity.source.rawValue + ":" + lhs.activity.identity.identifier.rawValue
        let rhsKey = rhs.activity.identity.source.rawValue + ":" + rhs.activity.identity.identifier.rawValue
        return lhsKey < rhsKey
    }

    private func removeSubscriber(_ token: ActivityBrokerSubscriptionToken) {
        guard subscribers[token.subscriberID]?.token == token else { return }
        subscribers.removeValue(forKey: token.subscriberID)
    }

    private func allocateSubmissionSequence() -> UInt64 {
        precondition(nextSubmissionSequence < UInt64.max, "ActivityBroker submission sequence space exhausted")
        nextSubmissionSequence += 1
        return nextSubmissionSequence
    }

    private func allocateActivityRevision() -> UInt64 {
        precondition(nextActivityRevision < UInt64.max, "ActivityBroker revision space exhausted")
        nextActivityRevision += 1
        return nextActivityRevision
    }

    private func allocateSubscriberGeneration() -> UInt64 {
        precondition(nextSubscriberGeneration < UInt64.max, "ActivityBroker subscriber generation space exhausted")
        nextSubscriberGeneration += 1
        return nextSubscriberGeneration
    }
}
