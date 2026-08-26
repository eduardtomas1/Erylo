import Darwin
import EryloActivity
import Foundation

@main
enum ActivityHarnessMain {
    static func main() async {
        var harness = ActivityHarness()
        await harness.verifyPriorityFIFOAndPreemption()
        await harness.verifyDedupeAndUpdate()
        await harness.verifyExpiryAndStaleTaskCancellation()
        await harness.verifyStaleExpiryGeneration()
        await harness.verifyExplicitCancellation()
        await harness.verifyDeclarativeAction()
        await harness.verifyFileHoldSchemaValues()
        await harness.verifyValidation()
        await harness.verifyActivityCapacity()
        await harness.verifySnapshotBackpressureAndLifecycle()
        await harness.verifySubscriberCapacity()
        await harness.verifySubscriberIdentityIsolation()
        await harness.verifyZeroRepeatingIdleWork()
        harness.finish()
    }
}

private struct ActivityHarness {
    private var checkCount = 0
    private var failures: [String] = []

    mutating func verifyPriorityFIFOAndPreemption() async {
        let broker = ActivityBroker()
        do {
            _ = try await broker.submit(request(id: "first", priority: 50))
            let tied = try await broker.submit(request(id: "second", priority: 50))
            check(identifiers(in: tied) == ["first", "second"], "equal priorities remain FIFO")

            let preempted = try await broker.submit(request(id: "urgent", priority: 75))
            check(preempted.current?.activity.identity.identifier.rawValue == "urgent", "higher priority preempts current")
            check(identifiers(in: preempted) == ["urgent", "first", "second"], "preemption preserves queued FIFO order")

            let lower = try await broker.submit(request(id: "background", priority: 25))
            check(lower.current?.activity.identity.identifier.rawValue == "urgent", "lower priority queues without preemption")
        } catch {
            recordUnexpected(error, context: "priority and preemption")
        }
    }

    mutating func verifyDedupeAndUpdate() async {
        let broker = ActivityBroker()
        do {
            let initial = try await broker.submit(request(id: "same", priority: 50, title: "Initial"))
            _ = try await broker.submit(request(id: "peer", priority: 50))
            let updated = try await broker.submit(request(id: "same", priority: 50, title: "Updated"))

            check(updated.ordered.count == 2, "identity update deduplicates instead of appending")
            check(identifiers(in: updated) == ["same", "peer"], "same-priority update retains original FIFO position")
            check(updated.current?.activity.presentation.title == "Updated", "dedupe atomically replaces presentation")
            check(
                updated.current?.submissionSequence == initial.current?.submissionSequence,
                "dedupe preserves original submission sequence"
            )
            check(updated.current?.revision != initial.current?.revision, "dedupe assigns a new revision")

            let reprioritized = try await broker.submit(request(id: "same", priority: 10, title: "Lower"))
            check(reprioritized.current?.activity.identity.identifier.rawValue == "peer", "priority update recomputes current selection")
        } catch {
            recordUnexpected(error, context: "dedupe and update")
        }
    }

    mutating func verifyExpiryAndStaleTaskCancellation() async {
        let scheduler = ManualExpirationScheduler()
        let broker = ActivityBroker(expirationScheduler: scheduler)
        do {
            _ = try await broker.submit(request(id: "fallback", priority: 25))
            _ = try await broker.submit(request(id: "ephemeral", priority: 75, ttlMilliseconds: 123))
            check(await waitUntil { await scheduler.totalSleepCount == 1 }, "TTL creates one one-shot expiry task")
            check(await scheduler.pendingDurations == [.milliseconds(123)], "expiry scheduler receives exact TTL")

            await scheduler.fireOldest()
            check(
                await waitUntil { await broker.snapshot().current?.activity.identity.identifier.rawValue == "fallback" },
                "expiry removes current and selects queued fallback"
            )
            check(await broker.workState().scheduledExpiryCount == 0, "fired expiry task is released")

            _ = try await broker.submit(request(id: "replace", priority: 50, ttlMilliseconds: 10))
            check(await waitUntil { await scheduler.totalSleepCount == 2 }, "first replacement expiry starts")
            _ = try await broker.submit(request(id: "replace", priority: 50, title: "Replacement", ttlMilliseconds: 20))
            check(await waitUntil { await scheduler.totalSleepCount == 3 }, "updated expiry starts a fresh one-shot task")
            check(await waitUntil { await scheduler.cancellationCount == 1 }, "update cancels the stale expiry task")
            check(await scheduler.pendingDurations == [.milliseconds(20)], "only replacement expiry remains pending")
            check(await broker.snapshot().ordered.contains { $0.activity.presentation.title == "Replacement" }, "stale cancellation leaves replacement live")

            await scheduler.fireOldest()
            check(
                await waitUntil { await broker.snapshot().ordered.allSatisfy { $0.activity.identity.identifier.rawValue != "replace" } },
                "replacement expires only from its own task"
            )
        } catch {
            recordUnexpected(error, context: "expiry")
        }
    }

    mutating func verifyExplicitCancellation() async {
        let scheduler = ManualExpirationScheduler()
        let broker = ActivityBroker(expirationScheduler: scheduler)
        do {
            let snapshot = try await broker.submit(request(id: "cancel-me", priority: 50, ttlMilliseconds: 100))
            let identity = snapshot.current?.activity.identity
            check(await waitUntil { await scheduler.totalSleepCount == 1 }, "cancellable activity schedules expiry")
            if let identity {
                check(await broker.cancel(identity), "explicit cancellation reports removal")
                check(!(await broker.cancel(identity)), "cancelling absent identity is a no-op")
            } else {
                check(false, "submitted activity exposes an identity")
                check(false, "absent cancellation path unavailable")
            }
            check(await broker.snapshot().current == nil, "explicit cancellation clears current")
            check(await waitUntil { await scheduler.cancellationCount == 1 }, "explicit cancellation stops expiry task")
            check(await broker.workState().scheduledExpiryCount == 0, "explicit cancellation releases scheduled work")
        } catch {
            recordUnexpected(error, context: "explicit cancellation")
        }
    }

    mutating func verifyStaleExpiryGeneration() async {
        let scheduler = NonCooperativeExpirationScheduler()
        let broker = ActivityBroker(expirationScheduler: scheduler)
        do {
            _ = try await broker.submit(request(id: "generation", priority: 50, title: "Old", ttlMilliseconds: 10))
            check(await waitUntil { await scheduler.totalSleepCount == 1 }, "stale-generation expiry starts")
            let replacement = try await broker.submit(request(id: "generation", priority: 50, title: "New"))
            check(replacement.current?.activity.presentation.title == "New", "replacement removes expiry lifecycle")

            await scheduler.fireOldestIgnoringCancellation()
            for _ in 0..<20 { await Task.yield() }
            check(
                await broker.snapshot().current?.activity.presentation.title == "New",
                "revision check rejects a late non-cooperative expiry"
            )
        } catch {
            recordUnexpected(error, context: "stale expiry generation")
        }
    }

    mutating func verifyValidation() async {
        let broker = ActivityBroker()
        await expect(
            .invalid(.unknownValue(.source, "unknown")),
            from: broker,
            request: request(id: "source", source: "unknown")
        )
        await expect(
            .invalid(.tooLarge(.source, maximumBytes: ActivityLimits.sourceBytes)),
            from: broker,
            request: request(id: "large-source", source: String(repeating: "x", count: ActivityLimits.sourceBytes + 1))
        )
        await expect(
            .invalid(.tooLarge(.kind, maximumBytes: ActivityLimits.kindBytes)),
            from: broker,
            request: request(id: "large-kind", kind: String(repeating: "x", count: ActivityLimits.kindBytes + 1))
        )
        await expect(
            .invalid(.unknownValue(.kind, "weather")),
            from: broker,
            request: request(id: "kind", kind: "weather")
        )
        await expect(
            .invalid(.unknownValue(.actionIntent, "run-shell")),
            from: broker,
            request: request(
                id: "action",
                actionIdentifier: "act",
                actionLabel: "Act",
                actionIntent: "run-shell"
            )
        )
        await expect(
            .invalid(.tooLarge(.actionIntent, maximumBytes: ActivityLimits.actionIntentBytes)),
            from: broker,
            request: request(
                id: "large-action",
                actionIdentifier: "act",
                actionLabel: "Act",
                actionIntent: String(repeating: "x", count: ActivityLimits.actionIntentBytes + 1)
            )
        )
        await expect(
            .invalid(.invalidFormat(.identifier)),
            from: broker,
            request: request(id: "bad id")
        )
        await expect(
            .invalid(.tooLarge(.identifier, maximumBytes: ActivityLimits.identifierBytes)),
            from: broker,
            request: request(id: String(repeating: "x", count: ActivityLimits.identifierBytes + 1))
        )
        await expect(
            .invalid(.invalidFormat(.title)),
            from: broker,
            request: request(id: "control", title: "bad\ntext")
        )
        await expect(
            .invalid(.invalidFormat(.actionIntent)),
            from: broker,
            request: request(id: "partial", actionIdentifier: "act")
        )
        await expect(
            .invalid(.tooLarge(.title, maximumBytes: ActivityLimits.titleBytes)),
            from: broker,
            request: request(id: "large", title: String(repeating: "x", count: ActivityLimits.titleBytes + 1))
        )
        await expect(
            .invalid(.tooLarge(.detail, maximumBytes: ActivityLimits.detailBytes)),
            from: broker,
            request: request(id: "large-detail", detail: String(repeating: "x", count: ActivityLimits.detailBytes + 1))
        )
        await expect(
            .invalid(.tooLarge(.actionIdentifier, maximumBytes: ActivityLimits.actionIdentifierBytes)),
            from: broker,
            request: request(
                id: "large-action-id",
                actionIdentifier: String(repeating: "x", count: ActivityLimits.actionIdentifierBytes + 1),
                actionLabel: "Act",
                actionIntent: "cancel"
            )
        )
        await expect(
            .invalid(.tooLarge(.actionLabel, maximumBytes: ActivityLimits.actionLabelBytes)),
            from: broker,
            request: request(
                id: "large-action-label",
                actionIdentifier: "act",
                actionLabel: String(repeating: "x", count: ActivityLimits.actionLabelBytes + 1),
                actionIntent: "cancel"
            )
        )
        await expect(
            .invalid(.outOfRange(.priority, minimum: 0, maximum: 100)),
            from: broker,
            request: request(id: "priority", priority: 101)
        )
        await expect(
            .invalid(.outOfRange(.progress, minimum: 0, maximum: 1)),
            from: broker,
            request: request(id: "progress", progress: .infinity)
        )
        await expect(
            .invalid(.outOfRange(.ttlMilliseconds, minimum: 1, maximum: 86_400_000)),
            from: broker,
            request: request(id: "ttl", ttlMilliseconds: 0)
        )
        check(await broker.snapshot().ordered.isEmpty, "rejected input never mutates broker state")
    }

    mutating func verifyActivityCapacity() async {
        let broker = ActivityBroker()
        do {
            for index in 0..<ActivityLimits.maximumActivityCount {
                _ = try await broker.submit(request(id: "capacity-\(index)", priority: 1))
            }
            await expect(
                .activityCapacityExceeded(maximum: ActivityLimits.maximumActivityCount),
                from: broker,
                request: request(id: "capacity-overflow", priority: 100)
            )
            check(await broker.snapshot().ordered.count == ActivityLimits.maximumActivityCount, "capacity rejection preserves bounded state")

            let replacement = try await broker.submit(request(id: "capacity-0", priority: 100, title: "Updated at capacity"))
            check(replacement.ordered.count == ActivityLimits.maximumActivityCount, "dedupe replacement is allowed at capacity")
            check(replacement.current?.activity.presentation.title == "Updated at capacity", "replacement at capacity still preempts deterministically")
        } catch {
            recordUnexpected(error, context: "activity capacity")
        }
    }

    mutating func verifyDeclarativeAction() async {
        let broker = ActivityBroker()
        do {
            let snapshot = try await broker.submit(
                request(
                    id: "bounded-action",
                    actionIdentifier: "timer.cancel",
                    actionLabel: "Cancel",
                    actionIntent: "cancel"
                )
            )
            let action = snapshot.current?.activity.action
            check(action?.identifier == "timer.cancel", "bounded action preserves validated identifier")
            check(action?.label == "Cancel", "bounded action preserves validated label")
            check(action?.intent == .cancel, "bounded action resolves to a fixed declarative intent")
        } catch {
            recordUnexpected(error, context: "declarative action")
        }
    }

    mutating func verifyFileHoldSchemaValues() async {
        let broker = ActivityBroker()
        do {
            let snapshot = try await broker.submit(
                request(id: "held-file", source: "file-hold", kind: "file")
            )
            check(snapshot.current?.activity.identity.source == .fileHold, "file-hold source is a known closed-schema value")
            check(snapshot.current?.activity.kind == .file, "file activity kind is accepted without generic fallback")
        } catch {
            recordUnexpected(error, context: "File Hold schema values")
        }
    }

    mutating func verifySnapshotBackpressureAndLifecycle() async {
        let broker = ActivityBroker()
        do {
            let stream = try await broker.snapshots()
            _ = try await broker.submit(request(id: "stream-first", priority: 25))
            let latest = try await broker.submit(request(id: "stream-latest", priority: 75))
            var iterator = stream.makeAsyncIterator()
            let received = await iterator.next()
            check(received == latest, "newest-only buffer drops superseded snapshots for slow subscribers")

            let lifecycleStream = try await broker.snapshots()
            let consumer = Task {
                var iterator = lifecycleStream.makeAsyncIterator()
                _ = await iterator.next()
                _ = await iterator.next()
            }
            check(await waitUntil { await broker.workState().subscriberCount == 2 }, "snapshot subscriptions are registered")
            consumer.cancel()
            _ = await consumer.value
            check(await waitUntil { await broker.workState().subscriberCount == 1 }, "cancelled iterator terminates and unregisters safely")
        } catch {
            recordUnexpected(error, context: "snapshot stream")
        }
    }

    mutating func verifySubscriberCapacity() async {
        let broker = ActivityBroker()
        do {
            var consumers: [Task<Void, Never>] = []
            for _ in 0..<ActivityLimits.maximumSubscriberCount {
                let stream = try await broker.snapshots()
                consumers.append(Task {
                    var iterator = stream.makeAsyncIterator()
                    _ = await iterator.next()
                    _ = await iterator.next()
                })
            }
            check(await broker.workState().subscriberCount == ActivityLimits.maximumSubscriberCount, "subscriber count reaches fixed bound")
            do {
                _ = try await broker.snapshots()
                check(false, "subscriber overflow is rejected")
            } catch let error {
                check(
                    error == .subscriberCapacityExceeded(maximum: ActivityLimits.maximumSubscriberCount),
                    "subscriber overflow returns typed capacity error"
                )
            }

            consumers.forEach { $0.cancel() }
            for consumer in consumers {
                _ = await consumer.value
            }
            check(await waitUntil { await broker.workState().subscriberCount == 0 }, "all cancelled subscribers are removed")
        } catch {
            recordUnexpected(error, context: "subscriber capacity")
        }
    }

    mutating func verifySubscriberIdentityIsolation() async {
        let broker = ActivityBroker()
        let subscriberID = UUID()
        do {
            let first = try await broker.snapshotSubscription(subscriberID: subscriberID)
            var firstIterator = first.stream.makeAsyncIterator()
            check(await firstIterator.next()?.version == 0, "explicit package subscription receives the initial snapshot")

            do {
                _ = try await broker.snapshotSubscription(subscriberID: subscriberID)
                check(false, "duplicate package subscriber identity is rejected")
            } catch let error {
                check(
                    error == ActivityBrokerSubscriptionError.duplicateSubscriberIdentifier,
                    "duplicate package subscriber identity returns its typed error"
                )
            }
            check(await broker.workState().subscriberCount == 1, "duplicate rejection preserves the original registration")

            await broker.cancelSnapshotSubscription(first.token)
            check(await broker.workState().subscriberCount == 0, "first registration token unregisters only its own stream")

            let second = try await broker.snapshotSubscription(subscriberID: subscriberID)
            var secondIterator = second.stream.makeAsyncIterator()
            check(await secondIterator.next()?.version == 0, "retired logical identity can register a new generation")
            check(first.token != second.token, "reused subscriber identity receives an immutable fresh generation")

            await broker.cancelSnapshotSubscription(first.token)
            check(
                await broker.workState().subscriberCount == 1,
                "delayed retired-token cancellation cannot remove its replacement"
            )
            let submitted = try await broker.submit(request(id: "subscriber-generation", priority: 50))
            check(await secondIterator.next() == submitted, "replacement stream remains live after stale first-generation termination")

            await broker.cancelSnapshotSubscription(second.token)
            check(await broker.workState().subscriberCount == 0, "current generation still unregisters exactly once")
        } catch {
            recordUnexpected(error, context: "subscriber identity isolation")
        }
    }

    mutating func verifyZeroRepeatingIdleWork() async {
        let scheduler = ManualExpirationScheduler()
        let broker = ActivityBroker(expirationScheduler: scheduler)
        check(await scheduler.totalSleepCount == 0, "idle broker starts no scheduler work")
        check(await broker.workState().scheduledExpiryCount == 0, "idle broker owns zero expiry tasks")

        do {
            _ = try await broker.submit(request(id: "persistent", priority: 50))
            for _ in 0..<20 { await Task.yield() }
            check(await scheduler.totalSleepCount == 0, "non-expiring activity starts no timer")
            check(await broker.workState().scheduledExpiryCount == 0, "non-expiring activity owns zero scheduled work")
        } catch {
            recordUnexpected(error, context: "idle work")
        }
    }

    private func request(
        id: String,
        source: String = "timer",
        kind: String = "timer",
        priority: Int = 50,
        title: String = "Activity",
        detail: String? = nil,
        progress: Double? = nil,
        actionIdentifier: String? = nil,
        actionLabel: String? = nil,
        actionIntent: String? = nil,
        ttlMilliseconds: Int? = nil
    ) -> ActivityRequest {
        ActivityRequest(
            identifier: id,
            source: source,
            kind: kind,
            priority: priority,
            title: title,
            detail: detail,
            progress: progress,
            actionIdentifier: actionIdentifier,
            actionLabel: actionLabel,
            actionIntent: actionIntent,
            ttlMilliseconds: ttlMilliseconds
        )
    }

    private func identifiers(in snapshot: ActivityBrokerSnapshot) -> [String] {
        snapshot.ordered.map { $0.activity.identity.identifier.rawValue }
    }

    private mutating func expect(
        _ expected: ActivityBrokerError,
        from broker: ActivityBroker,
        request: ActivityRequest
    ) async {
        do {
            _ = try await broker.submit(request)
            check(false, "expected rejection: \(expected)")
        } catch let error {
            check(error == expected, "typed rejection matches \(expected)")
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    private mutating func check(_ condition: Bool, _ name: String) {
        checkCount += 1
        if !condition {
            failures.append(name)
        }
    }

    private mutating func recordUnexpected(_ error: any Error, context: String) {
        checkCount += 1
        failures.append("\(context) produced unexpected error: \(error)")
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("Activity harness passed: \(checkCount) checks.")
            exit(EXIT_SUCCESS)
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        fputs("Activity harness failed: \(failures.count) of \(checkCount) checks.\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private actor ManualExpirationScheduler: ActivityExpirationScheduling {
    private struct Waiter {
        let identifier: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Waiter] = []
    private var cancelledBeforeRegistration: Set<UUID> = []
    private(set) var totalSleepCount = 0
    private(set) var cancellationCount = 0

    var pendingDurations: [Duration] {
        waiters.map(\.duration)
    }

    func sleep(for duration: Duration) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                totalSleepCount += 1
                if cancelledBeforeRegistration.remove(identifier) != nil {
                    cancellationCount += 1
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(
                        Waiter(
                            identifier: identifier,
                            duration: duration,
                            continuation: continuation
                        )
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(identifier) }
        }
    }

    func fireOldest() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    private func cancel(_ identifier: UUID) {
        guard let index = waiters.firstIndex(where: { $0.identifier == identifier }) else {
            cancelledBeforeRegistration.insert(identifier)
            return
        }
        cancellationCount += 1
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Deliberately violates cancellation cooperation to exercise the broker's revision backstop.
private actor NonCooperativeExpirationScheduler: ActivityExpirationScheduling {
    private var continuations: [CheckedContinuation<Void, any Error>] = []
    private(set) var totalSleepCount = 0

    func sleep(for duration: Duration) async throws {
        _ = duration
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            totalSleepCount += 1
            continuations.append(continuation)
        }
    }

    func fireOldestIgnoringCancellation() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}
