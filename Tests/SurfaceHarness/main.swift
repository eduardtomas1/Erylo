import CoreGraphics
import Darwin
import EryloActivity
import EryloCore
import EryloIntegrations
import EryloSurface
import EryloWindowing
import Foundation

@main
@MainActor
enum SurfaceHarnessMain {
    static func main() async {
        var harness = SurfaceHarness()
        await harness.verifyInitialStreamLifecycleAndCleanup()
        await harness.verifyAutomaticVisibilityLifecycle()
        await harness.verifyNewestHandoffDedupeAndQueueBounds()
        await harness.verifyActionFreshnessAndSafeFailure()
        await harness.verifyTerminalStopJoinsAllWork()
        await harness.verifyCancelledActionOwnershipAndTerminalDrain()
        await harness.verifyTerminalOverlapAwaitBarriers()
        await harness.verifyOverlappingLifecycleRequestsAreLatestWins()
        await harness.verifyStopIntentSynchronouslyRevokesAdmission()
        await harness.verifyPendingSubscriptionEpochRetirement()
        await harness.verifyEventCallbackLeases()
        await harness.verifyCoordinatorDeinitDoesNotPoisonSharedModel()
        await harness.verifyDetachedReleaseTeardown()
        harness.verifyLegacyCompatibilityDefaultsAreInert()
        harness.verifyStateContentAccessibilityAndPreviews()
        harness.verifyReduceMotionAndRapidStateChanges()
        await harness.verifySharedBrokerVisibilityAndDisabledWork()
        harness.finish()
    }
}

@MainActor
private struct SurfaceHarness {
    private var checkCount = 0
    private var failures: [String] = []

    mutating func verifyInitialStreamLifecycleAndCleanup() async {
        let broker = ActivityBroker()
        let model = SurfaceActivityModel(broker: broker)

        check(await broker.workState().subscriberCount == 0, "model initialization starts no subscriber")
        check(model.phase == .stopped, "model initializes in an explicit stopped phase")
        model.start()
        check(
            await waitUntil {
                await broker.workState().subscriberCount == 1 && model.phase == .active
            },
            "start owns one subscriber and receives the initial empty snapshot"
        )
        model.start()
        check(await broker.workState().subscriberCount == 1, "repeated start never creates a second stream")

        do {
            let submitted = try await broker.submit(request(id: "lifecycle", title: "Visible activity"))
            check(
                await waitUntil { model.snapshotVersion == submitted.version },
                "stream applies the submitted snapshot version"
            )
            check(model.current?.activity.presentation.title == "Visible activity", "stream exposes the current activity")

            await model.stop()
            check(model.phase == .stopped, "stop resets the observable phase")
            check(model.current == nil, "stop clears stale presentation content")
            check(
                await waitUntil { await broker.workState().subscriberCount == 0 },
                "stop cancels and unregisters the snapshot subscriber"
            )

            _ = try await broker.submit(request(id: "while-stopped", priority: 75, title: "Newest while stopped"))
            for _ in 0..<20 { await Task.yield() }
            check(model.current == nil, "stopped model performs no snapshot work")
            check(await broker.workState().subscriberCount == 0, "stopped model retains zero subscribers")

            model.start()
            check(
                await waitUntil {
                    let subscriberCount = await broker.workState().subscriberCount
                    return model.current?.activity.presentation.title == "Newest while stopped"
                        && subscriberCount == 1
                },
                "restart receives the broker's newest initial snapshot through one fresh stream"
            )
            await model.stop()
            check(
                await waitUntil { await broker.workState().subscriberCount == 0 },
                "restart remains symmetrically cancellable"
            )
        } catch {
            recordUnexpected(error, context: "initial stream lifecycle")
        }

        var disposableModel: SurfaceActivityModel? = SurfaceActivityModel(broker: broker)
        disposableModel?.start()
        check(
            await waitUntil { await broker.workState().subscriberCount == 1 },
            "disposable model registers its one stream"
        )
        disposableModel = nil
        check(
            await waitUntil { await broker.workState().subscriberCount == 0 },
            "model deinitialization cancels subscriber ownership"
        )

        var rapidLifecycleStayedBounded = true
        for _ in 0..<25 {
            model.start()
            guard await waitUntil({ await broker.workState().subscriberCount == 1 }) else {
                rapidLifecycleStayedBounded = false
                break
            }
            if await broker.workState().subscriberCount != 1 {
                rapidLifecycleStayedBounded = false
            }
            await model.stop()
            if await broker.workState().subscriberCount != 0 || model.workState != .stopped {
                rapidLifecycleStayedBounded = false
            }
        }
        check(rapidLifecycleStayedBounded, "rapid awaited stop and restart never accumulate broker subscriptions")
        check(model.workState == .stopped, "terminal stop returns with no snapshot or action task ownership")
    }

    mutating func verifyAutomaticVisibilityLifecycle() async {
        let expirationScheduler = ManualExpirationScheduler()
        let broker = ActivityBroker(expirationScheduler: expirationScheduler)
        let activityModel = SurfaceActivityModel(broker: broker)
        let motionScheduler = ManualOneShotScheduler()
        let panelModel = PanelSurfaceModel(
            displayGeometry: makeDisplaySnapshot(identity: 10).geometry,
            scheduler: motionScheduler,
            activityModel: activityModel
        )

        check(panelModel.state == .hidden, "startup defaults to an invisible surface")
        activityModel.start()
        check(
            await waitUntil { activityModel.phase == .active },
            "startup empty snapshot is received"
        )
        check(panelModel.state == .hidden, "startup empty snapshot remains invisible")

        do {
            let first = try await broker.submit(
                request(
                    id: "first-visible",
                    priority: 60,
                    title: "First visible activity",
                    ttlMilliseconds: 50
                )
            )
            check(
                await waitUntil { activityModel.snapshotVersion == first.version },
                "first activity reaches the observable surface"
            )
            check(panelModel.state == .compact, "first current activity automatically reveals compact state")
            check(
                await waitUntil { await expirationScheduler.pendingCount == 1 },
                "expiring visibility activity owns one one-shot expiry"
            )
            await expirationScheduler.fireOldest()
            check(
                await waitUntil { activityModel.current == nil && panelModel.state == .hidden },
                "last activity expiry automatically returns compact surface to hidden"
            )

            panelModel.send(.primaryAction)
            check(panelModel.state == .compact, "primary shortcut reveals an empty hidden surface")
            panelModel.send(.primaryAction)
            check(panelModel.state == .expanded, "revealed surface can enter deliberate expanded interaction")
            panelModel.send(.primaryAction)
            check(panelModel.state == .hidden, "closing an empty deliberate expansion returns to invisible rest")

            let fallback = try await broker.submit(
                request(id: "fallback", priority: 30, title: "Fallback")
            )
            check(
                await waitUntil { activityModel.snapshotVersion == fallback.version },
                "fallback activity becomes visible"
            )
            let urgent = try await broker.submit(
                request(
                    id: "urgent-expiry",
                    priority: 90,
                    title: "Urgent",
                    ttlMilliseconds: 50
                )
            )
            check(
                await waitUntil {
                    activityModel.snapshotVersion == urgent.version
                        && activityModel.current?.activity.identity.identifier.rawValue == "urgent-expiry"
                },
                "urgent activity preempts compact current"
            )
            check(
                await waitUntil { await expirationScheduler.pendingCount == 1 },
                "urgent handoff owns one expiry"
            )
            await expirationScheduler.fireOldest()
            check(
                await waitUntil {
                    activityModel.current?.activity.identity.identifier.rawValue == "fallback"
                },
                "urgent expiry hands off directly to queued fallback"
            )
            check(panelModel.state == .compact, "queue handoff stays visible without a hidden flash")
            check(
                activityModel.handoff?.from?.identifier.rawValue == "urgent-expiry"
                    && activityModel.handoff?.to?.identifier.rawValue == "fallback",
                "queue handoff exposes exact prior and next identities"
            )
            if let identity = activityModel.current?.activity.identity {
                _ = await broker.cancel(identity)
            }
            check(
                await waitUntil { panelModel.state == .hidden },
                "empty compact surface hides after final queue cancellation"
            )
        } catch {
            recordUnexpected(error, context: "automatic visibility lifecycle")
        }

        motionScheduler.runAll()
        await activityModel.stop()
        check(await broker.workState().subscriberCount == 0, "visibility lifecycle stops with zero subscribers")
    }

    mutating func verifyNewestHandoffDedupeAndQueueBounds() async {
        let broker = ActivityBroker()
        let model = SurfaceActivityModel(broker: broker)
        model.start()
        check(
            await waitUntil { await broker.workState().subscriberCount == 1 },
            "handoff model registers exactly one subscriber"
        )

        do {
            let first = try await broker.submit(
                request(id: "first", priority: 50, title: "First")
            )
            check(
                await waitUntil { model.snapshotVersion == first.version },
                "surface receives first current snapshot"
            )

            let urgent = try await broker.submit(
                request(id: "urgent", priority: 90, title: "Urgent")
            )
            check(
                await waitUntil { model.snapshotVersion == urgent.version },
                "surface advances to the newest preemption snapshot"
            )
            check(model.handoff?.from?.identifier.rawValue == "first", "handoff records the prior current identity")
            check(model.handoff?.to?.identifier.rawValue == "urgent", "handoff records the next current identity")

            let urgentRevision = model.current?.revision
            let deduped = try await broker.submit(
                request(id: "urgent", priority: 90, title: "Urgent updated")
            )
            check(
                await waitUntil { model.snapshotVersion == deduped.version },
                "surface receives the newest dedupe revision"
            )
            check(model.current?.activity.presentation.title == "Urgent updated", "dedupe replaces visible presentation")
            check(model.current?.revision != urgentRevision, "dedupe exposes the fresh activity revision")
            check(model.handoff == nil, "same-identity dedupe does not invent a handoff")

            var newest = deduped
            for index in 0..<5 {
                newest = try await broker.submit(
                    request(
                        id: "queued-\(index)",
                        priority: 40 - index,
                        title: "Queued \(index)"
                    )
                )
            }
            check(
                await waitUntil { model.snapshotVersion == newest.version },
                "newest-only stream converges to the latest burst snapshot"
            )
            check(model.queueContext.items.count == 2, "surface queue context has a fixed two-item bound")
            check(model.queueContext.remainingCount == 4, "bounded queue reports hidden queue context honestly")
            check(model.current?.activity.identity.identifier.rawValue == "urgent", "queue burst never displaces higher-priority current")
        } catch {
            recordUnexpected(error, context: "newest handoff and queue")
        }

        await model.stop()
        check(
            await waitUntil { await broker.workState().subscriberCount == 0 },
            "handoff model releases its subscriber"
        )
    }

    mutating func verifyActionFreshnessAndSafeFailure() async {
        let broker = ActivityBroker()
        let handler = RecordingActionHandler(outcome: .unhandled)
        let model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        model.start()
        check(
            await waitUntil { await broker.workState().subscriberCount == 1 },
            "action model registers one stream"
        )

        do {
            let initial = try await broker.submit(
                request(
                    id: "action",
                    title: "Initial action",
                    actionIdentifier: "timer.cancel",
                    actionLabel: "Cancel timer",
                    actionIntent: .cancel
                )
            )
            check(
                await waitUntil { model.snapshotVersion == initial.version && model.currentAction != nil },
                "surface exposes the one declarative activity action"
            )
            guard let staleAction = model.currentAction else {
                check(false, "initial action identity is available")
                await model.stop()
                return
            }

            let replacement = try await broker.submit(
                request(
                    id: "action",
                    title: "Fresh action",
                    actionIdentifier: "timer.cancel",
                    actionLabel: "Cancel timer",
                    actionIntent: .cancel
                )
            )
            check(
                await waitUntil { model.snapshotVersion == replacement.version },
                "action dedupe reaches its new revision"
            )
            check(
                !(await broker.cancelCurrentAction(
                    identity: staleAction.identity.activityIdentity,
                    revision: staleAction.identity.activityRevision,
                    actionIdentifier: staleAction.identity.actionIdentifier,
                    intent: staleAction.intent
                )),
                "broker atomically rejects stale action revision cancellation"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title == "Fresh action",
                "atomic stale rejection preserves the fresh activity"
            )
            check(!model.dispatch(staleAction), "stale action revision is rejected before dispatch")
            check(model.actionDispatchState == .stale, "stale rejection is observable without dismissal")
            check(handler.invocations.isEmpty, "stale action never reaches the injected handler")

            guard let freshAction = model.currentAction else {
                check(false, "fresh action identity is available")
                await model.stop()
                return
            }
            check(model.dispatch(freshAction), "fresh action is accepted for dispatch")
            check(
                await waitUntil { model.actionDispatchState == .unhandled },
                "unknown provider behavior fails as an explicit unhandled outcome"
            )
            check(handler.invocations.count == 1, "fresh action reaches the handler exactly once")
            check(handler.invocations.first?.intent == .cancel, "handler receives only the closed action intent")
            check(handler.invocations.first?.identity == freshAction.identity, "handler receives exact identity and revision metadata")
            check(await broker.snapshot().current?.activity.presentation.title == "Fresh action", "unhandled action does not dismiss current")
        } catch {
            recordUnexpected(error, context: "action freshness")
        }
        await model.stop()
        check(
            await waitUntil { await broker.workState().subscriberCount == 0 },
            "action model stops without subscriber work"
        )

        let dismissBroker = ActivityBroker()
        let dismissModel = SurfaceActivityModel(broker: dismissBroker)
        dismissModel.start()
        do {
            let submitted = try await dismissBroker.submit(
                request(
                    id: "dismiss",
                    title: "Dismissable",
                    actionIdentifier: "activity.dismiss",
                    actionLabel: "Dismiss",
                    actionIntent: .dismiss
                )
            )
            check(
                await waitUntil { dismissModel.snapshotVersion == submitted.version && dismissModel.currentAction != nil },
                "explicit dismiss action becomes current"
            )
            if let action = dismissModel.currentAction {
                check(dismissModel.dispatch(action), "explicit dismiss intent dispatches")
                check(
                    await waitUntil { await dismissBroker.snapshot().current == nil },
                    "only the explicitly supported dismiss intent removes broker state"
                )
            } else {
                check(false, "dismiss action is available")
                check(false, "dismiss outcome cannot be exercised")
            }
        } catch {
            recordUnexpected(error, context: "explicit dismiss")
        }
        await dismissModel.stop()
        check(
            await waitUntil { await dismissBroker.workState().subscriberCount == 0 },
            "dismiss model releases its subscriber"
        )

        let atomicBroker = ActivityBroker()
        do {
            let revisionOne = try await atomicBroker.submit(
                request(
                    id: "atomic-dismiss",
                    title: "Revision one",
                    actionIdentifier: "atomic.dismiss",
                    actionLabel: "Dismiss",
                    actionIntent: .dismiss
                )
            )
            let revisionTwo = try await atomicBroker.submit(
                request(
                    id: "atomic-dismiss",
                    title: "Revision two",
                    actionIdentifier: "atomic.dismiss",
                    actionLabel: "Dismiss",
                    actionIntent: .dismiss
                )
            )
            guard let stale = revisionOne.current, let fresh = revisionTwo.current else {
                check(false, "atomic revision fixtures are available")
                check(false, "rev1 cancellation cannot be exercised")
                check(false, "rev2 cancellation cannot be exercised")
                return
            }
            check(
                !(await atomicBroker.cancelCurrentAction(
                    identity: stale.activity.identity,
                    revision: stale.revision,
                    actionIdentifier: stale.activity.action?.identifier ?? "",
                    intent: .dismiss
                )),
                "atomic action consume prevents rev1 from cancelling rev2 replacement"
            )
            check(
                await atomicBroker.snapshot().current?.revision == fresh.revision,
                "failed rev1 action consume preserves rev2 as current"
            )
            check(
                await atomicBroker.cancelCurrentAction(
                    identity: fresh.activity.identity,
                    revision: fresh.revision,
                    actionIdentifier: fresh.activity.action?.identifier ?? "",
                    intent: .dismiss
                ),
                "atomic action consume allows the exact current revision"
            )
            check(await atomicBroker.snapshot().current == nil, "successful rev2 action consume removes current")
        } catch {
            recordUnexpected(error, context: "atomic action revision")
        }
    }

    mutating func verifyTerminalStopJoinsAllWork() async {
        let broker = ActivityBroker()
        let handler = CancellationWaitingActionHandler()
        let model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        model.start()
        do {
            let submitted = try await broker.submit(
                request(
                    id: "terminal-action",
                    title: "Terminal action",
                    actionIdentifier: "terminal.cancel",
                    actionLabel: "Cancel",
                    actionIntent: .cancel
                )
            )
            check(
                await waitUntil { model.snapshotVersion == submitted.version && model.currentAction != nil },
                "terminal-stop action becomes current"
            )
            if let action = model.currentAction {
                check(model.dispatch(action), "terminal-stop action task begins")
                check(
                    await waitUntil { handler.didStart && model.workState.hasActionTask },
                    "terminal-stop test observes physical action task ownership"
                )
            } else {
                check(false, "terminal-stop action is available")
                check(false, "terminal-stop action task cannot begin")
            }
        } catch {
            recordUnexpected(error, context: "terminal stop action")
        }

        await model.stop()
        check(handler.didFinishAfterCancellation, "terminal stop joins the cancellation-cooperative action task")
        check(model.workState == .stopped, "terminal stop clears physical snapshot/action task ownership")
        check(await broker.workState().subscriberCount == 0, "terminal stop unregisters its subscriber before returning")
    }

    mutating func verifyCancelledActionOwnershipAndTerminalDrain() async {
        await verifySupersessionShutdownDrainsOrphanCandidate()
        await verifyStreamEndShutdownDrainsOrphanCandidate()
        await verifySupersedeNewDispatchSerializesAndDrains()
        await verifyRepeatedSupersessionStaysBounded()
    }

    private mutating func verifySupersessionShutdownDrainsOrphanCandidate() async {
        let broker = ActivityBroker()
        let handler = TrackingGatedActionHandler()
        let model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        model.start()
        guard await submitAndDispatchTrackedAction(
            broker: broker,
            model: model,
            handler: handler,
            id: "supersession-shutdown"
        ) else {
            await model.shutdown()
            return
        }

        do {
            let replacement = try await broker.submit(
                request(
                    id: "supersession-shutdown",
                    title: "Replacement revision",
                    actionIdentifier: "supersession-shutdown.replacement",
                    actionLabel: "Replace",
                    actionIntent: .cancel
                )
            )
            check(
                await waitUntil {
                    model.snapshotVersion == replacement.version
                        && handler.blockedInvocations.contains(0)
                },
                "snapshot supersession cancels the old action into the deterministic gate"
            )
        } catch {
            recordUnexpected(error, context: "supersession shutdown replacement")
        }
        check(model.workState.unsettledActionTaskCount == 1, "superseded action remains owned while physically unsettled")

        var shutdownReturned = false
        let shutdownTask = Task { @MainActor in
            await model.shutdown()
            shutdownReturned = true
        }
        for _ in 0..<50 { await Task.yield() }
        check(!shutdownReturned, "shutdown cannot return while superseded action cleanup is gated")
        check(handler.activeHandlerCount == 1, "superseded handler remains physically active before release")
        handler.release(invocation: 0)
        await shutdownTask.value
        check(shutdownReturned, "shutdown returns after superseded action physically exits")
        check(handler.activeHandlerCount == 0, "supersession shutdown reaches zero active handlers")
        check(model.workState == .stopped, "supersession shutdown clears every owned task token")
    }

    private mutating func verifyStreamEndShutdownDrainsOrphanCandidate() async {
        let fixtureBroker = ActivityBroker()
        let handler = TrackingGatedActionHandler()
        do {
            let initial = try await fixtureBroker.submit(
                request(
                    id: "stream-end-shutdown",
                    title: "Stream ending action",
                    actionIdentifier: "stream-end-shutdown.cancel",
                    actionLabel: "Cancel",
                    actionIntent: .cancel
                )
            )
            let source = ControllableSnapshotSource(initialSnapshot: initial)
            let model = SurfaceActivityModel(snapshotSource: source, actionHandler: handler)
            model.start()
            check(
                await waitUntil { model.currentAction != nil && model.phase == .active },
                "controllable stream delivers its initial action"
            )
            guard let action = model.currentAction else {
                check(false, "stream-end action is dispatchable")
                await model.shutdown()
                return
            }
            check(model.dispatch(action), "stream-end action begins physical handler work")
            check(await waitUntil { handler.activeHandlerCount == 1 }, "stream-end handler becomes physically active")

            await source.finishCurrentStream()
            check(
                await waitUntil {
                    model.phase == .degraded && handler.blockedInvocations.contains(0)
                },
                "stream end cancels but retains the gated action task"
            )
            check(model.workState.unsettledActionTaskCount == 1, "stream-ended action remains explicitly owned")

            var shutdownReturned = false
            let shutdownTask = Task { @MainActor in
                await model.shutdown()
                shutdownReturned = true
            }
            for _ in 0..<50 { await Task.yield() }
            check(!shutdownReturned, "shutdown waits for action orphan candidate after stream end")
            handler.release(invocation: 0)
            await shutdownTask.value
            check(handler.activeHandlerCount == 0, "stream-end shutdown returns only at zero active handlers")
            check(model.workState == .stopped, "stream-end shutdown clears retained task ownership")
            check(await source.subscriberCount == 0, "stream end leaves zero source subscribers")
        } catch {
            recordUnexpected(error, context: "stream-end shutdown fixture")
        }
    }

    private mutating func verifySupersedeNewDispatchSerializesAndDrains() async {
        let broker = ActivityBroker()
        let handler = TrackingGatedActionHandler()
        let model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        model.start()
        guard await submitAndDispatchTrackedAction(
            broker: broker,
            model: model,
            handler: handler,
            id: "serialized-actions"
        ) else {
            await model.shutdown()
            return
        }

        do {
            let replacement = try await broker.submit(
                request(
                    id: "serialized-actions",
                    title: "Serialized replacement",
                    actionIdentifier: "serialized-actions.second",
                    actionLabel: "Second",
                    actionIntent: .cancel
                )
            )
            check(
                await waitUntil {
                    model.snapshotVersion == replacement.version
                        && handler.blockedInvocations.contains(0)
                        && model.currentAction != nil
                },
                "replacement action arrives while cancelled predecessor is gated"
            )
            guard let replacementAction = model.currentAction else {
                check(false, "replacement exposes a dispatchable action")
                handler.releaseAll()
                await model.shutdown()
                return
            }
            check(model.dispatch(replacementAction), "replacement action is accepted behind its unsettled predecessor")
            check(
                model.workState.unsettledActionTaskCount == SurfaceActivityModel.maximumUnsettledActionTaskCount,
                "serialized predecessor and successor fill the explicit two-task ownership bound"
            )
            check(handler.activeHandlerCount == 1, "queued successor does not execute concurrently")
            check(handler.maximumActiveHandlerCount == SurfaceActivityModel.maximumConcurrentActionHandlerCount, "physical handler concurrency remains capped at one")
            check(model.actionDispatchState == .inProgress, "replacement action remains visibly in progress")

            handler.release(invocation: 0)
            check(
                await waitUntil { handler.startCount == 2 && handler.activeHandlerCount == 1 },
                "successor begins only after stale predecessor physically exits"
            )
            check(model.actionDispatchState == .inProgress, "stale predecessor completion cannot alter current action state")
            check(model.workState.unsettledActionTaskCount == 1, "immutable predecessor token removes only itself on completion")

            var shutdownReturned = false
            let shutdownTask = Task { @MainActor in
                await model.shutdown()
                shutdownReturned = true
            }
            check(
                await waitUntil { handler.blockedInvocations.contains(1) },
                "shutdown cancellation gates the serialized successor"
            )
            for _ in 0..<50 { await Task.yield() }
            check(!shutdownReturned, "shutdown remains suspended while successor cleanup is active")
            handler.release(invocation: 1)
            await shutdownTask.value
            check(handler.activeHandlerCount == 0, "serialized shutdown returns at zero physical handlers")
            check(model.workState == .stopped, "serialized shutdown removes all immutable task tokens")
        } catch {
            recordUnexpected(error, context: "serialized successor action")
            handler.releaseAll()
            await model.shutdown()
        }
    }

    private mutating func verifyRepeatedSupersessionStaysBounded() async {
        let broker = ActivityBroker()
        let handler = TrackingGatedActionHandler()
        let model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        model.start()
        guard await submitAndDispatchTrackedAction(
            broker: broker,
            model: model,
            handler: handler,
            id: "bounded-supersession"
        ) else {
            await model.shutdown()
            return
        }

        var neverExceededBound = true
        var rejectedAtCapacity = false
        do {
            for revision in 1...40 {
                let replacement = try await broker.submit(
                    request(
                        id: "bounded-supersession",
                        title: "Bounded replacement \(revision)",
                        actionIdentifier: "bounded-supersession.\(revision)",
                        actionLabel: "Revision \(revision)",
                        actionIntent: .cancel
                    )
                )
                _ = await waitUntil { model.snapshotVersion == replacement.version }
                if let action = model.currentAction {
                    let accepted = model.dispatch(action)
                    if !accepted { rejectedAtCapacity = true }
                }
                if model.workState.unsettledActionTaskCount > SurfaceActivityModel.maximumUnsettledActionTaskCount {
                    neverExceededBound = false
                }
            }
        } catch {
            recordUnexpected(error, context: "repeated supersession")
        }
        check(rejectedAtCapacity, "repeated supersession safely rejects dispatch after ownership reaches capacity")
        check(neverExceededBound, "repeated supersession never exceeds the documented unsettled-task bound")
        check(model.workState.unsettledActionTaskCount == 2, "bounded supersession retains exactly its active and queued tasks")
        check(handler.activeHandlerCount == 1 && handler.maximumActiveHandlerCount == 1, "bounded supersession keeps one physical handler")

        let shutdownTask = Task { @MainActor in
            await model.shutdown()
        }
        check(
            await waitUntil { handler.blockedInvocations.contains(0) },
            "bounded supersession predecessor reaches its cancellation gate"
        )
        handler.release(invocation: 0)
        await shutdownTask.value
        check(handler.activeHandlerCount == 0, "bounded supersession shutdown drains physical work")
        check(model.workState == .stopped, "bounded supersession shutdown removes queued ownership")
    }

    mutating func verifyTerminalOverlapAwaitBarriers() async {
        await verifyModelStopJoinsConcurrentShutdown()
        await verifyCoordinatorStopJoinsConcurrentShutdown()
        await verifyCoordinatorStopFirstJoinsTerminalCleanup()
        await verifyCoordinatorUpdateFirstJoinsTerminalCleanup()
    }

    mutating func verifyLegacyCompatibilityDefaultsAreInert() {
        let geometry = makeDisplaySnapshot(identity: 12, isMain: true).geometry
        let legacySurface = PanelSurfaceModel(displayGeometry: geometry)
        check(legacySurface.state == .compact, "legacy surface initializer preserves its compact default")
        check(legacySurface.activityModel.phase == .stopped, "legacy surface initializer injects a stopped activity model")
        check(legacySurface.activityModel.workState == .stopped, "legacy surface initializer owns zero activity work")

        let displays = FakeDisplayProvider(displays: [makeDisplaySnapshot(identity: 12, isMain: true)])
        let events = FakeLifecycleEventSource()
        let registry = SharedModelPanelRegistry()
        let legacyFactory: PanelPresentationFactory = { snapshot in
            registry.makePanel(snapshot: snapshot, activityModel: legacySurface.activityModel)
        }
        let coordinator = PanelCoordinator(
            displayProvider: displays,
            policy: .safeDefault,
            lifecycleEventSource: events,
            panelFactory: legacyFactory
        )
        coordinator.start()
        check(events.isRunning && registry.openPanelCount == 1, "legacy coordinator start remains immediately observable")
        coordinator.update(policy: DisplayPolicy(isEnabled: false))
        check(!events.isRunning && registry.openPanelCount == 0, "legacy coordinator disable immediately retires events and panels")
        coordinator.stop()
        check(registry.mutationSnapshot.closeCount == 1, "legacy coordinator stop does not duplicate panel cleanup")

        _ = PanelCoordinator(
            displayProvider: displays,
            policy: DisplayPolicy(isEnabled: false),
            lifecycleEventSource: FakeLifecycleEventSource()
        )
        check(legacySurface.activityModel.workState == .stopped, "legacy compatibility paths remain subscriber- and task-free")
    }

    private mutating func verifyModelStopJoinsConcurrentShutdown() async {
        let broker = ActivityBroker()
        let handler = TrackingGatedActionHandler()
        let model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        model.start()
        guard await submitAndDispatchTrackedAction(
            broker: broker,
            model: model,
            handler: handler,
            id: "model-terminal-overlap"
        ) else {
            await model.shutdown()
            return
        }

        var shutdownReturned = false
        let shutdownTask = Task { @MainActor in
            await model.shutdown()
            shutdownReturned = true
        }
        check(
            await waitUntil {
                let subscriberCount = await broker.workState().subscriberCount
                return handler.blockedInvocations.contains(0)
                    && handler.activeHandlerCount == 1
                    && model.workState.unsettledActionTaskCount == 1
                    && subscriberCount == 0
            },
            "model terminal-overlap fixture blocks after cancellation with owned work"
        )

        var stopReturned = false
        let stopTask = Task { @MainActor in
            await model.stop()
            stopReturned = true
        }
        for _ in 0..<50 { await Task.yield() }
        check(!shutdownReturned, "model shutdown remains suspended while physical action cleanup is gated")
        check(!stopReturned, "overlapping model stop joins the in-flight terminal drain")
        check(
            handler.activeHandlerCount == 1 && model.workState.unsettledActionTaskCount == 1,
            "joined model stop cannot return while terminal action work remains active"
        )

        handler.release(invocation: 0)
        await shutdownTask.value
        await stopTask.value
        check(shutdownReturned && stopReturned, "model shutdown and joined stop settle after physical cleanup")
        check(handler.activeHandlerCount == 0, "model terminal overlap returns at zero active handlers")
        check(model.workState == .stopped, "model terminal overlap returns with zero owned tasks")
        check(await broker.workState().subscriberCount == 0, "model terminal overlap returns with zero subscribers")
    }

    private mutating func verifyCoordinatorStopJoinsConcurrentShutdown() async {
        let broker = ActivityBroker()
        let handler = TrackingGatedActionHandler()
        let model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        let displays = FakeDisplayProvider(displays: [makeDisplaySnapshot(identity: 10, isMain: true)])
        let events = FakeLifecycleEventSource()
        let registry = SharedModelPanelRegistry()
        let coordinator = makeCoordinator(
            displays: displays,
            events: events,
            registry: registry,
            model: model
        )
        await coordinator.startAndWait()
        guard await submitAndDispatchTrackedAction(
            broker: broker,
            model: model,
            handler: handler,
            id: "coordinator-terminal-overlap"
        ) else {
            await coordinator.shutdown()
            return
        }

        var shutdownReturned = false
        let shutdownTask = Task { @MainActor in
            await coordinator.shutdown()
            shutdownReturned = true
        }
        check(
            await waitUntil {
                let subscriberCount = await broker.workState().subscriberCount
                return handler.blockedInvocations.contains(0)
                    && handler.activeHandlerCount == 1
                    && model.workState.unsettledActionTaskCount == 1
                    && !events.isRunning
                    && registry.openPanelCount == 1
                    && subscriberCount == 0
            },
            "coordinator terminal-overlap fixture retires events but retains panels through gated model cleanup"
        )

        var stopReturned = [false, false, false]
        let stopTasks = (0..<stopReturned.count).map { index in
            Task { @MainActor in
                await coordinator.stopAndWait()
                stopReturned[index] = true
            }
        }
        stopTasks[1].cancel()
        for _ in 0..<50 { await Task.yield() }
        check(!shutdownReturned, "coordinator shutdown remains suspended while terminal model cleanup is gated")
        check(stopReturned.allSatisfy { !$0 }, "multiple and cancelled coordinator stops join the in-flight terminal cleanup")
        check(
            registry.openPanelCount == 1 && handler.activeHandlerCount == 1,
            "joined coordinator stop cannot return with panels or action work unsettled"
        )

        handler.release(invocation: 0)
        await shutdownTask.value
        for task in stopTasks { await task.value }
        check(shutdownReturned && stopReturned.allSatisfy { $0 }, "coordinator shutdown and all joined stops settle together")
        check(handler.activeHandlerCount == 0 && model.workState == .stopped, "coordinator terminal overlap returns with zero model work")
        check(await broker.workState().subscriberCount == 0, "coordinator terminal overlap returns with zero subscribers")
        check(!events.isRunning && events.runningInstanceCount == 0, "coordinator terminal overlap returns with zero event work")
        check(coordinator.activeDisplayIdentities.isEmpty && registry.openPanelCount == 0, "coordinator terminal overlap returns with zero panels")
        check(registry.mutationSnapshot.closeCount == 1, "coordinator terminal cleanup closes its panel exactly once")
    }

    private mutating func verifyCoordinatorStopFirstJoinsTerminalCleanup() async {
        let broker = ActivityBroker()
        let handler = TrackingGatedActionHandler()
        let model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        let displays = FakeDisplayProvider(displays: [makeDisplaySnapshot(identity: 11, isMain: true)])
        let events = FakeLifecycleEventSource()
        let registry = SharedModelPanelRegistry()
        let coordinator = makeCoordinator(
            displays: displays,
            events: events,
            registry: registry,
            model: model
        )
        await coordinator.startAndWait()
        guard await submitAndDispatchTrackedAction(
            broker: broker,
            model: model,
            handler: handler,
            id: "coordinator-stop-first-terminal-overlap"
        ) else {
            await coordinator.shutdown()
            return
        }

        var firstStopReturned = false
        let firstStopTask = Task { @MainActor in
            await coordinator.stopAndWait()
            firstStopReturned = true
        }
        check(
            await waitUntil {
                let subscriberCount = await broker.workState().subscriberCount
                return handler.blockedInvocations.contains(0)
                    && handler.activeHandlerCount == 1
                    && model.workState.unsettledActionTaskCount == 1
                    && !events.isRunning
                    && registry.openPanelCount == 0
                    && subscriberCount == 0
            },
            "stop-first fixture suspends in cancellation-insensitive cleanup after synchronous panel closure"
        )

        var shutdownStarted = false
        var shutdownReturned = false
        let shutdownTask = Task { @MainActor in
            shutdownStarted = true
            await coordinator.shutdown()
            shutdownReturned = true
        }
        check(await waitUntil { shutdownStarted }, "stop-first fixture lets shutdown take terminal ownership")

        var joinedStopReturned = [false, false, false]
        let joinedStopTasks = (0..<joinedStopReturned.count).map { index in
            Task { @MainActor in
                await coordinator.stopAndWait()
                joinedStopReturned[index] = true
            }
        }
        joinedStopTasks[1].cancel()
        for _ in 0..<50 { await Task.yield() }
        check(!firstStopReturned, "stop begun before shutdown still joins the terminal barrier")
        check(!shutdownReturned, "stop-first shutdown remains suspended until physical model cleanup settles")
        check(joinedStopReturned.allSatisfy { !$0 }, "later multiple and cancelled stops also remain behind the terminal barrier")
        check(
            registry.openPanelCount == 0 && handler.activeHandlerCount == 1,
            "no stop caller returns while the terminal owner still has action work"
        )

        handler.release(invocation: 0)
        await shutdownTask.value
        await firstStopTask.value
        for task in joinedStopTasks { await task.value }
        check(
            firstStopReturned && shutdownReturned && joinedStopReturned.allSatisfy { $0 },
            "stop-first terminal owner and every waiter settle after cleanup"
        )
        check(handler.activeHandlerCount == 0 && model.workState == .stopped, "stop-first overlap returns with zero model work")
        check(await broker.workState().subscriberCount == 0, "stop-first overlap returns with zero subscribers")
        check(!events.isRunning && events.runningInstanceCount == 0, "stop-first overlap returns with zero event work")
        check(coordinator.activeDisplayIdentities.isEmpty && registry.openPanelCount == 0, "stop-first overlap returns with zero panels")
        check(registry.mutationSnapshot.closeCount == 1, "stop-first terminal cleanup closes its panel exactly once")
    }

    private mutating func verifyCoordinatorUpdateFirstJoinsTerminalCleanup() async {
        let broker = ActivityBroker()
        let handler = TrackingGatedActionHandler()
        let model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        let displays = FakeDisplayProvider(displays: [makeDisplaySnapshot(identity: 12, isMain: true)])
        let events = FakeLifecycleEventSource()
        let registry = SharedModelPanelRegistry()
        let coordinator = makeCoordinator(
            displays: displays,
            events: events,
            registry: registry,
            model: model
        )
        await coordinator.startAndWait()
        guard await submitAndDispatchTrackedAction(
            broker: broker,
            model: model,
            handler: handler,
            id: "coordinator-update-first-terminal-overlap"
        ) else {
            await coordinator.shutdown()
            return
        }

        var updateReturned = false
        let updateTask = Task { @MainActor in
            await coordinator.updateAndWait(policy: DisplayPolicy(isEnabled: false))
            updateReturned = true
        }
        check(
            await waitUntil {
                let subscriberCount = await broker.workState().subscriberCount
                return handler.blockedInvocations.contains(0)
                    && handler.activeHandlerCount == 1
                    && model.workState.unsettledActionTaskCount == 1
                    && model.lifecycleRequestTaskCount == 1
                    && !events.isRunning
                    && registry.openPanelCount == 0
                    && subscriberCount == 0
            },
            "update-first fixture blocks after disabling UI and subscriber work"
        )

        var shutdownReturned = false
        let shutdownTask = Task { @MainActor in
            await coordinator.shutdown()
            shutdownReturned = true
        }
        shutdownTask.cancel()
        var joinedUpdatesReturned = [false, false]
        let joinedUpdates = (0..<joinedUpdatesReturned.count).map { index in
            Task { @MainActor in
                await coordinator.updateAndWait(policy: DisplayPolicy(isEnabled: false))
                joinedUpdatesReturned[index] = true
            }
        }
        joinedUpdates[1].cancel()
        for _ in 0..<50 { await Task.yield() }
        check(!updateReturned, "update begun before shutdown joins terminal cleanup")
        check(!shutdownReturned, "cancelled shutdown remains a physical cleanup barrier")
        check(joinedUpdatesReturned.allSatisfy { !$0 }, "multiple and cancelled policy waiters join terminal cleanup")
        check(
            handler.activeHandlerCount == 1
                && model.lifecycleRequestTaskCount == 1
                && registry.openPanelCount == 0,
            "no update waiter returns while terminal action work remains physically active"
        )

        handler.release(invocation: 0)
        await shutdownTask.value
        await updateTask.value
        for task in joinedUpdates { await task.value }
        check(
            updateReturned && shutdownReturned && joinedUpdatesReturned.allSatisfy { $0 },
            "update-first terminal owner and every waiter settle together"
        )
        check(handler.activeHandlerCount == 0, "update-first overlap returns at zero active handlers")
        check(model.workState == .stopped && model.lifecycleRequestTaskCount == 0, "update-first overlap returns with zero model task ownership")
        check(await broker.workState().subscriberCount == 0, "update-first overlap returns with zero subscribers")
        check(!events.isRunning && events.runningInstanceCount == 0, "update-first overlap returns with zero event work")
        check(coordinator.activeDisplayIdentities.isEmpty && registry.openPanelCount == 0, "update-first overlap returns with zero panels")
        check(registry.mutationSnapshot.closeCount == 1, "update-first cleanup closes its panel exactly once")
    }

    private mutating func submitAndDispatchTrackedAction(
        broker: ActivityBroker,
        model: SurfaceActivityModel,
        handler: TrackingGatedActionHandler,
        id: String
    ) async -> Bool {
        do {
            let submitted = try await broker.submit(
                request(
                    id: id,
                    title: "Tracked action",
                    actionIdentifier: "\(id).first",
                    actionLabel: "First",
                    actionIntent: .cancel
                )
            )
            check(
                await waitUntil { model.snapshotVersion == submitted.version && model.currentAction != nil },
                "\(id) tracked action reaches the model"
            )
            guard let action = model.currentAction else {
                check(false, "\(id) tracked action is dispatchable")
                return false
            }
            check(model.dispatch(action), "\(id) tracked action dispatches")
            check(
                await waitUntil { handler.activeHandlerCount == 1 },
                "\(id) tracked handler becomes physically active"
            )
            return true
        } catch {
            recordUnexpected(error, context: "\(id) tracked action fixture")
            return false
        }
    }

    mutating func verifyOverlappingLifecycleRequestsAreLatestWins() async {
        await verifyModelStartDuringBlockedStopDrain()
        await verifyCoordinatorOnOffOnDuringBlockedDrain()
        await verifyCoordinatorStopStartDuringBlockedDrain()
        await verifySynchronousCompatibilityRequestsAreLatestWins()
        await verifyCoordinatorShutdownIsTerminal()
    }

    private mutating func verifySynchronousCompatibilityRequestsAreLatestWins() async {
        let broker = ActivityBroker()
        let model = SurfaceActivityModel(broker: broker)
        let displays = FakeDisplayProvider(displays: [makeDisplaySnapshot(identity: 13, isMain: true)])
        let events = FakeLifecycleEventSource()
        let registry = SharedModelPanelRegistry()
        let coordinator = makeCoordinator(
            displays: displays,
            events: events,
            registry: registry,
            model: model
        )
        await coordinator.startAndWait()
        check(
            await waitUntil { await broker.workState().subscriberCount == 1 },
            "sync compatibility fixture starts one subscriber"
        )

        for _ in 0..<25 {
            coordinator.stop()
            check(model.lifecycleRequestTaskCount <= 1, "sync stop owns at most one model lifecycle task")
            coordinator.start()
            await coordinator.startAndWait()
            check(coordinator.isRunning && events.isRunning, "sync stop-start keeps the latest running state")
            check(registry.openPanelCount == 1, "sync stop-start retains exactly one current panel")
            check(model.isRunning && model.lifecycleRequestTaskCount == 0, "sync stop-start settles its owned model request")
            check(await broker.workState().subscriberCount == 1, "sync stop-start retains exactly one subscriber")

            coordinator.update(policy: DisplayPolicy(isEnabled: false))
            check(model.lifecycleRequestTaskCount <= 1, "sync disable owns at most one model lifecycle task")
            coordinator.update(policy: .safeDefault)
            await coordinator.updateAndWait(policy: .safeDefault)
            check(coordinator.policy.isEnabled && events.isRunning, "sync disable-enable keeps the latest enabled policy")
            check(registry.openPanelCount == 1, "sync disable-enable retains exactly one current panel")
            check(model.isRunning && model.lifecycleRequestTaskCount == 0, "sync disable-enable settles its owned model request")
            check(await broker.workState().subscriberCount == 1, "sync disable-enable retains exactly one subscriber")
        }

        await coordinator.stopAndWait()
        check(!events.isRunning && registry.openPanelCount == 0, "sync compatibility fixture closes events and panels")
        check(model.workState == .stopped && model.lifecycleRequestTaskCount == 0, "sync compatibility fixture settles every model task")
        check(await broker.workState().subscriberCount == 0, "sync compatibility fixture settles every subscriber")
    }

    mutating func verifyStopIntentSynchronouslyRevokesAdmission() async {
        let stopBroker = ActivityBroker()
        let stopHandler = RecordingActionHandler(outcome: .unhandled)
        let stopModel = SurfaceActivityModel(broker: stopBroker, actionHandler: stopHandler)
        let stopEvents = FakeLifecycleEventSource()
        let stopRegistry = SharedModelPanelRegistry()
        let stopCoordinator = makeCoordinator(
            displays: FakeDisplayProvider(displays: [makeDisplaySnapshot(identity: 14, isMain: true)]),
            events: stopEvents,
            registry: stopRegistry,
            model: stopModel
        )
        await stopCoordinator.startAndWait()
        do {
            _ = try await stopBroker.submit(
                request(
                    id: "public-stop-admission",
                    title: "Stop admission",
                    actionIdentifier: "public-stop-admission.cancel",
                    actionLabel: "Cancel",
                    actionIntent: .cancel
                )
            )
        } catch {
            recordUnexpected(error, context: "public stop-admission fixture")
        }
        check(
            await waitUntil { stopModel.currentAction != nil && stopModel.phase == .active },
            "public stop-admission fixture exposes a live action"
        )
        guard let stoppedAction = stopModel.currentAction else {
            check(false, "public stop-admission fixture saves an action")
            await stopCoordinator.stopAndWait()
            return
        }

        stopCoordinator.stop()
        check(!stopCoordinator.isRunning, "public synchronous stop records coordinator intent immediately")
        check(stopModel.isRunning && stopModel.phase == .active, "public synchronous stop can precede physical model drain")
        check(!stopModel.dispatch(stoppedAction), "public synchronous stop immediately rejects a saved action")
        check(
            stopModel.workState.unsettledActionTaskCount == 0 && stopHandler.invocations.isEmpty,
            "public synchronous stop creates no action task or handler invocation"
        )
        await stopCoordinator.stopAndWait()
        check(stopModel.workState == .stopped, "public synchronous stop settles with zero model work")
        check(await stopBroker.workState().subscriberCount == 0, "public synchronous stop settles with zero subscribers")
        check(!stopEvents.isRunning && stopRegistry.openPanelCount == 0, "public synchronous stop settles with zero events and panels")

        let disableBroker = ActivityBroker()
        let disableHandler = RecordingActionHandler(outcome: .unhandled)
        let disableModel = SurfaceActivityModel(broker: disableBroker, actionHandler: disableHandler)
        let disableEvents = FakeLifecycleEventSource()
        let disableRegistry = SharedModelPanelRegistry()
        let disableCoordinator = makeCoordinator(
            displays: FakeDisplayProvider(displays: [makeDisplaySnapshot(identity: 15, isMain: true)]),
            events: disableEvents,
            registry: disableRegistry,
            model: disableModel
        )
        await disableCoordinator.startAndWait()
        do {
            _ = try await disableBroker.submit(
                request(
                    id: "public-disable-admission",
                    title: "Disable admission",
                    actionIdentifier: "public-disable-admission.cancel",
                    actionLabel: "Cancel",
                    actionIntent: .cancel
                )
            )
        } catch {
            recordUnexpected(error, context: "public disable-admission fixture")
        }
        check(
            await waitUntil { disableModel.currentAction != nil && disableModel.phase == .active },
            "public disable-admission fixture exposes a live action"
        )
        guard let disabledAction = disableModel.currentAction else {
            check(false, "public disable-admission fixture saves an action")
            await disableCoordinator.stopAndWait()
            return
        }

        disableCoordinator.update(policy: DisplayPolicy(isEnabled: false))
        check(!disableCoordinator.policy.isEnabled, "public synchronous disable records policy intent immediately")
        check(disableModel.isRunning && disableModel.phase == .active, "public synchronous disable can precede physical model drain")
        check(!disableModel.dispatch(disabledAction), "public synchronous disable immediately rejects a saved action")
        check(
            disableModel.workState.unsettledActionTaskCount == 0 && disableHandler.invocations.isEmpty,
            "public synchronous disable creates no action task or handler invocation"
        )
        await disableCoordinator.updateAndWait(policy: DisplayPolicy(isEnabled: false))
        check(disableModel.workState == .stopped, "public synchronous disable settles with zero model work")
        check(await disableBroker.workState().subscriberCount == 0, "public synchronous disable settles with zero subscribers")
        check(!disableEvents.isRunning && disableRegistry.openPanelCount == 0, "public synchronous disable settles with zero events and panels")

        let reopenBroker = ActivityBroker()
        let reopenHandler = RecordingActionHandler(outcome: .unhandled)
        let reopenModel = SurfaceActivityModel(broker: reopenBroker, actionHandler: reopenHandler)
        let reopenEvents = FakeLifecycleEventSource()
        let reopenRegistry = SharedModelPanelRegistry()
        let reopenCoordinator = makeCoordinator(
            displays: FakeDisplayProvider(displays: [makeDisplaySnapshot(identity: 16, isMain: true)]),
            events: reopenEvents,
            registry: reopenRegistry,
            model: reopenModel
        )
        await reopenCoordinator.startAndWait()
        do {
            _ = try await reopenBroker.submit(
                request(
                    id: "public-reopen-admission",
                    title: "Reopen admission",
                    actionIdentifier: "public-reopen-admission.cancel",
                    actionLabel: "Cancel",
                    actionIntent: .cancel
                )
            )
        } catch {
            recordUnexpected(error, context: "public reopen-admission fixture")
        }
        check(
            await waitUntil { reopenModel.currentAction != nil && reopenModel.phase == .active },
            "public reopen-admission fixture exposes a live action"
        )
        guard let reopenedAction = reopenModel.currentAction else {
            check(false, "public reopen-admission fixture saves an action")
            await reopenCoordinator.stopAndWait()
            return
        }

        reopenCoordinator.stop()
        check(!reopenModel.dispatch(reopenedAction), "rapid stop closes admission before its drain runs")
        reopenCoordinator.start()
        check(!reopenModel.dispatch(reopenedAction), "rapid start cannot revive action content from the retired epoch")
        await reopenCoordinator.startAndWait()
        check(
            await waitUntil { reopenModel.currentAction != nil && reopenModel.phase == .active },
            "rapid start receives a fresh snapshot in the successor epoch"
        )
        guard let restartedAction = reopenModel.currentAction else {
            check(false, "rapid start exposes a fresh successor action")
            await reopenCoordinator.stopAndWait()
            return
        }
        check(reopenModel.dispatch(restartedAction), "fresh post-start content reopens action admission")
        check(
            await waitUntil { reopenHandler.invocations.count == 1 && !reopenModel.workState.hasActionTask },
            "rapid stop-start runs exactly one post-start handler and settles ownership"
        )
        check(await reopenBroker.workState().subscriberCount == 1, "rapid stop-start retains exactly one subscriber")

        reopenCoordinator.update(policy: DisplayPolicy(isEnabled: false))
        check(!reopenModel.dispatch(restartedAction), "rapid disable closes admission before its drain runs")
        reopenCoordinator.update(policy: .safeDefault)
        check(!reopenModel.dispatch(restartedAction), "rapid enable cannot revive action content from the retired epoch")
        await reopenCoordinator.updateAndWait(policy: .safeDefault)
        check(
            await waitUntil { reopenModel.currentAction != nil && reopenModel.phase == .active },
            "rapid enable receives a fresh snapshot in the successor epoch"
        )
        guard let reenabledAction = reopenModel.currentAction else {
            check(false, "rapid enable exposes a fresh successor action")
            await reopenCoordinator.stopAndWait()
            return
        }
        check(reopenModel.dispatch(reenabledAction), "fresh post-enable content reopens action admission")
        check(
            await waitUntil { reopenHandler.invocations.count == 2 && !reopenModel.workState.hasActionTask },
            "rapid disable-enable runs exactly one post-enable handler and settles ownership"
        )
        check(reopenEvents.isRunning && reopenRegistry.openPanelCount == 1, "rapid reopen retains one event source and panel")
        check(await reopenBroker.workState().subscriberCount == 1, "rapid disable-enable retains exactly one subscriber")

        await reopenCoordinator.stopAndWait()
        check(reopenModel.workState == .stopped, "rapid reopen fixture ends with zero model work")
        check(await reopenBroker.workState().subscriberCount == 0, "rapid reopen fixture ends with zero subscribers")
        check(!reopenEvents.isRunning && reopenRegistry.openPanelCount == 0, "rapid reopen fixture ends with zero events and panels")
    }

    mutating func verifyPendingSubscriptionEpochRetirement() async {
        await verifyPendingSubscriptionEpochRetirement(
            lifecycleName: "stop-start",
            identity: 17,
            retireAndReopen: { coordinator in
                coordinator.stop()
                coordinator.start()
            },
            settle: { coordinator in
                await coordinator.startAndWait()
            }
        )
        await verifyPendingSubscriptionEpochRetirement(
            lifecycleName: "disable-enable",
            identity: 18,
            retireAndReopen: { coordinator in
                coordinator.update(policy: DisplayPolicy(isEnabled: false))
                coordinator.update(policy: .safeDefault)
            },
            settle: { coordinator in
                await coordinator.updateAndWait(policy: .safeDefault)
            }
        )
    }

    private mutating func verifyPendingSubscriptionEpochRetirement(
        lifecycleName: String,
        identity: UInt32,
        retireAndReopen: (PanelCoordinator) -> Void,
        settle: (PanelCoordinator) async -> Void
    ) async {
        do {
            let retiredActivity = try Activity(
                validating: request(
                    id: "\(lifecycleName)-retired-subscription",
                    title: "Retired version 42"
                )
            )
            let successorActivity = try Activity(
                validating: request(
                    id: "\(lifecycleName)-successor-subscription",
                    title: "Fresh successor content"
                )
            )
            let retiredSnapshot = ActivityBrokerSnapshot(
                version: 42,
                current: PresentedActivity(
                    activity: retiredActivity,
                    submissionSequence: 1,
                    revision: 1
                ),
                queued: []
            )
            let successorSnapshot = ActivityBrokerSnapshot(
                version: 43,
                current: PresentedActivity(
                    activity: successorActivity,
                    submissionSequence: 2,
                    revision: 1
                ),
                queued: []
            )
            let source = GatedInitialSnapshotSource(
                retiredSnapshot: retiredSnapshot,
                successorSnapshot: successorSnapshot
            )
            let model = SurfaceActivityModel(
                snapshotSource: source,
                actionHandler: UnavailableActivityActionHandler()
            )
            let events = FakeLifecycleEventSource()
            let registry = SharedModelPanelRegistry()
            let coordinator = makeCoordinator(
                displays: FakeDisplayProvider(
                    displays: [makeDisplaySnapshot(identity: identity, isMain: true)]
                ),
                events: events,
                registry: registry,
                model: model
            )

            coordinator.start()
            check(
                await waitUntil { await source.firstCallIsBlocked },
                "\(lifecycleName) gates the pre-stop snapshotSubscription call"
            )
            let pendingCallCount = await source.callCount
            check(
                model.workState.hasSnapshotTask && pendingCallCount == 1,
                "\(lifecycleName) owns exactly one pending pre-stop subscription task"
            )

            retireAndReopen(coordinator)
            check(
                model.snapshotVersion == 0 && model.current == nil,
                "\(lifecycleName) does not expose pending retired snapshot content"
            )
            for _ in 0..<50 { await Task.yield() }
            check(
                await source.callCount == 1,
                "\(lifecycleName) cannot overlap a successor with the unsettled retired call"
            )

            await source.releaseFirstCall()
            await settle(coordinator)
            check(
                await waitUntil {
                    let sourceState = await source.state
                    return sourceState.callCount == 2
                        && sourceState.secondCallIsBlocked
                        && sourceState.cancelledGenerations == [1]
                },
                "\(lifecycleName) cancels the late old token before the successor call settles"
            )
            let retiredState = await source.state
            check(
                retiredState.activeGenerations.isEmpty
                    && model.snapshotVersion == 0
                    && model.current == nil,
                "\(lifecycleName) leaves no old task or applied version 42 at the successor gate"
            )

            await source.releaseSecondCall()
            check(
                await waitUntil {
                    let sourceState = await source.state
                    return sourceState.callCount == 2
                        && sourceState.activeGenerations == [2]
                        && model.snapshotVersion == 43
                        && model.current?.activity.presentation.title == "Fresh successor content"
                },
                "\(lifecycleName) registers one fresh successor subscription and applies new content"
            )
            let sourceState = await source.state
            check(
                sourceState.cancelledGenerations == [1],
                "\(lifecycleName) explicitly cancels the retired token returned after cancellation"
            )
            check(
                model.snapshotVersion == 43,
                "\(lifecycleName) never applies retired version 42"
            )
            check(
                model.workState.hasSnapshotTask
                    && !model.workState.hasActionTask
                    && sourceState.activeGenerations == [2],
                "\(lifecycleName) retains no old task and exactly one successor subscription"
            )

            await coordinator.stopAndWait()
            check(model.workState == .stopped, "\(lifecycleName) pending-subscription fixture settles zero model work")
            check(await source.state.activeGenerations.isEmpty, "\(lifecycleName) pending-subscription fixture settles zero source work")
            check(!events.isRunning && registry.openPanelCount == 0, "\(lifecycleName) pending-subscription fixture settles zero UI work")
        } catch {
            recordUnexpected(error, context: "\(lifecycleName) pending-subscription epoch fixture")
        }
    }

    private mutating func verifyModelStartDuringBlockedStopDrain() async {
        let broker = ActivityBroker()
        let handler = GatedCancellationActionHandler()
        let model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        model.start()
        guard await beginGatedAction(
            broker: broker,
            model: model,
            handler: handler,
            id: "model-overlap"
        ) else {
            await model.stop()
            return
        }

        let stopTask = Task { @MainActor in
            await model.stop()
        }
        check(
            await waitUntil {
                let subscriberCount = await broker.workState().subscriberCount
                return handler.isBlockedAfterCancellation
                    && model.workState.hasSnapshotTask
                    && model.workState.hasActionTask
                    && subscriberCount == 0
            },
            "model stop is deterministically suspended in a real cancelled action drain"
        )

        model.start()
        check(!model.isRunning, "start during a stop drain records intent without overlapping the draining stream")
        check(await broker.workState().subscriberCount <= 1, "queued model restart never exceeds one broker subscriber")
        handler.release()
        await stopTask.value
        check(
            await waitUntil {
                let subscriberCount = await broker.workState().subscriberCount
                return model.isRunning && subscriberCount == 1
            },
            "start requested during stop drain is replayed after physical cleanup"
        )
        check(model.workState.hasSnapshotTask, "latest model start owns one fresh snapshot task")
        check(!model.workState.hasActionTask, "drained action task cannot leak into the restarted model")

        await model.stop()
        check(await broker.workState().subscriberCount == 0, "overlap model fixture stops with zero subscribers")
    }

    private mutating func verifyCoordinatorOnOffOnDuringBlockedDrain() async {
        let broker = ActivityBroker()
        let handler = GatedCancellationActionHandler()
        let model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        let displays = FakeDisplayProvider(displays: [
            makeDisplaySnapshot(identity: 10, isMain: true),
            makeDisplaySnapshot(identity: 20, originX: 1_440),
        ])
        let events = FakeLifecycleEventSource()
        let registry = SharedModelPanelRegistry()
        let coordinator = makeCoordinator(
            displays: displays,
            events: events,
            registry: registry,
            model: model
        )
        await coordinator.startAndWait()
        guard await beginGatedAction(
            broker: broker,
            model: model,
            handler: handler,
            id: "policy-overlap"
        ) else {
            await coordinator.stopAndWait()
            return
        }

        let disableTask = Task { @MainActor in
            await coordinator.updateAndWait(policy: DisplayPolicy(isEnabled: false))
        }
        check(
            await waitUntil {
                let subscriberCount = await broker.workState().subscriberCount
                return handler.isBlockedAfterCancellation
                    && !events.isRunning
                    && subscriberCount == 0
            },
            "policy disable reaches a gated physical drain after stopping events"
        )
        check(await broker.workState().subscriberCount <= 1, "policy disable drain stays within one subscriber")

        var enableReturned = false
        let enableTask = Task { @MainActor in
            await coordinator.updateAndWait(policy: .safeDefault)
            enableReturned = true
        }
        for _ in 0..<50 { await Task.yield() }
        check(!enableReturned, "awaited policy enable remains behind the active physical drain")
        check(coordinator.isRunning && coordinator.policy.isEnabled, "overlapping on-off-on records enabled as latest policy")
        check(events.isRunning, "latest policy enable reinstalls the event source while the old drain is suspended")
        check(coordinator.activeDisplayIdentities.count == 2, "latest policy enable retains both requested panels")
        check(registry.openPanelCount == 2, "stale disable cleanup has not closed latest-policy panels")
        check(await broker.workState().subscriberCount <= 1, "overlapping policy restart never exceeds one subscriber")

        handler.release()
        await disableTask.value
        await enableTask.value
        check(enableReturned, "awaited policy enable returns after the superseded drain settles")
        check(
            await waitUntil {
                let subscriberCount = await broker.workState().subscriberCount
                return model.isRunning && subscriberCount == 1
            },
            "latest policy enable restarts the model after the stale disable drain"
        )
        check(events.isRunning && events.runningInstanceCount == 1, "on-off-on finishes with exactly one event source")
        check(coordinator.activeDisplayIdentities.count == 2, "stale disable continuation cannot close enabled panels")
        check(registry.openPanelCount == 2, "on-off-on finishes with exactly two open panels")
        check(await broker.workState().subscriberCount == 1, "on-off-on finishes with exactly one subscriber")

        await coordinator.stopAndWait()
        check(!events.isRunning && registry.openPanelCount == 0, "policy overlap fixture cleans up events and panels")
        check(await broker.workState().subscriberCount == 0, "policy overlap fixture cleans up its subscriber")
    }

    private mutating func verifyCoordinatorStopStartDuringBlockedDrain() async {
        let broker = ActivityBroker()
        let handler = GatedCancellationActionHandler()
        let model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        let displays = FakeDisplayProvider(displays: [makeDisplaySnapshot(identity: 10, isMain: true)])
        let events = FakeLifecycleEventSource()
        let registry = SharedModelPanelRegistry()
        let coordinator = makeCoordinator(
            displays: displays,
            events: events,
            registry: registry,
            model: model
        )
        await coordinator.startAndWait()
        guard await beginGatedAction(
            broker: broker,
            model: model,
            handler: handler,
            id: "coordinator-overlap"
        ) else {
            await coordinator.stopAndWait()
            return
        }

        let stopTask = Task { @MainActor in
            await coordinator.stopAndWait()
        }
        check(
            await waitUntil {
                let subscriberCount = await broker.workState().subscriberCount
                return handler.isBlockedAfterCancellation
                    && !events.isRunning
                    && subscriberCount == 0
            },
            "coordinator stop is suspended in the gated model drain"
        )

        var startReturned = false
        let startTask = Task { @MainActor in
            await coordinator.startAndWait()
            startReturned = true
        }
        for _ in 0..<50 { await Task.yield() }
        check(!startReturned, "awaited restart remains behind the active physical stop drain")
        check(coordinator.isRunning, "overlapping stop-start records running as the latest request")
        check(events.isRunning && events.runningInstanceCount == 1, "latest start restores exactly one event source")
        check(coordinator.activeDisplayIdentities.count == 1, "latest start retains the requested panel")
        check(await broker.workState().subscriberCount <= 1, "overlapping coordinator restart never exceeds one subscriber")

        handler.release()
        await stopTask.value
        await startTask.value
        check(startReturned, "awaited restart returns after the superseded stop drain settles")
        check(
            await waitUntil {
                let subscriberCount = await broker.workState().subscriberCount
                return model.isRunning && subscriberCount == 1
            },
            "latest coordinator start restarts the model after stale stop drain"
        )
        check(coordinator.isRunning && events.isRunning, "stop-start finishes running with events active")
        check(coordinator.activeDisplayIdentities.count == 1 && registry.openPanelCount == 1, "stale stop cannot close latest-start panel")
        check(await broker.workState().subscriberCount == 1, "stop-start finishes with exactly one subscriber")

        await coordinator.stopAndWait()
        check(!coordinator.isRunning && !events.isRunning, "stop-start fixture performs a later normal stop")
        check(registry.openPanelCount == 0, "later normal stop closes the restarted panel")
        check(await broker.workState().subscriberCount == 0, "later normal stop removes the restarted subscriber")
    }

    private mutating func verifyCoordinatorShutdownIsTerminal() async {
        let broker = ActivityBroker()
        let handler = GatedCancellationActionHandler()
        let model = SurfaceActivityModel(broker: broker, actionHandler: handler)
        let displays = FakeDisplayProvider(displays: [makeDisplaySnapshot(identity: 10, isMain: true)])
        let events = FakeLifecycleEventSource()
        let registry = SharedModelPanelRegistry()
        let coordinator = makeCoordinator(
            displays: displays,
            events: events,
            registry: registry,
            model: model
        )
        await coordinator.startAndWait()
        guard await beginGatedAction(
            broker: broker,
            model: model,
            handler: handler,
            id: "terminal-overlap"
        ) else {
            await coordinator.shutdown()
            return
        }

        let shutdownTask = Task { @MainActor in
            await coordinator.shutdown()
        }
        check(
            await waitUntil {
                let subscriberCount = await broker.workState().subscriberCount
                return handler.isBlockedAfterCancellation
                    && !events.isRunning
                    && subscriberCount == 0
            },
            "terminal shutdown is gated on physical action cleanup"
        )
        var rejectedRequestsReturned = [false, false, false]
        let rejectedRequests = [
            Task { @MainActor in
                await coordinator.startAndWait()
                rejectedRequestsReturned[0] = true
            },
            Task { @MainActor in
                await coordinator.updateAndWait(policy: DisplayPolicy(isEnabled: false))
                rejectedRequestsReturned[1] = true
            },
            Task { @MainActor in
                await coordinator.updateAndWait(policy: .safeDefault)
                rejectedRequestsReturned[2] = true
            },
        ]
        for _ in 0..<50 { await Task.yield() }
        check(rejectedRequestsReturned.allSatisfy { !$0 }, "awaited requests during shutdown join terminal cleanup")
        check(!coordinator.isRunning && !events.isRunning, "terminal shutdown rejects overlapping restart requests")

        handler.release()
        await shutdownTask.value
        for task in rejectedRequests { await task.value }
        check(rejectedRequestsReturned.allSatisfy { $0 }, "terminal-overlap lifecycle waiters settle with shutdown")
        check(model.workState == .stopped && !model.isRunning, "terminal shutdown returns with no model task ownership")
        check(await broker.workState().subscriberCount == 0, "terminal shutdown returns with zero subscribers")
        check(coordinator.activeDisplayIdentities.isEmpty && registry.openPanelCount == 0, "terminal shutdown closes every panel")
        check(!events.isRunning && events.runningInstanceCount == 0, "terminal shutdown leaves zero event sources")

        await coordinator.startAndWait()
        model.start()
        for _ in 0..<20 { await Task.yield() }
        check(!coordinator.isRunning && !model.isRunning, "terminal coordinator and model cannot restart after shutdown returns")
        check(await broker.workState().subscriberCount == 0, "post-shutdown start attempts perform zero subscriber work")
    }

    private mutating func beginGatedAction(
        broker: ActivityBroker,
        model: SurfaceActivityModel,
        handler: GatedCancellationActionHandler,
        id: String
    ) async -> Bool {
        do {
            let submitted = try await broker.submit(
                request(
                    id: id,
                    title: "Gated lifecycle action",
                    actionIdentifier: "\(id).cancel",
                    actionLabel: "Cancel",
                    actionIntent: .cancel
                )
            )
            check(
                await waitUntil { model.snapshotVersion == submitted.version && model.currentAction != nil },
                "\(id) action reaches the shared model"
            )
            guard let action = model.currentAction else {
                check(false, "\(id) exposes a dispatchable action")
                return false
            }
            check(model.dispatch(action), "\(id) begins cancellable action work")
            check(
                await waitUntil { handler.didStart && model.workState.hasActionTask },
                "\(id) owns a physically active action task"
            )
            return true
        } catch {
            recordUnexpected(error, context: "\(id) gated lifecycle fixture")
            return false
        }
    }

    private func makeCoordinator(
        displays: FakeDisplayProvider,
        events: FakeLifecycleEventSource,
        registry: SharedModelPanelRegistry,
        model: SurfaceActivityModel
    ) -> PanelCoordinator {
        PanelCoordinator(
            displayProvider: displays,
            policy: .safeDefault,
            lifecycleEventSource: events,
            activityModel: model,
            panelFactory: { snapshot, activityModel in
                registry.makePanel(snapshot: snapshot, activityModel: activityModel)
            }
        )
    }

    mutating func verifyEventCallbackLeases() async {
        let broker = ActivityBroker()
        let model = SurfaceActivityModel(broker: broker)
        let display = makeDisplaySnapshot(identity: 10, isMain: true)
        let displays = FakeDisplayProvider(displays: [display])
        let events = FakeLifecycleEventSource()
        let registry = SharedModelPanelRegistry()
        let coordinator = makeCoordinator(
            displays: displays,
            events: events,
            registry: registry,
            model: model
        )
        await coordinator.startAndWait()
        check(events.registrationCount == 1, "initial coordinator run installs one leased event callback")
        check(
            await waitUntil { await broker.workState().subscriberCount == 1 },
            "event-lease fixture starts one broker subscriber"
        )

        let enabledVariant = DisplayPolicy(
            enabledDisplayIdentities: [display.identity],
            selectedDisplayIdentity: display.identity
        )
        await coordinator.updateAndWait(policy: enabledVariant)
        check(events.registrationCount == 1, "enabled policy update preserves its still-owned event registration")
        let enabledUpdateActionBaseline = registry.totalPrimaryActionCount
        events.replayRegistration(0, event: .primaryShortcut)
        check(
            registry.totalPrimaryActionCount == enabledUpdateActionBaseline + 1,
            "preserved callback remains current and works exactly once after enabled policy update"
        )

        await coordinator.updateAndWait(policy: DisplayPolicy(isEnabled: false))
        await coordinator.updateAndWait(policy: .safeDefault)
        check(events.registrationCount == 2, "disable-enable installs a fresh immutable event lease")
        let disableEnableBaseline = registry.mutationSnapshot
        let disableEnableDisplayRequests = displays.requestCount
        replayAllLifecycleEvents(events, registration: 0)
        check(registry.mutationSnapshot == disableEnableBaseline, "retired disable-generation callbacks perform zero panel mutations")
        check(displays.requestCount == disableEnableDisplayRequests, "retired disable-generation display callback performs zero discovery")
        check(coordinator.isRunning && coordinator.policy.isEnabled, "retired disable-generation callbacks cannot change current lifecycle")
        let currentAfterEnable = registry.totalPrimaryActionCount
        events.replayRegistration(1, event: .primaryShortcut)
        check(registry.totalPrimaryActionCount == currentAfterEnable + 1, "new enable callback works exactly once")

        await coordinator.stopAndWait()
        await coordinator.startAndWait()
        check(events.registrationCount == 3, "stop-start installs a third event lease")
        guard let latestPanel = registry.latestOpenPanel else {
            check(false, "stop-start replacement panel is available")
            await coordinator.shutdown()
            return
        }
        let latestHideCount = latestPanel.hideCount
        events.replayRegistration(1, event: .workspaceWillSleep)
        check(
            latestPanel.hideCount == latestHideCount && coordinator.isRunning,
            "retired generation-2 sleep callback cannot hide the latest panel while coordinator runs"
        )
        let stopStartBaseline = registry.mutationSnapshot
        let stopStartDisplayRequests = displays.requestCount
        replayAllLifecycleEvents(events, registration: 1)
        check(registry.mutationSnapshot == stopStartBaseline, "all retired stop-generation callbacks perform zero panel mutations")
        check(displays.requestCount == stopStartDisplayRequests, "retired stop-generation display callback performs zero discovery")
        let currentAfterRestart = registry.totalPrimaryActionCount
        events.replayRegistration(2, event: .primaryShortcut)
        check(registry.totalPrimaryActionCount == currentAfterRestart + 1, "restart callback works exactly once")

        await coordinator.shutdown()
        let shutdownBaseline = registry.mutationSnapshot
        let shutdownDisplayRequests = displays.requestCount
        replayAllLifecycleEvents(events, registration: 2)
        check(registry.mutationSnapshot == shutdownBaseline, "retired shutdown callbacks perform zero panel mutations")
        check(displays.requestCount == shutdownDisplayRequests, "retired shutdown display callback performs zero discovery")
        check(!coordinator.isRunning && !events.isRunning, "retired shutdown callbacks cannot revive terminal coordinator")
        check(await broker.workState().subscriberCount == 0, "event-lease terminal fixture returns with zero subscribers")
    }

    private func replayAllLifecycleEvents(
        _ events: FakeLifecycleEventSource,
        registration: Int
    ) {
        events.replayRegistration(registration, event: .pointerMoved(CGPoint(x: 42, y: 42)))
        events.replayRegistration(registration, event: .workspaceWillSleep)
        events.replayRegistration(registration, event: .workspaceDidWake)
        events.replayRegistration(registration, event: .displayConfigurationChanged)
        events.replayRegistration(registration, event: .primaryShortcut)
    }

    mutating func verifyCoordinatorDeinitDoesNotPoisonSharedModel() async {
        let broker = ActivityBroker()
        let model = SurfaceActivityModel(broker: broker)
        let displays = FakeDisplayProvider(displays: [makeDisplaySnapshot(identity: 10, isMain: true)])
        let firstEvents = FakeLifecycleEventSource()
        let firstRegistry = SharedModelPanelRegistry()
        var firstCoordinator: PanelCoordinator? = makeCoordinator(
            displays: displays,
            events: firstEvents,
            registry: firstRegistry,
            model: model
        )
        weak var releasedFirstCoordinator: PanelCoordinator?
        releasedFirstCoordinator = firstCoordinator
        await firstCoordinator?.startAndWait()
        check(
            await waitUntil { await broker.workState().subscriberCount == 1 },
            "first coordinator starts the shared model subscriber"
        )
        firstCoordinator = nil
        check(releasedFirstCoordinator == nil, "first coordinator deinitializes synchronously")
        check(
            await waitUntil { !firstEvents.isRunning && firstRegistry.openPanelCount == 0 },
            "coordinator deinit retires only its own events and panels"
        )
        let subscriberCountAfterFirstDeinit = await broker.workState().subscriberCount
        check(model.isRunning && subscriberCountAfterFirstDeinit == 1, "old coordinator deinit does not terminally stop shared model")

        let secondEvents = FakeLifecycleEventSource()
        let secondRegistry = SharedModelPanelRegistry()
        let secondCoordinator = makeCoordinator(
            displays: displays,
            events: secondEvents,
            registry: secondRegistry,
            model: model
        )
        await secondCoordinator.startAndWait()
        check(secondCoordinator.isRunning && secondRegistry.openPanelCount == 1, "replacement coordinator starts with the same injected model")
        check(await broker.workState().subscriberCount == 1, "replacement owner retains exactly one shared broker subscriber")
        do {
            let submitted = try await broker.submit(request(id: "replacement-owner", title: "Replacement owner update"))
            check(
                await waitUntil { model.snapshotVersion == submitted.version },
                "replacement coordinator model receives fresh broker updates"
            )
        } catch {
            recordUnexpected(error, context: "replacement coordinator broker update")
        }
        await secondCoordinator.stopAndWait()
        model.start()
        check(
            await waitUntil {
                let subscriberCount = await broker.workState().subscriberCount
                return model.isRunning && subscriberCount == 1
            },
            "shared model remains directly restartable after replacement coordinator stop"
        )
        await model.stop()

        let drainBroker = ActivityBroker()
        let drainHandler = TrackingGatedActionHandler()
        let drainModel = SurfaceActivityModel(broker: drainBroker, actionHandler: drainHandler)
        let drainDisplays = FakeDisplayProvider(displays: [makeDisplaySnapshot(identity: 20, isMain: true)])
        let drainEvents = FakeLifecycleEventSource()
        let drainRegistry = SharedModelPanelRegistry()
        var drainingCoordinator: PanelCoordinator? = makeCoordinator(
            displays: drainDisplays,
            events: drainEvents,
            registry: drainRegistry,
            model: drainModel
        )
        await drainingCoordinator?.startAndWait()
        guard await submitAndDispatchTrackedAction(
            broker: drainBroker,
            model: drainModel,
            handler: drainHandler,
            id: "deinit-pending-drain"
        ) else {
            await drainModel.shutdown()
            return
        }

        drainingCoordinator?.stop()
        check(
            await waitUntil {
                let subscriberCount = await drainBroker.workState().subscriberCount
                return drainHandler.blockedInvocations.contains(0)
                    && drainModel.workState.unsettledActionTaskCount == 1
                    && drainModel.lifecycleRequestTaskCount == 1
                    && subscriberCount == 0
            },
            "replacement-owner fixture reaches a model-owned physical drain from synchronous coordinator stop"
        )
        drainingCoordinator = nil
        check(
            await waitUntil { !drainEvents.isRunning && drainRegistry.openPanelCount == 0 },
            "deinit during pending drain cleans only coordinator-owned state"
        )
        check(
            drainModel.workState.unsettledActionTaskCount == 1
                && drainModel.lifecycleRequestTaskCount == 1,
            "deinit during pending drain preserves all model-owned work"
        )

        let replacementEvents = FakeLifecycleEventSource()
        let replacementRegistry = SharedModelPanelRegistry()
        let replacementCoordinator = makeCoordinator(
            displays: drainDisplays,
            events: replacementEvents,
            registry: replacementRegistry,
            model: drainModel
        )
        var replacementStartReturned = false
        let replacementStartTask = Task { @MainActor in
            await replacementCoordinator.startAndWait()
            replacementStartReturned = true
        }
        for _ in 0..<50 { await Task.yield() }
        check(!replacementStartReturned, "successor awaited start joins the inherited model drain")
        check(replacementCoordinator.isRunning && replacementRegistry.openPanelCount == 1, "successor coordinator starts while prior model drain is pending")
        drainHandler.release(invocation: 0)
        await replacementStartTask.value
        check(replacementStartReturned, "successor awaited start returns after inherited model work settles")
        check(
            await waitUntil {
                let subscriberCount = await drainBroker.workState().subscriberCount
                return drainModel.isRunning && subscriberCount == 1
            },
            "successor start is replayed after pending drain without old deinit poisoning"
        )
        check(drainHandler.activeHandlerCount == 0, "pending drain completes without orphaned action work")
        check(replacementCoordinator.isRunning && replacementEvents.isRunning, "successor coordinator remains current after drain completion")
        await replacementCoordinator.shutdown()
        let finalDrainSubscriberCount = await drainBroker.workState().subscriberCount
        check(drainModel.workState == .stopped && finalDrainSubscriberCount == 0, "explicit final owner shutdown remains terminal and complete")
    }

    mutating func verifyDetachedReleaseTeardown() async {
        var lifecycleSource: SystemPanelLifecycleEventSource? = SystemPanelLifecycleEventSource()
        let lifecycleProbe = lifecycleSource?.workProbe
        lifecycleSource?.start { _ in }
        weak var releasedLifecycleSource: SystemPanelLifecycleEventSource?
        releasedLifecycleSource = lifecycleSource
        check(lifecycleProbe?.isRunning == true, "detached-release system event source starts explicitly")
        check(lifecycleProbe?.observerCount == 4, "detached-release system event source owns all notification observers")
        check(lifecycleProbe?.handlerCount == 1, "detached-release system event source owns one event handler")
        check(lifecycleProbe?.hasWork == true, "detached-release system event source exposes active platform work")

        let lifecycleGate = DetachedReleaseGate()
        let lifecycleRelease = Task.detached { [lifecycleSource] in
            await lifecycleGate.wait()
            withExtendedLifetime(lifecycleSource) {}
        }
        lifecycleSource = nil
        await lifecycleGate.open()
        await lifecycleRelease.value
        check(releasedLifecycleSource == nil, "system event source last strong reference is released by a detached task")
        check(
            await waitUntil { lifecycleProbe?.hasWork == false },
            "detached system event source deinit settles every observer, monitor, hot-key, and handler resource"
        )
        check(lifecycleProbe?.observerCount == 0, "detached system event source removes notification observers exactly")
        check(lifecycleProbe?.monitorCount == 0, "detached system event source removes pointer monitors exactly")
        check(lifecycleProbe?.hotKeyResourceCount == 0, "detached system event source removes hot-key resources exactly")
        check(lifecycleProbe?.handlerCount == 0, "detached system event source clears its callback exactly")
        check(lifecycleProbe?.callbackLeaseCount == 0, "detached system event source retires its callback lease exactly")

        let observerModel = makeEmptyPreviewModel()
        let surfaceScheduler = ManualOneShotScheduler()
        var surfaceModel: PanelSurfaceModel? = PanelSurfaceModel(
            displayGeometry: makeDisplaySnapshot(identity: 10, isMain: true).geometry,
            scheduler: surfaceScheduler,
            activityModel: observerModel
        )
        surfaceModel?.send(.primaryAction)
        weak var releasedSurfaceModel: PanelSurfaceModel?
        releasedSurfaceModel = surfaceModel
        check(observerModel.observerCount == 1, "detached-release surface fixture owns one activity observer")
        check(surfaceScheduler.activeOperationCount == 1, "detached-release surface fixture owns one scheduled operation")

        let surfaceGate = DetachedReleaseGate()
        let surfaceRelease = Task.detached { [surfaceModel] in
            await surfaceGate.wait()
            withExtendedLifetime(surfaceModel) {}
        }
        surfaceModel = nil
        await surfaceGate.open()
        await surfaceRelease.value
        check(releasedSurfaceModel == nil, "surface last strong reference is released by a detached task")
        check(
            await waitUntil {
                releasedSurfaceModel == nil
                    && observerModel.observerCount == 0
                    && surfaceScheduler.activeOperationCount == 0
            },
            "detached surface deinit completes exact MainActor observer and operation teardown without crashing"
        )
        check(observerModel.workState == .stopped, "detached surface teardown leaves no observer-owned task work")

        let broker = ActivityBroker()
        let sharedModel = SurfaceActivityModel(broker: broker)
        let displays = FakeDisplayProvider(displays: [makeDisplaySnapshot(identity: 20, isMain: true)])
        let events = FakeLifecycleEventSource()
        let registry = SharedModelPanelRegistry()
        var coordinator: PanelCoordinator? = makeCoordinator(
            displays: displays,
            events: events,
            registry: registry,
            model: sharedModel
        )
        weak var releasedCoordinator: PanelCoordinator?
        releasedCoordinator = coordinator
        await coordinator?.startAndWait()
        check(
            await waitUntil { await broker.workState().subscriberCount == 1 },
            "detached-release coordinator fixture starts one shared subscriber"
        )
        check(events.isRunning && registry.openPanelCount == 1, "detached-release coordinator owns one event source and panel")

        let coordinatorGate = DetachedReleaseGate()
        let coordinatorRelease = Task.detached { [coordinator] in
            await coordinatorGate.wait()
            withExtendedLifetime(coordinator) {}
        }
        coordinator = nil
        await coordinatorGate.open()
        await coordinatorRelease.value
        check(releasedCoordinator == nil, "coordinator last strong reference is released by a detached task")
        check(
            await waitUntil {
                releasedCoordinator == nil
                    && !events.isRunning
                    && registry.openPanelCount == 0
            },
            "detached coordinator deinit completes exact MainActor event and panel teardown without crashing"
        )
        check(events.stopCount == 1, "detached coordinator teardown stops its event source exactly once")
        check(registry.mutationSnapshot.closeCount == 1, "detached coordinator teardown closes its panel exactly once")
        let subscriberCountAfterDeinit = await broker.workState().subscriberCount
        check(sharedModel.isRunning && subscriberCountAfterDeinit == 1, "detached coordinator teardown does not shut down the injected shared model")

        do {
            let submitted = try await broker.submit(
                request(id: "detached-release-update", title: "Still shared")
            )
            check(
                await waitUntil { sharedModel.snapshotVersion == submitted.version },
                "shared model still receives broker work after detached coordinator release"
            )
        } catch {
            recordUnexpected(error, context: "detached coordinator shared-model update")
        }

        await sharedModel.shutdown()
        check(sharedModel.workState == .stopped, "explicit final owner drains all work after detached coordinator teardown")
        check(await broker.workState().subscriberCount == 0, "detached coordinator fixture ends with zero orphan subscribers")
    }

    mutating func verifyStateContentAccessibilityAndPreviews() {
        let expectedKinds: [(ActivitySurfacePreviewScenario, ActivityKind, String)] = [
            (ActivitySurfacePreviewCatalog.generic, .generic, SurfaceStrings.genericKind),
            (ActivitySurfacePreviewCatalog.battery, .battery, SurfaceStrings.batteryKind),
            (ActivitySurfacePreviewCatalog.charging, .charging, SurfaceStrings.chargingKind),
            (ActivitySurfacePreviewCatalog.timer, .timer, SurfaceStrings.timerKind),
            (ActivitySurfacePreviewCatalog.meeting, .meeting, SurfaceStrings.meetingKind),
            (ActivitySurfacePreviewCatalog.volume, .volume, SurfaceStrings.volumeKind),
            (ActivitySurfacePreviewCatalog.media, .media, SurfaceStrings.mediaKind),
            (ActivitySurfacePreviewCatalog.file, .file, SurfaceStrings.fileKind),
        ]

        for (scenario, expectedKind, expectedLabel) in expectedKinds {
            do {
                let snapshot = try scenario.snapshot()
                guard let current = snapshot.current else {
                    check(false, "\(scenario.name) preview has current content")
                    continue
                }
                let item = ActivitySurfaceItem(current)
                check(item.kind == expectedKind, "\(scenario.name) maps the bounded activity kind")
                check(item.kindLabel == expectedLabel, "\(scenario.name) exposes stable kind copy")
                check(item.title == current.activity.presentation.title, "\(scenario.name) preserves broker title honestly")
                check(!item.symbolName.isEmpty, "\(scenario.name) includes a non-color status symbol")
                check(snapshot.queued.count <= ActivityQueueContext.maximumVisibleItems, "\(scenario.name) preview queue remains bounded")
            } catch {
                recordUnexpected(error, context: "preview \(scenario.name)")
            }
        }

        do {
            let display = makeDisplaySnapshot(identity: 10).geometry
            let expanded = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.media,
                displayGeometry: display,
                scheduler: ManualOneShotScheduler()
            )
            check(expanded.content.state == .expanded, "preview host maps expanded state deterministically")
            check(expanded.content.queue.items.count == 2, "expanded content exposes small queue context")
            check(expanded.content.action != nil, "expanded content exposes at most its one domain action")
            check(expanded.accessibility.label == SurfaceStrings.surfaceLabel, "surface accessibility label is centralized and stable")
            check(expanded.accessibility.value.contains(SurfaceStrings.expandedState), "accessibility value names the presentation state")
            check(expanded.accessibility.value.contains(SurfaceStrings.mediaKind), "accessibility value names activity kind without color")
            check(expanded.accessibility.hint == SurfaceStrings.collapseHint, "expanded accessibility hint explains the focus-safe shortcut")

            let compact = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.generic,
                displayGeometry: display,
                scheduler: ManualOneShotScheduler()
            )
            check(compact.accessibility.hint == SurfaceStrings.expandHint, "compact accessibility hint explains expansion")

            let dropTarget = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.dropTarget,
                displayGeometry: display,
                scheduler: ManualOneShotScheduler()
            )
            check(dropTarget.accessibility.value.contains("no files will be stored"), "drop-target accessibility copy never claims storage")
            check(dropTarget.accessibility.hint == SurfaceStrings.dropTargetHint, "drop target has a distinct VoiceOver hint")
        } catch {
            recordUnexpected(error, context: "preview host")
        }

        let emptyContent = ActivitySurfaceContent(
            state: .expanded,
            phase: .active,
            current: nil,
            queueContext: .empty,
            action: nil,
            actionDispatchState: .idle
        )
        check(
            emptyContent.primary == .empty(title: SurfaceStrings.quietTitle, detail: SurfaceStrings.quietDetail),
            "expanded empty state is graceful and explicit"
        )
        let degradedContent = ActivitySurfaceContent(
            state: .peek,
            phase: .degraded,
            current: nil,
            queueContext: .empty,
            action: nil,
            actionDispatchState: .idle
        )
        check(
            degradedContent.primary == .degraded(
                title: SurfaceStrings.degradedTitle,
                detail: SurfaceStrings.degradedDetail
            ),
            "degraded stream state has honest fallback copy"
        )
        check(ActivitySurfacePreviewCatalog.representative.count == 10, "preview seam includes bounded representative and state scenarios")

        do {
            guard let current = try ActivitySurfacePreviewCatalog.generic.snapshot().current else {
                check(false, "queue overflow fixture is available")
                check(false, "oversized queue cannot be bounded")
                check(false, "Int.max queue count cannot be saturated")
                return
            }
            let item = ActivitySurfaceItem(current)
            let oversizedItems = Array(
                repeating: item,
                count: ActivityLimits.maximumActivityCount + 10
            )
            let saturated = ActivityQueueContext(
                items: oversizedItems,
                remainingCount: Int.max
            )
            check(saturated.items.count == 2, "oversized public queue input still exposes two items")
            check(
                saturated.remainingCount == ActivityQueueContext.maximumRemainingCount,
                "Int.max remaining count saturates at the bounded domain cap"
            )
            check(saturated.remainingCount >= 0, "saturating queue arithmetic cannot wrap negative")
        } catch {
            recordUnexpected(error, context: "queue saturation")
        }
    }

    mutating func verifyReduceMotionAndRapidStateChanges() {
        let scheduler = ManualOneShotScheduler()
        let model = PanelSurfaceModel(
            displayGeometry: makeDisplaySnapshot(identity: 10).geometry,
            initialState: .compact,
            scheduler: scheduler,
            activityModel: makeEmptyPreviewModel()
        )
        check(model.motionStyle == .standard, "surface defaults to interruption-safe standard motion")
        model.updateReduceMotion(true)
        check(model.motionStyle == .reduced, "system Reduce Motion selects reduced motion content")
        model.send(.primaryAction)
        check(scheduler.lastScheduledDelay == .milliseconds(120), "Reduce Motion chooses the tested crossfade/scale duration")

        model.updateReduceMotion(false)
        model.send(.primaryAction)
        check(scheduler.lastScheduledDelay == .milliseconds(220), "standard morph remains inside the 180–240 ms brief range")
        for _ in 0..<500 {
            model.send(.primaryAction)
            model.send(.primaryAction)
        }
        check(model.state == .compact, "rapid state reversals settle on the latest deterministic state")
        check(model.content.state == model.state, "content mapping remains synchronized during rapid state changes")
        scheduler.runAll()
        check(model.interactionHitRegion == model.layout.hitRegion, "cancelled motion completions cannot restore stale hit testing")
    }

    mutating func verifySharedBrokerVisibilityAndDisabledWork() async {
        let broker = ActivityBroker()
        let sharedModel = SurfaceActivityModel(broker: broker)
        let displays = FakeDisplayProvider(displays: [
            makeDisplaySnapshot(identity: 10, isMain: true),
            makeDisplaySnapshot(identity: 20, originX: 1_440),
        ])
        let events = FakeLifecycleEventSource()
        let registry = SharedModelPanelRegistry()
        let coordinator = PanelCoordinator(
            displayProvider: displays,
            policy: DisplayPolicy(isEnabled: false),
            lifecycleEventSource: events,
            activityModel: sharedModel,
            panelFactory: { snapshot, activityModel in
                registry.makePanel(snapshot: snapshot, activityModel: activityModel)
            }
        )

        await coordinator.startAndWait()
        check(await broker.workState().subscriberCount == 0, "disabled coordinator starts no broker subscriber task")
        check(registry.creationCount == 0, "disabled coordinator constructs no hidden panels")

        await coordinator.updateAndWait(policy: .safeDefault)
        check(
            await waitUntil { await broker.workState().subscriberCount == 1 },
            "re-enabled coordinator starts the shared model's one subscriber"
        )
        check(registry.creationCount == 2, "panel factory remains injected for both displays")
        check(registry.modelIdentities.count == 1, "all display panels receive the same observable activity model")
        check(registry.modelIdentities.first == ObjectIdentifier(sharedModel), "panel factory receives the app-owned model identity")

        do {
            let submitted = try await broker.submit(
                request(id: "shared", priority: 80, title: "Shared broker activity")
            )
            check(
                await waitUntil { sharedModel.snapshotVersion == submitted.version },
                "shared broker snapshot is visible through the injected model"
            )
            check(
                registry.models.allSatisfy {
                    $0.current?.activity.presentation.title == "Shared broker activity"
                },
                "every panel observes the same broker-driven current activity"
            )
            check(await broker.workState().subscriberCount == 1, "multiple panels do not create hidden second broker streams")
        } catch {
            recordUnexpected(error, context: "shared broker visibility")
        }

        await coordinator.updateAndWait(policy: DisplayPolicy(isEnabled: false))
        check(
            await waitUntil { await broker.workState().subscriberCount == 0 },
            "disabling coordinator cancels all surface subscription work"
        )
        check(sharedModel.phase == .stopped, "disabled coordinator leaves model explicitly stopped")
        await coordinator.stopAndWait()
        check(await broker.workState().subscriberCount == 0, "stopping disabled coordinator remains zero-work")
    }

    private func request(
        id: String,
        source: ActivitySource = .timer,
        kind: ActivityKind = .timer,
        priority: Int = 50,
        title: String,
        detail: String? = nil,
        progress: Double? = nil,
        actionIdentifier: String? = nil,
        actionLabel: String? = nil,
        actionIntent: ActivityActionIntent? = nil,
        ttlMilliseconds: Int? = nil
    ) -> ActivityRequest {
        ActivityRequest(
            identifier: id,
            source: source.rawValue,
            kind: kind.rawValue,
            priority: priority,
            title: title,
            detail: detail,
            progress: progress,
            actionIdentifier: actionIdentifier,
            actionLabel: actionLabel,
            actionIntent: actionIntent?.rawValue,
            ttlMilliseconds: ttlMilliseconds
        )
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
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
            print("Surface harness passed: \(checkCount) checks.")
            exit(EXIT_SUCCESS)
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        fputs("Surface harness failed: \(failures.count) of \(checkCount) checks.\n", stderr)
        exit(EXIT_FAILURE)
    }
}

@MainActor
private final class RecordingActionHandler: ActivityActionHandling {
    struct Invocation: Equatable {
        let intent: ActivityActionIntent
        let identity: SurfaceActionIdentity
    }

    var outcome: ActivityActionOutcome
    private(set) var invocations: [Invocation] = []

    init(outcome: ActivityActionOutcome) {
        self.outcome = outcome
    }

    func handle(
        _ intent: ActivityActionIntent,
        identity: SurfaceActionIdentity
    ) async -> ActivityActionOutcome {
        invocations.append(Invocation(intent: intent, identity: identity))
        return outcome
    }
}

@MainActor
private final class CancellationWaitingActionHandler: ActivityActionHandling {
    private(set) var didStart = false
    private(set) var didFinishAfterCancellation = false

    func handle(
        _ intent: ActivityActionIntent,
        identity: SurfaceActionIdentity
    ) async -> ActivityActionOutcome {
        _ = intent
        _ = identity
        didStart = true
        while !Task.isCancelled {
            await Task.yield()
        }
        didFinishAfterCancellation = true
        return .unhandled
    }
}

@MainActor
private final class GatedCancellationActionHandler: ActivityActionHandling {
    private(set) var didStart = false
    private(set) var isBlockedAfterCancellation = false
    private(set) var didFinishAfterRelease = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func handle(
        _ intent: ActivityActionIntent,
        identity: SurfaceActionIdentity
    ) async -> ActivityActionOutcome {
        _ = intent
        _ = identity
        didStart = true
        while !Task.isCancelled {
            await Task.yield()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            isBlockedAfterCancellation = true
        }
        didFinishAfterRelease = true
        return .unhandled
    }

    func release() {
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class TrackingGatedActionHandler: ActivityActionHandling {
    private(set) var activeHandlerCount = 0
    private(set) var maximumActiveHandlerCount = 0
    private(set) var startCount = 0
    private(set) var completedInvocations: Set<Int> = []
    private(set) var blockedInvocations: Set<Int> = []
    private var releaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedBeforeBlocking: Set<Int> = []

    func handle(
        _ intent: ActivityActionIntent,
        identity: SurfaceActionIdentity
    ) async -> ActivityActionOutcome {
        _ = intent
        _ = identity
        let invocation = startCount
        startCount += 1
        activeHandlerCount += 1
        maximumActiveHandlerCount = max(maximumActiveHandlerCount, activeHandlerCount)

        while !Task.isCancelled {
            await Task.yield()
        }
        await withCheckedContinuation { continuation in
            if releasedBeforeBlocking.remove(invocation) != nil {
                continuation.resume()
            } else {
                blockedInvocations.insert(invocation)
                releaseContinuations[invocation] = continuation
            }
        }
        blockedInvocations.remove(invocation)
        activeHandlerCount -= 1
        completedInvocations.insert(invocation)
        return .unhandled
    }

    func release(invocation: Int) {
        guard let continuation = releaseContinuations.removeValue(forKey: invocation) else {
            releasedBeforeBlocking.insert(invocation)
            return
        }
        continuation.resume()
    }

    func releaseAll() {
        let continuations = releaseContinuations.values
        releaseContinuations.removeAll()
        blockedInvocations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor GatedInitialSnapshotSource: SurfaceActivitySnapshotStreaming {
    struct State: Sendable {
        let callCount: Int
        let secondCallIsBlocked: Bool
        let activeGenerations: [UInt64]
        let cancelledGenerations: [UInt64]
    }

    private let retiredSnapshot: ActivityBrokerSnapshot
    private let successorSnapshot: ActivityBrokerSnapshot
    private var calls = 0
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?
    private var secondReleaseContinuation: CheckedContinuation<Void, Never>?
    private var firstBlocked = false
    private var secondBlocked = false
    private var continuations: [
        ActivityBrokerSubscriptionToken: AsyncStream<ActivityBrokerSnapshot>.Continuation
    ] = [:]
    private var cancelledGenerations: [UInt64] = []

    init(
        retiredSnapshot: ActivityBrokerSnapshot,
        successorSnapshot: ActivityBrokerSnapshot
    ) {
        self.retiredSnapshot = retiredSnapshot
        self.successorSnapshot = successorSnapshot
    }

    var firstCallIsBlocked: Bool {
        firstBlocked
    }

    var callCount: Int {
        calls
    }

    var state: State {
        State(
            callCount: calls,
            secondCallIsBlocked: secondBlocked,
            activeGenerations: continuations.keys.map(\.generation).sorted(),
            cancelledGenerations: cancelledGenerations.sorted()
        )
    }

    func snapshotSubscription(
        subscriberID: UUID
    ) async throws -> ActivityBrokerSnapshotSubscription {
        calls += 1
        let generation = UInt64(calls)
        if generation == 1 {
            await withCheckedContinuation { continuation in
                firstReleaseContinuation = continuation
                firstBlocked = true
            }
        } else if generation == 2 {
            await withCheckedContinuation { continuation in
                secondReleaseContinuation = continuation
                secondBlocked = true
            }
        }

        let token = ActivityBrokerSubscriptionToken(
            subscriberID: subscriberID,
            generation: generation
        )
        let (stream, continuation) = AsyncStream.makeStream(
            of: ActivityBrokerSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[token] = continuation
        continuation.yield(generation == 1 ? retiredSnapshot : successorSnapshot)
        return ActivityBrokerSnapshotSubscription(token: token, stream: stream)
    }

    func cancelSnapshotSubscription(_ token: ActivityBrokerSubscriptionToken) {
        guard let continuation = continuations.removeValue(forKey: token) else { return }
        cancelledGenerations.append(token.generation)
        continuation.finish()
    }

    func releaseFirstCall() {
        let continuation = firstReleaseContinuation
        firstReleaseContinuation = nil
        continuation?.resume()
    }

    func releaseSecondCall() {
        let continuation = secondReleaseContinuation
        secondReleaseContinuation = nil
        continuation?.resume()
    }
}

private actor ControllableSnapshotSource: SurfaceActivitySnapshotStreaming {
    private let initialSnapshot: ActivityBrokerSnapshot
    private var continuation: AsyncStream<ActivityBrokerSnapshot>.Continuation?
    private var activeSubscriberID: UUID?
    private var activeToken: ActivityBrokerSubscriptionToken?
    private var nextGeneration: UInt64 = 0

    init(initialSnapshot: ActivityBrokerSnapshot) {
        self.initialSnapshot = initialSnapshot
    }

    var subscriberCount: Int {
        activeSubscriberID == nil ? 0 : 1
    }

    func snapshotSubscription(
        subscriberID: UUID
    ) throws -> ActivityBrokerSnapshotSubscription {
        nextGeneration += 1
        let token = ActivityBrokerSubscriptionToken(
            subscriberID: subscriberID,
            generation: nextGeneration
        )
        let (stream, continuation) = AsyncStream.makeStream(
            of: ActivityBrokerSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation
        activeSubscriberID = subscriberID
        activeToken = token
        continuation.yield(initialSnapshot)
        return ActivityBrokerSnapshotSubscription(token: token, stream: stream)
    }

    func cancelSnapshotSubscription(_ token: ActivityBrokerSubscriptionToken) {
        guard activeToken == token else { return }
        activeSubscriberID = nil
        activeToken = nil
        continuation?.finish()
        continuation = nil
    }

    func finishCurrentStream() {
        continuation?.finish()
    }
}

private actor DetachedReleaseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ManualExpirationScheduler: ActivityExpirationScheduling {
    private struct Waiter {
        let identifier: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Waiter] = []
    private var cancelledBeforeRegistration: Set<UUID> = []

    var pendingCount: Int {
        waiters.count
    }

    func sleep(for duration: Duration) async throws {
        _ = duration
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledBeforeRegistration.remove(identifier) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(identifier: identifier, continuation: continuation))
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
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private final class ManualScheduledOperation: ScheduledOperation {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

@MainActor
private final class ManualOneShotScheduler: OneShotScheduling {
    private struct Entry {
        let delay: Duration
        let token: ManualScheduledOperation
        let operation: @MainActor @Sendable () -> Void
    }

    private var entries: [Entry] = []

    var lastScheduledDelay: Duration? {
        entries.last?.delay
    }

    var activeOperationCount: Int {
        entries.lazy.filter { !$0.token.isCancelled }.count
    }

    func schedule(
        after delay: Duration,
        operation: @escaping @MainActor @Sendable () -> Void
    ) -> any ScheduledOperation {
        let token = ManualScheduledOperation()
        entries.append(Entry(delay: delay, token: token, operation: operation))
        return token
    }

    func runAll() {
        var safetyBudget = 10_000
        while !entries.isEmpty, safetyBudget > 0 {
            safetyBudget -= 1
            let entry = entries.removeFirst()
            if !entry.token.isCancelled {
                entry.operation()
            }
        }
    }
}

@MainActor
private final class FakeDisplayProvider: EnabledDisplayProviding {
    var displays: [DisplaySnapshot]
    private(set) var requestCount = 0

    init(displays: [DisplaySnapshot]) {
        self.displays = displays
    }

    func enabledDisplays() -> [DisplaySnapshot] {
        requestCount += 1
        return displays
    }
}

@MainActor
private final class FakeLifecycleEventSource: PanelLifecycleEventSourcing {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var activeRegistration: Int?
    private var registrations: [@MainActor @Sendable (PanelLifecycleEvent) -> Void] = []

    var runningInstanceCount: Int {
        startCount - stopCount
    }

    var registrationCount: Int {
        registrations.count
    }

    func start(handler: @escaping @MainActor @Sendable (PanelLifecycleEvent) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        startCount += 1
        registrations.append(handler)
        activeRegistration = registrations.indices.last
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopCount += 1
        activeRegistration = nil
    }

    func emitCurrent(_ event: PanelLifecycleEvent) {
        guard let activeRegistration else { return }
        registrations[activeRegistration](event)
    }

    func replayRegistration(_ registration: Int, event: PanelLifecycleEvent) {
        guard registrations.indices.contains(registration) else { return }
        registrations[registration](event)
    }
}

private struct PanelMutationSnapshot: Equatable {
    let creationCount: Int
    let openPanelCount: Int
    let showCount: Int
    let hideCount: Int
    let closeCount: Int
    let updateCount: Int
    let pointerUpdateCount: Int
    let primaryActionCount: Int
}

@MainActor
private final class SharedModelPanelRegistry {
    private(set) var models: [SurfaceActivityModel] = []
    private(set) var panels: [FakePanel] = []
    private(set) var creationCount = 0

    var modelIdentities: Set<ObjectIdentifier> {
        Set(models.map(ObjectIdentifier.init))
    }

    var openPanelCount: Int {
        panels.lazy.filter { !$0.isClosed }.count
    }

    var totalPrimaryActionCount: Int {
        panels.reduce(0) { $0 + $1.primaryActionCount }
    }

    var latestOpenPanel: FakePanel? {
        panels.last { !$0.isClosed }
    }

    var mutationSnapshot: PanelMutationSnapshot {
        PanelMutationSnapshot(
            creationCount: creationCount,
            openPanelCount: openPanelCount,
            showCount: panels.reduce(0) { $0 + $1.showCount },
            hideCount: panels.reduce(0) { $0 + $1.hideCount },
            closeCount: panels.reduce(0) { $0 + $1.closeCount },
            updateCount: panels.reduce(0) { $0 + $1.updateCount },
            pointerUpdateCount: panels.reduce(0) { $0 + $1.pointerUpdateCount },
            primaryActionCount: totalPrimaryActionCount
        )
    }

    func makePanel(
        snapshot: DisplaySnapshot,
        activityModel: SurfaceActivityModel
    ) -> any PanelPresenting {
        models.append(activityModel)
        creationCount += 1
        let panel = FakePanel(displayIdentity: snapshot.identity)
        panels.append(panel)
        return panel
    }
}

@MainActor
private final class FakePanel: PanelPresenting {
    let displayIdentity: DisplayIdentity
    private(set) var isClosed = false
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var closeCount = 0
    private(set) var updateCount = 0
    private(set) var pointerUpdateCount = 0
    private(set) var primaryActionCount = 0

    init(displayIdentity: DisplayIdentity) {
        self.displayIdentity = displayIdentity
    }

    func show() {
        showCount += 1
    }

    func hide() {
        hideCount += 1
    }

    func close() {
        closeCount += 1
        isClosed = true
    }

    func update(snapshot: DisplaySnapshot) {
        updateCount += 1
    }

    func updatePointer(screenPoint: CGPoint) {
        pointerUpdateCount += 1
    }

    func performPrimaryAction() {
        primaryActionCount += 1
    }
    func cancelPendingInteractions() {}
}

@MainActor
private func makeEmptyPreviewModel() -> SurfaceActivityModel {
    SurfaceActivityModel(
        previewSnapshot: ActivityBrokerSnapshot(version: 0, current: nil, queued: [])
    )
}

private func makeDisplaySnapshot(
    identity: UInt32,
    originX: CGFloat = 0,
    isMain: Bool = false
) -> DisplaySnapshot {
    let frame = CGRect(x: originX, y: 0, width: 1_440, height: 900)
    return DisplaySnapshot(
        identity: DisplayIdentity(rawValue: identity),
        geometry: DisplayGeometry(
            frame: frame,
            visibleFrame: CGRect(x: originX, y: 0, width: 1_440, height: 875),
            backingScaleFactor: 2,
            topEdgeOcclusion: nil
        ),
        isMain: isMain
    )
}
