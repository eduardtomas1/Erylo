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
        await harness.verifyOwnershipCapacityAndRelease()
        await harness.verifyOwnershipClaimIntentAdmission()
        await harness.verifyOwnedRecordFencing()
        await harness.verifySnapshotBackpressureAndLifecycle()
        await harness.verifySubscriberCapacity()
        await harness.verifySubscriberIdentityIsolation()
        await harness.verifyZeroRepeatingIdleWork()
        await harness.verifyTerminalShutdown()
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

    mutating func verifyTerminalShutdown() async {
        let scheduler = ManualExpirationScheduler()
        let broker = ActivityBroker(expirationScheduler: scheduler)
        let identity = ActivityIdentity(
            source: .timer,
            identifier: try! ActivityIdentifier(validating: "terminal-shutdown")
        )
        guard let delayedIntent = broker.ownershipCoordinator.prepareClaim(for: identity) else {
            check(false, "terminal shutdown fixture prepares ownership intent")
            return
        }

        do {
            _ = try await broker.submit(
                request(id: "terminal-shutdown", priority: 50, ttlMilliseconds: 60_000)
            )
            let stream = try await broker.snapshots()
            check(
                await waitUntil {
                    let work = await broker.workState()
                    return work.scheduledExpiryCount == 1 && work.subscriberCount == 1
                },
                "terminal shutdown fixture owns expiry and subscription work"
            )

            await broker.shutdown()
            await broker.shutdown()
            withExtendedLifetime(stream) {}

            let work = await broker.workState()
            check(work.scheduledExpiryCount == 0, "terminal shutdown releases expiry work")
            check(work.subscriberCount == 0, "terminal shutdown finishes subscriptions")
            check(work.activeOwnershipCount == 0, "terminal shutdown releases ownership state")
            check(work.pendingOwnershipIntentCount == 0, "terminal shutdown releases pending ownership intent state")
            check(await scheduler.cancellationCount == 1, "terminal shutdown joins expiry cancellation")
            check(await broker.snapshot().ordered.isEmpty, "terminal shutdown clears broker records")
            check(
                await broker.claimOwnership(of: identity, admitting: delayedIntent) == nil,
                "terminal shutdown rejects a delayed ownership claim"
            )
            check(
                broker.ownershipCoordinator.prepareClaim(for: identity) == nil,
                "terminal shutdown rejects new ownership intent admission"
            )
            await expect(
                .brokerShutDown,
                from: broker,
                request: request(id: "after-shutdown", priority: 50)
            )
            do {
                _ = try await broker.snapshots()
                check(false, "terminal shutdown rejects a new subscription")
            } catch let error {
                check(error == .brokerShutDown, "terminal subscription rejection is typed")
            }
        } catch {
            recordUnexpected(error, context: "terminal shutdown")
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

    mutating func verifyOwnershipCapacityAndRelease() async {
        let broker = ActivityBroker()
        var leases: [ActivityOwnershipLease] = []

        do {
            for index in 0..<ActivityLimits.maximumOwnershipCount {
                let identity = ActivityIdentity(
                    source: .external,
                    identifier: try ActivityIdentifier(validating: "owner-\(index)")
                )
                if let lease = await claimOwnership(of: identity, from: broker) {
                    leases.append(lease)
                }
            }
            check(
                leases.count == ActivityLimits.maximumOwnershipCount,
                "ownership capacity admits exactly its fixed bound"
            )
            check(
                await broker.workState().activeOwnershipCount
                    == ActivityLimits.maximumOwnershipCount,
                "ownership work state reports the fixed live-generation bound"
            )

            let overflowIdentity = ActivityIdentity(
                source: .external,
                identifier: try ActivityIdentifier(validating: "owner-overflow")
            )
            let overflowLease = await claimOwnership(
                of: overflowIdentity,
                from: broker
            )
            check(
                overflowLease == nil,
                "unique ownership overflow fails closed without retaining state"
            )
            check(
                await broker.workState().activeOwnershipCount
                    == ActivityLimits.maximumOwnershipCount,
                "rejected ownership overflow preserves bounded state"
            )

            for lease in leases {
                lease.beginRetirement()
                check(
                    await broker.releaseOwnership(lease),
                    "exact ownership generation releases its capacity"
                )
            }
            check(
                await broker.workState().activeOwnershipCount == 0,
                "retired ownership generations leave zero retained admission state"
            )

            let reclaimed = await claimOwnership(of: overflowIdentity, from: broker)
            check(reclaimed != nil, "released ownership capacity is reusable")
            if let reclaimed {
                reclaimed.beginRetirement()
                check(
                    await broker.releaseOwnership(reclaimed),
                    "reused ownership generation releases cleanly"
                )
            }
            check(
                await broker.workState().activeOwnershipCount == 0,
                "reused ownership capacity returns to zero"
            )
        } catch {
            recordUnexpected(error, context: "ownership capacity and release")
        }
    }

    mutating func verifyOwnershipClaimIntentAdmission() async {
        let broker = ActivityBroker()

        do {
            let identity = ActivityIdentity(
                source: .external,
                identifier: try ActivityIdentifier(validating: "claim-order")
            )
            guard let delayedIntent = broker.ownershipCoordinator.prepareClaim(
                for: identity
            ), let successorIntent = broker.ownershipCoordinator.prepareClaim(
                for: identity
            ), let successorLease = await broker.claimOwnership(
                of: identity,
                admitting: successorIntent
            ) else {
                check(false, "ownership claim-order fixture prepares both intents")
                return
            }
            let successorSnapshot = try await broker.submit(
                request(
                    id: identity.identifier.rawValue,
                    source: "external",
                    title: "Successor"
                ),
                ifOwnedBy: successorLease
            )
            check(
                successorSnapshot?.current?.activity.presentation.title == "Successor",
                "newer synchronously ordered intent owns the record"
            )
            check(
                await broker.cancel(identity, ifOwnedBy: successorLease),
                "successor removes its exact owned record before release"
            )
            check(
                await broker.releaseOwnership(successorLease),
                "successor releases while a delayed older intent remains"
            )
            let releasedSnapshot = await broker.snapshot()
            let retainedWork = await broker.workState()
            check(
                retainedWork.activeOwnershipCount == 1
                    && retainedWork.pendingOwnershipIntentCount == 1,
                "delayed intent retains one bounded high-water lane after successor release"
            )
            check(
                await broker.claimOwnership(of: identity, admitting: delayedIntent) == nil,
                "delayed older intent cannot claim after the successor releases"
            )
            check(
                await broker.snapshot() == releasedSnapshot,
                "rejected delayed intent performs no broker mutation"
            )
            let prunedWork = await broker.workState()
            check(
                prunedWork.activeOwnershipCount == 0
                    && prunedWork.pendingOwnershipIntentCount == 0,
                "settled stale intent prunes its high-water lane"
            )

            guard let retiredIntent = broker.ownershipCoordinator.prepareClaim(
                for: identity
            ) else {
                check(false, "ownership retirement fixture prepares an intent")
                return
            }
            retiredIntent.retire()
            check(
                broker.ownershipCoordinator.workState()
                    == ActivityOwnershipWorkState(
                        retainedIdentityCount: 0,
                        pendingIntentCount: 0,
                        activeLeaseCount: 0
                    ),
                "synchronous intent retirement releases admission state"
            )
            check(
                await broker.claimOwnership(of: identity, admitting: retiredIntent) == nil,
                "a retired token remains rejected when a wrapper delivers it later"
            )

            var boundedIntents: [ActivityOwnershipClaimIntent] = []
            for _ in 0..<ActivityLimits.maximumOwnershipIntentCount {
                if let intent = broker.ownershipCoordinator.prepareClaim(for: identity) {
                    boundedIntents.append(intent)
                }
            }
            check(
                boundedIntents.count == ActivityLimits.maximumOwnershipIntentCount,
                "ownership pending-intent capacity admits exactly its fixed bound"
            )
            check(
                broker.ownershipCoordinator.prepareClaim(for: identity) == nil,
                "ownership pending-intent overflow fails closed"
            )
            check(
                broker.ownershipCoordinator.workState()
                    == ActivityOwnershipWorkState(
                        retainedIdentityCount: 1,
                        pendingIntentCount: ActivityLimits.maximumOwnershipIntentCount,
                        activeLeaseCount: 0
                    ),
                "ownership pending-intent work remains globally bounded"
            )
            boundedIntents.forEach { $0.retire() }
            check(
                broker.ownershipCoordinator.workState()
                    == ActivityOwnershipWorkState(
                        retainedIdentityCount: 0,
                        pendingIntentCount: 0,
                        activeLeaseCount: 0
                    ),
                "retiring bounded pending intents prunes all retained state"
            )

            let freshLease = await claimOwnership(of: identity, from: broker)
            check(freshLease != nil, "claim capacity is reusable after pending-intent pruning")
            if let freshLease {
                check(
                    await broker.releaseOwnership(freshLease),
                    "fresh reusable claim releases cleanly"
                )
            }
            check(
                await broker.workState().activeOwnershipCount == 0,
                "fresh reusable claim leaves no retained ownership state"
            )
        } catch {
            recordUnexpected(error, context: "ownership claim intent admission")
        }
    }

    mutating func verifyOwnedRecordFencing() async {
        let scheduler = ManualExpirationScheduler()
        let broker = ActivityBroker(expirationScheduler: scheduler)
        do {
            let identity = ActivityIdentity(
                source: .timer,
                identifier: try ActivityIdentifier(validating: "public-owner")
            )
            guard let submittedLease = await claimOwnership(
                of: identity,
                from: broker
            ) else {
                check(false, "public broker claims owned-record fixture")
                return
            }
            let ownedRequest = request(id: identity.identifier.rawValue, title: "Owned")
            check(
                try await broker.submit(ownedRequest, ifOwnedBy: submittedLease) != nil,
                "owned fixture binds its record to the lease generation"
            )
            let unleased = try await broker.submit(
                request(id: identity.identifier.rawValue, title: "Unleased replacement")
            )
            check(
                unleased.current?.activity.presentation.title == "Unleased replacement",
                "public unleased submit replaces the owned record"
            )
            check(
                await broker.workState().activeOwnershipCount == 0,
                "public unleased submit atomically invalidates provider admission"
            )
            submittedLease.beginRetirement()
            check(
                !(await broker.cancel(identity, ifOwnedBy: submittedLease)),
                "retired owner cannot cancel a later unleased record"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "Unleased replacement",
                "later unleased record survives old owned cleanup"
            )
            check(
                !(await broker.releaseOwnership(submittedLease)),
                "stale owned release cannot disturb unleased state"
            )

            guard let cancelledLease = await claimOwnership(
                of: identity,
                from: broker
            ) else {
                check(false, "public broker reclaims generation after unleased replacement")
                return
            }
            check(
                await broker.snapshot().ordered.isEmpty,
                "ownership takeover clears the preceding unleased record"
            )
            check(
                try await broker.submit(ownedRequest, ifOwnedBy: cancelledLease) != nil,
                "reclaimed generation submits an owned record"
            )
            check(await broker.cancel(identity), "unleased cancellation removes an owned record")
            check(
                await broker.workState().activeOwnershipCount == 0,
                "unleased cancellation invalidates and prunes owned admission"
            )
            _ = try await broker.submit(
                request(id: identity.identifier.rawValue, title: "After public cancel")
            )
            cancelledLease.beginRetirement()
            check(
                !(await broker.cancel(identity, ifOwnedBy: cancelledLease)),
                "lease invalidated by public cancellation cannot erase a future record"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "After public cancel",
                "future record survives cleanup from a publicly cancelled lease"
            )
            _ = await broker.cancel(identity)

            guard let actionLease = await claimOwnership(
                of: identity,
                from: broker
            ) else {
                check(false, "public broker claims action-cancellation ownership fixture")
                return
            }
            let actionRequest = request(
                id: identity.identifier.rawValue,
                title: "Owned action",
                actionIdentifier: "timer.cancel",
                actionLabel: "Cancel",
                actionIntent: "cancel"
            )
            let actionSnapshot = try await broker.submit(
                actionRequest,
                ifOwnedBy: actionLease
            )
            if let actionRevision = actionSnapshot?.current?.revision {
                check(
                    await broker.cancelCurrentAction(
                        identity: identity,
                        revision: actionRevision,
                        actionIdentifier: "timer.cancel",
                        intent: .cancel
                    ),
                    "public current-action cancellation removes its exact owned record"
                )
            } else {
                check(false, "owned action fixture exposes its current revision")
            }
            check(
                await broker.workState().activeOwnershipCount == 0,
                "public current-action cancellation invalidates owned admission"
            )
            _ = try await broker.submit(
                request(id: identity.identifier.rawValue, title: "After current action")
            )
            check(
                try await broker.submit(actionRequest, ifOwnedBy: actionLease) == nil,
                "action-invalidated lease cannot submit over a future record"
            )
            actionLease.beginRetirement()
            check(
                !(await broker.cancel(identity, ifOwnedBy: actionLease)),
                "action-invalidated lease cannot cancel a future record"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "After current action",
                "future record survives cleanup from action-invalidated ownership"
            )
            check(
                !(await broker.releaseOwnership(actionLease)),
                "stale action-owned release cannot disturb future state"
            )
            _ = await broker.cancel(identity)

            guard let expiringLease = await claimOwnership(
                of: identity,
                from: broker
            ) else {
                check(false, "public broker claims expiring ownership fixture")
                return
            }
            let expiringRequest = request(
                id: identity.identifier.rawValue,
                title: "Owned expiry",
                ttlMilliseconds: 10
            )
            check(
                try await broker.submit(expiringRequest, ifOwnedBy: expiringLease) != nil,
                "owned expiring record is admitted"
            )
            check(
                await waitUntil { await scheduler.pendingDurations == [.milliseconds(10)] },
                "owned expiry installs one bounded one-shot"
            )
            await scheduler.fireOldest()
            check(
                await waitUntil {
                    let snapshot = await broker.snapshot()
                    let work = await broker.workState()
                    return snapshot.ordered.isEmpty
                        && work.scheduledExpiryCount == 0
                        && work.activeOwnershipCount == 0
                },
                "owned expiry removes its record, task, and admission generation"
            )
            _ = try await broker.submit(
                request(id: identity.identifier.rawValue, title: "After owned expiry")
            )
            expiringLease.beginRetirement()
            check(
                !(await broker.cancel(identity, ifOwnedBy: expiringLease)),
                "expired ownership cannot erase a future unleased record"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "After owned expiry",
                "future record survives cleanup from an expired ownership generation"
            )
            _ = await broker.cancel(identity)
        } catch {
            recordUnexpected(error, context: "owned record fencing")
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

    private func claimOwnership(
        of identity: ActivityIdentity,
        from broker: ActivityBroker
    ) async -> ActivityOwnershipLease? {
        guard let intent = broker.ownershipCoordinator.prepareClaim(for: identity) else {
            return nil
        }
        return await broker.claimOwnership(of: identity, admitting: intent)
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
