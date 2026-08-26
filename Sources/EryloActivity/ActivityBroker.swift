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

    private let expirationScheduler: any ActivityExpirationScheduling
    private var records: [ActivityIdentity: Record] = [:]
    private var expiryTasks: [ActivityIdentity: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<ActivityBrokerSnapshot>.Continuation] = [:]
    private var nextSubmissionSequence: UInt64 = 0
    private var nextActivityRevision: UInt64 = 0
    private var version: UInt64 = 0

    public init(
        expirationScheduler: any ActivityExpirationScheduling = ContinuousActivityExpirationScheduler()
    ) {
        self.expirationScheduler = expirationScheduler
    }

    deinit {
        expiryTasks.values.forEach { $0.cancel() }
        subscribers.values.forEach { $0.finish() }
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

    public func snapshot() -> ActivityBrokerSnapshot {
        makeSnapshot()
    }

    /// Newest-only buffering bounds each slow subscriber to one pending snapshot.
    public func snapshots() throws(ActivityBrokerError) -> AsyncStream<ActivityBrokerSnapshot> {
        guard subscribers.count < ActivityLimits.maximumSubscriberCount else {
            throw .subscriberCapacityExceeded(maximum: ActivityLimits.maximumSubscriberCount)
        }
        let subscriberID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: ActivityBrokerSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberID) }
        }
        subscribers[subscriberID] = continuation
        continuation.yield(makeSnapshot())
        return stream
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
        var terminatedSubscribers: [UUID] = []
        for (identifier, continuation) in subscribers {
            if case .terminated = continuation.yield(snapshot) {
                terminatedSubscribers.append(identifier)
            }
        }
        terminatedSubscribers.forEach { subscribers.removeValue(forKey: $0) }
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

    private func removeSubscriber(_ identifier: UUID) {
        subscribers.removeValue(forKey: identifier)
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
}
