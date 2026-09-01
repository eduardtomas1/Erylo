import AppKit
import CoreGraphics
import Darwin
import EryloActivity
import EryloCore
import EryloIntegrations
import EryloSurface
import EryloWindowing
import Foundation
import SwiftUI

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
        await harness.verifyPointerEventDeliveryIsBounded()
        await harness.verifyCoordinatorDeinitDoesNotPoisonSharedModel()
        await harness.verifyDetachedReleaseTeardown()
        harness.verifyLegacyCompatibilityDefaultsAreInert()
        harness.verifyStateContentAccessibilityAndPreviews()
        await harness.verifyFocusTimerProjectionAndLauncher()
        await harness.verifyProductInteractionSemantics()
        await harness.verifyKeyboardFocusAndEscapeSemantics()
        await harness.verifyTemporalProjectionPhysicalVisibility()
        harness.verifyWindowTransitionStaging()
        harness.verifyReduceMotionAndRapidStateChanges()
        await harness.verifySharedBrokerVisibilityAndDisabledWork()
        if let outputDirectory = ProcessInfo.processInfo.environment["ERYLO_VISUAL_QA_DIRECTORY"] {
            do {
                try writeNativeVisualQA(to: URL(fileURLWithPath: outputDirectory))
            } catch {
                fputs("Visual QA rendering failed: \(error)\n", stderr)
                Darwin.exit(1)
            }
        }
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
        let displayGeometry = DisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 950),
            backingScaleFactor: 2,
            topEdgeOcclusion: TopEdgeOcclusion(
                frame: CGRect(x: 663, y: 950, width: 185, height: 32)
            )
        )
        let panelModel = PanelSurfaceModel(
            displayGeometry: displayGeometry,
            scheduler: motionScheduler,
            activityModel: activityModel
        )
        let layoutChanges = CallbackCounter()
        panelModel.didChange = { [weak layoutChanges] in
            layoutChanges?.increment()
        }

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
            check(panelModel.state == .hidden, "second empty shortcut returns to invisible rest")

            let fallback = try await broker.submit(
                request(id: "fallback", priority: 30, title: "Fallback")
            )
            check(
                await waitUntil { activityModel.snapshotVersion == fallback.version },
                "fallback activity becomes visible"
            )
            motionScheduler.runAll()
            let fallbackHitRegion = panelModel.interactionHitRegion
            let layoutChangeBaseline = layoutChanges.count
            let urgent = try await broker.submit(
                request(
                    id: "urgent-expiry",
                    source: .volume,
                    kind: .volume,
                    priority: 90,
                    title: "Studio Display",
                    presentationRole: .volumeOutputChanged,
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
            check(panelModel.state == .compact, "activity handoff retains compact presentation state")
            check(
                layoutChanges.count > layoutChangeBaseline,
                "same-state activity geometry notifies the native layout owner"
            )
            let urgentHitRegion = panelModel.layout.hitRegion
            check(
                panelModel.interactionHitRegion
                    == fallbackHitRegion.intersecting(urgentHitRegion),
                "same-state activity growth keeps input inside visible geometry"
            )
            motionScheduler.runAll()
            check(
                panelModel.interactionHitRegion == urgentHitRegion,
                "same-state activity growth settles on its exact hit region"
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
                panelModel.interactionHitRegion
                    == urgentHitRegion.intersecting(fallbackHitRegion),
                "same-state fallback shrink never accepts input outside visible geometry"
            )
            motionScheduler.runAll()
            check(
                panelModel.interactionHitRegion == panelModel.layout.hitRegion
                    && panelModel.interactionHitRegion == fallbackHitRegion,
                "same-state fallback handoff restores the exact compact hit region"
            )
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
        check(events.isRunning && registry.openPanelCount == 0, "legacy coordinator start remains observable without hidden panels")
        events.emitCurrent(.primaryShortcut)
        check(registry.openPanelCount == 1, "legacy shortcut constructs its selected panel on demand")
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
            check(registry.openPanelCount == 0, "sync stop-start preserves zero idle panels")
            check(model.isRunning && model.lifecycleRequestTaskCount == 0, "sync stop-start settles its owned model request")
            check(await broker.workState().subscriberCount == 1, "sync stop-start retains exactly one subscriber")

            coordinator.update(policy: DisplayPolicy(isEnabled: false))
            check(model.lifecycleRequestTaskCount <= 1, "sync disable owns at most one model lifecycle task")
            coordinator.update(policy: .safeDefault)
            await coordinator.updateAndWait(policy: .safeDefault)
            check(coordinator.policy.isEnabled && events.isRunning, "sync disable-enable keeps the latest enabled policy")
            check(registry.openPanelCount == 0, "sync disable-enable preserves zero idle panels")
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
        let enabledPolicy = DisplayPolicy(surfaceScope: .allAvailable)
        let coordinator = makeCoordinator(
            displays: displays,
            events: events,
            registry: registry,
            model: model,
            policy: enabledPolicy
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
            await coordinator.updateAndWait(policy: enabledPolicy)
            enableReturned = true
        }
        for _ in 0..<50 { await Task.yield() }
        check(!enableReturned, "awaited policy enable remains behind the active physical drain")
        check(coordinator.isRunning && coordinator.policy.isEnabled, "overlapping on-off-on records enabled as latest policy")
        check(events.isRunning, "latest policy enable reinstalls the event source while the old drain is suspended")
        check(coordinator.activeDisplayIdentities.isEmpty, "latest policy enable stays panel-free during the old drain")
        check(registry.openPanelCount == 0, "stale disable cleanup cannot recreate panels before fresh content")
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
        check(
            await waitUntil {
                coordinator.activeDisplayIdentities.count == 2
                    && registry.openPanelCount == 2
            },
            "on-off-on constructs exactly the two enabled panels after fresh content arrives"
        )
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
        check(coordinator.activeDisplayIdentities.isEmpty, "latest start stays panel-free during the old drain")
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
        check(
            await waitUntil {
                coordinator.activeDisplayIdentities.count == 1
                    && registry.openPanelCount == 1
            },
            "stale stop cannot close the panel created by fresh successor content"
        )
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
        model: SurfaceActivityModel,
        policy: DisplayPolicy = .safeDefault
    ) -> PanelCoordinator {
        PanelCoordinator(
            displayProvider: displays,
            policy: policy,
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
            surfaceScope: .custom,
            enabledDisplayUUIDs: [display.uuid],
            preferredDisplayUUID: display.uuid
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
        events.replayRegistration(2, event: .primaryShortcut)
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

    mutating func verifyPointerEventDeliveryIsBounded() async {
        let scheduler = ManualMainActorDeliveryScheduler()
        let source = SystemPanelLifecycleEventSource(
            pointerDeliveryScheduler: { operation in
                scheduler.schedule(operation)
            }
        )
        let probe = source.workProbe
        var deliveredPositions: [CGPoint] = []
        source.start { event in
            guard case let .pointerMoved(point) = event else { return }
            deliveredPositions.append(point)
        }

        let idleHotKeyResourceCount = probe.hotKeyResourceCount
        check(probe.monitorCount == 0, "started lifecycle discovery owns zero idle pointer monitors")
        source.setPointerMonitoringEnabled(true)
        check(probe.monitorCount == 2, "visible demand installs one local and one global monitor")
        for revision in 0..<20_000 {
            source.submitPointerPositionForTesting(
                CGPoint(x: CGFloat(revision), y: CGFloat(revision % 997))
            )
        }
        let newestBurstPosition = CGPoint(x: 19_999, y: CGFloat(19_999 % 997))
        check(scheduler.pendingOperationCount == 1, "high-rate pointer burst schedules exactly one MainActor delivery")
        check(
            probe.pointerDeliveryWorkState.pendingDeliveryCount == 1
                && probe.pointerDeliveryWorkState.hasBufferedPosition,
            "high-rate pointer burst owns one pending delivery and one newest-value buffer"
        )
        check(
            probe.pointerDeliveryWorkState.maximumPendingDeliveryCount == 1,
            "pointer delivery work-state never exceeds its one-task bound"
        )

        await scheduler.runNext()
        check(deliveredPositions == [newestBurstPosition], "pointer burst delivers only its newest screen position")
        check(
            probe.pointerDeliveryWorkState.pendingDeliveryCount == 0
                && !probe.pointerDeliveryWorkState.hasBufferedPosition,
            "newest pointer delivery drains all scheduled and buffered work"
        )

        source.submitPointerPositionForTesting(newestBurstPosition)
        source.submitPointerPositionForTesting(newestBurstPosition)
        check(scheduler.pendingOperationCount == 0, "equivalent delivered pointer positions schedule no work")

        source.setPointerMonitoringEnabled(false)
        check(probe.monitorCount == 0, "final hide removes both pointer monitors")
        check(
            probe.observerCount == 4
                && probe.hotKeyResourceCount == idleHotKeyResourceCount
                && probe.handlerCount == 1 && probe.callbackLeaseCount == 1,
            "final hide preserves display, Space, sleep/wake, and shortcut discovery"
        )
        check(
            probe.pointerDeliveryWorkState.pendingDeliveryCount == 0
                && !probe.pointerDeliveryWorkState.hasBufferedPosition,
            "final hide leaves no pending pointer delivery"
        )
        source.setPointerMonitoringEnabled(true)

        source.submitPointerPositionForTesting(CGPoint(x: 21_000, y: 210))
        check(scheduler.pendingOperationCount == 1, "a fresh pointer position schedules one delivery")
        source.stop()
        check(
            probe.pointerDeliveryWorkState.pendingDeliveryCount == 0
                && !probe.pointerDeliveryWorkState.hasBufferedPosition,
            "shutdown synchronously revokes pending pointer ownership"
        )
        source.start { event in
            guard case let .pointerMoved(point) = event else { return }
            deliveredPositions.append(point)
        }
        source.setPointerMonitoringEnabled(true)
        let restartedPosition = CGPoint(x: 22_000, y: 220)
        source.submitPointerPositionForTesting(restartedPosition)
        check(scheduler.pendingOperationCount == 2, "restart owns one new delivery alongside one stale scheduled callback")
        await scheduler.runNext()
        check(deliveredPositions == [newestBurstPosition], "stop revokes a queued pointer callback before delivery")
        check(
            probe.pointerDeliveryWorkState.pendingDeliveryCount == 1
                && probe.pointerDeliveryWorkState.hasBufferedPosition,
            "stale callback cannot consume successor delivery ownership"
        )
        await scheduler.runNext()
        check(
            deliveredPositions == [newestBurstPosition, restartedPosition],
            "restart delivers only its fresh leased pointer position"
        )
        source.stop()
        check(
            probe.pointerDeliveryWorkState.pendingDeliveryCount == 0
                && !probe.pointerDeliveryWorkState.hasBufferedPosition,
            "stopped pointer delivery settles with zero owned work"
        )
        check(probe.monitorCount == 0, "stop removes both pointer monitors")

        let releaseScheduler = ManualMainActorDeliveryScheduler()
        var releasedDeliveryCount = 0
        var releasableSource: SystemPanelLifecycleEventSource? = SystemPanelLifecycleEventSource(
            pointerDeliveryScheduler: { operation in
                releaseScheduler.schedule(operation)
            }
        )
        let releaseProbe = releasableSource?.workProbe
        weak var releasedSource: SystemPanelLifecycleEventSource?
        releasedSource = releasableSource
        releasableSource?.start { event in
            if case .pointerMoved = event {
                releasedDeliveryCount += 1
            }
        }
        releasableSource?.setPointerMonitoringEnabled(true)
        for revision in 0..<20_000 {
            releasableSource?.submitPointerPositionForTesting(
                CGPoint(x: CGFloat(revision), y: CGFloat(-revision))
            )
        }
        check(releaseScheduler.pendingOperationCount == 1, "release stress retains one queued delivery at peak load")
        releasableSource = nil
        check(releasedSource == nil, "high-rate event source releases synchronously without task retention")
        check(
            await waitUntil { releaseProbe?.isRunning == false },
            "high-rate event source release retires platform registrations on MainActor"
        )
        await releaseScheduler.runNext()
        check(releasedDeliveryCount == 0, "released high-rate event source emits no stale pointer callback")
        check(releaseProbe?.hasWork == false, "released high-rate event source settles every owned resource")
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
        check(secondCoordinator.isRunning && secondRegistry.openPanelCount == 0, "replacement coordinator starts panel-free with the same idle model")
        check(await broker.workState().subscriberCount == 1, "replacement owner retains exactly one shared broker subscriber")
        do {
            let submitted = try await broker.submit(request(id: "replacement-owner", title: "Replacement owner update"))
            check(
                await waitUntil { model.snapshotVersion == submitted.version },
                "replacement coordinator model receives fresh broker updates"
            )
            check(
                await waitUntil { secondRegistry.openPanelCount == 1 },
                "replacement coordinator constructs its panel on fresh broker activity"
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
        check(replacementCoordinator.isRunning && replacementRegistry.openPanelCount == 0, "successor coordinator stays panel-free while the prior model drain is pending")
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
        check(
            await waitUntil { replacementRegistry.openPanelCount == 1 },
            "successor coordinator constructs one panel after fresh activity replay"
        )
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
        check(events.isRunning && registry.openPanelCount == 0, "detached-release coordinator owns discovery events but zero idle panels")

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
        check(registry.mutationSnapshot.closeCount == 0, "detached idle coordinator has no panel cleanup allocation")
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
        let expectedKinds: [(
            ActivitySurfacePreviewScenario,
            ActivityKind,
            String,
            ActivitySurfaceComposition,
            String?
        )] = [
            (ActivitySurfacePreviewCatalog.generic, .generic, SurfaceStrings.genericKind, .standard, nil),
            (ActivitySurfacePreviewCatalog.battery, .battery, SurfaceStrings.batteryKind, .battery, SurfaceStrings.shortProgressValue(62)),
            (ActivitySurfacePreviewCatalog.charging, .charging, SurfaceStrings.chargingKind, .charging, SurfaceStrings.shortProgressValue(48)),
            (ActivitySurfacePreviewCatalog.timer, .timer, SurfaceStrings.timerKind, .timerCountdown, "12:40"),
            (ActivitySurfacePreviewCatalog.timerCompact, .timer, SurfaceStrings.timerKind, .timerCountdown, "12:40"),
            (ActivitySurfacePreviewCatalog.timerCompletion, .timer, SurfaceStrings.timerKind, .timerCompletion, "Focus complete"),
            (ActivitySurfacePreviewCatalog.meeting, .meeting, SurfaceStrings.meetingKind, .standard, nil),
            (ActivitySurfacePreviewCatalog.volume, .volume, SurfaceStrings.volumeKind, .volumeLevel, SurfaceStrings.shortProgressValue(72)),
            (ActivitySurfacePreviewCatalog.volumeMuted, .volume, SurfaceStrings.volumeKind, .volumeMuted, SurfaceStrings.volumeMuted),
            (ActivitySurfacePreviewCatalog.volumeUnmuted, .volume, SurfaceStrings.volumeKind, .volumeUnmuted, SurfaceStrings.shortProgressValue(64)),
            (ActivitySurfacePreviewCatalog.volumeOutput, .volume, SurfaceStrings.volumeKind, .volumeOutput, "Studio Display"),
            (ActivitySurfacePreviewCatalog.media, .media, SurfaceStrings.mediaKind, .standard, SurfaceStrings.shortProgressValue(41)),
            (ActivitySurfacePreviewCatalog.file, .file, SurfaceStrings.fileKind, .standard, nil),
        ]

        for (scenario, expectedKind, expectedLabel, expectedComposition, expectedPrincipal) in expectedKinds {
            do {
                let snapshot = try scenario.snapshot()
                guard let current = snapshot.current else {
                    check(false, "\(scenario.name) preview has current content")
                    continue
                }
                let item = ActivitySurfaceItem(current)
                check(item.kind == expectedKind, "\(scenario.name) maps the bounded activity kind")
                check(item.kindLabel == expectedLabel, "\(scenario.name) exposes stable kind copy")
                check(
                    item.composition == expectedComposition,
                    "\(scenario.name) selects its deterministic activity-specific composition"
                )
                check(
                    item.signalPrincipalValue == expectedPrincipal,
                    "\(scenario.name) selects its deterministic principal signal value"
                )
                check(item.title == current.activity.presentation.title, "\(scenario.name) preserves broker title honestly")
                check(!item.symbolName.isEmpty, "\(scenario.name) includes a non-color status symbol")
                check(snapshot.queued.count <= ActivityQueueContext.maximumVisibleItems, "\(scenario.name) preview queue remains bounded")
            } catch {
                recordUnexpected(error, context: "preview \(scenario.name)")
            }
        }

        do {
            guard let timerPresented = try ActivitySurfacePreviewCatalog.timer.snapshot().current,
                  let levelPresented = try ActivitySurfacePreviewCatalog.volume.snapshot().current,
                  let mutedPresented = try ActivitySurfacePreviewCatalog.volumeMuted.snapshot().current,
                  let unmutedPresented = try ActivitySurfacePreviewCatalog.volumeUnmuted.snapshot().current,
                  let outputPresented = try ActivitySurfacePreviewCatalog.volumeOutput.snapshot().current else {
                check(false, "production-faithful Timer and Volume previews provide current content")
                return
            }
            let timer = ActivitySurfaceItem(timerPresented)
            let level = ActivitySurfaceItem(levelPresented)
            let muted = ActivitySurfaceItem(mutedPresented)
            let unmuted = ActivitySurfaceItem(unmutedPresented)
            let output = ActivitySurfaceItem(outputPresented)
            check(
                timer.semanticSymbolAccent == .amber,
                "countdown timer keeps its semantic Amber glyph independently of attachment"
            )
            check(
                level.title == "Volume"
                    && level.shortProgressValue == SurfaceStrings.shortProgressValue(72),
                "level preview renders a truthful percentage"
            )
            check(
                level.symbolName == "speaker.wave.2.fill"
                    && level.accessibilitySummary
                        == [SurfaceStrings.volumeKind, SurfaceStrings.progressValue(72)]
                            .joined(separator: ", "),
                "level preview has an appropriate symbol and non-duplicative VoiceOver copy"
            )
            check(
                muted.title == SurfaceStrings.volumeMuted
                    && muted.progressFraction == nil
                    && muted.shortProgressValue == nil
                    && !muted.hasSemanticProgress,
                "muted preview says Muted and never renders zero percent"
            )
            check(
                muted.symbolName == "speaker.slash.fill"
                    && muted.notchCompactValue == SurfaceStrings.volumeMuted
                    && muted.accessibilitySummary
                        == [SurfaceStrings.volumeKind, SurfaceStrings.volumeMuted]
                            .joined(separator: ", "),
                "muted preview has an appropriate symbol and non-duplicative VoiceOver copy"
            )
            check(
                output.title == "Studio Display"
                    && output.detail == SurfaceStrings.volumeOutputChanged
                    && output.notchCompactValue == "Studio Display"
                    && !output.hasSemanticProgress,
                "output preview renders the bounded device name in compact and expanded projections"
            )
            check(
                output.symbolName == "hifispeaker.2.fill"
                    && output.accessibilitySummary
                        == [
                            SurfaceStrings.volumeKind,
                            SurfaceStrings.volumeOutputChanged,
                            "Studio Display",
                        ].joined(separator: ", "),
                "output preview has an appropriate symbol and non-duplicative VoiceOver copy"
            )

            let notchedDisplay = DisplayGeometry(
                frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 875),
                backingScaleFactor: 2,
                topEdgeOcclusion: TopEdgeOcclusion(
                    frame: CGRect(x: 610, y: 856, width: 220, height: 44)
                )
            )
            let mutedModel = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.volumeMuted,
                displayGeometry: notchedDisplay,
                scheduler: ManualOneShotScheduler()
            )
            let levelModel = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.volume,
                displayGeometry: notchedDisplay,
                scheduler: ManualOneShotScheduler()
            )
            let levelWingWidth = (
                levelModel.layout.surfaceFrame.width
                    - (notchedDisplay.topEdgeOcclusion?.frame.width ?? 0)
            ) / 2
            check(
                mutedModel.layout.surfaceFrame.width >= 340
                    && levelWingWidth
                        >= PanelSurfaceVisualMetrics.minimumCompactNotchWingWidth,
                "notch-native signal states reserve enough wing width for padded glyph and copy"
            )
            check(
                (12...16).contains(PanelSurfaceVisualMetrics.notchWingOuterPadding)
                    && PanelSurfaceVisualMetrics.notchWingCameraClearance > 0
                    && PanelSurfaceVisualMetrics.notchWingContentWidth(for: levelWingWidth) >= 28,
                "notch wings keep safe outer padding, camera clearance, and useful content width"
            )

            let longOutputName = "Conference Room Display With an Intentionally Long Name"
            let longOutputScenario = ActivitySurfacePreviewScenario(
                name: "Long Volume output name",
                state: .compact,
                current: ActivityRequest(
                    identifier: "preview.volume.output.long",
                    source: ActivitySource.volume.rawValue,
                    kind: ActivityKind.volume.rawValue,
                    priority: ActivityPriority.high.rawValue,
                    title: longOutputName,
                    detail: SurfaceStrings.volumeOutputChanged,
                    temporalProgress: nil,
                    presentationRole: .volumeOutputChanged
                )
            )
            let longOutputModel = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: longOutputScenario,
                displayGeometry: notchedDisplay,
                scheduler: ManualOneShotScheduler()
            )
            let longOutputWingWidth = (
                longOutputModel.layout.surfaceFrame.width
                    - (notchedDisplay.topEdgeOcclusion?.frame.width ?? 0)
            ) / 2
            let longOutputItem = try longOutputScenario.snapshot().current.map(ActivitySurfaceItem.init)
            check(
                longOutputWingWidth == 82
                    && PanelSurfaceVisualMetrics.notchWingContentWidth(for: longOutputWingWidth) == 62
                    && longOutputItem?.notchCompactValue == longOutputName
                    && longOutputItem?.accessibilitySummary.contains(longOutputName) == true,
                "long output names retain full semantics inside one bounded truncating notch wing"
            )

            check(
                unmuted.title == SurfaceStrings.volumeUnmuted
                    && unmuted.notchCompactValue == SurfaceStrings.volumeUnmuted
                    && unmuted.progressFraction == 0.64
                    && unmuted.composition == .volumeUnmuted,
                "unmute presentation says Sound on while retaining truthful level progress"
            )

            guard let completionPresented = try ActivitySurfacePreviewCatalog.timerCompletion
                .snapshot().current else {
                check(false, "timer completion preview provides current content")
                return
            }
            let completion = ActivitySurfaceItem(completionPresented)
            check(
                completion.composition == .timerCompletion
                    && completion.symbolName == "checkmark.circle.fill"
                    && completion.accent == .mint
                    && completion.semanticSymbolAccent == .mint
                    && completion.title == "Focus complete"
                    && completion.signalPrincipalValue == "Focus complete"
                    && !completion.hasSemanticProgress,
                "timer completion has a dedicated success composition and non-color symbol"
            )
            let completionModel = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.timerCompletion,
                displayGeometry: notchedDisplay,
                scheduler: ManualOneShotScheduler()
            )
            let completionLayout = completionModel.layout
            let completionBodyHeight = completionLayout.surfaceFrame.height
                - completionLayout.surfaceContentTopInset
            check(
                completionLayout.attachment == .notchIntegrated
                    && completionLayout.surfaceContentTopInset == 44
                    && completionBodyHeight >= 40,
                "notched completion Peek reserves a full forty-point body below the camera housing"
            )
            check(
                completionModel.content.action?.label == "Done"
                    && completionLayout.hitRegion != .empty,
                "completion render contract keeps its real Done target visible and interactive"
            )

            let tallNotchedDisplay = DisplayGeometry(
                frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 826),
                backingScaleFactor: 2,
                topEdgeOcclusion: TopEdgeOcclusion(
                    frame: CGRect(x: 610, y: 826, width: 220, height: 74)
                )
            )
            let filePeekModel = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.file,
                displayGeometry: tallNotchedDisplay,
                scheduler: ManualOneShotScheduler()
            )
            check(
                filePeekModel.layout.surfaceFrame.height
                    - filePeekModel.layout.surfaceContentTopInset == 36,
                "standard notched Peek reserves a thirty-six-point body below the camera housing"
            )

            let timerModel = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.timer,
                displayGeometry: tallNotchedDisplay,
                scheduler: ManualOneShotScheduler()
            )
            check(
                timerModel.layout.surfaceFrame.height
                    - timerModel.layout.surfaceContentTopInset == 112,
                "expanded notched timer reserves its full countdown composition below the housing"
            )

            let genericExpanded = ActivitySurfacePreviewScenario(
                name: "Generic expanded body geometry",
                state: .expanded,
                current: ActivitySurfacePreviewCatalog.generic.current
            )
            let genericExpandedModel = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: genericExpanded,
                displayGeometry: tallNotchedDisplay,
                scheduler: ManualOneShotScheduler()
            )
            check(
                genericExpandedModel.layout.surfaceFrame.height
                    - genericExpandedModel.layout.surfaceContentTopInset == 104,
                "standard expanded detail reserves its base body below the housing"
            )

            let meetingModel = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.meeting,
                displayGeometry: tallNotchedDisplay,
                scheduler: ManualOneShotScheduler()
            )
            check(
                meetingModel.layout.surfaceFrame.height
                    - meetingModel.layout.surfaceContentTopInset == 132,
                "standard expanded action reserves its larger body below the housing"
            )

            let queuedActionModel = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.media,
                displayGeometry: notchedDisplay,
                scheduler: ManualOneShotScheduler()
            )
            let queuedActionLayout = queuedActionModel.layout
            let queuedActionBodyHeight = queuedActionLayout.surfaceFrame.height
                - queuedActionLayout.surfaceContentTopInset
            check(
                queuedActionBodyHeight == 176,
                "standard expanded queue and action reserve a one-hundred-seventy-six-point body"
            )
            check(
                queuedActionLayout.surfaceFrame.height
                    <= PanelMetrics.feasibility.maximumSize.height,
                "worst-case standard queue and action remain inside the fixed maximum envelope"
            )
            check(
                PanelSurfaceVisualMetrics.expandedActionTrailingInset
                    > PanelSurfaceVisualMetrics.expandedActionLeadingInset,
                "queued expanded action reserves an explicit trailing safety inset"
            )
            check(
                PanelSurfaceVisualMetrics.notchlessLightShadowOpacity
                    < PanelSurfaceVisualMetrics.notchlessDarkShadowOpacity
                    && PanelSurfaceVisualMetrics.notchlessLightShadowRadius
                        < PanelSurfaceVisualMetrics.notchlessDarkShadowRadius,
                "light notchless surfaces use a quieter shadow than dark surfaces"
            )

            let clampedQueuedActionModel = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.media,
                displayGeometry: tallNotchedDisplay,
                scheduler: ManualOneShotScheduler()
            )
            let clampedQueuedActionLayout = clampedQueuedActionModel.layout
            check(
                clampedQueuedActionLayout.surfaceFrame.height
                    == PanelMetrics.feasibility.maximumSize.height
                    && clampedQueuedActionLayout.surfaceFrame.height
                        - clampedQueuedActionLayout.surfaceContentTopInset == 166,
                "queued action body uses every available point when a tall occlusion forces clamping"
            )
        } catch {
            recordUnexpected(error, context: "semantic Volume surface previews")
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
            check(expanded.accessibility.hint.hasPrefix("Activate Erylo"), "expanded accessibility copy names deliberate activation instead of hover")
            check(
                expanded.accessibilitySurfaceAction == .collapse
                    && expanded.accessibilitySurfaceAction?.label
                        == SurfaceStrings.collapseAction,
                "expanded surface exposes an explicit named accessibility collapse action"
            )
            expanded.performAccessibilitySurfaceAction()
            check(expanded.state == .compact, "accessibility collapse action follows the safe reducer path")
            check(
                SurfaceStrings.actionHint(for: .cancel)
                    == SurfaceStrings.cancelTimerActionHint,
                "timer cancel exposes an accurate VoiceOver hint"
            )
            check(
                SurfaceStrings.actionHint(for: .pause) == SurfaceStrings.actionHint,
                "non-timer actions retain the generic action hint"
            )

            let compact = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.generic,
                displayGeometry: display,
                scheduler: ManualOneShotScheduler()
            )
            check(compact.accessibility.hint == SurfaceStrings.expandHint, "compact accessibility hint explains expansion")
            check(compact.accessibility.hint.hasPrefix("Activate Erylo"), "compact accessibility copy names deliberate activation instead of hover")
            check(
                compact.accessibilitySurfaceAction == .expand
                    && compact.accessibilitySurfaceAction?.label == SurfaceStrings.expandAction,
                "compact activity exposes an explicit named accessibility expand action"
            )
            compact.performAccessibilitySurfaceAction()
            check(compact.state == .expanded, "accessibility expand action follows the safe reducer path")

            let completion = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.timerCompletion,
                displayGeometry: display,
                scheduler: ManualOneShotScheduler()
            )
            check(
                completion.content.action?.intent == .dismiss
                    && completion.content.action?.label == "Done",
                "completion peek exposes one real Done dismiss action"
            )
            check(
                completion.content.hasExplicitControls,
                "completion Peek reports its real Done control to native focus policy"
            )

            let compactTimerWithExpandedAction = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewScenario(
                    name: "Compact timer with Expanded-only action",
                    state: .compact,
                    current: ActivitySurfacePreviewCatalog.timer.current
                ),
                displayGeometry: display,
                scheduler: ManualOneShotScheduler()
            )
            check(
                compactTimerWithExpandedAction.content.action == nil
                    && !compactTimerWithExpandedAction.content.hasExplicitControls,
                "Compact timer withholds its Expanded-only Cancel action and keyboard focus"
            )

            let compactCompletion = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewScenario(
                    name: "Compact retained completion",
                    state: .compact,
                    current: ActivitySurfacePreviewCatalog.timerCompletion.current
                ),
                displayGeometry: display,
                scheduler: ManualOneShotScheduler()
            )
            check(
                compactCompletion.content.action?.label == "Done"
                    && compactCompletion.content.hasExplicitControls,
                "retained Compact completion reports its rendered Done control"
            )
            check(
                completion.accessibilitySurfaceAction == .dismiss
                    && completion.accessibilitySurfaceAction?.label
                        == SurfaceStrings.dismissCompletionAction
                    && completion.accessibility.hint
                        == SurfaceStrings.dismissCompletionHint,
                "completion VoiceOver action dismisses instead of falsely offering expansion"
            )

            let dropTarget = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.dropTarget,
                displayGeometry: display,
                scheduler: ManualOneShotScheduler()
            )
            check(
                dropTarget.content.primary == .hidden,
                "unmounted File Hold exposes no reject-only drop affordance"
            )
            check(
                dropTarget.accessibility.value == SurfaceStrings.hiddenState
                    && dropTarget.accessibility.hint.isEmpty,
                "unmounted File Hold exposes no drop instruction to VoiceOver"
            )
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
        check(ActivitySurfacePreviewCatalog.representative.count == 16, "preview seam includes launcher, timer lifecycle, and representative Volume states")

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

    mutating func verifyFocusTimerProjectionAndLauncher() async {
        let start = Date(timeIntervalSinceReferenceDate: 70_000)
        let end = start.addingTimeInterval(3_700)
        let temporalRequest = ActivityRequest(
            identifier: "active-countdown",
            source: ActivitySource.timer.rawValue,
            kind: ActivityKind.timer.rawValue,
            priority: 60,
            title: "Focus Timer",
            detail: "62m remaining",
            progress: 0,
            actionIdentifier: "timer.cancel",
            actionLabel: "Cancel",
            actionIntent: ActivityActionIntent.cancel.rawValue,
            temporalProgress: ActivityTemporalProgress(
                startedAt: start,
                endsAt: end
            )
        )
        do {
            let activity = try Activity(
                validating: temporalRequest
            )
            let presented = PresentedActivity(
                activity: activity,
                submissionSequence: 1,
                revision: 41
            )
            let item = ActivitySurfaceItem(presented)
            guard let projection = item.temporalProjection else {
                check(false, "timer activity preserves its internal temporal projection")
                check(false, "timer projection formats MM:SS")
                check(false, "timer projection formats H:MM:SS")
                check(false, "timer projection derives local progress")
                return
            }
            let nearEnd = projection.snapshot(at: end.addingTimeInterval(-9.2))
            let hourScale = projection.snapshot(at: start.addingTimeInterval(39.2))
            check(nearEnd.remainingText == "00:10", "timer projection rounds useful MM:SS remaining time")
            check(hourScale.remainingText == "1:01:01", "timer projection formats H:MM:SS without percentage fallback")
            check(
                hourScale.fractionCompleted > 0 && hourScale.fractionCompleted < 1,
                "timer projection derives progress locally from immutable timestamps"
            )
            let compactContent = ActivitySurfaceContent(
                state: .compact,
                phase: .active,
                current: presented,
                queueContext: .empty,
                action: nil,
                actionDispatchState: .idle
            )
            let expandedContent = ActivitySurfaceContent(
                state: .expanded,
                phase: .active,
                current: presented,
                queueContext: .empty,
                action: nil,
                actionDispatchState: .idle
            )
            let compactAccessibility = PanelSurfaceAccessibility(
                content: compactContent,
                temporalSnapshot: nearEnd
            )
            let expandedAccessibility = PanelSurfaceAccessibility(
                content: expandedContent,
                temporalSnapshot: hourScale
            )
            check(
                compactAccessibility.value == [
                    SurfaceStrings.compactState,
                    SurfaceStrings.timerKind,
                    "Focus Timer",
                    SurfaceStrings.remainingTime("00:10"),
                ].joined(separator: ", "),
                "compact timer VoiceOver value comes from the live timestamp projection exactly once"
            )
            check(
                expandedAccessibility.value == [
                    SurfaceStrings.expandedState,
                    SurfaceStrings.timerKind,
                    "Focus Timer",
                    SurfaceStrings.remainingTime("1:01:01"),
                ].joined(separator: ", ")
                    && !expandedAccessibility.value.contains("62m remaining"),
                "expanded timer VoiceOver replaces stale request detail with the same live projection"
            )

            let visualDate = Date(timeIntervalSinceReferenceDate: 75_000)
            let visualScenario = ActivitySurfacePreviewCatalog.timerVisualQA(
                at: visualDate,
                state: .expanded
            )
            let visualPresented = try visualScenario.snapshot().current
            let visualItem = visualPresented.map { ActivitySurfaceItem($0) }
            check(
                visualItem?.temporalProjection?.snapshot(at: visualDate).remainingText == "12:40"
                    && visualItem?.signalPrincipalValue == "12:40",
                "native timer visual QA exercises temporal projection with a deterministic fallback"
            )

            let broker = ActivityBroker()
            let handler = CancellationWaitingActionHandler()
            let activityModel = SurfaceActivityModel(broker: broker, actionHandler: handler)
            activityModel.start()
            let snapshot = try await broker.submit(temporalRequest)
            check(
                await waitUntil {
                    activityModel.snapshotVersion == snapshot.version
                        && activityModel.currentAction != nil
                },
                "timestamp-backed timer exposes its stable cancel action"
            )
            if let action = activityModel.currentAction {
                check(activityModel.dispatch(action), "timestamp-backed cancel action begins dispatch")
                check(
                    await waitUntil { handler.didStart },
                    "cancel handler is deterministically in flight before local projection"
                )
                let brokerVersion = await broker.snapshot().version
                for second in 1...5 {
                    _ = projection.snapshot(at: start.addingTimeInterval(Double(second)))
                }
                check(
                    activityModel.actionDispatchState == .inProgress
                        && activityModel.currentAction == action
                        && activityModel.workState.hasActionTask,
                    "visible-only projection cannot cancel or stale an in-flight Cancel action"
                )
                check(
                    await broker.snapshot().version == brokerVersion,
                    "visible-only projection allocates no broker revision"
                )
            } else {
                check(false, "timestamp-backed cancel action is available for dispatch")
                check(false, "cancel handler can remain in flight through local projection")
                check(false, "local projection can preserve the broker revision")
            }
            await activityModel.stop()
            check(
                handler.didFinishAfterCancellation && activityModel.workState == .stopped,
                "projection fixture drains its action and subscription at the stop barrier"
            )
        } catch {
            recordUnexpected(error, context: "surface timer projection")
        }

        let frame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let geometry = DisplayGeometry(
            frame: frame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 875),
            backingScaleFactor: 2,
            topEdgeOcclusion: TopEdgeOcclusion(
                frame: CGRect(x: 610, y: 856, width: 220, height: 44)
            )
        )
        let model = PanelSurfaceModel(
            displayGeometry: geometry,
            initialState: .compact,
            scheduler: ManualOneShotScheduler(),
            activityModel: makeEmptyPreviewModel()
        )
        var launchedMinutes: [Int] = []
        model.setFocusTimerStartHandler { minutes in
            launchedMinutes.append(minutes)
            return true
        }
        check(model.showsFocusTimerLauncher, "idle deliberate compact state exposes the Focus Timer launcher")
        check(
            model.content.hasExplicitControls,
            "idle launcher reports explicit controls to native focus policy"
        )
        check(
            model.layout.surfaceFrame.size == PanelMetrics.feasibility.timerLauncherSize,
            "notch-native launcher has one bounded compact geometry"
        )
        check(model.startFocusTimer(minutes: 15), "launcher accepts the 15-minute preset")
        check(model.startFocusTimer(minutes: 25), "launcher accepts the 25-minute preset")
        check(model.startFocusTimer(minutes: 50), "launcher accepts the 50-minute preset")
        check(!model.startFocusTimer(minutes: 30), "launcher rejects non-preset durations")
        check(launchedMinutes == [15, 25, 50], "launcher routes only the three closed preset values")
        check(
            PanelSurfaceVisualMetrics.focusTimerPresetSpacing > 0
                && PanelSurfaceVisualMetrics.focusTimerPresetMinimumWidth * 3
                    + PanelSurfaceVisualMetrics.focusTimerPresetSpacing * 2
                    <= PanelMetrics.feasibility.notchlessTimerLauncherSize.width,
            "three routed timer presets retain visibly separate bounded control regions"
        )
        check(
            model.accessibility.hint == SurfaceStrings.focusTimerLauncherHint,
            "launcher exposes an accurate VoiceOver choice hint"
        )

        let geometryBroker = ActivityBroker()
        let geometryActivityModel = SurfaceActivityModel(broker: geometryBroker)
        let geometryScheduler = ManualOneShotScheduler()
        let geometryModel = PanelSurfaceModel(
            displayGeometry: geometry,
            initialState: .compact,
            scheduler: geometryScheduler,
            activityModel: geometryActivityModel
        )
        geometryModel.setFocusTimerStartHandler { _ in true }
        geometryScheduler.runAll()
        let launcherHitRegion = geometryModel.interactionHitRegion
        geometryActivityModel.start()
        check(
            await waitUntil { geometryActivityModel.phase == .active },
            "content-driven geometry fixture receives its initial snapshot"
        )
        do {
            _ = try await geometryBroker.submit(temporalRequest)
            check(
                await waitUntil { geometryActivityModel.current != nil },
                "starting a timer replaces the launcher without changing compact state"
            )
            let compactTarget = geometryModel.layout.hitRegion
            check(
                launcherHitRegion.intersecting(compactTarget) == .empty
                    && geometryModel.interactionHitRegion == .empty
                    && !geometryModel.isHitRegionSettled,
                "disjoint launcher shrink admits no native click region while settling"
            )
            geometryScheduler.runAll()
            check(
                geometryModel.interactionHitRegion == compactTarget,
                "same-state launcher shrink settles on the rendered timer geometry"
            )
        } catch {
            recordUnexpected(error, context: "content-driven timer geometry")
        }
        await geometryActivityModel.stop()
    }

    mutating func verifyProductInteractionSemantics() async {
        let display = makeDisplaySnapshot(identity: 72, isMain: true).geometry

        let launcherScheduler = ManualOneShotScheduler()
        let launcher = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .compact,
            scheduler: launcherScheduler,
            activityModel: makeEmptyPreviewModel()
        )
        let compactGeometryKey = launcher.geometryAnimationKey
        launcher.setFocusTimerStartHandler { _ in true }
        let launcherGeometryKey = launcher.geometryAnimationKey
        launcherScheduler.runAll()
        launcher.setPointerInside(true)
        launcherScheduler.runAll()
        check(
            launcher.state == .compact && launcher.showsFocusTimerLauncher,
            "idle Focus Timer launcher survives hover dwell instead of becoming an empty Peek"
        )
        check(
            launcherScheduler.activeOperationCount == 0,
            "idle launcher hover creates no delayed presentation work"
        )
        check(
            compactGeometryKey != launcherGeometryKey,
            "same-state launcher geometry produces a distinct animation key"
        )
        check(
            launcher.acceptsPointerInteraction && !launcher.acceptsBackgroundTap,
            "launcher accepts only its explicit preset buttons, not an ancestor tap"
        )

        let passiveScenarios = [
            ActivitySurfacePreviewCatalog.volume,
            ActivitySurfacePreviewCatalog.volumeMuted,
            ActivitySurfacePreviewCatalog.volumeOutput,
            ActivitySurfacePreviewCatalog.battery,
            ActivitySurfacePreviewCatalog.charging,
        ]
        for scenario in passiveScenarios {
            do {
                let scheduler = ManualOneShotScheduler()
                let model = try ActivitySurfacePreviewCatalog.makeModel(
                    scenario: scenario,
                    displayGeometry: display,
                    scheduler: scheduler
                )
                let surfaceFrame = model.layout.surfaceFrame
                let disposition = model.pointerDisposition(
                    at: CGPoint(x: surfaceFrame.midX, y: surfaceFrame.midY)
                )
                check(
                    !model.acceptsPointerInteraction
                        && !model.acceptsBackgroundTap
                        && !model.content.hasExplicitControls
                        && !disposition.acceptsMouseEvents
                        && !disposition.isInsideTargetSurface,
                    "\(scenario.name) remains click-through across its visible surface"
                )
                model.setPointerInside(true)
                scheduler.runAll()
                model.send(.hoverBegan)
                model.send(.primaryAction)
                check(
                    model.state == .compact,
                    "\(scenario.name) remains a compact passive acknowledgement"
                )
                check(
                    model.accessibilitySurfaceAction == nil
                        && model.accessibility.hint == SurfaceStrings.passiveStatusHint,
                    "\(scenario.name) advertises no useless expansion to VoiceOver"
                )
            } catch {
                recordUnexpected(error, context: "passive interaction \(scenario.name)")
            }
        }

        do {
            let scheduler = ManualOneShotScheduler()
            let activeTimer = ActivitySurfacePreviewScenario(
                name: "Compact active timer",
                state: .compact,
                current: ActivitySurfacePreviewCatalog.timer.current
            )
            let model = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: activeTimer,
                displayGeometry: display,
                scheduler: scheduler
            )
            model.setPointerInside(true)
            scheduler.runAll()
            model.send(.hoverBegan)
            check(
                model.state == .compact,
                "Focus Timer suppresses Peek when it would repeat the compact countdown"
            )
            check(
                model.acceptsBackgroundTap && model.acceptsPointerInteraction,
                "compact Focus Timer owns one deliberate expansion tap"
            )
            model.send(.primaryAction)
            check(
                model.state == .expanded,
                "Focus Timer expands only for its useful Cancel action"
            )
            check(
                !model.acceptsBackgroundTap && model.acceptsPointerInteraction,
                "expanded Focus Timer delegates input to Cancel without an ancestor tap"
            )
            check(
                !model.isHitRegionSettled
                    && model.interactionHitRegion != model.layout.hitRegion,
                "newly revealed timer controls remain gated while the native hit region catches up"
            )
            scheduler.runAll()
            check(
                model.isHitRegionSettled
                    && model.interactionHitRegion == model.layout.hitRegion,
                "timer controls become available only after the exact native hit region settles"
            )
            let timerIdentity = model.activityModel.current?.activity.identity
            model.prepareForWindowOrderOut()
            check(
                model.state == .compact
                    && model.activityModel.current?.activity.identity == timerIdentity
                    && model.interactionHitRegion == model.layout.hitRegion
                    && model.isHitRegionSettled
                    && scheduler.activeOperationCount == 0,
                "physical order-out preserves the timer but retires Expanded and all transition work"
            )

            let interruptedScheduler = ManualOneShotScheduler()
            let interrupted = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: activeTimer,
                displayGeometry: display,
                scheduler: interruptedScheduler
            )
            interrupted.send(.primaryAction)
            check(
                !interrupted.isHitRegionSettled,
                "an animated expansion advertises its conservative interaction phase"
            )
            interrupted.updateReduceMotion(true)
            check(
                interrupted.isHitRegionSettled
                    && interrupted.interactionHitRegion == interrupted.layout.hitRegion
                    && interruptedScheduler.activeOperationCount == 0,
                "enabling Reduce Motion settles an in-flight hit-region transition immediately"
            )

            let titleOnly = ActivitySurfacePreviewScenario(
                name: "Title-only standard activity",
                state: .compact,
                current: request(
                    id: "title-only-standard",
                    source: .external,
                    kind: .generic,
                    title: "Build succeeded"
                )
            )
            let titleOnlyDisplay = DisplayGeometry(
                frame: display.frame,
                visibleFrame: display.visibleFrame,
                backingScaleFactor: display.backingScaleFactor,
                topEdgeOcclusion: TopEdgeOcclusion(
                    frame: CGRect(x: 610, y: 856, width: 220, height: 44)
                )
            )
            let titleOnlyModel = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: titleOnly,
                displayGeometry: titleOnlyDisplay,
                scheduler: ManualOneShotScheduler()
            )
            titleOnlyModel.send(.hoverBegan)
            titleOnlyModel.send(.primaryAction)
            check(
                titleOnlyModel.state == .compact,
                "standard title-only activity opens neither redundant Peek nor empty Expanded"
            )
            let titleWingWidth = titleOnlyDisplay.topEdgeOcclusion.map {
                (titleOnlyModel.layout.surfaceFrame.width - $0.frame.width) / 2
            }
            check(
                titleWingWidth.map { $0 >= 76 } == true
                    && !titleOnlyModel.acceptsPointerInteraction,
                "title-only automation reserves a readable notch wing without becoming a dead control"
            )

            let detailedScheduler = ManualOneShotScheduler()
            let detailed = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.generic,
                displayGeometry: display,
                scheduler: detailedScheduler
            )
            detailed.setPointerInside(true)
            detailedScheduler.runAll()
            check(
                detailed.state == .peek,
                "standard activity earns Peek only when it adds distinct detail"
            )
        } catch {
            recordUnexpected(error, context: "active interaction policy")
        }

        let broker = ActivityBroker()
        let activityModel = SurfaceActivityModel(broker: broker)
        let scheduler = ManualOneShotScheduler()
        let panel = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .hidden,
            scheduler: scheduler,
            activityModel: activityModel
        )
        activityModel.start()
        check(
            await waitUntil { activityModel.phase == .active },
            "interaction update fixture receives its initial snapshot"
        )
        do {
            let first = try await broker.submit(
                request(
                    id: "hover-update",
                    source: .external,
                    kind: .generic,
                    priority: 70,
                    title: "First build",
                    detail: "Ready to inspect"
                )
            )
            check(
                await waitUntil { activityModel.snapshotVersion == first.version },
                "interaction update fixture publishes its first activity"
            )
            panel.setPointerInside(true)
            scheduler.runAll()
            check(panel.state == .peek, "detail activity enters Peek after bounded hover dwell")
            panel.setPointerInside(false)

            let replacement = try await broker.submit(
                request(
                    id: "hover-update",
                    source: .external,
                    kind: .generic,
                    priority: 70,
                    title: "Second build",
                    detail: "Still ready to inspect"
                )
            )
            check(
                await waitUntil { activityModel.snapshotVersion == replacement.version },
                "activity update lands while hover exit is pending"
            )
            check(panel.state == .peek, "activity update preserves the in-flight hover corridor")
            scheduler.runAll()
            check(
                panel.state == .compact,
                "activity update re-arms hover exit instead of stranding Peek"
            )

            panel.send(.primaryAction)
            check(panel.state == .expanded, "detailed activity enters Expanded deliberately")
            let exactReplacement = try await broker.submit(
                request(
                    id: "hover-update",
                    source: .external,
                    kind: .generic,
                    priority: 70,
                    title: "Third build",
                    detail: "Replacement revision"
                )
            )
            check(
                await waitUntil { activityModel.snapshotVersion == exactReplacement.version },
                "expanded activity replacement reaches the shared model"
            )
            check(
                panel.state == .compact,
                "exact expanded activity replacement collapses instead of swapping content in place"
            )

            panel.send(.primaryAction)
            check(panel.state == .expanded, "replacement can be expanded explicitly")
            if let replacementIdentity = exactReplacement.current?.activity.identity {
                _ = await broker.cancel(replacementIdentity)
            } else {
                check(false, "replacement snapshot retains its exact activity identity")
            }
            check(
                await waitUntil { activityModel.current == nil && panel.state == .hidden },
                "expanded activity disappearance hides instead of stranding an empty panel"
            )
        } catch {
            recordUnexpected(error, context: "hover and expanded activity updates")
        }
        await activityModel.stop()
        await broker.shutdown()
    }

    mutating func verifyKeyboardFocusAndEscapeSemantics() async {
        check(
            DeliberatePanelFocusPolicy.shouldFocusExistingControls(
                state: .peek,
                isWindowPresented: true,
                hasExplicitControls: true
            ),
            "visible completion controls use the focus route instead of the semantic primary action"
        )
        check(
            !DeliberatePanelFocusPolicy.shouldFocusExistingControls(
                state: .peek,
                isWindowPresented: true,
                hasExplicitControls: false
            ),
            "passive Peek content remains outside deliberate key focus"
        )

        let compactPolicy = ExpandedInteractionPolicy(
            state: .compact,
            isWindowPresented: true,
            hitRegion: .empty,
            hasExplicitControls: true
        )
        let peekPolicy = ExpandedInteractionPolicy(
            state: .peek,
            isWindowPresented: true,
            hitRegion: .empty,
            hasExplicitControls: true
        )
        check(
            compactPolicy.escapeDecision(panelIsKey: true) == .retireKeyFocus
                && peekPolicy.escapeDecision(panelIsKey: true) == .retireKeyFocus,
            "Escape retires key-capable Compact and Peek without invoking their controls"
        )
        check(
            peekPolicy.escapeDecision(panelIsKey: false) == .ignore,
            "a passive non-key Peek never intercepts Escape"
        )

        do {
            let completion = try ActivitySurfacePreviewCatalog.makeModel(
                scenario: ActivitySurfacePreviewCatalog.timerCompletion,
                displayGeometry: makeDisplaySnapshot(identity: 73).geometry,
                scheduler: ManualOneShotScheduler()
            )
            let completionIdentity = completion.activityModel.current?.activity.identity
            completion.requestDeliberateControlFocus()
            check(
                completion.deliberateControlFocusRequest?.control == .completionDone
                    && completion.state == .peek
                    && completion.activityModel.current?.activity.identity == completionIdentity,
                "requesting completion focus targets Done without acknowledging or contracting it"
            )
            completion.retireDeliberateControlFocus()
            check(
                completion.deliberateControlFocusRequest == nil
                    && completion.activityModel.current?.activity.identity == completionIdentity,
                "retiring completion focus preserves the pending acknowledgement"
            )
            completion.send(.hide)
            check(
                completion.state == .hidden
                    && completion.activityModel.current?.activity.identity == completionIdentity,
                "Escape-style hiding orders out completion without acknowledging Done"
            )
        } catch {
            recordUnexpected(error, context: "completion keyboard focus")
        }

        let broker = ActivityBroker()
        let activityModel = SurfaceActivityModel(broker: broker)
        let displays = FakeDisplayProvider(displays: [
            makeDisplaySnapshot(identity: 74, isMain: true),
        ])
        let events = FakeLifecycleEventSource()
        let registry = SharedModelPanelRegistry()
        let coordinator = makeCoordinator(
            displays: displays,
            events: events,
            registry: registry,
            model: activityModel
        )
        await coordinator.startAndWait()
        do {
            let submitted = try await broker.submit(
                request(
                    id: "shortcut-completion",
                    priority: 90,
                    title: "Focus complete",
                    actionIdentifier: "timer.dismiss-completion",
                    actionLabel: "Done",
                    actionIntent: .dismiss,
                    presentationRole: .completionAcknowledgement
                )
            )
            check(
                await waitUntil {
                    activityModel.snapshotVersion == submitted.version
                        && registry.latestOpenPanel?.state == .peek
                },
                "completion shortcut fixture reaches a visible Peek"
            )
            let panel = registry.latestOpenPanel
            events.emitCurrent(.primaryShortcut)
            check(
                panel?.focusExistingControlsCount == 1
                    && panel?.primaryActionCount == 0
                    && panel?.state == .peek
                    && activityModel.current?.activity.identity
                        == submitted.current?.activity.identity,
                "Control-Command-E focuses an existing Done control without dispatching Done"
            )
        } catch {
            recordUnexpected(error, context: "completion shortcut routing")
        }
        await coordinator.shutdown()
        await broker.shutdown()
    }

    mutating func verifyTemporalProjectionPhysicalVisibility() async {
        let broker = ActivityBroker()
        let activityModel = SurfaceActivityModel(broker: broker)
        let display = makeDisplaySnapshot(identity: 71, isMain: true)
        let displays = FakeDisplayProvider(displays: [display])
        let events = FakeLifecycleEventSource()
        let registry = SharedModelPanelRegistry()
        let coordinator = makeCoordinator(
            displays: displays,
            events: events,
            registry: registry,
            model: activityModel
        )
        await coordinator.startAndWait()

        let start = Date(timeIntervalSinceReferenceDate: 80_000)
        let end = start.addingTimeInterval(90)
        do {
            let submitted = try await broker.submit(
                ActivityRequest(
                    identifier: "physical-visibility-timer",
                    source: ActivitySource.timer.rawValue,
                    kind: ActivityKind.timer.rawValue,
                    priority: 60,
                    title: "Focus Timer",
                    actionIdentifier: "timer.cancel",
                    actionLabel: "Cancel",
                    actionIntent: ActivityActionIntent.cancel.rawValue,
                    temporalProgress: ActivityTemporalProgress(
                        startedAt: start,
                        endsAt: end
                    )
                )
            )
            check(
                await waitUntil {
                    activityModel.snapshotVersion == submitted.version
                        && registry.activeTemporalProjectionCount == 1
                },
                "shown timer panel owns one visible-only temporal projection"
            )
            guard let panel = registry.latestOpenPanel else {
                check(false, "temporal projection panel remains available")
                await coordinator.shutdown()
                await broker.shutdown()
                return
            }
            let stableVersion = await broker.snapshot().version

            events.emitCurrent(.primaryShortcut)
            check(panel.state == .expanded, "timer expands deliberately before Space reconciliation")
            events.emitCurrent(.activeSpaceChanged)
            check(
                panel.state == .compact && panel.isTemporalProjectionActive,
                "active-Space reconciliation contracts Expanded without retiring the timer"
            )
            events.emitCurrent(.primaryShortcut)
            check(panel.state == .expanded, "timer can expand again before workspace sleep")

            events.emitCurrent(.workspaceWillSleep)
            check(
                panel.hideCount == 1
                    && panel.state == .compact
                    && registry.activeTemporalProjectionCount == 0,
                "workspace sleep orders out the panel and retires all timeline projection work"
            )
            check(
                panel.temporalSnapshot(at: start.addingTimeInterval(30))?.remainingText == "01:00",
                "ordered-out timer retains immutable timestamps without scheduling"
            )
            check(
                await broker.snapshot().version == stableVersion,
                "sleeping projection performs no broker revision churn"
            )

            events.emitCurrent(.workspaceDidWake)
            check(
                panel.showCount == 2 && registry.activeTemporalProjectionCount == 1,
                "workspace wake reshows the panel and re-enables visible-only projection"
            )
            check(
                panel.temporalSnapshot(at: start.addingTimeInterval(61))?.remainingText == "00:29",
                "reshown projection resumes directly from current timestamps"
            )
            check(
                await broker.snapshot().version == stableVersion,
                "wake-time projection preserves the exact activity revision"
            )

            check(coordinator.toggleSelectedPanelVisibility(), "menu hide reaches the selected timer panel")
            check(
                !panel.isTemporalProjectionActive,
                "logically hidden shown panel owns zero temporal projection work"
            )
            check(coordinator.toggleSelectedPanelVisibility(), "menu reshow restores the selected timer panel")
            check(
                panel.isTemporalProjectionActive,
                "logical reshow restores projection without a provider tick"
            )
        } catch {
            recordUnexpected(error, context: "temporal projection physical visibility")
        }

        await coordinator.shutdown()
        check(
            registry.panels.allSatisfy { !$0.isTemporalProjectionActive },
            "projection visibility shutdown leaves zero mounted timeline work"
        )
        let finalBrokerWork = await broker.workState()
        check(
            activityModel.workState == .stopped
                && finalBrokerWork.subscriberCount == 0,
            "projection visibility shutdown settles all surface subscription work"
        )
        await broker.shutdown()
    }

    mutating func verifyWindowTransitionStaging() {
        let display = makeDisplaySnapshot(identity: 9).geometry
        let scheduler = ManualOneShotScheduler()
        let model = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .compact,
            scheduler: scheduler,
            activityModel: makeEmptyPreviewModel()
        )
        model.setWindowPresented(false)

        let gate = PanelWindowTransitionGate(scheduler: scheduler)
        let trace = WindowTransitionTrace()
        gate.orderIn(
            stageHidden: {
                trace.append("hidden")
                return model.stageForWindowOrderIn()
            },
            orderFront: {
                trace.append("front")
                model.setWindowPresented(true)
            },
            commitCompact: {
                trace.append("compact")
                model.commitStagedWindowOrderIn()
            }
        )
        check(
            trace.events == ["hidden", "front"]
                && model.state == .compact
                && model.renderedState == .hidden
                && model.content.state == .hidden
                && model.interactionHitRegion == .empty,
            "window order-in presents an inert Hidden render without withdrawing Compact demand"
        )
        check(
            scheduler.lastScheduledDelay == PanelWindowTransitionGate.orderInStagingDelay
                && scheduler.activeOperationCount == 1
                && gate.pendingKind == .orderInCommit,
            "Compact commit waits one display frame so Hidden cannot be coalesced away"
        )

        scheduler.runNext()
        check(
            trace.events == ["hidden", "front", "compact"]
                && model.state == .compact
                && model.renderedState == .compact
                && !model.isHitRegionSettled
                && scheduler.lastScheduledDelay == .milliseconds(220),
            "staged Compact commit enters the existing conservative morph interval"
        )
        scheduler.runAll()
        check(
            model.interactionHitRegion == model.layout.hitRegion
                && model.isHitRegionSettled
                && scheduler.activeOperationCount == 0,
            "ordered-in Compact controls become interactive only after the morph settles"
        )

        let exitScheduler = ManualOneShotScheduler()
        let exitGate = PanelWindowTransitionGate(scheduler: exitScheduler)
        let exitCounter = CallbackCounter()
        exitGate.orderOut(after: .milliseconds(220)) {
            exitCounter.increment()
        }
        check(
            exitCounter.count == 0
                && exitScheduler.lastScheduledDelay == .milliseconds(220)
                && exitGate.hasPendingOrderOut,
            "standard demand loss keeps the physical panel ordered in for the outgoing morph"
        )
        exitScheduler.runAll()
        check(exitCounter.count == 1, "standard order-out fires once after 220 milliseconds")

        let interruptedScheduler = ManualOneShotScheduler()
        let interruptedGate = PanelWindowTransitionGate(scheduler: interruptedScheduler)
        let staleExitCounter = CallbackCounter()
        let replacementTrace = WindowTransitionTrace()
        interruptedGate.orderOut(after: .milliseconds(220)) {
            staleExitCounter.increment()
        }
        interruptedGate.orderIn(
            stageHidden: {
                replacementTrace.append("hidden")
                return true
            },
            orderFront: {
                replacementTrace.append("front")
            },
            commitCompact: {
                replacementTrace.append("compact")
            }
        )
        interruptedScheduler.runAll()
        check(
            staleExitCounter.count == 0
                && replacementTrace.events == ["hidden", "front", "compact"]
                && interruptedScheduler.activeOperationCount == 0,
            "a newer order-in cancels the stale physical exit generation"
        )

        let reverseScheduler = ManualOneShotScheduler()
        let reverseGate = PanelWindowTransitionGate(scheduler: reverseScheduler)
        let staleCommitCounter = CallbackCounter()
        let replacementExitCounter = CallbackCounter()
        reverseGate.orderIn(
            stageHidden: { true },
            orderFront: {},
            commitCompact: {
                staleCommitCounter.increment()
            }
        )
        reverseGate.orderOut(after: nil) {
            replacementExitCounter.increment()
        }
        reverseScheduler.runAll()
        check(
            staleCommitCounter.count == 0
                && replacementExitCounter.count == 1
                && reverseScheduler.activeOperationCount == 0,
            "a newer immediate retirement cancels the stale Compact commit"
        )

        let immediateGate = PanelWindowTransitionGate(
            scheduler: ManualOneShotScheduler()
        )
        let immediateCounter = CallbackCounter()
        immediateGate.orderOut(after: nil) {
            immediateCounter.increment()
        }
        check(
            immediateCounter.count == 1 && immediateGate.pendingKind == nil,
            "Reduce Motion performs physical order-out synchronously"
        )

        let reducedScheduler = ManualOneShotScheduler()
        let reducedModel = PanelSurfaceModel(
            displayGeometry: display,
            initialState: .compact,
            scheduler: reducedScheduler,
            activityModel: makeEmptyPreviewModel()
        )
        reducedModel.setWindowPresented(false)
        reducedModel.updateReduceMotion(true)
        check(
            !reducedModel.stageForWindowOrderIn()
                && reducedModel.renderedState == .compact
                && reducedModel.windowOrderOutDelay == nil
                && reducedScheduler.activeOperationCount == 0,
            "Reduce Motion skips the staged entrance and exposes no delayed exit"
        )
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
        check(
            model.motionStyle.allowsHoverOpacityAnimation,
            "standard motion permits the subtle hover opacity response"
        )
        model.updateReduceMotion(true)
        check(model.motionStyle == .reduced, "system Reduce Motion selects reduced motion content")
        check(
            !model.motionStyle.allowsHoverOpacityAnimation,
            "Reduce Motion suppresses hover opacity animation"
        )
        model.send(.primaryAction)
        check(
            model.isHitRegionSettled
                && model.interactionHitRegion == model.layout.hitRegion
                && scheduler.activeOperationCount == 0,
            "Reduce Motion snaps geometry and hit testing without scheduling motion work"
        )

        model.updateReduceMotion(false)
        check(
            model.motionStyle == .standard
                && model.motionStyle.allowsHoverOpacityAnimation,
            "disabling system Reduce Motion restores standard presentation immediately"
        )
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
        check(scheduler.activeOperationCount == 0, "rapid interaction stress settles with zero pending surface work")
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

        await coordinator.updateAndWait(policy: DisplayPolicy(surfaceScope: .allAvailable))
        check(
            await waitUntil { await broker.workState().subscriberCount == 1 },
            "re-enabled coordinator starts the shared model's one subscriber"
        )
        check(registry.creationCount == 0, "re-enabled idle coordinator constructs zero hidden panels")

        do {
            let submitted = try await broker.submit(
                request(id: "shared", priority: 80, title: "Shared broker activity")
            )
            check(
                await waitUntil { sharedModel.snapshotVersion == submitted.version },
                "shared broker snapshot is visible through the injected model"
            )
            check(
                await waitUntil { registry.creationCount == 2 },
                "first broker activity invokes one bounded factory path for both enabled displays"
            )
            check(registry.modelIdentities.count == 1, "all display panels receive the same observable activity model")
            check(registry.modelIdentities.first == ObjectIdentifier(sharedModel), "panel factory receives the app-owned model identity")
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
        presentationRole: ActivityPresentationRole = .standard,
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
            ttlMilliseconds: ttlMilliseconds,
            temporalProgress: nil,
            presentationRole: presentationRole
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
private final class CallbackCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@MainActor
private final class WindowTransitionTrace {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
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

    func runNext() {
        guard !entries.isEmpty else { return }
        let entry = entries.removeFirst()
        if !entry.token.isCancelled {
            entry.operation()
        }
    }

    func runAll() {
        var safetyBudget = 10_000
        while !entries.isEmpty, safetyBudget > 0 {
            safetyBudget -= 1
            runNext()
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

private final class ManualMainActorDeliveryScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@MainActor @Sendable () async -> Void] = []

    var pendingOperationCount: Int {
        lock.withLock { operations.count }
    }

    func schedule(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        lock.withLock {
            operations.append(operation)
        }
    }

    @MainActor
    func runNext() async {
        let operation = lock.withLock {
            operations.isEmpty ? nil : operations.removeFirst()
        }
        await operation?()
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

    var activeTemporalProjectionCount: Int {
        panels.lazy.filter(\.isTemporalProjectionActive).count
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
        let panel = FakePanel(
            displayIdentity: snapshot.identity,
            surfaceModel: PanelSurfaceModel(
                displayGeometry: snapshot.geometry,
                initialState: .hidden,
                activityModel: activityModel
            )
        )
        panels.append(panel)
        return panel
    }
}

@MainActor
private final class FakePanel: PanelPresenting, PanelExistingControlFocusing {
    let displayIdentity: DisplayIdentity
    private let surfaceModel: PanelSurfaceModel
    private(set) var isClosed = false
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var closeCount = 0
    private(set) var updateCount = 0
    private(set) var pointerUpdateCount = 0
    private(set) var primaryActionCount = 0
    private(set) var focusExistingControlsCount = 0

    var isTemporalProjectionActive: Bool {
        surfaceModel.isTemporalProjectionActive
    }

    var state: PanelPresentationState {
        surfaceModel.state
    }

    init(displayIdentity: DisplayIdentity, surfaceModel: PanelSurfaceModel) {
        self.displayIdentity = displayIdentity
        self.surfaceModel = surfaceModel
        surfaceModel.setWindowPresented(false)
    }

    func show() {
        showCount += 1
        surfaceModel.setWindowPresented(true)
    }

    func hide() {
        hideCount += 1
        surfaceModel.setWindowPresented(false)
        surfaceModel.prepareForWindowOrderOut()
    }

    func close() {
        closeCount += 1
        isClosed = true
        surfaceModel.setWindowPresented(false)
        surfaceModel.prepareForWindowOrderOut()
    }

    func update(snapshot: DisplaySnapshot) {
        updateCount += 1
    }

    func updatePointer(screenPoint: CGPoint) {
        pointerUpdateCount += 1
    }

    func performPrimaryAction() {
        primaryActionCount += 1
        surfaceModel.send(.primaryAction)
    }

    func focusExistingControls() -> Bool {
        guard DeliberatePanelFocusPolicy.shouldFocusExistingControls(
            state: surfaceModel.state,
            isWindowPresented: surfaceModel.isWindowPresented,
            hasExplicitControls: surfaceModel.logicalContentHasExplicitControls
        ) else {
            return false
        }
        focusExistingControlsCount += 1
        return true
    }

    func performVisibilityToggle() {
        surfaceModel.send(surfaceModel.state == .hidden ? .show : .hide)
    }

    func temporalSnapshot(at date: Date) -> ActivitySurfaceTemporalSnapshot? {
        guard case let .activity(item) = surfaceModel.content.primary else { return nil }
        return item.temporalProjection?.snapshot(at: date)
    }
    func cancelPendingInteractions() {}

    func contractForEnvironmentalTransition() {
        surfaceModel.prepareForWindowOrderOut()
    }
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
        uuid: makeDisplayUUID(identity),
        localizedName: isMain ? "Built-in Display" : "External Display",
        geometry: DisplayGeometry(
            frame: frame,
            visibleFrame: CGRect(x: originX, y: 0, width: 1_440, height: 875),
            backingScaleFactor: 2,
            topEdgeOcclusion: nil
        ),
        isMain: isMain
    )
}

private func makeDisplayUUID(_ value: UInt32) -> DisplayUUID {
    let uuid = String(format: "00000000-0000-0000-0000-%012llx", UInt64(value))
    return DisplayUUID(rawValue: uuid)!
}

@MainActor
private func writeNativeVisualQA(to directory: URL) throws {
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let frame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    let notchedGeometry = DisplayGeometry(
        frame: frame,
        visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 875),
        backingScaleFactor: 2,
        topEdgeOcclusion: TopEdgeOcclusion(
            frame: CGRect(x: 610, y: 856, width: 220, height: 44)
        )
    )
    let notchlessGeometry = DisplayGeometry(
        frame: frame,
        visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 875),
        backingScaleFactor: 2,
        topEdgeOcclusion: nil
    )
    let compactOutput = ActivitySurfacePreviewScenario(
        name: "Volume output compact visual QA",
        state: .compact,
        current: ActivitySurfacePreviewCatalog.volumeOutput.current
    )
    let genericPeek = ActivitySurfacePreviewScenario(
        name: "Generic Peek visual QA",
        state: .peek,
        current: ActivitySurfacePreviewCatalog.generic.current
    )
    let scenarios: [NativeVisualQAFixture] = [
        NativeVisualQAFixture(
            filename: "erylo-timer-launcher.png",
            scenario: { ActivitySurfacePreviewCatalog.focusTimerLauncher },
            geometry: notchedGeometry,
            desktop: .dark
        ),
        NativeVisualQAFixture(
            filename: "erylo-timer-launcher-notchless.png",
            scenario: { ActivitySurfacePreviewCatalog.focusTimerLauncher },
            geometry: notchlessGeometry,
            desktop: .dark
        ),
        NativeVisualQAFixture(
            filename: "erylo-timer-compact.png",
            scenario: {
                ActivitySurfacePreviewCatalog.timerVisualQA(at: Date(), state: .compact)
            },
            geometry: notchedGeometry,
            desktop: .dark
        ),
        NativeVisualQAFixture(
            filename: "erylo-timer-expanded.png",
            scenario: {
                ActivitySurfacePreviewCatalog.timerVisualQA(at: Date(), state: .expanded)
            },
            geometry: notchedGeometry,
            desktop: .dark
        ),
        NativeVisualQAFixture(
            filename: "erylo-timer-completion.png",
            scenario: { ActivitySurfacePreviewCatalog.timerCompletion },
            geometry: notchedGeometry,
            desktop: .dark
        ),
        NativeVisualQAFixture(
            filename: "erylo-volume-muted-notched.png",
            scenario: { ActivitySurfacePreviewCatalog.volumeMuted },
            geometry: notchedGeometry,
            desktop: .dark
        ),
        NativeVisualQAFixture(
            filename: "erylo-volume-unmuted-notched.png",
            scenario: { ActivitySurfacePreviewCatalog.volumeUnmuted },
            geometry: notchedGeometry,
            desktop: .dark
        ),
        NativeVisualQAFixture(
            filename: "erylo-volume-output-notched.png",
            scenario: { ActivitySurfacePreviewCatalog.volumeOutput },
            geometry: notchedGeometry,
            desktop: .dark
        ),
        NativeVisualQAFixture(
            filename: "erylo-volume-muted-notchless.png",
            scenario: { ActivitySurfacePreviewCatalog.volumeMuted },
            geometry: notchlessGeometry,
            desktop: .dark
        ),
        NativeVisualQAFixture(
            filename: "erylo-volume-output-notchless.png",
            scenario: { compactOutput },
            geometry: notchlessGeometry,
            desktop: .dark
        ),
        NativeVisualQAFixture(
            filename: "erylo-timer-expanded-light-desktop.png",
            scenario: {
                ActivitySurfacePreviewCatalog.timerVisualQA(at: Date(), state: .expanded)
            },
            geometry: notchedGeometry,
            desktop: .light
        ),
        NativeVisualQAFixture(
            filename: "erylo-volume-output-notchless-light.png",
            scenario: { compactOutput },
            geometry: notchlessGeometry,
            desktop: .light
        ),
        NativeVisualQAFixture(
            filename: "erylo-battery-notched.png",
            scenario: { ActivitySurfacePreviewCatalog.battery },
            geometry: notchedGeometry,
            desktop: .dark
        ),
        NativeVisualQAFixture(
            filename: "erylo-charging-notchless.png",
            scenario: { ActivitySurfacePreviewCatalog.charging },
            geometry: notchlessGeometry,
            desktop: .dark
        ),
        NativeVisualQAFixture(
            filename: "erylo-generic-peek-notched.png",
            scenario: { genericPeek },
            geometry: notchedGeometry,
            desktop: .dark
        ),
        NativeVisualQAFixture(
            filename: "erylo-queued-action-expanded-notched.png",
            scenario: { ActivitySurfacePreviewCatalog.media },
            geometry: notchedGeometry,
            desktop: .dark
        ),
    ]
    guard Set(scenarios.map(\.desktop)) == Set(NativeVisualQADesktop.allCases) else {
        throw VisualQARenderingError.incompleteDesktopContexts
    }

    for fixture in scenarios {
        let scenario = fixture.scenario()
        let model = try ActivitySurfacePreviewCatalog.makeModel(
            scenario: scenario,
            displayGeometry: fixture.geometry,
            scheduler: ManualOneShotScheduler()
        )
        let renderedSize = PanelMetrics.feasibility.maximumSize
        let rootView = ZStack(alignment: .top) {
            fixture.desktop.backdrop
            PanelSurfaceView(model: model)
        }
        .frame(
            width: renderedSize.width,
            height: renderedSize.height,
            alignment: .top
        )
        .environment(\.colorScheme, fixture.desktop.colorScheme)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(origin: .zero, size: renderedSize)
        hostingView.layoutSubtreeIfNeeded()
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(renderedSize.width * 2),
            pixelsHigh: Int(renderedSize.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw VisualQARenderingError.encodingFailed(fixture.filename)
        }
        representation.size = renderedSize
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        try validateNativeSurfacePixels(
            representation,
            expectedSurfaceSize: model.layout.surfaceFrame.size,
            filename: fixture.filename
        )
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw VisualQARenderingError.encodingFailed(fixture.filename)
        }
        try png.write(
            to: directory.appendingPathComponent(fixture.filename),
            options: .atomic
        )
    }
}

@MainActor
private func validateNativeSurfacePixels(
    _ representation: NSBitmapImageRep,
    expectedSurfaceSize: CGSize,
    filename: String
) throws {
    let sampleStride = 2
    // The dark notchless material can differ from the flat QA backdrop by only
    // about 0.016 per channel after the guaranteed ink overlay. Stay below that
    // bound while remaining safely above a byte of flat-color quantization.
    let backdropDelta: CGFloat = 0.009
    guard let backdrop = deviceRGBSample(representation, x: 0, y: 0) else {
        throw VisualQARenderingError.unreadablePixels(filename)
    }

    var changedCount = 0
    var minimumX = representation.pixelsWide
    var minimumY = representation.pixelsHigh
    var maximumX = 0
    var maximumY = 0
    for y in stride(from: 0, to: representation.pixelsHigh, by: sampleStride) {
        for x in stride(from: 0, to: representation.pixelsWide, by: sampleStride) {
            guard let sample = deviceRGBSample(representation, x: x, y: y) else {
                continue
            }
            guard sample.maximumComponentDelta(from: backdrop) > backdropDelta else {
                continue
            }
            changedCount += 1
            minimumX = min(minimumX, x)
            minimumY = min(minimumY, y)
            maximumX = max(maximumX, x)
            maximumY = max(maximumY, y)
        }
    }

    let pixelsPerPoint = CGFloat(representation.pixelsWide) / representation.size.width
    let samplesPerPoint = pixelsPerPoint / CGFloat(sampleStride)
    let expectedChangedCount = Int(
        (
            expectedSurfaceSize.width
                * expectedSurfaceSize.height
                * samplesPerPoint
                * samplesPerPoint
        ).rounded(.down)
    )
    let minimumChangedCount = max(Int(Double(expectedChangedCount) * 0.52), 120)
    // Notchless pills include a bounded native shadow outside the silhouette.
    // Coverage plus the independent width/height bounds below reject blank,
    // materially clipped, and accidental full-host surfaces.
    let maximumChangedCount = max(Int(Double(expectedChangedCount) * 1.75), 240)
    guard changedCount >= minimumChangedCount,
          changedCount <= maximumChangedCount else {
        throw VisualQARenderingError.implausibleSurfaceCoverage(
            filename,
            changed: changedCount,
            expected: expectedChangedCount
        )
    }

    let observedWidth = maximumX - minimumX + sampleStride
    let observedHeight = maximumY - minimumY + sampleStride
    let expectedPixelWidth = expectedSurfaceSize.width * pixelsPerPoint
    let expectedPixelHeight = expectedSurfaceSize.height * pixelsPerPoint
    guard CGFloat(observedWidth) >= expectedPixelWidth * 0.60,
          CGFloat(observedHeight) >= expectedPixelHeight * 0.60,
          CGFloat(observedWidth) <= expectedPixelWidth * 1.25 else {
        throw VisualQARenderingError.implausibleSurfaceBounds(
            filename,
            width: observedWidth,
            height: observedHeight
        )
    }

    let interiorInset = max(Int((pixelsPerPoint * 4).rounded(.up)), sampleStride)
    guard maximumX - minimumX > interiorInset * 2,
          maximumY - minimumY > interiorInset * 2 else {
        throw VisualQARenderingError.missingSurfaceInterior(filename)
    }
    var visibleContentCount = 0
    for y in stride(
        from: minimumY + interiorInset,
        through: maximumY - interiorInset,
        by: sampleStride
    ) {
        for x in stride(
            from: minimumX + interiorInset,
            through: maximumX - interiorInset,
            by: sampleStride
        ) {
            guard let sample = deviceRGBSample(representation, x: x, y: y) else {
                continue
            }
            if sample.luminance > 0.35,
               sample.maximumComponentDelta(from: backdrop) > backdropDelta {
                visibleContentCount += 1
            }
        }
    }
    let minimumVisibleContentCount = max(
        Int(Double(expectedChangedCount) * 0.0005),
        20
    )
    guard visibleContentCount >= minimumVisibleContentCount else {
        throw VisualQARenderingError.missingVisibleContent(
            filename,
            observed: visibleContentCount,
            minimum: minimumVisibleContentCount
        )
    }

    if filename.hasPrefix("erylo-timer-launcher") {
        let glyphXRange = filename == "erylo-timer-launcher.png"
            ? 270..<310
            : 285..<325
        var amberPixelCount = 0
        for y in 0..<representation.pixelsHigh {
            for x in glyphXRange where x < representation.pixelsWide {
                guard let sample = deviceRGBSample(representation, x: x, y: y) else {
                    continue
                }
                if sample.red >= 0.55,
                   sample.green >= 0.32,
                   sample.blue <= 0.45,
                   sample.red - sample.green >= 0.12,
                   sample.green - sample.blue >= 0.08 {
                    amberPixelCount += 1
                }
            }
        }
        guard amberPixelCount >= 12 else {
            throw VisualQARenderingError.missingSemanticAccent(
                filename,
                observed: amberPixelCount,
                minimum: 12
            )
        }
    }
}

@MainActor
private func deviceRGBSample(
    _ representation: NSBitmapImageRep,
    x: Int,
    y: Int
) -> DeviceRGBSample? {
    guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
        return nil
    }
    return DeviceRGBSample(
        red: color.redComponent,
        green: color.greenComponent,
        blue: color.blueComponent
    )
}

private struct DeviceRGBSample {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    var luminance: CGFloat {
        red * 0.2126 + green * 0.7152 + blue * 0.0722
    }

    func maximumComponentDelta(from other: DeviceRGBSample) -> CGFloat {
        max(
            max(abs(red - other.red), abs(green - other.green)),
            abs(blue - other.blue)
        )
    }
}

private struct NativeVisualQAFixture {
    let filename: String
    let scenario: @MainActor () -> ActivitySurfacePreviewScenario
    let geometry: DisplayGeometry
    let desktop: NativeVisualQADesktop
}

private enum NativeVisualQADesktop: CaseIterable, Hashable {
    case light
    case dark

    var backdrop: Color {
        switch self {
        case .light:
            Color(red: 0.87, green: 0.89, blue: 0.92)
        case .dark:
            Color(red: 0.035, green: 0.047, blue: 0.067)
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
}

private enum VisualQARenderingError: Error {
    case encodingFailed(String)
    case incompleteDesktopContexts
    case unreadablePixels(String)
    case implausibleSurfaceCoverage(String, changed: Int, expected: Int)
    case implausibleSurfaceBounds(String, width: Int, height: Int)
    case missingSurfaceInterior(String)
    case missingVisibleContent(String, observed: Int, minimum: Int)
    case missingSemanticAccent(String, observed: Int, minimum: Int)
}
