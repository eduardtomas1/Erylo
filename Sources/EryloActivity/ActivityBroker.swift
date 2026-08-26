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

    public init(scheduledExpiryCount: Int, subscriberCount: Int) {
        self.scheduledExpiryCount = scheduledExpiryCount
        self.subscriberCount = subscriberCount
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
    }

    private struct Subscriber: Sendable {
        let token: ActivityBrokerSubscriptionToken
        let continuation: AsyncStream<ActivityBrokerSnapshot>.Continuation
    }

    private let expirationScheduler: any ActivityExpirationScheduling
    private var records: [ActivityIdentity: Record] = [:]
    private var expiryTasks: [ActivityIdentity: Task<Void, Never>] = [:]
    private var subscribers: [UUID: Subscriber] = [:]
    private var nextSubmissionSequence: UInt64 = 0
    private var nextActivityRevision: UInt64 = 0
    private var nextSubscriberGeneration: UInt64 = 0
    private var version: UInt64 = 0

    public init(
        expirationScheduler: any ActivityExpirationScheduling = ContinuousActivityExpirationScheduler()
    ) {
        self.expirationScheduler = expirationScheduler
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
            expiryRevision: nil
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
        guard records.removeValue(forKey: identity) != nil else { return false }
        expiryTasks.removeValue(forKey: identity)?.cancel()
        _ = publishMutation()
        return true
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
        ActivityBrokerWorkState(
            scheduledExpiryCount: expiryTasks.count,
            subscriberCount: subscribers.count
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
        records.removeValue(forKey: identity)
        expiryTasks.removeValue(forKey: identity)
        _ = publishMutation()
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
