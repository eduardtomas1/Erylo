import Darwin
import EryloActivity
import EryloGlance
import Foundation

@main
enum GlanceHarnessMain {
    static func main() async {
        var harness = GlanceHarness()
        await harness.verifyConversionAndValidation()
        await harness.verifyConditionalBrokerConformance()
        await harness.verifyLegacyBrokerRuntimeCompatibility()
        await harness.verifyDisabledStateAndLifecycleIdempotence()
        await harness.verifyConcurrentLifecycleRaces()
        await harness.verifyActivationRelayHandoffOrdering()
        await harness.verifyQuietPresentationPolicies()
        await harness.verifyPowerDedupeAndStaleGenerations()
        await harness.verifyVolumeDeviceChangesAndFloodDisable()
        await harness.verifyCalendarChangesAndBoundaries()
        await harness.verifyCalendarSystemConvergence()
        await harness.verifyCalendarBrokerMutationOrdering()
        await harness.verifyCalendarNoPresentationSupersedesSubmit()
        await harness.verifyCalendarEventCoalescing()
        await harness.verifyCalendarPermissionSeams()
        await harness.verifyCalendarUnavailableTakeover()
        await harness.verifyCountdownCancellationReplacementAndExpiry()
        await harness.verifyCountdownNaturalCompletionBarrier()
        await harness.verifyVisibleCountdownDemand()
        await harness.verifyCountdownDemandMutationOrdering()
        await harness.verifyBoundaryAndMutationDraining()
        await harness.verifyNonCooperativeTimerGenerationBackstop()
        await harness.verifyCancellationInsensitiveShutdown()
        await harness.verifyReleaseCleanupFallbacks()
        await harness.verifyReplacementOwnershipLeases()
        await harness.verifyCrossInstanceClaimAdmission()
        await harness.verifyCrossInstanceSubmitAdmission()
        await harness.verifyUnleasedReplacementFencing()
        await harness.verifyDisableDeinitOverlap()
        await harness.verifyLifecycleStress()
        await harness.verifyNormalizedFailureHealth()
        harness.finish()
    }
}

private struct GlanceHarness {
    private var checkCount = 0
    private var failures: [String] = []

    mutating func verifyConversionAndValidation() async {
        do {
            _ = try PowerSnapshot(chargeLevel: -0.01, isCharging: false, isConnectedToPower: false)
            check(false, "negative battery level is rejected")
        } catch {
            check(error == .invalidChargeLevel, "negative battery level returns a typed error")
        }
        do {
            _ = try VolumeSnapshot(deviceID: 1, scalar: .nan, isMuted: false)
            check(false, "non-finite volume is rejected")
        } catch {
            check(error == .invalidVolume, "non-finite volume returns a typed error")
        }

        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        do {
            _ = try CountdownTimer(title: "Invalid", startedAt: start, endsAt: start)
            check(false, "empty timer range is rejected")
        } catch {
            check(error == .invalidDateRange, "timer range returns a typed error")
        }
        do {
            _ = try CountdownTimer(
                title: "Extreme",
                startedAt: .distantPast,
                endsAt: .distantFuture
            )
            check(false, "extreme countdown duration is rejected")
        } catch {
            check(error == .countdownDurationOutOfRange, "extreme countdown duration returns a typed error")
        }
        do {
            _ = try CalendarMeeting(
                eventIdentifier: "extreme",
                title: "Extreme",
                startDate: .distantPast,
                endDate: .distantFuture
            )
            check(false, "extreme meeting duration is rejected")
        } catch {
            check(error == .meetingDurationOutOfRange, "extreme meeting duration returns a typed error")
        }
        do {
            _ = try CalendarLookAhead(seconds: .nan)
            check(false, "non-finite calendar look-ahead is rejected")
        } catch {
            check(error == .invalidCalendarLookAhead, "calendar look-ahead returns a typed error")
        }
        do {
            let capped = try CalendarLookAhead(seconds: CalendarLookAhead.maximumSeconds * 2)
            check(capped.seconds == CalendarLookAhead.maximumSeconds, "calendar look-ahead is capped to a reasonable horizon")
        } catch {
            recordUnexpected(error, context: "calendar look-ahead cap")
        }
        do {
            _ = try CalendarPresentationWindow(leadTime: -1)
            check(false, "negative calendar lead time is rejected")
        } catch {
            check(error == .invalidLeadTime, "calendar lead time returns a dedicated typed error")
        }
        do {
            _ = try BatteryPresentationPolicy(
                lowBatteryThreshold: .nan,
                transientMilliseconds: 1_800
            )
            check(false, "non-finite battery policy threshold is rejected")
        } catch {
            check(
                error == .invalidLowBatteryThreshold,
                "battery threshold returns a dedicated typed error"
            )
        }
        do {
            _ = try BatteryPresentationPolicy(
                lowBatteryThreshold: 0.2,
                transientMilliseconds: 0
            )
            check(false, "non-positive battery transient duration is rejected")
        } catch {
            check(
                error == .invalidTransientDuration,
                "battery transient duration returns a dedicated typed error"
            )
        }

        do {
            let rawTitle = "\n  " + String(repeating: "é", count: 200) + "\t"
            let meeting = try CalendarMeeting(
                eventIdentifier: String(repeating: "event", count: 200),
                title: rawTitle,
                startDate: start.addingTimeInterval(60),
                endDate: start.addingTimeInterval(120)
            )
            check(meeting.eventIdentifier.utf8.count <= 512, "calendar identifiers are byte bounded")
            check(meeting.title.utf8.count <= ActivityLimits.titleBytes, "calendar titles are byte bounded")
            check(
                !meeting.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                "calendar titles normalize control characters"
            )

            let broker = makeBroker()
            let meetingSnapshot = try await broker.submit(GlanceRequestFactory.meeting(meeting, now: start))
            check(meetingSnapshot.current?.activity.kind == .meeting, "meeting conversion passes broker validation")
            check(meetingSnapshot.current?.activity.action?.intent == .openSource, "meeting action stays declarative")

            let timer = try CountdownTimer(
                title: "Focus",
                startedAt: start,
                endsAt: start.addingTimeInterval(100)
            )
            let initial = timer.presentation(at: start)
            let midpoint = timer.presentation(at: start.addingTimeInterval(50))
            let expired = timer.presentation(at: timer.endsAt)
            check(initial.fractionCompleted == 0, "temporal timer state begins at zero")
            check(midpoint.fractionCompleted == 0.5, "temporal timer state derives midpoint progress")
            check(expired.fractionCompleted == 1 && expired.isExpired, "temporal timer state derives expiry")
            check(initial.startedAt == timer.startedAt && initial.endsAt == timer.endsAt, "surface timer state exposes timestamps")
            let distantPresentation = timer.presentation(at: .distantPast)
            check(distantPresentation.fractionCompleted == 0, "distant display date clamps timer progress safely")
            check(!distantPresentation.detail.isEmpty, "distant display date produces bounded timer detail")
            let timerSnapshot = try await broker.submit(
                GlanceRequestFactory.countdown(timer, now: start.addingTimeInterval(25))
            )
            check(timerSnapshot.current?.activity.presentation.progress?.fractionCompleted == 0.25, "timestamp progress passes broker validation")

            let power = try PowerSnapshot(chargeLevel: 0.42, isCharging: true, isConnectedToPower: true)
            let powerSnapshot = try await broker.submit(GlanceRequestFactory.power(power))
            check(
                powerSnapshot.ordered.first(where: { $0.activity.identity.source == .battery })?.activity.kind == .charging,
                "power conversion selects the charging schema"
            )

            let volume = try VolumeSnapshot(deviceID: 7, scalar: 0.5, isMuted: true)
            let volumeSnapshot = try await broker.submit(GlanceRequestFactory.volume(volume))
            check(volumeSnapshot.current?.activity.presentation.detail == "Muted", "volume conversion normalizes mute presentation")
        } catch {
            recordUnexpected(error, context: "conversion and validation")
        }

        do {
            try await SystemGlanceClock().sleep(until: .distantFuture)
            check(false, "system clock rejects an unsafe distant boundary")
        } catch {
            check(error as? GlanceClockError == .deadlineOutOfRange, "system clock bounds one-shot conversion safely")
        }
    }

    mutating func verifyActivationRelayHandoffOrdering() async {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Int.self,
            bufferingPolicy: .unbounded
        )
        let handoffGate = RelayPendingDeliveryGate()
        let relay = GlanceActivationEventRelay(
            continuation: continuation,
            beforePendingDelivery: { handoffGate.pause() }
        )

        relay.yield(0)
        check(
            relay.beginActivationSettlement() == 0,
            "activation relay extracts its synchronous baseline"
        )
        relay.yield(1)

        let completion = Task.detached {
            relay.completeActivation()
        }
        check(
            handoffGate.waitUntilPaused(),
            "activation relay reaches its pending-delivery handoff gate"
        )

        let laterStarted = ThreadSafeFlag()
        let laterFinished = ThreadSafeFlag()
        Thread.detachNewThread {
            laterStarted.set()
            relay.yield(2)
            laterFinished.set()
        }
        check(
            await waitUntil { laterStarted.value },
            "later serial source callback reaches the relay handoff"
        )
        try? await Task.sleep(for: .milliseconds(20))
        check(
            !laterFinished.value,
            "later callback cannot overtake pending delivery before live admission"
        )

        handoffGate.release()
        await completion.value
        check(
            await waitUntil { laterFinished.value },
            "later callback completes after pending delivery opens live admission"
        )
        relay.finish()

        var delivered: [Int] = []
        for await event in stream {
            delivered.append(event)
        }
        check(
            delivered == [1, 2],
            "pending callback A is delivered before newer live callback B"
        )

        let (newestStream, newestContinuation) = AsyncStream.makeStream(
            of: Int.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let newestHandoffGate = RelayPendingDeliveryGate()
        let newestRelay = GlanceActivationEventRelay(
            continuation: newestContinuation,
            beforePendingDelivery: { newestHandoffGate.pause() }
        )
        newestRelay.yield(0)
        check(
            newestRelay.beginActivationSettlement() == 0,
            "newest-only relay extracts its synchronous baseline"
        )
        newestRelay.yield(1)

        let newestCompletion = Task.detached {
            newestRelay.completeActivation()
        }
        check(
            newestHandoffGate.waitUntilPaused(),
            "newest-only relay gates pending recovery A before live admission"
        )
        let newestLaterStarted = ThreadSafeFlag()
        let newestLaterFinished = ThreadSafeFlag()
        Thread.detachNewThread {
            newestLaterStarted.set()
            newestRelay.yield(2)
            newestLaterFinished.set()
        }
        check(
            await waitUntil { newestLaterStarted.value },
            "newer recovery B reaches the production-faithful relay handoff"
        )
        try? await Task.sleep(for: .milliseconds(20))
        check(
            !newestLaterFinished.value,
            "newer recovery B waits until pending A is ordered"
        )

        newestHandoffGate.release()
        await newestCompletion.value
        check(
            await waitUntil { newestLaterFinished.value },
            "newer recovery B enters after the ordered handoff"
        )
        newestRelay.finish()

        var newestDelivered: [Int] = []
        for await event in newestStream {
            newestDelivered.append(event)
        }
        check(
            newestDelivered == [2],
            "delayed newest-only consumption retains recovery B and never stale A"
        )
    }

    mutating func verifyConditionalBrokerConformance() async {
        let scheduler = ManualBrokerScheduler()
        let concreteBroker = ActivityBroker(expirationScheduler: scheduler)
        let broker: any GlanceRevisionActivityBroker = concreteBroker
        let ownershipBroker: any GlanceOwnershipActivityBroker = concreteBroker
        do {
            let identity = ActivityIdentity(
                source: .calendar,
                identifier: try ActivityIdentifier(validating: "conditional-witness")
            )
            let oldSnapshot = try await broker.submit(
                ActivityRequest(
                    identifier: identity.identifier.rawValue,
                    source: identity.source.rawValue,
                    kind: ActivityKind.meeting.rawValue,
                    priority: 60,
                    title: "Old witness activity",
                    ttlMilliseconds: 1_000
                )
            )
            guard let oldRevision = oldSnapshot.current?.revision else {
                check(false, "conditional broker witness returns the old revision")
                return
            }
            check(
                await waitUntil { await scheduler.totalSleepCount == 1 },
                "conditional broker witness schedules the old expiry"
            )
            let replacementSnapshot = try await broker.submit(
                ActivityRequest(
                    identifier: identity.identifier.rawValue,
                    source: identity.source.rawValue,
                    kind: ActivityKind.meeting.rawValue,
                    priority: 60,
                    title: "Replacement witness activity",
                    ttlMilliseconds: 2_000
                )
            )
            guard let replacementRevision = replacementSnapshot.current?.revision else {
                check(false, "conditional broker witness returns the replacement revision")
                return
            }
            check(
                await waitUntil {
                    let sleepCount = await scheduler.totalSleepCount
                    let pendingCount = await scheduler.pendingCount
                    return sleepCount == 2 && pendingCount == 1
                },
                "conditional broker witness replaces the expiry one-shot"
            )

            check(
                !(await broker.cancel(identity, ifRevision: oldRevision)),
                "existential conditional cancel rejects a superseded revision"
            )
            check(
                await concreteBroker.snapshot().current?.activity.presentation.title
                    == "Replacement witness activity",
                "existential conditional cancel preserves the replacement"
            )
            check(
                await concreteBroker.snapshot().version == replacementSnapshot.version,
                "rejected conditional cancel publishes no mutation"
            )
            check(
                await waitUntil {
                    await concreteBroker.workState().scheduledExpiryCount == 1
                },
                "rejected conditional cancel preserves only replacement expiry work after predecessor settlement"
            )
            check(
                await broker.cancel(identity, ifRevision: replacementRevision),
                "existential conditional cancel removes the exact owned revision"
            )
            check(
                await concreteBroker.snapshot().ordered.isEmpty,
                "existential conditional cancel publishes the exact removal"
            )
            check(
                await concreteBroker.snapshot().version == replacementSnapshot.version + 1,
                "exact conditional removal publishes one mutation"
            )
            check(
                await waitUntil {
                    let workState = await concreteBroker.workState()
                    let pendingCount = await scheduler.pendingCount
                    return workState.scheduledExpiryCount == 0 && pendingCount == 0
                },
                "exact conditional removal cancels and releases expiry work"
            )

            let ownedIdentity = ActivityIdentity(
                source: .calendar,
                identifier: try ActivityIdentifier(validating: "ownership-witness")
            )
            let ownedRequest = ActivityRequest(
                identifier: ownedIdentity.identifier.rawValue,
                source: ownedIdentity.source.rawValue,
                kind: ActivityKind.meeting.rawValue,
                priority: 60,
                title: "Old owned witness"
            )
            guard let oldIntent = ownershipBroker.ownershipCoordinator.prepareClaim(
                for: ownedIdentity
            ), let oldLease = await ownershipBroker.claimOwnership(
                of: ownedIdentity,
                admitting: oldIntent
            ) else {
                check(false, "existential broker claims the first ownership generation")
                return
            }
            check(
                try await ownershipBroker.submit(ownedRequest, ifOwnedBy: oldLease) != nil,
                "existential owned submit admits its current generation"
            )
            guard let successorIntent = ownershipBroker.ownershipCoordinator.prepareClaim(
                for: ownedIdentity
            ), let successorLease = await ownershipBroker.claimOwnership(
                of: ownedIdentity,
                admitting: successorIntent
            ) else {
                check(false, "existential broker claims the successor ownership generation")
                return
            }
            check(
                await concreteBroker.snapshot().ordered.isEmpty,
                "successor claim atomically retires the predecessor presentation"
            )
            check(
                try await ownershipBroker.submit(ownedRequest, ifOwnedBy: oldLease) == nil,
                "existential owned submit rejects a superseded generation"
            )
            let successorRequest = ActivityRequest(
                identifier: ownedIdentity.identifier.rawValue,
                source: ownedIdentity.source.rawValue,
                kind: ActivityKind.meeting.rawValue,
                priority: 60,
                title: "Successor owned witness"
            )
            check(
                try await ownershipBroker.submit(
                    successorRequest,
                    ifOwnedBy: successorLease
                ) != nil,
                "existential owned submit admits the successor generation"
            )
            oldLease.beginRetirement()
            check(
                !(await ownershipBroker.cancel(ownedIdentity, ifOwnedBy: oldLease)),
                "existential old cleanup fails closed after successor publication"
            )
            check(
                !(await ownershipBroker.releaseOwnership(oldLease)),
                "existential stale release cannot prune successor admission"
            )
            check(
                await concreteBroker.snapshot().current?.activity.presentation.title
                    == "Successor owned witness",
                "existential old cleanup and release preserve the successor"
            )
            successorLease.beginRetirement()
            check(
                try await ownershipBroker.submit(
                    successorRequest,
                    ifOwnedBy: successorLease
                ) == nil,
                "synchronous retirement closes future existential submit admission"
            )
            check(
                await ownershipBroker.cancel(ownedIdentity, ifOwnedBy: successorLease),
                "retiring successor may remove its exact current generation"
            )
            check(
                await ownershipBroker.releaseOwnership(successorLease),
                "exact successor release prunes ownership admission"
            )
            check(
                await concreteBroker.workState().activeOwnershipCount == 0,
                "existential ownership lifecycle returns retained state to zero"
            )

        } catch {
            recordUnexpected(error, context: "conditional broker conformance witness")
        }
    }

    mutating func verifyLegacyBrokerRuntimeCompatibility() async {
        let now = Date(timeIntervalSinceReferenceDate: 19_500)

        do {
            let broker = LegacyGlanceBroker()
            let source = ManualCalendarSource(authorization: .fullAccess)
            let clock = ManualGlanceClock(now: now)
            let meeting = try CalendarMeeting(
                eventIdentifier: "legacy-calendar",
                title: "Legacy calendar conformer",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(180)
            )
            await source.setMeeting(meeting)
            let provider = CalendarGlanceProvider(
                broker: broker,
                source: source,
                clock: clock
            )
            await provider.enable()
            check(
                await provider.status().health == .healthy,
                "pre-change calendar broker conformance enables without degradation"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "Legacy calendar conformer",
                "pre-change calendar broker conformance submits at runtime"
            )
            check(await broker.submitCallCount == 1, "legacy calendar submits exactly once")
            await provider.disable()
            check(await broker.cancelCallCount == 1, "legacy calendar disable cancels at runtime")
            check(await broker.snapshot().ordered.isEmpty, "legacy calendar disable clears activity")
            check(await provider.workState().isIdle, "legacy calendar disable drains provider work")
        } catch {
            recordUnexpected(error, context: "legacy calendar broker runtime compatibility")
        }

        do {
            let broker = LegacyGlanceBroker()
            let clock = ManualGlanceClock(now: now)
            let timer = try CountdownTimer(
                title: "Legacy countdown conformer",
                startedAt: now,
                endsAt: now.addingTimeInterval(120)
            )
            let provider = CountdownGlanceProvider(broker: broker, clock: clock)
            await provider.setCountdown(timer)
            await provider.enable()
            check(
                await provider.status().health == .healthy,
                "pre-change countdown broker conformance enables without degradation"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "Legacy countdown conformer",
                "pre-change countdown broker conformance submits at runtime"
            )
            check(await broker.submitCallCount == 1, "legacy countdown submits exactly once")
            await provider.disable()
            check(await broker.cancelCallCount == 1, "legacy countdown disable cancels at runtime")
            check(await broker.snapshot().ordered.isEmpty, "legacy countdown disable clears activity")
            check(await provider.workState().isIdle, "legacy countdown disable drains provider work")
        } catch {
            recordUnexpected(error, context: "legacy countdown broker runtime compatibility")
        }
    }

    mutating func verifyDisabledStateAndLifecycleIdempotence() async {
        let broker = makeBroker()
        let powerSource = ManualPowerSource()
        let volumeSource = ManualVolumeSource()
        let calendarSource = ManualCalendarSource(authorization: .notDetermined)
        let clock = ManualGlanceClock(now: Date(timeIntervalSinceReferenceDate: 20_000))
        let glance = EryloGlance(
            broker: broker,
            powerSource: powerSource,
            volumeSource: volumeSource,
            calendarSource: calendarSource,
            clock: clock
        )

        do {
            let timer = try CountdownTimer(
                title: "Stored while disabled",
                startedAt: Date(timeIntervalSinceReferenceDate: 20_000),
                endsAt: Date(timeIntervalSinceReferenceDate: 20_060)
            )
            await glance.countdown.setCountdown(timer)
        } catch {
            recordUnexpected(error, context: "disabled timer setup")
        }

        check(await powerSource.startCount == 0, "disabled power provider installs no observer")
        check(await volumeSource.startCount == 0, "disabled volume provider installs no observer")
        check(await calendarSource.startCount == 0, "disabled calendar provider installs no observer")
        check(await calendarSource.permissionRequestCount == 0, "disabled calendar provider requests no permission")
        check(await clock.pendingCount == 0, "disabled timer schedules no boundary")
        check(await glance.power.workState().isIdle, "disabled power work state is idle")
        check(await glance.volume.workState().isIdle, "disabled volume work state is idle")
        check(await glance.calendar.workState().isIdle, "disabled calendar work state is idle")
        check(await glance.countdown.workState().isIdle, "disabled countdown work state is idle")
        check(await broker.snapshot().ordered.isEmpty, "disabled glance layer submits nothing")

        await glance.power.enable()
        await glance.power.enable()
        check(await powerSource.startCount == 1, "power enable is idempotent")
        let enabledWork = await glance.power.workState()
        check(enabledWork.activeObserverCount == 1, "enabled power owns one observer")
        check(enabledWork.activeConsumerTaskCount == 1, "enabled power owns one bounded consumer")
        await glance.power.disable()
        await glance.power.disable()
        check(await powerSource.stopCount == 1, "power disable is idempotent")
        check(await glance.power.status() == .disabled, "power disable returns explicit disabled health")
        check(await glance.power.workState().isIdle, "power disable releases all work")

        await glance.power.enable()
        await glance.volume.enable()
        await glance.calendar.enable()
        await glance.countdown.enable()
        await glance.disableAll()
        check(await glance.power.workState().isIdle, "aggregate shutdown drains power work")
        check(await glance.volume.workState().isIdle, "aggregate shutdown drains volume work")
        check(await glance.calendar.workState().isIdle, "aggregate shutdown drains calendar work")
        check(await glance.countdown.workState().isIdle, "aggregate shutdown drains countdown work")
        check(await calendarSource.permissionRequestCount == 0, "aggregate restore-style enable never requests calendar access")
        check(await broker.snapshot().ordered.isEmpty, "aggregate shutdown cancels all broker activities")
    }

    mutating func verifyConcurrentLifecycleRaces() async {
        let powerBroker = makeBroker()
        let powerSource = DeferredPowerSource()
        let power = PowerGlanceProvider(broker: powerBroker, source: powerSource)
        let powerEnable = Task { await power.enable() }
        check(await waitUntil { await powerSource.startPending }, "power deferred start begins")
        let powerSecondEnableFlag = CompletionFlag()
        let powerSecondEnable = Task {
            await power.enable()
            await powerSecondEnableFlag.markComplete()
        }
        await yieldSeveralTimes()
        check(!(await powerSecondEnableFlag.isComplete), "concurrent power enable awaits the same startup")
        await powerSource.finishStart()
        await powerEnable.value
        await powerSecondEnable.value
        check(await powerSource.startCount == 1, "concurrent power enables share one source start")

        let powerDisableFlag = CompletionFlag()
        let powerDisable = Task {
            await power.disable()
            await powerDisableFlag.markComplete()
        }
        check(await waitUntil { await powerSource.stopPending }, "power deferred stop begins")
        let powerSecondDisableFlag = CompletionFlag()
        let powerSecondDisable = Task {
            await power.disable()
            await powerSecondDisableFlag.markComplete()
        }
        await yieldSeveralTimes()
        check(!(await powerDisableFlag.isComplete), "power disable waits for in-flight start cleanup")
        check(!(await powerSecondDisableFlag.isComplete), "concurrent power disable awaits the same cleanup")
        await powerSource.finishStop()
        await powerDisable.value
        await powerSecondDisable.value
        check(await powerSource.stopCount == 1, "concurrent power disables share one source stop")
        check(!(await powerSource.isActive), "power race leaves no observer when disable returns")
        check(await power.workState().isIdle, "power race leaves no task when disable returns")
        await powerSource.emitStale(.unavailable)
        await yieldSeveralTimes()
        check(await powerBroker.snapshot().ordered.isEmpty, "power stale callback after stop is inert")

        let volumeBroker = makeBroker()
        let volumeSource = DeferredVolumeSource()
        let volume = VolumeGlanceProvider(broker: volumeBroker, source: volumeSource)
        let volumeEnable = Task { await volume.enable() }
        check(await waitUntil { await volumeSource.startPending }, "volume deferred start begins")
        let volumeDisableFlag = CompletionFlag()
        let volumeDisable = Task {
            await volume.disable()
            await volumeDisableFlag.markComplete()
        }
        await yieldSeveralTimes()
        check(!(await volumeDisableFlag.isComplete), "volume disable waits for in-flight start cleanup")
        await volumeSource.finishStart()
        check(await waitUntil { await volumeSource.stopPending }, "volume late start enters serialized stop")
        check(!(await volumeDisableFlag.isComplete), "volume disable remains pending through source stop")
        await volumeSource.finishStop()
        await volumeEnable.value
        await volumeDisable.value
        check(!(await volumeSource.isActive), "volume race leaves no observer when disable returns")
        check(await volume.workState().isIdle, "volume race leaves no task when disable returns")
        await volumeSource.emitStale(.unavailable)
        await yieldSeveralTimes()
        check(await volumeBroker.snapshot().ordered.isEmpty, "volume stale callback after stop is inert")

        let calendarBroker = makeBroker()
        let calendarSource = DeferredCalendarSource()
        let calendar = CalendarGlanceProvider(
            broker: calendarBroker,
            source: calendarSource,
            clock: ManualGlanceClock()
        )
        let calendarEnable = Task { await calendar.enable() }
        check(await waitUntil { await calendarSource.startPending }, "calendar deferred start begins")
        let calendarDisableFlag = CompletionFlag()
        let calendarDisable = Task {
            await calendar.disable()
            await calendarDisableFlag.markComplete()
        }
        await yieldSeveralTimes()
        check(!(await calendarDisableFlag.isComplete), "calendar disable waits for in-flight start cleanup")
        await calendarSource.finishStart()
        check(await waitUntil { await calendarSource.stopPending }, "calendar late start enters serialized stop")
        check(!(await calendarDisableFlag.isComplete), "calendar disable remains pending through source stop")
        await calendarSource.finishStop()
        await calendarEnable.value
        await calendarDisable.value
        check(!(await calendarSource.isActive), "calendar race leaves no observer when disable returns")
        check(await calendar.workState().isIdle, "calendar race leaves no task when disable returns")
        await calendarSource.emitStale()
        await yieldSeveralTimes()
        check(await calendarBroker.snapshot().ordered.isEmpty, "calendar stale callback after stop is inert")
    }

    mutating func verifyQuietPresentationPolicies() async {
        let scheduler = ManualBrokerScheduler()
        let batteryBroker = ActivityBroker(expirationScheduler: scheduler)
        let batterySource = ManualPowerSource()
        let battery = PowerGlanceProvider(broker: batteryBroker, source: batterySource)
        do {
            let resting = try PowerSnapshot(
                chargeLevel: 0.72,
                isCharging: false,
                isConnectedToPower: false
            )
            let changed = try PowerSnapshot(
                chargeLevel: 0.71,
                isCharging: false,
                isConnectedToPower: false
            )
            let low = try PowerSnapshot(
                chargeLevel: 0.18,
                isCharging: false,
                isConnectedToPower: false
            )

            await battery.enable()
            await batterySource.emit(.snapshot(resting))
            check(
                await waitUntil {
                    await battery.latestProcessedSnapshot() == resting
                },
                "ordinary initial battery snapshot is consumed as the quiet baseline"
            )
            check(await batteryBroker.snapshot().ordered.isEmpty, "ordinary initial battery snapshot stays hidden at rest")
            check(await scheduler.totalSleepCount == 0, "resting battery starts no broker expiry work")

            await batterySource.emit(.snapshot(changed))
            check(
                await waitUntil { !(await batteryBroker.snapshot().ordered.isEmpty) },
                "battery changes receive a transient presentation"
            )
            if case .expires = await batteryBroker.snapshot().current?.activity.lifecycle {
                check(true, "ordinary battery change is explicitly transient")
            } else {
                check(false, "ordinary battery change is explicitly transient")
            }

            await batterySource.emit(.snapshot(low))
            check(
                await waitUntil {
                    await batteryBroker.snapshot().current?.activity.presentation.detail == "18%"
                },
                "actionable low battery replaces the transient presentation"
            )
            if case .untilCancelled = await batteryBroker.snapshot().current?.activity.lifecycle {
                check(true, "actionable low battery is explicitly ambient")
            } else {
                check(false, "actionable low battery is explicitly ambient")
            }
            check(await batteryBroker.workState().scheduledExpiryCount == 0, "ambient low battery owns no repeating or expiry task")
            await battery.disable()
        } catch {
            recordUnexpected(error, context: "quiet battery presentation policy")
        }

        let now = Date(timeIntervalSinceReferenceDate: 25_000)
        let calendarClock = ManualGlanceClock(now: now)
        let calendarSource = ManualCalendarSource(authorization: .fullAccess)
        let calendarBroker = makeBroker()
        let calendar = CalendarGlanceProvider(
            broker: calendarBroker,
            source: calendarSource,
            clock: calendarClock
        )
        do {
            let distant = try CalendarMeeting(
                eventIdentifier: "distant",
                title: "Later review",
                startDate: now.addingTimeInterval(3_600),
                endDate: now.addingTimeInterval(4_200)
            )
            await calendarSource.setMeeting(distant)
            await calendar.enable()
            check(await calendarBroker.snapshot().ordered.isEmpty, "distant meeting creates no broker activity")
            check(
                await waitUntil {
                    await calendarClock.pendingDeadlines == [distant.startDate.addingTimeInterval(-600)]
                },
                "distant meeting schedules the documented ten-minute lead boundary"
            )
            let queryCount = await calendarSource.queryCount
            await yieldSeveralTimes()
            check(await calendarSource.queryCount == queryCount, "calendar performs no idle polling")

            let leadStart = distant.startDate.addingTimeInterval(-600)
            await calendarClock.advance(to: leadStart.addingTimeInterval(-0.001))
            await yieldSeveralTimes()
            check(await calendarBroker.snapshot().ordered.isEmpty, "meeting stays hidden immediately before lead time")
            await calendarClock.advance(to: leadStart)
            check(
                await waitUntil {
                    await calendarBroker.snapshot().current?.activity.presentation.title == "Later review"
                },
                "meeting becomes visible exactly at the lead-time boundary"
            )
            check(
                await waitUntil { await calendarClock.pendingDeadlines == [distant.startDate] },
                "lead-time presentation schedules only the meeting-start boundary"
            )
            await calendar.disable()
        } catch {
            recordUnexpected(error, context: "quiet calendar presentation policy")
        }
    }

    mutating func verifyPowerDedupeAndStaleGenerations() async {
        let scheduler = ManualBrokerScheduler()
        let broker = ActivityBroker(expirationScheduler: scheduler)
        let source = ManualPowerSource()
        let provider = PowerGlanceProvider(broker: broker, source: source)
        do {
            let first = try PowerSnapshot(chargeLevel: 0.4, isCharging: false, isConnectedToPower: false)
            let changed = try PowerSnapshot(chargeLevel: 0.5, isCharging: false, isConnectedToPower: false)
            let actionable = try PowerSnapshot(chargeLevel: 0.1, isCharging: false, isConnectedToPower: false)
            await provider.enable()
            await source.emit(.snapshot(first))
            await yieldSeveralTimes()
            check(await broker.snapshot().ordered.isEmpty, "initial ordinary power event establishes a quiet baseline")
            let firstSnapshot = await broker.snapshot()

            await source.emit(.snapshot(first))
            await yieldSeveralTimes()
            check(await broker.snapshot().version == firstSnapshot.version, "duplicate power event is deduplicated")

            await source.emit(.snapshot(changed))
            check(await waitUntil { await broker.snapshot().version == firstSnapshot.version + 1 }, "changed power event replaces broker activity")

            await provider.disable()
            check(await broker.snapshot().ordered.isEmpty, "power disable cancels broker activity")
            await provider.enable()
            check(await source.handlerCount == 2, "re-enable creates a fresh callback generation")

            await source.emit(.snapshot(first), handlerIndex: 0)
            await yieldSeveralTimes()
            check(await broker.snapshot().ordered.isEmpty, "stale power callback cannot submit after re-enable")

            await source.emit(.snapshot(actionable), handlerIndex: 1)
            check(await waitUntil { !(await broker.snapshot().ordered.isEmpty) }, "current power callback can submit")

            await source.emit(.unavailable, handlerIndex: 1)
            check(
                await waitUntil { await broker.snapshot().ordered.isEmpty },
                "sleep/wake-style Battery unavailability clears stale ambient state"
            )
            check(
                await provider.status().health == .unavailable(.eventSourceUnavailable),
                "Battery unavailability remains observable while the source can recover"
            )
            await source.emit(.snapshot(first), handlerIndex: 1)
            check(
                await waitUntil { !(await broker.snapshot().ordered.isEmpty) },
                "post-wake Battery delivery converges through the current source generation"
            )
            if case let .expires(ttl) = await broker.snapshot().current?.activity.lifecycle {
                check(ttl.rawValue == 1_800, "post-wake Battery acknowledgement remains bounded")
            } else {
                check(false, "post-wake Battery acknowledgement remains bounded")
            }
            check(await scheduler.pendingCount == 1, "post-wake Battery convergence owns one cancellable expiry")
            await provider.disable()
            check(await scheduler.pendingCount == 0, "Battery disable drains the post-wake expiry")
            check(await broker.workState().activeOwnershipCount == 0, "Battery lifecycle retains no broker ownership")
        } catch {
            recordUnexpected(error, context: "power event lifecycle")
        }
    }

    mutating func verifyVolumeDeviceChangesAndFloodDisable() async {
        let scheduler = ManualBrokerScheduler()
        let broker = ActivityBroker(expirationScheduler: scheduler)
        do {
            let builtIn = try VolumeSnapshot(deviceID: 1, scalar: 0.35, isMuted: false)
            let builtInChanged = try VolumeSnapshot(deviceID: 1, scalar: 0.45, isMuted: false)
            let external = try VolumeSnapshot(deviceID: 2, scalar: 0.45, isMuted: false)
            let muted = try VolumeSnapshot(deviceID: 2, scalar: 0.45, isMuted: true)
            let source = ManualVolumeSource(initialEvent: .snapshot(builtIn))
            let provider = VolumeGlanceProvider(broker: broker, source: source)
            await provider.enable()
            check(await broker.snapshot().ordered.isEmpty, "synchronous initial Volume snapshot establishes a quiet baseline")
            check(await broker.snapshot().version == 0, "quiet Volume activation performs no broker mutation")
            check(await scheduler.pendingCount == 0, "quiet Volume activation schedules no expiry work")

            await source.emit(.snapshot(builtInChanged))
            check(await waitUntil { await broker.snapshot().version == 1 }, "volume event reaches broker")
            if case let .expires(ttl) = await broker.snapshot().current?.activity.lifecycle {
                check(ttl.rawValue == 1_800, "volume acknowledgement uses the bounded transient lifetime")
            } else {
                check(false, "volume acknowledgement uses the bounded transient lifetime")
            }
            check(await scheduler.pendingCount == 1, "volume acknowledgement owns one cancellable expiry")
            let firstRevision = await broker.snapshot().current?.revision

            await source.emit(.snapshot(builtInChanged))
            await yieldSeveralTimes()
            check(await broker.snapshot().version == 1, "duplicate volume callback is deduplicated")

            await source.emit(.snapshot(external))
            check(await waitUntil { await broker.snapshot().version == 2 }, "default-device change refreshes volume activity")
            check(await broker.snapshot().current?.revision != firstRevision, "device change creates a new broker revision")
            check(await scheduler.pendingCount == 1, "default-device switch replaces rather than accumulates expiry work")

            await source.emit(.snapshot(muted))
            check(await waitUntil { await broker.snapshot().version == 3 }, "mute change refreshes volume activity")
            check(await broker.snapshot().current?.activity.presentation.detail == "Muted", "mute callback produces honest HUD detail")
            if case let .expires(ttl) = await broker.snapshot().current?.activity.lifecycle {
                check(ttl.rawValue == 1_800, "mute acknowledgement remains bounded")
            } else {
                check(false, "mute acknowledgement remains bounded")
            }
            check(await scheduler.pendingCount == 1, "mute change retains one bounded expiry")

            await source.emit(.unavailable)
            check(
                await waitUntil { await broker.snapshot().ordered.isEmpty },
                "missing default output clears the stale Volume acknowledgement"
            )
            check(await scheduler.pendingCount == 0, "missing default output cancels Volume expiry work")
            await source.emit(.snapshot(external))
            check(
                await waitUntil { await broker.snapshot().version == 5 },
                "restored default output converges without restarting the observer"
            )
            check(await source.startCount == 1, "default-output recovery retains one event observer")
            check(await provider.status().health == .healthy, "default-output recovery restores healthy status")

            await source.emitFlood(count: 5_000)
            let floodWork = await provider.workState()
            check(floodWork.activeConsumerTaskCount == 1, "volume flood retains one bounded consumer task")
            await provider.disable()
            check(await broker.snapshot().ordered.isEmpty, "volume disable cancels broker activity after flood")
            check(await provider.workState().isIdle, "volume flood disable drains all provider work")
            check(!(await source.isActive), "volume flood disable removes source callback")
            check(await provider.status() == .disabled, "volume flood disable completes lifecycle state")
            check(await scheduler.pendingCount == 0, "volume disable drains every transient expiry")
            check(await broker.workState().activeOwnershipCount == 0, "Volume lifecycle retains no broker ownership")

            let versionBeforeReenable = await broker.snapshot().version
            await provider.enable()
            check(await source.startCount == 2, "Volume re-enable installs exactly one new observer")
            check(await broker.snapshot().ordered.isEmpty, "synchronous Volume re-enable baseline remains quiet")
            check(
                await broker.snapshot().version == versionBeforeReenable,
                "Volume re-enable baseline performs no broker mutation"
            )
            check(await scheduler.pendingCount == 0, "Volume re-enable baseline schedules no expiry")

            await source.emit(.snapshot(builtInChanged))
            check(
                await waitUntil { await broker.snapshot().version == versionBeforeReenable + 1 },
                "first true Volume change after re-enable publishes exactly once"
            )
            check(await scheduler.pendingCount == 1, "post-re-enable Volume change owns one bounded expiry")
            if case let .expires(ttl) = await broker.snapshot().current?.activity.lifecycle {
                check(ttl.rawValue == 1_800, "post-re-enable Volume HUD retains its bounded lifetime")
            } else {
                check(false, "post-re-enable Volume HUD retains its bounded lifetime")
            }
            await provider.disable()
            check(await provider.workState().isIdle, "post-re-enable Volume disable drains all work")
            check(await scheduler.pendingCount == 0, "post-re-enable Volume disable cancels its expiry")
        } catch {
            recordUnexpected(error, context: "volume device changes")
        }
    }

    mutating func verifyCalendarChangesAndBoundaries() async {
        let now = Date(timeIntervalSinceReferenceDate: 30_000)
        let clock = ManualGlanceClock(now: now)
        let source = ManualCalendarSource(authorization: .fullAccess)
        let broker = makeBroker()
        let provider = CalendarGlanceProvider(broker: broker, source: source, clock: clock)
        do {
            let first = try CalendarMeeting(
                eventIdentifier: "first",
                title: "Design review",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(120)
            )
            await source.setMeeting(first)
            await provider.enable()
            check(await broker.snapshot().current?.activity.presentation.title == "Design review", "calendar enable submits the next meeting")
            check(
                await waitUntil { await clock.pendingCount == 1 },
                "calendar schedules one start boundary"
            )
            let initialVersion = await broker.snapshot().version

            await source.emitChange()
            check(await waitUntil { await source.queryCount >= 2 }, "calendar change notification refreshes EventKit query")
            await yieldSeveralTimes()
            check(await broker.snapshot().version == initialVersion, "unchanged calendar result is deduplicated")

            let changed = try CalendarMeeting(
                eventIdentifier: "second",
                title: "Roadmap",
                startDate: now.addingTimeInterval(90),
                endDate: now.addingTimeInterval(180)
            )
            await source.setMeeting(changed)
            await source.emitChange()
            check(
                await waitUntil { await broker.snapshot().current?.activity.presentation.title == "Roadmap" },
                "calendar store change replaces the next meeting"
            )
            check(
                await waitUntil { await clock.pendingCount == 1 },
                "calendar replacement keeps one boundary"
            )

            await clock.advance(to: changed.startDate)
            check(
                await waitUntil { await broker.snapshot().current?.activity.presentation.detail == "In progress" },
                "meeting start boundary refreshes timestamp-derived state"
            )
            check(
                await waitUntil { await clock.pendingCount == 1 },
                "in-progress meeting schedules only its end boundary"
            )

            await clock.advance(to: changed.endDate)
            check(await waitUntil { await broker.snapshot().ordered.isEmpty }, "meeting end boundary cancels expired calendar activity")
            check(
                await waitUntil { await provider.workState().scheduledBoundaryCount == 0 },
                "calendar expiry leaves no timer work"
            )

            await provider.disable()
            check(await source.stopCount == 1, "calendar disable removes its observer")
            check(await provider.workState().isIdle, "calendar disable releases all work")
        } catch {
            recordUnexpected(error, context: "calendar changes")
        }
    }

    mutating func verifyCalendarSystemConvergence() async {
        let now = Date(timeIntervalSinceReferenceDate: 35_000)
        let clock = ManualGlanceClock(now: now)
        let source = ManualCalendarSource(authorization: .fullAccess)
        let broker = makeBroker()
        let provider = CalendarGlanceProvider(broker: broker, source: source, clock: clock)
        do {
            let meeting = try CalendarMeeting(
                eventIdentifier: "system-events",
                title: "Clock convergence",
                startDate: now.addingTimeInterval(3_600),
                endDate: now.addingTimeInterval(4_200)
            )
            await source.setMeeting(meeting)
            await provider.enable()
            check(await broker.snapshot().ordered.isEmpty, "system-event fixture begins outside the meeting lead window")

            await clock.setNow(meeting.startDate.addingTimeInterval(-300))
            await source.emit(.wallClockChanged)
            check(
                await waitUntil {
                    await broker.snapshot().current?.activity.presentation.title == "Clock convergence"
                },
                "wall-clock change converges a meeting that moved into lead time"
            )
            check(
                await waitUntil { await clock.pendingDeadlines == [meeting.startDate] },
                "wall-clock convergence replaces the stale lead boundary"
            )

            let wallClockVersion = await broker.snapshot().version
            await source.emit(.timeZoneChanged)
            check(
                await waitUntil { await broker.snapshot().version == wallClockVersion + 1 },
                "time-zone change refreshes visible time-derived presentation"
            )
            check(
                await waitUntil { await clock.pendingCount == 1 },
                "time-zone convergence retains one boundary"
            )

            await clock.setNow(meeting.endDate.addingTimeInterval(1))
            await source.emit(.didWake)
            check(await waitUntil { await broker.snapshot().ordered.isEmpty }, "wake after meeting end removes stale activity")
            check(
                await waitUntil { await clock.pendingCount == 0 },
                "wake after meeting end leaves no stale boundary"
            )

            await clock.setNow(now)
            await source.emit(.wallClockChanged)
            check(
                await waitUntil {
                    await clock.pendingDeadlines == [meeting.startDate.addingTimeInterval(-600)]
                },
                "backward wall-clock change restores the correct future lead boundary"
            )
            check(await broker.snapshot().ordered.isEmpty, "backward clock convergence keeps distant meeting hidden")
            await provider.disable()
        } catch {
            recordUnexpected(error, context: "calendar system convergence")
        }
    }

    mutating func verifyCalendarBrokerMutationOrdering() async {
        let now = Date(timeIntervalSinceReferenceDate: 37_000)
        let healthy = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: .healthy
        )
        let activeWork = GlanceProviderWorkState(
            activeObserverCount: 1,
            activeConsumerTaskCount: 1,
            scheduledBoundaryCount: 1,
            activeBrokerMutationCount: 0
        )

        do {
            let clock = ManualGlanceClock(now: now)
            let source = ManualCalendarSource(authorization: .fullAccess)
            let broker = GatedGlanceBroker()
            let provider = CalendarGlanceProvider(
                broker: broker,
                source: source,
                clock: clock
            )
            let oldMeeting = try CalendarMeeting(
                eventIdentifier: "old-submit",
                title: "Old submit",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(180)
            )
            let newMeeting = try CalendarMeeting(
                eventIdentifier: "new-submit",
                title: "New submit",
                startDate: now.addingTimeInterval(120),
                endDate: now.addingTimeInterval(240)
            )
            await source.setMeeting(oldMeeting)
            await broker.gateNextSubmit()
            let enable = Task { await provider.enable() }
            check(
                await waitUntil { await broker.submitPending },
                "old calendar activation reaches its gated submit"
            )

            await source.setMeeting(newMeeting)
            await source.emitChange()
            check(
                await waitUntil { await source.queryCount == 2 },
                "new calendar store refresh overlaps the old submit"
            )
            check(
                await broker.submitCallCount == 1,
                "new calendar submit remains serialized behind the old submit"
            )
            await broker.releaseSubmit()
            await enable.value
            check(
                await waitUntil {
                    await broker.snapshot().current?.activity.presentation.title == "New submit"
                },
                "new calendar submit is the final broker mutation"
            )
            check(await broker.submitCallCount == 2, "both ordered calendar submits execute exactly once")
            check(await broker.snapshot().ordered.count == 1, "ordered calendar submits retain one identity")
            check(await provider.status() == healthy, "latest submit refresh owns exact healthy status")
            check(
                await waitUntil { await clock.pendingDeadlines == [newMeeting.startDate] },
                "latest submit refresh owns the exact boundary"
            )
            check(await provider.workState() == activeWork, "latest submit refresh drains its broker mutation tail")

            let reusableMeeting = try CalendarMeeting(
                eventIdentifier: "reusable-submit",
                title: "Reusable submit",
                startDate: now.addingTimeInterval(150),
                endDate: now.addingTimeInterval(270)
            )
            await broker.gateNextSubmit()
            await source.setMeeting(reusableMeeting)
            await source.emitChange()
            check(
                await waitUntil { await broker.submitPending },
                "serialized submit capacity is reusable after the race"
            )
            await broker.releaseSubmit()
            check(
                await waitUntil {
                    await broker.snapshot().current?.activity.presentation.title == "Reusable submit"
                },
                "reused serialized submit capacity converges"
            )
            check(
                await waitUntil { await clock.pendingDeadlines == [reusableMeeting.startDate] },
                "reused submit capacity replaces the boundary exactly"
            )
            check(await provider.workState() == activeWork, "reused submit capacity fully drains")
            await provider.disable()
            check(await broker.snapshot().ordered.isEmpty, "submit race disable removes calendar activity")
            check(await provider.workState().isIdle, "submit race disable drains all work")
        } catch {
            recordUnexpected(error, context: "calendar old-submit/new-submit ordering")
        }

        do {
            let clock = ManualGlanceClock(now: now)
            let source = ManualCalendarSource(authorization: .fullAccess)
            let broker = GatedGlanceBroker()
            let provider = CalendarGlanceProvider(
                broker: broker,
                source: source,
                clock: clock
            )
            let endingMeeting = try CalendarMeeting(
                eventIdentifier: "old-cancel",
                title: "Old cancel",
                startDate: now.addingTimeInterval(-60),
                endDate: now.addingTimeInterval(60)
            )
            let newMeeting = try CalendarMeeting(
                eventIdentifier: "after-cancel",
                title: "After cancel",
                startDate: now.addingTimeInterval(120),
                endDate: now.addingTimeInterval(240)
            )
            await source.setMeeting(endingMeeting)
            await provider.enable()
            check(await broker.submitCallCount == 1, "cancel race fixture submits its active meeting once")
            await broker.gateNextCancel()
            await clock.advance(to: endingMeeting.endDate)
            check(
                await waitUntil { await broker.cancelPending },
                "old boundary refresh reaches its gated cancellation"
            )

            await source.setMeeting(newMeeting)
            await source.emitChange()
            check(
                await waitUntil { await source.queryCount == 3 },
                "new store refresh overlaps the old cancellation"
            )
            check(
                await broker.submitCallCount == 1,
                "new submit remains serialized behind the old cancellation"
            )
            await broker.releaseCancel()
            check(
                await waitUntil {
                    await broker.snapshot().current?.activity.presentation.title == "After cancel"
                },
                "new submit survives stale old-cancel completion"
            )
            check(await broker.cancelCallCount == 1, "old calendar cancellation executes exactly once")
            check(await broker.submitCallCount == 2, "post-cancel calendar submit executes exactly once")
            check(await broker.snapshot().ordered.count == 1, "cancel-submit race retains one exact broker record")
            check(await provider.status() == healthy, "post-cancel refresh owns exact healthy status")
            check(
                await waitUntil { await clock.pendingDeadlines == [newMeeting.startDate] },
                "post-cancel refresh owns the exact boundary"
            )
            check(await provider.workState() == activeWork, "cancel-submit race drains its mutation tail")

            let reusableMeeting = try CalendarMeeting(
                eventIdentifier: "reusable-after-cancel",
                title: "Reusable after cancel",
                startDate: now.addingTimeInterval(150),
                endDate: now.addingTimeInterval(270)
            )
            await broker.gateNextSubmit()
            await source.setMeeting(reusableMeeting)
            await source.emitChange()
            check(
                await waitUntil { await broker.submitPending },
                "cancel-submit serializer retains reusable capacity"
            )
            await broker.releaseSubmit()
            check(
                await waitUntil {
                    await broker.snapshot().current?.activity.presentation.title == "Reusable after cancel"
                },
                "reused cancel-submit serializer converges"
            )
            check(
                await waitUntil { await clock.pendingDeadlines == [reusableMeeting.startDate] },
                "reused cancel-submit serializer owns one exact boundary"
            )
            check(await provider.workState() == activeWork, "reused cancel-submit serializer fully drains")
            await provider.disable()
            check(await broker.snapshot().ordered.isEmpty, "cancel-submit race disable removes activity")
            check(await provider.workState().isIdle, "cancel-submit race disable drains all work")
        } catch {
            recordUnexpected(error, context: "calendar old-cancel/new-submit ordering")
        }
    }

    mutating func verifyCalendarNoPresentationSupersedesSubmit() async {
        let now = Date(timeIntervalSinceReferenceDate: 38_000)
        let healthy = GlanceProviderStatus(
            isEnabled: true,
            capability: .available,
            health: .healthy
        )

        for scenario in CalendarClearScenario.allCases {
            let clock = ManualGlanceClock(now: now)
            let source = ManualCalendarSource(authorization: .fullAccess)
            let broker = GatedGlanceBroker()
            let provider = CalendarGlanceProvider(
                broker: broker,
                source: source,
                clock: clock
            )

            do {
                let staleMeeting = try CalendarMeeting(
                    eventIdentifier: "stale-\(scenario.label)",
                    title: "STALE SHOULD NOT SURVIVE",
                    startDate: now.addingTimeInterval(60),
                    endDate: now.addingTimeInterval(180)
                )
                let distantMeeting = try CalendarMeeting(
                    eventIdentifier: "distant-\(scenario.label)",
                    title: "Distant replacement",
                    startDate: now.addingTimeInterval(3_600),
                    endDate: now.addingTimeInterval(3_900)
                )
                await source.setMeeting(staleMeeting)
                await broker.gateNextSubmit()
                let enable = Task { await provider.enable() }
                check(
                    await waitUntil { await broker.submitPending },
                    "\(scenario.label) fixture gates the stale activation submit"
                )

                switch scenario {
                case .noMeeting:
                    await source.setMeeting(nil)
                case .distantMeeting:
                    await source.setMeeting(distantMeeting)
                case .queryFailure:
                    await source.setFailQueries(true)
                }
                await source.emitChange()
                check(
                    await waitUntil { await source.queryCount == 2 },
                    "\(scenario.label) newer refresh resolves before stale submit completion"
                )
                check(
                    await broker.cancelCallCount == 0,
                    "\(scenario.label) clear remains serialized behind stale submit"
                )

                await broker.releaseSubmit()
                await enable.value
                check(
                    await waitUntil { await broker.snapshot().ordered.isEmpty },
                    "\(scenario.label) newer no-presentation intent clears stale broker activity"
                )
                check(
                    await broker.cancelCallCount == 1,
                    "\(scenario.label) newer result executes one explicit broker clear"
                )
                check(
                    await broker.snapshot().current?.activity.presentation.title
                        != "STALE SHOULD NOT SURVIVE",
                    "\(scenario.label) stale activation title cannot survive"
                )

                let expectedStatus = scenario == .queryFailure
                    ? GlanceProviderStatus(
                        isEnabled: true,
                        capability: .available,
                        health: .degraded(.sourceQueryFailed)
                    )
                    : healthy
                check(
                    await waitUntil { await provider.status() == expectedStatus },
                    "\(scenario.label) latest refresh owns exact provider status"
                )
                let expectedWork = GlanceProviderWorkState(
                    activeObserverCount: 1,
                    activeConsumerTaskCount: 1,
                    scheduledBoundaryCount: scenario == .distantMeeting ? 1 : 0,
                    activeBrokerMutationCount: 0
                )
                check(
                    await waitUntil { await provider.workState() == expectedWork },
                    "\(scenario.label) leaves no hidden mutation or unexpected boundary work"
                )
                if scenario == .distantMeeting {
                    check(
                        await waitUntil {
                            await clock.pendingDeadlines
                                == [distantMeeting.startDate.addingTimeInterval(-600)]
                        },
                        "distant replacement retains only its lead-time boundary"
                    )
                } else {
                    check(
                        await clock.pendingDeadlines.isEmpty,
                        "\(scenario.label) leaves no clock work"
                    )
                }

                let reusableMeeting = try CalendarMeeting(
                    eventIdentifier: "reuse-\(scenario.label)",
                    title: "Reusable after \(scenario.label)",
                    startDate: now.addingTimeInterval(120),
                    endDate: now.addingTimeInterval(240)
                )
                await source.setFailQueries(false)
                await source.setMeeting(reusableMeeting)
                await source.emitChange()
                check(
                    await waitUntil {
                        await broker.snapshot().current?.activity.presentation.title
                            == "Reusable after \(scenario.label)"
                    },
                    "\(scenario.label) serializer remains reusable after stale clear"
                )
                check(
                    await waitUntil { await clock.pendingDeadlines == [reusableMeeting.startDate] },
                    "\(scenario.label) reuse installs one exact boundary"
                )
                check(await provider.status() == healthy, "\(scenario.label) reuse restores healthy status")
                check(
                    await provider.workState() == GlanceProviderWorkState(
                        activeObserverCount: 1,
                        activeConsumerTaskCount: 1,
                        scheduledBoundaryCount: 1,
                        activeBrokerMutationCount: 0
                    ),
                    "\(scenario.label) reuse drains its mutation tail"
                )
                await provider.disable()
                check(await broker.snapshot().ordered.isEmpty, "\(scenario.label) disable removes reused activity")
                check(await provider.workState().isIdle, "\(scenario.label) disable drains all work")
                check(await clock.pendingDeadlines.isEmpty, "\(scenario.label) disable drains reused boundary")
            } catch {
                recordUnexpected(error, context: "calendar \(scenario.label) stale-submit clear")
            }
        }

        do {
            let clock = ManualGlanceClock(now: now)
            let source = ManualCalendarSource(authorization: .fullAccess)
            let broker = GatedGlanceBroker()
            let provider = CalendarGlanceProvider(
                broker: broker,
                source: source,
                clock: clock
            )
            let meeting = try CalendarMeeting(
                eventIdentifier: "disable-stale-submit",
                title: "Disable stale submit",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(180)
            )
            await source.setMeeting(meeting)
            await broker.gateNextSubmit()
            let enable = Task { await provider.enable() }
            check(
                await waitUntil { await broker.submitPending },
                "deactivation fixture gates activation submit"
            )
            let disableFlag = CompletionFlag()
            let disable = Task {
                await provider.disable()
                await disableFlag.markComplete()
            }
            await yieldSeveralTimes()
            check(!(await disableFlag.isComplete), "deactivation drains gated prior submit")
            await broker.releaseSubmit()
            await enable.value
            await disable.value
            check(await broker.snapshot().ordered.isEmpty, "deactivation clear wins after stale submit")
            check(await broker.cancelCallCount == 1, "deactivation performs one terminal broker clear")
            check(await provider.status() == .disabled, "deactivation overlap reaches exact disabled status")
            check(await provider.workState().isIdle, "deactivation overlap leaves no hidden work")
            check(await clock.pendingDeadlines.isEmpty, "deactivation overlap leaves no boundary")

            await provider.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title == "Disable stale submit",
                "deactivation overlap retains reusable broker capacity"
            )
            check(await provider.status() == healthy, "deactivation overlap reuse becomes healthy")
            await provider.disable()
            check(await broker.snapshot().ordered.isEmpty, "reused deactivation fixture disables cleanly")
            check(await provider.workState().isIdle, "reused deactivation fixture drains all work")
        } catch {
            recordUnexpected(error, context: "calendar deactivation stale-submit clear")
        }
    }

    mutating func verifyCalendarEventCoalescing() async {
        let now = Date(timeIntervalSinceReferenceDate: 39_000)
        let movedNow = now.addingTimeInterval(30)
        let clock = NonCooperativeGlanceClock(now: now)
        let source = ManualCalendarSource(authorization: .fullAccess)
        let broker = GatedGlanceBroker()
        let provider = CalendarGlanceProvider(
            broker: broker,
            source: source,
            clock: clock
        )

        do {
            let initialMeeting = try CalendarMeeting(
                eventIdentifier: "coalesced-initial",
                title: "Initial relay meeting",
                startDate: now.addingTimeInterval(120),
                endDate: now.addingTimeInterval(300)
            )
            let updatedMeeting = try CalendarMeeting(
                eventIdentifier: "coalesced-updated",
                title: "Updated relay meeting",
                startDate: now.addingTimeInterval(180),
                endDate: now.addingTimeInterval(360)
            )
            await source.setMeeting(initialMeeting)
            await provider.enable()
            check(await waitUntil { await clock.waiterCount == 1 }, "coalescing fixture owns one initial boundary")
            check(await broker.submitCallCount == 1, "coalescing fixture submits its initial meeting once")

            await broker.gateNextSubmit()
            await source.setMeeting(updatedMeeting)
            await source.emit(.eventStoreChanged)
            check(
                await waitUntil { await broker.submitPending },
                "calendar consumer is deterministically gated in a store submission"
            )
            await clock.setNow(movedNow)
            await source.emit(.wallClockChanged)
            await source.emit(.eventStoreChanged)
            await broker.releaseSubmit()
            check(
                await waitUntil { await clock.cancellationAttemptCount >= 1 },
                "store refresh begins replacing the noncooperative old boundary"
            )
            await clock.fire(index: 0, at: movedNow)
            check(
                await waitUntil {
                    let submitCallCount = await broker.submitCallCount
                    let cancellationAttemptCount = await clock.cancellationAttemptCount
                    return submitCallCount == 3 && cancellationAttemptCount >= 2
                },
                "system-dominant coalescing forces resubmission and boundary replacement"
            )
            await clock.fire(index: 0, at: movedNow)
            check(
                await waitUntil {
                    let totalSleepCount = await clock.totalSleepCount
                    let pendingDeadlines = await clock.pendingDeadlines
                    return totalSleepCount == 3
                        && pendingDeadlines == [updatedMeeting.startDate]
                },
                "coalesced system refresh installs one fresh exact deadline"
            )
            check(await source.queryCount == 3, "equivalent store trigger coalesces behind the stronger system trigger")
            check(
                await broker.snapshot().current?.activity.presentation.title == "Updated relay meeting",
                "coalesced refresh retains the latest broker presentation"
            )
            check(await broker.snapshot().ordered.count == 1, "coalesced refresh retains one broker identity")
            check(
                await provider.status() == GlanceProviderStatus(
                    isEnabled: true,
                    capability: .available,
                    health: .healthy
                ),
                "coalesced refresh retains exact healthy status"
            )
            check(
                await provider.workState() == GlanceProviderWorkState(
                    activeObserverCount: 1,
                    activeConsumerTaskCount: 1,
                    scheduledBoundaryCount: 1,
                    activeBrokerMutationCount: 0
                ),
                "coalesced refresh leaves one observer, consumer, and one-shot boundary"
            )

            let disableFlag = CompletionFlag()
            let disable = Task {
                await provider.disable()
                await disableFlag.markComplete()
            }
            check(
                await waitUntil { await clock.cancellationAttemptCount >= 3 },
                "disable cancels the final noncooperative boundary"
            )
            await yieldSeveralTimes()
            check(!(await disableFlag.isComplete), "disable drains the final noncooperative boundary")
            await clock.fire(index: 0, at: movedNow)
            await disable.value
            check(await clock.waiterCount == 0, "disable leaves no stale clock waiter")
            check(await broker.snapshot().ordered.isEmpty, "disable removes the coalesced calendar activity")
            check(await provider.status() == .disabled, "coalesced calendar disable reaches exact disabled status")
            check(await provider.workState().isIdle, "coalesced calendar disable drains all work")

            let callsAfterDisable = await broker.physicalCallCount
            await source.emitStale(.didWake)
            await source.emitStale(.eventStoreChanged)
            await yieldSeveralTimes()
            check(
                await broker.physicalCallCount == callsAfterDisable,
                "coalesced stale events perform zero physical broker work after disable"
            )
            check(await source.queryCount == 3, "coalesced stale events perform zero queries after disable")
        } catch {
            recordUnexpected(error, context: "calendar strongest-trigger coalescing")
        }
    }

    mutating func verifyCalendarPermissionSeams() async {
        let denied = ManualCalendarSource(authorization: .denied)
        let deniedProvider = CalendarGlanceProvider(broker: makeBroker(), source: denied, clock: ManualGlanceClock())
        await deniedProvider.enable()
        check(await denied.permissionRequestCount == 0, "already-denied calendar access is not requested again")
        check(await denied.startCount == 0, "denied calendar access installs no observer")
        check(await deniedProvider.status().capability == .permissionDenied, "denied calendar state is reported honestly")
        check(await deniedProvider.workState().isIdle, "denied calendar state owns zero ongoing work")

        let restricted = ManualCalendarSource(authorization: .restricted)
        let restrictedProvider = CalendarGlanceProvider(broker: makeBroker(), source: restricted, clock: ManualGlanceClock())
        await restrictedProvider.enable()
        check(await restricted.permissionRequestCount == 0, "restricted calendar access is not requested")
        check(await restricted.startCount == 0, "restricted calendar access installs no observer")
        check(await restrictedProvider.status().capability == .restricted, "restricted calendar state is reported honestly")

        let granted = ManualCalendarSource(
            authorization: .notDetermined,
            authorizationAfterRequest: .fullAccess,
            requestResult: true
        )
        let grantedProvider = CalendarGlanceProvider(broker: makeBroker(), source: granted, clock: ManualGlanceClock())
        check(await granted.permissionRequestCount == 0, "not-determined permission remains untouched before enable")
        await grantedProvider.enable()
        await grantedProvider.enable()
        check(await granted.permissionRequestCount == 0, "persisted restore and repeated enable perform zero permission calls")
        check(await granted.startCount == 0, "permission-required restore installs no observer")
        check(await grantedProvider.status().capability == .permissionRequired, "prompt-free restore reports permission required")
        check(await grantedProvider.status().health == .healthy, "prompt-free restore reports healthy idle machinery")
        check(await grantedProvider.workState().isIdle, "prompt-free restore remains physically idle")
        do {
            let authorization = try await grantedProvider.requestFullAccess()
            check(authorization == .fullAccess, "explicit contextual permission seam reports granted access")
        } catch {
            recordUnexpected(error, context: "explicit granted calendar permission")
        }
        check(await granted.permissionRequestCount == 1, "explicit contextual permission seam requests exactly once")
        check(await granted.startCount == 0, "permission acquisition remains separate from provider start")
        await grantedProvider.enable()
        check(await granted.startCount == 1, "post-permission enable starts one observer")
        check(await grantedProvider.status().capability == .available, "post-permission enable becomes available")
        await grantedProvider.disable()

        let declined = ManualCalendarSource(
            authorization: .notDetermined,
            authorizationAfterRequest: .denied,
            requestResult: false
        )
        let declinedProvider = CalendarGlanceProvider(broker: makeBroker(), source: declined, clock: ManualGlanceClock())
        await declinedProvider.enable()
        check(await declined.permissionRequestCount == 0, "not-determined enable never implicitly prompts")
        do {
            let authorization = try await declinedProvider.requestFullAccess()
            check(authorization == .denied, "explicit contextual denial returns current authorization")
        } catch {
            recordUnexpected(error, context: "explicit declined calendar permission")
        }
        check(await declined.permissionRequestCount == 1, "explicit contextual denial attempts one permission request")
        check(await declined.startCount == 0, "declined request installs no observer")
        check(await declinedProvider.status().capability == .permissionDenied, "declined request reports denial")

        let deferred = DeferredPermissionCalendarSource()
        let deferredProvider = CalendarGlanceProvider(
            broker: makeBroker(),
            source: deferred,
            clock: ManualGlanceClock()
        )
        let firstRequest = Task { try? await deferredProvider.requestFullAccess() }
        check(await waitUntil { await deferred.requestPending }, "explicit deferred permission request begins")
        let secondRequest = Task { try? await deferredProvider.requestFullAccess() }
        await yieldSeveralTimes()
        check(await deferred.permissionRequestCount == 1, "overlapping contextual permission calls share one request")
        let disableFlag = CompletionFlag()
        let disable = Task {
            await deferredProvider.disable()
            await disableFlag.markComplete()
        }
        await yieldSeveralTimes()
        check(!(await disableFlag.isComplete), "disable drains an in-flight permission request even while provider is disabled")
        await deferred.finishPermission(granted: true)
        check(await firstRequest.value == .fullAccess, "first shared permission caller receives grant")
        check(await secondRequest.value == .fullAccess, "second shared permission caller receives grant")
        await disable.value
        check(await disableFlag.isComplete, "disable completes after contextual permission work drains")
    }

    mutating func verifyCalendarUnavailableTakeover() async {
        let now = Date(timeIntervalSinceReferenceDate: 46_500)
        let authorizationScenarios: [(
            authorization: CalendarAuthorization,
            capability: GlanceProviderCapability,
            label: String
        )] = [
            (.denied, .permissionDenied, "denied"),
            (.notDetermined, .permissionRequired, "not-determined"),
            (.restricted, .restricted, "restricted"),
        ]

        for scenario in authorizationScenarios {
            do {
                let broker = makeBroker()
                let oldSource = ManualCalendarSource(authorization: .fullAccess)
                let oldClock = ManualGlanceClock(now: now)
                let oldMeeting = try CalendarMeeting(
                    eventIdentifier: "takeover-\(scenario.label)",
                    title: "Old visible \(scenario.label) meeting",
                    startDate: now.addingTimeInterval(60),
                    endDate: now.addingTimeInterval(180)
                )
                await oldSource.setMeeting(oldMeeting)
                let oldProvider = CalendarGlanceProvider(
                    broker: broker,
                    source: oldSource,
                    clock: oldClock
                )
                await oldProvider.enable()
                check(
                    await broker.snapshot().current?.activity.presentation.title
                        == "Old visible \(scenario.label) meeting",
                    "\(scenario.label) takeover fixture starts with an old visible meeting"
                )

                let replacementSource = ManualCalendarSource(
                    authorization: scenario.authorization
                )
                let replacement = CalendarGlanceProvider(
                    broker: broker,
                    source: replacementSource,
                    clock: ManualGlanceClock(now: now)
                )
                await replacement.enable()
                check(
                    await broker.snapshot().ordered.isEmpty,
                    "\(scenario.label) successor claim atomically clears the old meeting"
                )
                check(
                    await replacement.status().capability == scenario.capability,
                    "\(scenario.label) successor reports its exact unavailable capability"
                )
                check(
                    await replacementSource.permissionRequestCount == 0,
                    "\(scenario.label) successor takeover performs zero permission prompts"
                )
                check(
                    await replacementSource.startCount == 0,
                    "\(scenario.label) successor takeover starts no event source"
                )
                check(
                    await replacement.workState().isIdle,
                    "\(scenario.label) successor takeover is quiet at rest"
                )

                await oldSource.emitChange()
                check(
                    await waitUntil { await oldSource.queryCount == 2 },
                    "\(scenario.label) stale predecessor refresh reaches broker admission"
                )
                check(
                    await broker.snapshot().ordered.isEmpty,
                    "\(scenario.label) stale predecessor cannot republish after takeover"
                )

                await oldProvider.disable()
                await replacement.disable()
                check(
                    await broker.workState().activeOwnershipCount == 0,
                    "\(scenario.label) takeover releases both ownership generations"
                )
                let oldWork = await oldProvider.workState()
                let replacementWork = await replacement.workState()
                check(
                    oldWork.isIdle && replacementWork.isIdle,
                    "\(scenario.label) takeover drains predecessor and successor work"
                )
            } catch {
                recordUnexpected(error, context: "\(scenario.label) calendar takeover")
            }
        }

        do {
            let broker = makeBroker()
            let oldSource = ManualCalendarSource(authorization: .fullAccess)
            let oldClock = ManualGlanceClock(now: now)
            let oldMeeting = try CalendarMeeting(
                eventIdentifier: "takeover-start-failure",
                title: "Old visible source-start meeting",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(180)
            )
            await oldSource.setMeeting(oldMeeting)
            let oldProvider = CalendarGlanceProvider(
                broker: broker,
                source: oldSource,
                clock: oldClock
            )
            await oldProvider.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "Old visible source-start meeting",
                "source-start takeover fixture begins with an old visible meeting"
            )

            let failedSource = ManualCalendarSource(
                authorization: .fullAccess,
                failStart: true
            )
            let replacement = CalendarGlanceProvider(
                broker: broker,
                source: failedSource,
                clock: ManualGlanceClock(now: now)
            )
            await replacement.enable()
            check(
                await broker.snapshot().ordered.isEmpty,
                "source-start failure successor claim atomically clears the old meeting"
            )
            check(
                await replacement.status().health
                    == .unavailable(.eventSourceUnavailable),
                "source-start failure successor reports normalized unavailability"
            )
            check(await failedSource.startCount == 1, "source-start failure is attempted once")
            check(
                await replacement.workState().isIdle,
                "source-start failure successor drains relay and observer work"
            )

            await oldSource.emitChange()
            check(
                await waitUntil { await oldSource.queryCount == 2 },
                "source-start failure stale predecessor reaches broker admission"
            )
            check(
                await broker.snapshot().ordered.isEmpty,
                "source-start failure stale predecessor cannot republish"
            )

            await oldProvider.disable()
            await replacement.disable()
            check(
                await broker.workState().activeOwnershipCount == 0,
                "source-start failure takeover releases both ownership generations"
            )
            let oldWork = await oldProvider.workState()
            let replacementWork = await replacement.workState()
            check(
                oldWork.isIdle && replacementWork.isIdle,
                "source-start failure takeover drains predecessor and successor work"
            )
        } catch {
            recordUnexpected(error, context: "source-start failure calendar takeover")
        }
    }

    mutating func verifyCountdownCancellationReplacementAndExpiry() async {
        let now = Date(timeIntervalSinceReferenceDate: 40_000)
        let clock = ManualGlanceClock(now: now)
        let acknowledgementScheduler = ManualBrokerScheduler()
        let broker = ActivityBroker(expirationScheduler: acknowledgementScheduler)
        let provider = CountdownGlanceProvider(broker: broker, clock: clock)
        do {
            let first = try CountdownTimer(
                title: "First",
                startedAt: now,
                endsAt: now.addingTimeInterval(120)
            )
            let replacement = try CountdownTimer(
                title: "Replacement",
                startedAt: now,
                endsAt: now.addingTimeInterval(60)
            )
            await provider.setCountdown(first)
            check(await clock.pendingCount == 0, "disabled countdown replacement schedules no work")
            check(await broker.snapshot().ordered.isEmpty, "disabled countdown replacement submits nothing")

            await provider.enable()
            check(await broker.snapshot().current?.activity.presentation.title == "First", "countdown enable submits stored timer")
            check(
                await waitUntil { await clock.pendingCount == 1 },
                "countdown schedules one expiry boundary"
            )
            check(
                await provider.presentation(at: now.addingTimeInterval(60))?.fractionCompleted == 0.5,
                "provider exposes live timestamp-derived progress without broker ticks"
            )

            await provider.setCountdown(replacement)
            check(await broker.snapshot().current?.activity.presentation.title == "Replacement", "countdown replacement updates one broker identity")
            check(
                await waitUntil { await clock.pendingCount == 1 },
                "countdown replacement retains exactly one boundary"
            )
            check(await clock.cancellationCount >= 1, "countdown replacement cancels the previous boundary")

            await provider.cancelCountdown()
            check(await broker.snapshot().ordered.isEmpty, "countdown cancellation removes broker activity")
            check(await provider.countdown() == nil, "countdown cancellation clears active state")
            check(
                await waitUntil { await clock.pendingCount == 0 },
                "countdown cancellation releases boundary work"
            )

            await provider.setCountdown(replacement)
            check(
                await waitUntil { await clock.pendingCount == 1 },
                "new countdown schedules one boundary"
            )
            await clock.advance(to: replacement.endsAt)
            check(await waitUntil { await provider.countdown() == nil }, "countdown expires at its one-shot boundary")
            check(
                await broker.snapshot().current?.activity.presentation.title == "Focus complete",
                "countdown expiry publishes one bounded completion acknowledgement"
            )
            check(
                await broker.snapshot().current?.activity.action == nil,
                "completion acknowledgement exposes no stale timer action"
            )
            check(await provider.status() == .disabled, "natural completion disables the provider")
            check(
                await broker.workState().activeOwnershipCount == 0,
                "natural completion releases broker ownership before acknowledgement expiry"
            )
            check(await provider.workState().isIdle, "expired countdown owns zero work")
            check(
                await waitUntil { await acknowledgementScheduler.pendingCount == 1 },
                "completion acknowledgement owns one short broker expiry"
            )
            await acknowledgementScheduler.fireNext()
            check(
                await waitUntil { await broker.snapshot().ordered.isEmpty },
                "completion acknowledgement disappears at its bounded expiry"
            )
            check(
                await broker.workState() == ActivityBrokerWorkState(
                    scheduledExpiryCount: 0,
                    subscriberCount: 0,
                    activeOwnershipCount: 0,
                    pendingOwnershipIntentCount: 0
                ),
                "completion acknowledgement expiry leaves no timer work or ownership"
            )

            await provider.disable()
            await provider.disable()
            check(await provider.status() == .disabled, "countdown disable is idempotent")

            let endedClock = ManualGlanceClock(
                now: now.addingTimeInterval(300)
            )
            let endedBroker = makeBroker()
            let endedProvider = CountdownGlanceProvider(
                broker: endedBroker,
                clock: endedClock
            )
            let alreadyEnded = try CountdownTimer(
                title: "Already ended",
                startedAt: now,
                endsAt: now.addingTimeInterval(30)
            )
            await endedProvider.setCountdown(alreadyEnded)
            await endedProvider.enable()
            check(
                await endedProvider.countdown() == nil,
                "already-ended countdown clears provider state during activation"
            )
            check(
                await endedBroker.snapshot().ordered.isEmpty,
                "already-ended countdown publishes no activity"
            )
            check(
                await endedProvider.workState().isIdle,
                "already-ended countdown schedules no timer work"
            )
            await endedProvider.disable()
            check(
                await endedBroker.workState().activeOwnershipCount == 0,
                "already-ended countdown releases ownership on disable"
            )
        } catch {
            recordUnexpected(error, context: "countdown lifecycle")
        }
    }

    mutating func verifyCountdownNaturalCompletionBarrier() async {
        let now = Date(timeIntervalSinceReferenceDate: 41_000)
        let clock = ManualGlanceClock(now: now)
        let broker = GatedGlanceBroker()
        let provider = CountdownGlanceProvider(broker: broker, clock: clock)
        let completionGate = NaturalCompletionGate()
        do {
            let timer = try CountdownTimer(
                title: "Barrier timer",
                startedAt: now,
                endsAt: now.addingTimeInterval(5)
            )
            let timerOperationIdentity = CountdownOperationIdentity()
            await provider.setNaturalCompletionHandler { completion in
                await completionGate.wait(completion)
            }
            await provider.setCountdown(
                timer,
                operationIdentity: timerOperationIdentity
            )
            await provider.enable()
            check(
                await waitUntil { await clock.pendingDeadlines == [timer.endsAt] },
                "natural-completion barrier fixture owns one expiry boundary"
            )

            await broker.gateNextRelease()
            await clock.advance(to: timer.endsAt)
            check(
                await waitUntil { await broker.releasePending },
                "natural completion reaches the gated physical ownership release"
            )
            check(await provider.status() == .disabled, "gated natural completion retires logical provider state")
            check(
                !(await provider.workState().isIdle),
                "gated natural completion remains accounted while lease release is unsettled"
            )
            check(
                await broker.workState().activeOwnershipCount == 1,
                "gated natural completion retains ownership until physical release"
            )

            let disableFinished = CompletionFlag()
            let disableTask = Task {
                await provider.disable()
                await disableFinished.markComplete()
            }
            await yieldSeveralTimes()
            check(
                !(await disableFinished.isComplete),
                "concurrent disable is a barrier for natural-completion cleanup"
            )

            await broker.releaseRelease()
            check(
                await waitUntil { await completionGate.didStart },
                "natural completion invokes its callback only after ownership release"
            )
            check(
                await broker.workState().activeOwnershipCount == 0,
                "natural completion physically releases ownership before its callback"
            )
            let callbackWork = await provider.workState()
            let disableDidFinish = await disableFinished.isComplete
            check(
                !callbackWork.isIdle && !disableDidFinish,
                "callback settlement remains provider work and keeps disable blocked"
            )

            let replacement = try CountdownTimer(
                title: "Reusable replacement",
                startedAt: timer.endsAt,
                endsAt: timer.endsAt.addingTimeInterval(30)
            )
            let replacementOperationIdentity = CountdownOperationIdentity()
            await provider.setCountdown(
                replacement,
                operationIdentity: replacementOperationIdentity
            )
            let enableFinished = CompletionFlag()
            let enableTask = Task {
                await provider.enable()
                await enableFinished.markComplete()
            }
            await yieldSeveralTimes()
            let admittedReplacement = await provider.countdown()
            let replacementEnableDidFinish = await enableFinished.isComplete
            check(
                admittedReplacement == replacement && !replacementEnableDidFinish,
                "replacement is admitted while the predecessor callback keeps enable gated"
            )
            check(
                await completionGate.completedTimer == timer,
                "natural-completion callback identifies the exact retired timer generation"
            )
            check(
                await completionGate.completedOperationIdentity == timerOperationIdentity
                    && timerOperationIdentity != replacementOperationIdentity,
                "natural-completion callback carries the immutable retired operation identity"
            )

            await completionGate.release()
            await disableTask.value
            await enableTask.value
            check(
                await broker.snapshot().current?.activity.presentation.title == "Reusable replacement",
                "callback-gated natural completion permits its admitted generation-safe replacement"
            )
            check(
                await waitUntil { await clock.pendingDeadlines == [replacement.endsAt] },
                "replacement owns exactly one fresh expiry boundary"
            )
            await provider.disable()
            let replacementProviderWork = await provider.workState()
            let replacementBrokerWork = await broker.workState()
            check(
                replacementProviderWork.isIdle
                    && replacementBrokerWork.activeOwnershipCount == 0,
                "replacement reuse drains its boundary and ownership"
            )
        } catch {
            recordUnexpected(error, context: "countdown natural-completion barrier")
        }
    }

    mutating func verifyVisibleCountdownDemand() async {
        let now = Date(timeIntervalSinceReferenceDate: 42_000.25)
        let clock = ManualGlanceClock(now: now)
        let broker = makeBroker()
        let provider = CountdownGlanceProvider(broker: broker, clock: clock)
        do {
            let timer = try CountdownTimer(
                title: "Visible timer",
                startedAt: now,
                endsAt: now.addingTimeInterval(4.75)
            )
            await provider.setCountdown(timer)
            await provider.enable()
            check(await provider.presentationDemand() == .hidden, "timer live updates default to hidden demand")
            check(
                await waitUntil { await clock.pendingDeadlines == [timer.endsAt] },
                "hidden timer retains only its expiry one-shot"
            )

            let staticVersion = await broker.snapshot().version
            let staticRevision = await broker.snapshot().current?.revision
            await provider.setPresentationDemand(.visible)
            check(await provider.presentationDemand() == .visible, "surface can explicitly demand visible timer updates")
            check(
                await broker.snapshot().version == staticVersion,
                "visible demand performs no broker progress publication"
            )
            let firstTick = Date(timeIntervalSinceReferenceDate: 42_001)
            check(
                await waitUntil { await clock.pendingDeadlines == [timer.endsAt] },
                "visible timer retains only its single expiry boundary"
            )

            await clock.advance(to: firstTick)
            await yieldSeveralTimes()
            let afterVisibleTick = await broker.snapshot()
            check(afterVisibleTick.version == staticVersion, "visible tick performs no broker mutation")
            check(
                afterVisibleTick.current?.revision == staticRevision,
                "visible tick preserves the exact cancel action revision"
            )
            check(
                await clock.pendingDeadlines == [timer.endsAt],
                "visible tick allocates no successor timer work"
            )

            let visibleVersion = await broker.snapshot().version
            await provider.setPresentationDemand(.hidden)
            check(
                await waitUntil { await clock.pendingDeadlines == [timer.endsAt] },
                "hiding timer immediately replaces live tick with expiry-only boundary"
            )
            await clock.advance(to: firstTick.addingTimeInterval(1))
            await yieldSeveralTimes()
            check(await broker.snapshot().version == visibleVersion, "hidden timer performs no progress submissions")

            await provider.setPresentationDemand(.visible)
            await clock.advance(to: timer.endsAt)
            check(await waitUntil { await provider.countdown() == nil }, "visible timer expires deterministically at its end date")
            check(
                await broker.snapshot().current?.activity.presentation.title == "Focus complete",
                "visible timer expiry replaces the action with one completion acknowledgement"
            )
            check(await provider.status() == .disabled, "visible timer natural completion disables provider")
            check(await provider.workState().isIdle, "visible timer expiry stops all one-shot work")

            let cancellable = try CountdownTimer(
                title: "Cancellable visible timer",
                startedAt: timer.endsAt,
                endsAt: timer.endsAt.addingTimeInterval(30)
            )
            await provider.setCountdown(cancellable)
            await provider.setPresentationDemand(.visible)
            await provider.enable()
            check(
                await waitUntil { await clock.pendingCount == 1 },
                "new visible timer owns one boundary"
            )
            await provider.cancelCountdown()
            check(await clock.pendingCount == 0, "timer cancellation immediately stops live scheduling")
            check(await provider.workState().isIdle, "cancelled visible timer owns zero work")

            await provider.disable()
            check(await provider.presentationDemand() == .hidden, "disable clears stale visible demand")
        } catch {
            recordUnexpected(error, context: "visible countdown demand")
        }
    }

    mutating func verifyCountdownDemandMutationOrdering() async {
        let now = Date(timeIntervalSinceReferenceDate: 44_000.25)

        do {
            let clock = ManualGlanceClock(now: now)
            let broker = GatedGlanceBroker()
            let provider = CountdownGlanceProvider(broker: broker, clock: clock)
            let initial = try CountdownTimer(
                title: "Demand ordering initial",
                startedAt: now,
                endsAt: now.addingTimeInterval(300)
            )
            let blocked = try CountdownTimer(
                title: "DEMAND ORDERING BLOCKED A",
                startedAt: now,
                endsAt: now.addingTimeInterval(240)
            )
            let replacement = try CountdownTimer(
                title: "DEMAND ORDERING REPLACEMENT B",
                startedAt: now,
                endsAt: now.addingTimeInterval(180)
            )

            await provider.setCountdown(initial)
            await provider.enable()
            await broker.gateNextSubmit()
            let blockedMutation = Task { await provider.setCountdown(blocked) }
            check(
                await waitUntil { await broker.submitPending },
                "countdown replacement-demand fixture gates mutation A in broker submit"
            )
            let blockedQueueRevision = await provider.mutationQueueRevision()

            let replacementFlag = CompletionFlag()
            let replacementMutation = Task {
                await provider.setCountdown(replacement)
                await replacementFlag.markComplete()
            }
            check(
                await waitUntil {
                    await provider.mutationQueueRevision() == blockedQueueRevision + 1
                },
                "countdown replacement B is admitted behind blocked mutation A"
            )

            let demandFlag = CompletionFlag()
            let demandMutation = Task {
                await provider.setPresentationDemand(.visible)
                await demandFlag.markComplete()
            }
            check(
                await waitUntil {
                    await provider.mutationQueueRevision() == blockedQueueRevision + 2
                },
                "visible demand is admitted behind queued replacement B"
            )
            let replacementCompletedWhileBlocked = await replacementFlag.isComplete
            let demandCompletedWhileBlocked = await demandFlag.isComplete
            check(
                !replacementCompletedWhileBlocked && !demandCompletedWhileBlocked,
                "replacement and demand remain serialized behind blocked mutation A"
            )

            await broker.releaseSubmit()
            await blockedMutation.value
            await replacementMutation.value
            await demandMutation.value

            check(
                await provider.countdown() == replacement,
                "visible demand cannot suppress the queued countdown replacement"
            )
            check(
                await provider.presentationDemand() == .visible,
                "visible demand applies to the replacement logical state"
            )
            let replacementSnapshot = await broker.snapshot()
            check(
                replacementSnapshot.ordered.count == 1
                    && replacementSnapshot.queued.isEmpty
                    && replacementSnapshot.current?.activity.presentation.title
                        == "DEMAND ORDERING REPLACEMENT B",
                "replacement B owns the exact broker snapshot after visible demand"
            )
            check(
                await broker.submitCallCount == 3,
                "replacement performs its ordered submit while visible demand stays broker-free"
            )
            check(
                await waitUntil { await clock.pendingDeadlines == [replacement.endsAt] },
                "visible replacement owns only its expiry boundary"
            )
            check(
                await provider.workState() == GlanceProviderWorkState(
                    activeObserverCount: 0,
                    activeConsumerTaskCount: 0,
                    scheduledBoundaryCount: 1
                ),
                "replacement-demand ordering leaves only its visible one-shot"
            )
            let replacementBrokerWork = await broker.workState()
            check(
                replacementBrokerWork.scheduledExpiryCount == 0
                    && replacementBrokerWork.subscriberCount == 0
                    && replacementBrokerWork.activeOwnershipCount == 1
                    && replacementBrokerWork.pendingOwnershipIntentCount == 0,
                "replacement-demand ordering retains one bounded ownership lane"
            )

            let versionBeforeProjectionTick = replacementSnapshot.version
            await clock.advance(to: Date(timeIntervalSinceReferenceDate: 44_001))
            await yieldSeveralTimes()
            let submitCountAfterProjectionTick = await broker.submitCallCount
            let snapshotAfterProjectionTick = await broker.snapshot()
            check(
                submitCountAfterProjectionTick == 3
                    && snapshotAfterProjectionTick.version == versionBeforeProjectionTick,
                "visible replacement progress performs no provider or broker work"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "DEMAND ORDERING REPLACEMENT B",
                "blocked mutation A cannot reappear on a later visible boundary"
            )

            await provider.cancelCountdown()
            let reusable = try CountdownTimer(
                title: "DEMAND ORDERING REUSABLE",
                startedAt: Date(timeIntervalSinceReferenceDate: 44_001),
                endsAt: Date(timeIntervalSinceReferenceDate: 44_121)
            )
            await provider.setCountdown(reusable)
            let reusableCountdown = await provider.countdown()
            let reusableSnapshot = await broker.snapshot()
            check(
                reusableCountdown == reusable
                    && reusableSnapshot.current?.activity.presentation.title
                        == "DEMAND ORDERING REUSABLE",
                "replacement-demand mutation capacity remains reusable"
            )
            await provider.disable()
            let finalProviderWork = await provider.workState()
            let finalSnapshot = await broker.snapshot()
            let finalBrokerWork = await broker.workState()
            check(
                finalProviderWork.isIdle
                    && finalSnapshot.ordered.isEmpty
                    && finalBrokerWork.activeOwnershipCount == 0
                    && finalBrokerWork.pendingOwnershipIntentCount == 0,
                "replacement-demand reuse drains provider and ownership work exactly"
            )
        } catch {
            recordUnexpected(error, context: "countdown replacement versus demand ordering")
        }

        do {
            let clock = ManualGlanceClock(now: now)
            let broker = GatedGlanceBroker()
            let provider = CountdownGlanceProvider(broker: broker, clock: clock)
            let initial = try CountdownTimer(
                title: "Cancel-demand initial",
                startedAt: now,
                endsAt: now.addingTimeInterval(300)
            )
            let blocked = try CountdownTimer(
                title: "CANCEL DEMAND BLOCKED A",
                startedAt: now,
                endsAt: now.addingTimeInterval(240)
            )

            await provider.setCountdown(initial)
            await provider.enable()
            await provider.setPresentationDemand(.visible)
            await broker.gateNextSubmit()
            let blockedMutation = Task { await provider.setCountdown(blocked) }
            check(
                await waitUntil { await broker.submitPending },
                "countdown cancel-demand fixture gates mutation A in broker submit"
            )
            let blockedQueueRevision = await provider.mutationQueueRevision()

            let cancelFlag = CompletionFlag()
            let cancelMutation = Task {
                await provider.cancelCountdown()
                await cancelFlag.markComplete()
            }
            check(
                await waitUntil {
                    await provider.mutationQueueRevision() == blockedQueueRevision + 1
                },
                "countdown cancellation is admitted behind blocked mutation A"
            )

            let demandFlag = CompletionFlag()
            let demandMutation = Task {
                await provider.setPresentationDemand(.hidden)
                await demandFlag.markComplete()
            }
            check(
                await waitUntil {
                    await provider.mutationQueueRevision() == blockedQueueRevision + 2
                },
                "hidden demand is admitted behind queued countdown cancellation"
            )
            let cancelCompletedWhileBlocked = await cancelFlag.isComplete
            let demandCompletedWhileBlocked = await demandFlag.isComplete
            check(
                !cancelCompletedWhileBlocked && !demandCompletedWhileBlocked,
                "cancellation and hidden demand remain serialized behind blocked mutation A"
            )

            await broker.releaseSubmit()
            await blockedMutation.value
            await cancelMutation.value
            await demandMutation.value

            check(
                await provider.countdown() == nil,
                "hidden demand cannot suppress the queued countdown cancellation"
            )
            check(
                await provider.presentationDemand() == .hidden,
                "hidden demand applies after cancellation"
            )
            let cancelledSnapshot = await broker.snapshot()
            check(
                cancelledSnapshot.current == nil
                    && cancelledSnapshot.queued.isEmpty
                    && cancelledSnapshot.ordered.isEmpty,
                "cancel-demand ordering leaves the exact broker snapshot empty"
            )
            let submitCallCount = await broker.submitCallCount
            let cancelCallCount = await broker.cancelCallCount
            check(
                submitCallCount == 2 && cancelCallCount == 1,
                "cancel-demand ordering performs the expected bounded physical mutations"
            )
            let cancelledProviderWork = await provider.workState()
            let cancelledBoundaryCount = await clock.pendingCount
            check(
                cancelledProviderWork.isIdle && cancelledBoundaryCount == 0,
                "cancel-demand ordering leaves no stale boundary or mutation work"
            )

            await clock.advance(to: blocked.endsAt.addingTimeInterval(1))
            await yieldSeveralTimes()
            let countdownAfterAdvance = await provider.countdown()
            let snapshotAfterAdvance = await broker.snapshot()
            check(
                countdownAfterAdvance == nil && snapshotAfterAdvance.ordered.isEmpty,
                "blocked mutation A cannot reappear after queued cancellation"
            )

            let reusable = try CountdownTimer(
                title: "CANCEL DEMAND REUSABLE",
                startedAt: blocked.endsAt.addingTimeInterval(1),
                endsAt: blocked.endsAt.addingTimeInterval(121)
            )
            await provider.setCountdown(reusable)
            let reusableCountdown = await provider.countdown()
            let reusableSnapshot = await broker.snapshot()
            check(
                reusableCountdown == reusable
                    && reusableSnapshot.current?.activity.presentation.title
                        == "CANCEL DEMAND REUSABLE",
                "cancel-demand mutation capacity remains reusable"
            )
            check(
                await waitUntil { await clock.pendingDeadlines == [reusable.endsAt] },
                "reused hidden countdown owns only its expiry boundary"
            )
            await provider.disable()
            let finalProviderWork = await provider.workState()
            let finalSnapshot = await broker.snapshot()
            let finalBrokerWork = await broker.workState()
            check(
                finalProviderWork.isIdle
                    && finalSnapshot.ordered.isEmpty
                    && finalBrokerWork.activeOwnershipCount == 0
                    && finalBrokerWork.pendingOwnershipIntentCount == 0,
                "cancel-demand reuse drains provider and ownership work exactly"
            )
        } catch {
            recordUnexpected(error, context: "countdown cancellation versus demand ordering")
        }
    }

    mutating func verifyBoundaryAndMutationDraining() async {
        let calendarNow = Date(timeIntervalSinceReferenceDate: 45_000)
        let calendarClock = ManualGlanceClock(now: calendarNow)
        let calendarSource = ManualCalendarSource(authorization: .fullAccess)
        let calendarBroker = GatedGlanceBroker()
        let calendar = CalendarGlanceProvider(
            broker: calendarBroker,
            source: calendarSource,
            clock: calendarClock
        )

        do {
            let meeting = try CalendarMeeting(
                eventIdentifier: "gated-boundary",
                title: "Boundary review",
                startDate: calendarNow.addingTimeInterval(30),
                endDate: calendarNow.addingTimeInterval(90)
            )
            await calendarSource.setMeeting(meeting)
            await calendar.enable()
            await calendarBroker.gateNextSubmit()
            await calendarClock.advance(to: meeting.startDate)
            check(
                await waitUntil { await calendarBroker.submitPending },
                "calendar boundary refresh reaches gated broker submission"
            )

            let disableFlag = CompletionFlag()
            let disable = Task {
                await calendar.disable()
                await disableFlag.markComplete()
            }
            await yieldSeveralTimes()
            check(
                !(await disableFlag.isComplete),
                "calendar disable drains an in-flight boundary refresh"
            )
            await calendarBroker.releaseSubmit()
            await disable.value
            check(await calendar.status() == .disabled, "calendar stale boundary cannot overwrite disabled health")
            check(await calendar.workState().isIdle, "calendar boundary drain returns with zero work")
            check(await calendarBroker.snapshot().ordered.isEmpty, "calendar final disable cancellation wins after stale submission")

            await calendar.enable()
            check(
                await calendarBroker.snapshot().current?.activity.presentation.title == "Boundary review",
                "calendar re-enable submits after the stale completion was drained"
            )
            check(await calendar.status().health == .healthy, "calendar stale completion cannot overwrite re-enabled health")
            await calendar.disable()
        } catch {
            recordUnexpected(error, context: "calendar boundary drain")
        }

        let countdownNow = Date(timeIntervalSinceReferenceDate: 46_000)
        let countdownClock = ManualGlanceClock(now: countdownNow)
        let countdownBroker = GatedGlanceBroker()
        let countdown = CountdownGlanceProvider(broker: countdownBroker, clock: countdownClock)

        do {
            let first = try CountdownTimer(
                title: "First gated timer",
                startedAt: countdownNow,
                endsAt: countdownNow.addingTimeInterval(120)
            )
            let replacement = try CountdownTimer(
                title: "Replacement gated timer",
                startedAt: countdownNow,
                endsAt: countdownNow.addingTimeInterval(60)
            )
            await countdown.setCountdown(first)
            await countdown.enable()

            await countdownBroker.gateNextSubmit()
            let replacementFlag = CompletionFlag()
            let replacementTask = Task {
                await countdown.setCountdown(replacement)
                await replacementFlag.markComplete()
            }
            check(
                await waitUntil { await countdownBroker.submitPending },
                "countdown replacement reaches gated broker submission"
            )
            let disableFlag = CompletionFlag()
            let disableTask = Task {
                await countdown.disable()
                await disableFlag.markComplete()
            }
            await yieldSeveralTimes()
            check(!(await replacementFlag.isComplete), "gated countdown submission remains in flight")
            check(!(await disableFlag.isComplete), "countdown disable drains an in-flight mutation submission")
            await countdownBroker.releaseSubmit()
            await replacementTask.value
            await disableTask.value
            check(await countdown.status() == .disabled, "stale countdown submission cannot overwrite disabled health")
            check(await countdown.workState().isIdle, "countdown submission drain returns with zero work")
            check(await countdownBroker.snapshot().ordered.isEmpty, "countdown final disable cancellation wins after stale submission")

            await countdown.enable()
            check(
                await countdownBroker.snapshot().current?.activity.presentation.title == "Replacement gated timer",
                "countdown re-enable uses the replacement after stale submission drains"
            )
            check(await countdown.status().health == .healthy, "stale countdown submission cannot overwrite re-enabled health")

            await countdownBroker.gateNextSubmit()
            await countdownClock.advance(to: replacement.endsAt)
            check(
                await waitUntil { await countdownBroker.submitPending },
                "countdown expiry reaches gated completion acknowledgement"
            )
            let expiryDisableFlag = CompletionFlag()
            let expiryDisable = Task {
                await countdown.disable()
                await expiryDisableFlag.markComplete()
            }
            check(
                await waitUntil {
                    await countdown.workState().scheduledBoundaryCount == 0
                },
                "countdown disable retires the gated expiry boundary before release"
            )
            check(
                !(await expiryDisableFlag.isComplete),
                "countdown disable drains expiry already inside broker acknowledgement"
            )
            await countdownBroker.releaseSubmit()
            await expiryDisable.value
            check(await countdown.status() == .disabled, "stale expiry cannot overwrite disabled health")
            check(await countdown.countdown() == replacement, "stale expiry cannot clear the retained countdown")
            check(await countdownBroker.snapshot().ordered.isEmpty, "expiry disable finishes with no timer activity")
            check(await countdown.workState().isIdle, "expiry disable drains its boundary task")
        } catch {
            recordUnexpected(error, context: "countdown boundary and submission drain")
        }

        let mutationClock = ManualGlanceClock(now: countdownNow)
        let mutationBroker = GatedGlanceBroker()
        let mutationProvider = CountdownGlanceProvider(broker: mutationBroker, clock: mutationClock)
        do {
            let first = try CountdownTimer(
                title: "Mutation first",
                startedAt: countdownNow,
                endsAt: countdownNow.addingTimeInterval(180)
            )
            let replacement = try CountdownTimer(
                title: "Mutation replacement",
                startedAt: countdownNow,
                endsAt: countdownNow.addingTimeInterval(90)
            )
            await mutationProvider.setCountdown(first)
            await mutationProvider.enable()
            await mutationBroker.gateNextSubmit()
            let replace = Task { await mutationProvider.setCountdown(replacement) }
            check(
                await waitUntil { await mutationBroker.submitPending },
                "concurrent replacement reaches gated submission"
            )
            let cancelFlag = CompletionFlag()
            let cancel = Task {
                await mutationProvider.cancelCountdown()
                await cancelFlag.markComplete()
            }
            await yieldSeveralTimes()
            check(!(await cancelFlag.isComplete), "concurrent timer cancel queues behind replacement mutation")
            await mutationBroker.releaseSubmit()
            await replace.value
            await cancel.value
            check(await mutationProvider.countdown() == nil, "serialized concurrent cancel wins over replacement")
            check(await mutationBroker.snapshot().ordered.isEmpty, "serialized concurrent cancel removes replacement submission")
            check(await mutationProvider.workState().scheduledBoundaryCount == 0, "serialized concurrent mutations leave no boundary")
            check(await mutationProvider.status().health == .healthy, "latest concurrent mutation owns final health")
            await mutationProvider.disable()
        } catch {
            recordUnexpected(error, context: "concurrent countdown mutations")
        }

        let activationClock = ManualGlanceClock(now: countdownNow)
        let activationBroker = GatedGlanceBroker()
        let activationProvider = CountdownGlanceProvider(
            broker: activationBroker,
            clock: activationClock
        )
        do {
            let timer = try CountdownTimer(
                title: "Activation race",
                startedAt: countdownNow,
                endsAt: countdownNow.addingTimeInterval(120)
            )
            await activationProvider.setCountdown(timer)
            await activationBroker.gateNextSubmit()
            let enable = Task { await activationProvider.enable() }
            check(
                await waitUntil { await activationBroker.submitPending },
                "countdown activation reaches gated submission"
            )
            let cancelFlag = CompletionFlag()
            let cancel = Task {
                await activationProvider.cancelCountdown()
                await cancelFlag.markComplete()
            }
            await yieldSeveralTimes()
            check(!(await cancelFlag.isComplete), "countdown cancel queues behind activation submission")
            await activationBroker.releaseSubmit()
            await enable.value
            await cancel.value
            check(await activationProvider.countdown() == nil, "cancel during activation clears countdown")
            check(await activationBroker.snapshot().ordered.isEmpty, "cancel after activation tail prevents stale resurrection")
            check(await activationProvider.workState().scheduledBoundaryCount == 0, "cancel during activation leaves no boundary")
            await activationProvider.disable()
        } catch {
            recordUnexpected(error, context: "countdown activation mutation ordering")
        }
    }

    mutating func verifyNonCooperativeTimerGenerationBackstop() async {
        let now = Date(timeIntervalSinceReferenceDate: 50_000)
        let clock = NonCooperativeGlanceClock(now: now)
        let broker = makeBroker()
        let provider = CountdownGlanceProvider(broker: broker, clock: clock)
        do {
            let first = try CountdownTimer(title: "Old", startedAt: now, endsAt: now.addingTimeInterval(30))
            let replacement = try CountdownTimer(title: "New", startedAt: now, endsAt: now.addingTimeInterval(60))
            await provider.setCountdown(first)
            await provider.enable()
            check(await waitUntil { await clock.waiterCount == 1 }, "old countdown registers one non-cooperative waiter")
            let replacementFlag = CompletionFlag()
            let replacementTask = Task {
                await provider.setCountdown(replacement)
                await replacementFlag.markComplete()
            }
            await yieldSeveralTimes()
            check(!(await replacementFlag.isComplete), "replacement drains a non-cooperative old boundary")
            await clock.fire(index: 0, at: now.addingTimeInterval(30))
            await replacementTask.value
            check(await provider.countdown() == replacement, "stale timer generation cannot expire replacement")
            check(await broker.snapshot().current?.activity.presentation.title == "New", "stale timer callback cannot cancel replacement activity")
            check(await waitUntil { await clock.waiterCount == 1 }, "replacement registers a new waiter after the old one drains")

            await clock.fire(index: 0, at: replacement.endsAt)
            check(await waitUntil { await provider.countdown() == nil }, "current timer generation can expire")
            check(
                await broker.snapshot().current?.activity.presentation.title == "Focus complete",
                "current expiry publishes only the bounded completion acknowledgement"
            )
            check(await provider.status() == .disabled, "current expiry disables its provider generation")
        } catch {
            recordUnexpected(error, context: "timer generation backstop")
        }
    }

    mutating func verifyCancellationInsensitiveShutdown() async {
        let broker = CancellationRecordingBroker()
        let powerSource = ManualPowerSource()
        let volumeSource = ManualVolumeSource()
        let calendarSource = ManualCalendarSource(authorization: .fullAccess)
        let clock = ManualGlanceClock(now: Date(timeIntervalSinceReferenceDate: 55_000))
        let power = PowerGlanceProvider(broker: broker, source: powerSource)
        let volume = VolumeGlanceProvider(broker: broker, source: volumeSource)
        let calendar = CalendarGlanceProvider(broker: broker, source: calendarSource, clock: clock)
        let countdown = CountdownGlanceProvider(broker: broker, clock: clock)

        do {
            let low = try PowerSnapshot(chargeLevel: 0.1, isCharging: false, isConnectedToPower: false)
            let volumeSnapshot = try VolumeSnapshot(deviceID: 1, scalar: 0.5, isMuted: false)
            let timer = try CountdownTimer(
                title: "Shutdown drain",
                startedAt: await clock.now(),
                endsAt: (await clock.now()).addingTimeInterval(60)
            )
            await countdown.setCountdown(timer)
            await power.enable()
            await volume.enable()
            await calendar.enable()
            await countdown.enable()
            await powerSource.emit(.snapshot(low))
            await volumeSource.emit(.snapshot(volumeSnapshot))
            let changedVolumeSnapshot = try VolumeSnapshot(deviceID: 1, scalar: 0.6, isMuted: false)
            await volumeSource.emit(.snapshot(changedVolumeSnapshot))
            check(
                await waitUntil { await broker.snapshot().ordered.count == 3 },
                "shutdown fixture starts physical provider work"
            )

            let powerStop = Task {
                while !Task.isCancelled { await Task.yield() }
                await power.disable()
            }
            let volumeStop = Task {
                while !Task.isCancelled { await Task.yield() }
                await volume.disable()
            }
            let calendarStop = Task {
                while !Task.isCancelled { await Task.yield() }
                await calendar.disable()
            }
            let countdownStop = Task {
                while !Task.isCancelled { await Task.yield() }
                await countdown.disable()
            }
            powerStop.cancel()
            volumeStop.cancel()
            calendarStop.cancel()
            countdownStop.cancel()
            await powerStop.value
            await volumeStop.value
            await calendarStop.value
            await countdownStop.value

            check(!(await powerSource.stopObservedCancellation), "power shutdown source stop is cancellation-insensitive")
            check(!(await volumeSource.stopObservedCancellation), "volume shutdown source stop is cancellation-insensitive")
            check(!(await calendarSource.stopObservedCancellation), "calendar shutdown source stop is cancellation-insensitive")
            check(!(await broker.cancelObservedCancellation), "all final broker cancellations run outside caller cancellation")
            check(await power.workState().isIdle, "cancelled caller still drains power work")
            check(await volume.workState().isIdle, "cancelled caller still drains volume work")
            check(await calendar.workState().isIdle, "cancelled caller still drains calendar work")
            check(await countdown.workState().isIdle, "cancelled caller still drains timer work")
            check(await broker.snapshot().ordered.isEmpty, "cancelled shutdown callers still remove every activity")

            let callsAfterDisable = await broker.physicalCallCount
            await powerSource.emit(.snapshot(low), handlerIndex: 0)
            await calendarSource.emitStale(.didWake)
            await clock.advance(to: timer.endsAt.addingTimeInterval(10))
            await yieldSeveralTimes()
            check(
                await broker.physicalCallCount == callsAfterDisable,
                "stale callbacks and boundaries perform zero physical broker work after disable"
            )
        } catch {
            recordUnexpected(error, context: "cancellation-insensitive shutdown")
        }
    }

    mutating func verifyReleaseCleanupFallbacks() async {
        let now = Date(timeIntervalSinceReferenceDate: 56_000)

        do {
            let source = ManualCalendarSource(authorization: .fullAccess)
            let clock = ManualGlanceClock(now: now)
            let broker = GatedGlanceBroker()
            let distantMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-drop",
                title: "Calendar drop",
                startDate: now.addingTimeInterval(3_600),
                endDate: now.addingTimeInterval(3_900)
            )
            await source.setMeeting(distantMeeting)
            var provider: CalendarGlanceProvider? = CalendarGlanceProvider(
                broker: broker,
                source: source,
                clock: clock
            )
            await provider?.enable()
            check(await source.isActive, "calendar drop fixture installs its observer")
            check(
                await waitUntil { await clock.pendingCount == 1 },
                "calendar drop fixture owns one boundary"
            )
            let weakProvider = WeakProviderReference(provider!)
            provider = nil
            check(
                await waitUntil { weakProvider.isReleased },
                "dropping enabled calendar releases the provider"
            )
            check(
                await waitUntil { !(await source.isActive) },
                "calendar deinit fallback removes source observation"
            )
            check(await source.stopCount == 1, "calendar deinit fallback stops its source once")
            check(
                await waitUntil { await clock.pendingCount == 0 },
                "calendar deinit fallback cancels its one-shot"
            )
            check(await clock.cancellationCount == 1, "calendar drop records one boundary cancellation")
            check(
                await waitUntil { await broker.snapshot().ordered.isEmpty },
                "calendar deinit fallback clears broker activity"
            )
            check(
                await waitUntil {
                    let brokerWork = await broker.workState()
                    return await broker.cancelCallCount == 2
                        && brokerWork.activeOwnershipCount == 0
                        && brokerWork.pendingOwnershipIntentCount == 0
                },
                "calendar drop performs quiet clear and terminal retirement"
            )
            let queriesAfterDrop = await source.queryCount
            await source.emitStale(.didWake)
            await yieldSeveralTimes()
            check(await source.queryCount == queriesAfterDrop, "calendar dropped relay rejects stale source events")
        } catch {
            recordUnexpected(error, context: "calendar release cleanup fallback")
        }

        do {
            let clock = ManualGlanceClock(now: now)
            let broker = GatedGlanceBroker()
            let timer = try CountdownTimer(
                title: "Countdown drop",
                startedAt: now,
                endsAt: now.addingTimeInterval(120)
            )
            var provider: CountdownGlanceProvider? = CountdownGlanceProvider(
                broker: broker,
                clock: clock
            )
            await provider?.setCountdown(timer)
            await provider?.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title == "Countdown drop",
                "countdown drop fixture publishes its timer"
            )
            check(
                await waitUntil { await clock.pendingCount == 1 },
                "countdown drop fixture owns one boundary"
            )
            let weakProvider = WeakProviderReference(provider!)
            provider = nil
            check(
                await waitUntil { weakProvider.isReleased },
                "dropping enabled countdown releases the provider"
            )
            check(
                await waitUntil { await clock.pendingCount == 0 },
                "countdown deinit fallback cancels its one-shot"
            )
            check(await clock.cancellationCount == 1, "countdown drop records one boundary cancellation")
            check(
                await waitUntil { await broker.snapshot().ordered.isEmpty },
                "countdown deinit fallback clears broker activity"
            )
            check(await broker.cancelCallCount == 1, "countdown drop performs one terminal clear")
        } catch {
            recordUnexpected(error, context: "countdown release cleanup fallback")
        }
    }

    mutating func verifyReplacementOwnershipLeases() async {
        let now = Date(timeIntervalSinceReferenceDate: 56_500)

        do {
            let broker = GatedGlanceBroker()
            let oldSource = ManualCalendarSource(authorization: .fullAccess)
            let oldClock = ManualGlanceClock(now: now)
            let oldMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-old-owner",
                title: "Old calendar owner",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(180)
            )
            await oldSource.setMeeting(oldMeeting)
            var oldProvider: CalendarGlanceProvider? = CalendarGlanceProvider(
                broker: broker,
                source: oldSource,
                clock: oldClock
            )
            await oldProvider?.enable()
            let weakOldProvider = WeakProviderReference(oldProvider!)

            await broker.gateNextCancel()
            oldProvider = nil
            check(
                await waitUntil { await broker.cancelPending },
                "calendar replacement fixture gates old detached cleanup"
            )
            let oldRevision = await broker.gatedConditionalExpectedRevision
            check(
                await broker.gatedConditionalComparisonMatched,
                "calendar cleanup gate observes the old revision before replacement"
            )
            check(
                await broker.snapshot().current?.revision == oldRevision,
                "calendar cleanup gate captures the exact old broker revision"
            )
            check(weakOldProvider.isReleased, "calendar old provider releases before detached cleanup settles")

            let replacementSource = ManualCalendarSource(authorization: .fullAccess)
            let replacementClock = ManualGlanceClock(now: now)
            let replacementMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-replacement-owner",
                title: "Calendar replacement survives",
                startDate: now.addingTimeInterval(90),
                endDate: now.addingTimeInterval(210)
            )
            await replacementSource.setMeeting(replacementMeeting)
            let replacement = CalendarGlanceProvider(
                broker: broker,
                source: replacementSource,
                clock: replacementClock
            )
            await replacement.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "Calendar replacement survives",
                "calendar replacement publishes while old cleanup is gated"
            )
            check(
                await broker.snapshot().current?.revision != oldRevision,
                "calendar replacement advances the broker revision before old removal"
            )

            await broker.releaseCancel()
            check(
                await waitUntil { await broker.conditionalCancelCompletionCount == 1 },
                "calendar old conditional cleanup settles"
            )
            check(
                await broker.lastConditionalCancelResult == false,
                "calendar atomic conditional removal fails closed after replacement"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "Calendar replacement survives",
                "calendar old cleanup cannot erase replacement revision"
            )
            check(!(await oldSource.isActive), "calendar old observation remains retired")
            check(await oldSource.stopCount == 1, "calendar old source stops exactly once")
            check(
                await waitUntil { await oldClock.pendingCount == 0 },
                "calendar old one-shot settles to zero"
            )
            check(
                await replacement.workState() == GlanceProviderWorkState(
                    activeObserverCount: 1,
                    activeConsumerTaskCount: 1,
                    scheduledBoundaryCount: 1,
                    activeBrokerMutationCount: 0
                ),
                "calendar replacement owns only its expected work"
            )

            await replacement.disable()
            check(await broker.snapshot().ordered.isEmpty, "calendar replacement later clears its own revision")
            check(await broker.cancelCallCount == 2, "calendar ownership handoff performs two exact clears")
            check(await replacement.workState().isIdle, "calendar replacement disable drains all work")
            check(
                await broker.workState().activeOwnershipCount == 0,
                "calendar replacement handoff releases all broker admission state"
            )
        } catch {
            recordUnexpected(error, context: "calendar deinit replacement ownership")
        }

        do {
            let broker = GatedGlanceBroker()
            let oldClock = ManualGlanceClock(now: now)
            let oldTimer = try CountdownTimer(
                title: "Old countdown owner",
                startedAt: now,
                endsAt: now.addingTimeInterval(120)
            )
            var oldProvider: CountdownGlanceProvider? = CountdownGlanceProvider(
                broker: broker,
                clock: oldClock
            )
            await oldProvider?.setCountdown(oldTimer)
            await oldProvider?.enable()
            let weakOldProvider = WeakProviderReference(oldProvider!)

            await broker.gateNextCancel()
            oldProvider = nil
            check(
                await waitUntil { await broker.cancelPending },
                "countdown replacement fixture gates old detached cleanup"
            )
            let oldRevision = await broker.gatedConditionalExpectedRevision
            check(
                await broker.gatedConditionalComparisonMatched,
                "countdown cleanup gate observes the old revision before replacement"
            )
            check(
                await broker.snapshot().current?.revision == oldRevision,
                "countdown cleanup gate captures the exact old broker revision"
            )
            check(weakOldProvider.isReleased, "countdown old provider releases before detached cleanup settles")

            let replacementClock = ManualGlanceClock(now: now)
            let replacementTimer = try CountdownTimer(
                title: "Countdown replacement survives",
                startedAt: now,
                endsAt: now.addingTimeInterval(180)
            )
            let replacement = CountdownGlanceProvider(
                broker: broker,
                clock: replacementClock
            )
            await replacement.setCountdown(replacementTimer)
            await replacement.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "Countdown replacement survives",
                "countdown replacement publishes while old cleanup is gated"
            )
            check(
                await broker.snapshot().current?.revision != oldRevision,
                "countdown replacement advances the broker revision before old removal"
            )

            await broker.releaseCancel()
            check(
                await waitUntil { await broker.conditionalCancelCompletionCount == 1 },
                "countdown old conditional cleanup settles"
            )
            check(
                await broker.lastConditionalCancelResult == false,
                "countdown atomic conditional removal fails closed after replacement"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "Countdown replacement survives",
                "countdown old cleanup cannot erase replacement revision"
            )
            check(
                await waitUntil { await oldClock.pendingCount == 0 },
                "countdown old one-shot settles to zero"
            )
            check(
                await replacement.workState() == GlanceProviderWorkState(
                    activeObserverCount: 0,
                    activeConsumerTaskCount: 0,
                    scheduledBoundaryCount: 1
                ),
                "countdown replacement owns only its expected work"
            )

            await replacement.disable()
            check(await broker.snapshot().ordered.isEmpty, "countdown replacement later clears its own revision")
            check(await broker.cancelCallCount == 2, "countdown ownership handoff performs two exact clears")
            check(await replacement.workState().isIdle, "countdown replacement disable drains all work")
            check(
                await broker.workState().activeOwnershipCount == 0,
                "countdown replacement handoff releases all broker admission state"
            )
        } catch {
            recordUnexpected(error, context: "countdown deinit replacement ownership")
        }
    }

    mutating func verifyCrossInstanceSubmitAdmission() async {
        let now = Date(timeIntervalSinceReferenceDate: 56_750)

        do {
            let broker = GatedGlanceBroker()
            let oldSource = ManualCalendarSource(authorization: .fullAccess)
            let oldClock = ManualGlanceClock(now: now)
            let oldMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-late-drop",
                title: "CALENDAR OLD LATE DROP",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(180)
            )
            await oldSource.setMeeting(oldMeeting)
            var oldProvider: CalendarGlanceProvider? = CalendarGlanceProvider(
                broker: broker,
                source: oldSource,
                clock: oldClock
            )
            let weakOldProvider = WeakProviderReference(oldProvider!)
            await broker.gateNextSubmit()
            let oldEnable = Task { [weak provider = oldProvider] in
                await provider?.enable()
            }
            check(
                await waitUntil { await broker.submitPending },
                "calendar drop fixture gates old submit before broker admission"
            )
            oldProvider = nil

            let replacementSource = ManualCalendarSource(authorization: .fullAccess)
            let replacementClock = ManualGlanceClock(now: now)
            let replacementMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-late-drop-replacement",
                title: "CALENDAR DROP REPLACEMENT",
                startDate: now.addingTimeInterval(90),
                endDate: now.addingTimeInterval(210)
            )
            await replacementSource.setMeeting(replacementMeeting)
            let replacement = CalendarGlanceProvider(
                broker: broker,
                source: replacementSource,
                clock: replacementClock
            )
            await replacement.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "CALENDAR DROP REPLACEMENT",
                "calendar replacement publishes before old gated submit"
            )

            await broker.releaseSubmit()
            await oldEnable.value
            check(
                await waitUntil { await broker.ownedSubmitCompletionCount == 2 },
                "calendar late old submit reaches shared admission"
            )
            check(
                await broker.lastOwnedSubmitAccepted == false,
                "calendar retired generation rejects the late old submit"
            )
            check(
                await waitUntil { weakOldProvider.isReleased },
                "calendar old provider releases after rejected submit"
            )
            check(
                await waitUntil { await broker.conditionalCancelCompletionCount == 1 },
                "calendar old detached cleanup settles after rejected submit"
            )
            check(
                await broker.lastConditionalCancelResult == false,
                "calendar old cleanup is fenced by successor generation"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "CALENDAR DROP REPLACEMENT",
                "calendar late old submit and cleanup preserve replacement"
            )
            check(!(await oldSource.isActive), "calendar dropped old observer settles to zero")
            check(
                await waitUntil { await oldClock.pendingCount == 0 },
                "calendar dropped old boundary settles to zero"
            )

            await replacement.disable()
            check(await broker.snapshot().ordered.isEmpty, "calendar drop replacement clears its generation")
            check(await replacement.workState().isIdle, "calendar drop replacement disable drains work")
            check(
                await broker.workState().activeOwnershipCount == 0,
                "calendar drop replacement prunes all admission generations"
            )
        } catch {
            recordUnexpected(error, context: "calendar gated submit drop replacement")
        }

        do {
            let broker = GatedGlanceBroker()
            let oldSource = ManualCalendarSource(authorization: .fullAccess)
            let oldClock = ManualGlanceClock(now: now)
            let initialMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-disable-initial",
                title: "Calendar disable initial",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(180)
            )
            let lateMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-disable-late",
                title: "CALENDAR OLD LATE DISABLE",
                startDate: now.addingTimeInterval(120),
                endDate: now.addingTimeInterval(240)
            )
            await oldSource.setMeeting(initialMeeting)
            let oldProvider = CalendarGlanceProvider(
                broker: broker,
                source: oldSource,
                clock: oldClock
            )
            await oldProvider.enable()
            await broker.gateNextSubmit()
            await oldSource.setMeeting(lateMeeting)
            await oldSource.emitChange()
            check(
                await waitUntil { await broker.submitPending },
                "calendar disable fixture gates an old refresh submit"
            )
            let disable = Task { await oldProvider.disable() }
            await yieldSeveralTimes()

            let replacementSource = ManualCalendarSource(authorization: .fullAccess)
            let replacementClock = ManualGlanceClock(now: now)
            let replacementMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-disable-submit-replacement",
                title: "CALENDAR DISABLE REPLACEMENT",
                startDate: now.addingTimeInterval(90),
                endDate: now.addingTimeInterval(210)
            )
            await replacementSource.setMeeting(replacementMeeting)
            let replacement = CalendarGlanceProvider(
                broker: broker,
                source: replacementSource,
                clock: replacementClock
            )
            await replacement.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "CALENDAR DISABLE REPLACEMENT",
                "calendar replacement publishes while old disable drains submit"
            )

            await broker.releaseSubmit()
            await disable.value
            check(
                await broker.lastOwnedSubmitAccepted == false,
                "calendar disable closes admission for its gated submit"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "CALENDAR DISABLE REPLACEMENT",
                "calendar disabled old submit cannot overwrite replacement"
            )
            check(await oldProvider.workState().isIdle, "calendar old disable settles all work")
            check(!(await oldSource.isActive), "calendar old disable stops observation")
            check(await oldClock.pendingCount == 0, "calendar old disable drains boundaries")

            await replacement.disable()
            check(await broker.snapshot().ordered.isEmpty, "calendar disable replacement clears its generation")
            check(await replacement.workState().isIdle, "calendar disable replacement drains work")
            check(
                await broker.workState().activeOwnershipCount == 0,
                "calendar disable replacement prunes all admission generations"
            )
        } catch {
            recordUnexpected(error, context: "calendar gated submit disable replacement")
        }

        do {
            let broker = GatedGlanceBroker()
            let oldClock = ManualGlanceClock(now: now)
            let oldTimer = try CountdownTimer(
                title: "COUNTDOWN OLD LATE DROP",
                startedAt: now,
                endsAt: now.addingTimeInterval(120)
            )
            var oldProvider: CountdownGlanceProvider? = CountdownGlanceProvider(
                broker: broker,
                clock: oldClock
            )
            await oldProvider?.setCountdown(oldTimer)
            let weakOldProvider = WeakProviderReference(oldProvider!)
            await broker.gateNextSubmit()
            let oldEnable = Task { [weak provider = oldProvider] in
                await provider?.enable()
            }
            check(
                await waitUntil { await broker.submitPending },
                "countdown drop fixture gates old submit before broker admission"
            )
            oldProvider = nil

            let replacementClock = ManualGlanceClock(now: now)
            let replacementTimer = try CountdownTimer(
                title: "COUNTDOWN DROP REPLACEMENT",
                startedAt: now,
                endsAt: now.addingTimeInterval(180)
            )
            let replacement = CountdownGlanceProvider(
                broker: broker,
                clock: replacementClock
            )
            await replacement.setCountdown(replacementTimer)
            await replacement.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "COUNTDOWN DROP REPLACEMENT",
                "countdown replacement publishes before old gated submit"
            )

            await broker.releaseSubmit()
            await oldEnable.value
            check(
                await waitUntil { await broker.ownedSubmitCompletionCount == 2 },
                "countdown late old submit reaches shared admission"
            )
            check(
                await broker.lastOwnedSubmitAccepted == false,
                "countdown retired generation rejects the late old submit"
            )
            check(
                await waitUntil { weakOldProvider.isReleased },
                "countdown old provider releases after rejected submit"
            )
            check(
                await waitUntil { await broker.conditionalCancelCompletionCount == 1 },
                "countdown old detached cleanup settles after rejected submit"
            )
            check(
                await broker.lastConditionalCancelResult == false,
                "countdown old cleanup is fenced by successor generation"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "COUNTDOWN DROP REPLACEMENT",
                "countdown late old submit and cleanup preserve replacement"
            )
            check(
                await waitUntil { await oldClock.pendingCount == 0 },
                "countdown dropped old boundary settles to zero"
            )

            await replacement.disable()
            check(await broker.snapshot().ordered.isEmpty, "countdown drop replacement clears its generation")
            check(await replacement.workState().isIdle, "countdown drop replacement disable drains work")
            check(
                await broker.workState().activeOwnershipCount == 0,
                "countdown drop replacement prunes all admission generations"
            )
        } catch {
            recordUnexpected(error, context: "countdown gated submit drop replacement")
        }

        do {
            let broker = GatedGlanceBroker()
            let oldClock = ManualGlanceClock(now: now)
            let initialTimer = try CountdownTimer(
                title: "Countdown disable initial",
                startedAt: now,
                endsAt: now.addingTimeInterval(120)
            )
            let lateTimer = try CountdownTimer(
                title: "COUNTDOWN OLD LATE DISABLE",
                startedAt: now,
                endsAt: now.addingTimeInterval(180)
            )
            let oldProvider = CountdownGlanceProvider(
                broker: broker,
                clock: oldClock
            )
            await oldProvider.setCountdown(initialTimer)
            await oldProvider.enable()
            await broker.gateNextSubmit()
            let lateSet = Task { await oldProvider.setCountdown(lateTimer) }
            check(
                await waitUntil { await broker.submitPending },
                "countdown disable fixture gates an old replacement submit"
            )
            let disable = Task { await oldProvider.disable() }
            await yieldSeveralTimes()

            let replacementClock = ManualGlanceClock(now: now)
            let replacementTimer = try CountdownTimer(
                title: "COUNTDOWN DISABLE REPLACEMENT",
                startedAt: now,
                endsAt: now.addingTimeInterval(240)
            )
            let replacement = CountdownGlanceProvider(
                broker: broker,
                clock: replacementClock
            )
            await replacement.setCountdown(replacementTimer)
            await replacement.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "COUNTDOWN DISABLE REPLACEMENT",
                "countdown replacement publishes while old disable drains submit"
            )

            await broker.releaseSubmit()
            await lateSet.value
            await disable.value
            check(
                await broker.lastOwnedSubmitAccepted == false,
                "countdown disable closes admission for its gated submit"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "COUNTDOWN DISABLE REPLACEMENT",
                "countdown disabled old submit cannot overwrite replacement"
            )
            check(await oldProvider.workState().isIdle, "countdown old disable settles all work")
            check(await oldClock.pendingCount == 0, "countdown old disable drains boundaries")

            await replacement.disable()
            check(await broker.snapshot().ordered.isEmpty, "countdown disable replacement clears its generation")
            check(await replacement.workState().isIdle, "countdown disable replacement drains work")
            check(
                await broker.workState().activeOwnershipCount == 0,
                "countdown disable replacement prunes all admission generations"
            )
        } catch {
            recordUnexpected(error, context: "countdown gated submit disable replacement")
        }
    }

    mutating func verifyCrossInstanceClaimAdmission() async {
        let now = Date(timeIntervalSinceReferenceDate: 56_625)

        do {
            let broker = GatedGlanceBroker()
            let oldProvider = CalendarGlanceProvider(
                broker: broker,
                source: ManualCalendarSource(authorization: .fullAccess),
                clock: ManualGlanceClock(now: now)
            )
            await broker.gateNextClaim()
            let oldEnable = Task { await oldProvider.enable() }
            check(
                await waitUntil { await broker.claimPending },
                "calendar disable gates old claim after synchronous intent admission"
            )
            await oldProvider.disable()
            check(await oldProvider.status() == .disabled, "calendar pending-claim disable completes")
            check(await oldProvider.workState().isIdle, "calendar pending-claim disable owns no work")

            let replacementSource = ManualCalendarSource(authorization: .fullAccess)
            let replacementMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-claim-disable-replacement",
                title: "CALENDAR CLAIM DISABLE REPLACEMENT",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(180)
            )
            await replacementSource.setMeeting(replacementMeeting)
            let replacement = CalendarGlanceProvider(
                broker: broker,
                source: replacementSource,
                clock: ManualGlanceClock(now: now)
            )
            await replacement.enable()
            let replacementSnapshot = await broker.snapshot()
            check(
                replacementSnapshot.current?.activity.presentation.title
                    == "CALENDAR CLAIM DISABLE REPLACEMENT",
                "calendar successor is visible before old claim release"
            )
            let pendingWork = await broker.workState()
            check(
                pendingWork.activeOwnershipCount == 1
                    && pendingWork.pendingOwnershipIntentCount == 0,
                "calendar disable retires its delayed intent while retaining the successor"
            )

            await broker.releaseClaim()
            await oldEnable.value
            check(
                await waitUntil { await broker.claimCompletionCount == 2 },
                "calendar delayed old claim settles"
            )
            check(await broker.lastClaimAccepted == false, "calendar delayed old claim is rejected")
            check(
                await broker.snapshot() == replacementSnapshot,
                "calendar rejected old claim performs no record mutation"
            )
            await replacement.disable()
            let finalWork = await broker.workState()
            check(
                finalWork.activeOwnershipCount == 0
                    && finalWork.pendingOwnershipIntentCount == 0,
                "calendar claim-disable cleanup releases all admission state"
            )
        } catch {
            recordUnexpected(error, context: "calendar gated old claim versus disable")
        }

        do {
            let broker = GatedGlanceBroker()
            var oldProvider: CalendarGlanceProvider? = CalendarGlanceProvider(
                broker: broker,
                source: ManualCalendarSource(authorization: .fullAccess),
                clock: ManualGlanceClock(now: now)
            )
            let weakOldProvider = WeakProviderReference(oldProvider!)
            await broker.gateNextClaim()
            let oldEnable = Task { [weak provider = oldProvider] in
                await provider?.enable()
            }
            check(
                await waitUntil { await broker.claimPending },
                "calendar drop gates old claim after synchronous intent admission"
            )
            oldProvider = nil

            let replacementSource = ManualCalendarSource(authorization: .fullAccess)
            let replacementMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-claim-drop-replacement",
                title: "CALENDAR CLAIM DROP REPLACEMENT",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(180)
            )
            await replacementSource.setMeeting(replacementMeeting)
            let replacement = CalendarGlanceProvider(
                broker: broker,
                source: replacementSource,
                clock: ManualGlanceClock(now: now)
            )
            await replacement.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "CALENDAR CLAIM DROP REPLACEMENT",
                "calendar drop successor is visible before old claim release"
            )
            await replacement.disable()
            let releasedSnapshot = await broker.snapshot()
            let retainedWork = await broker.workState()
            check(
                retainedWork.activeOwnershipCount == 1
                    && retainedWork.pendingOwnershipIntentCount == 1,
                "calendar released successor retains bounded stale-claim high-water"
            )

            await broker.releaseClaim()
            await oldEnable.value
            check(
                await waitUntil { weakOldProvider.isReleased },
                "calendar dropped old provider releases after claim rejection"
            )
            check(await broker.lastClaimAccepted == false, "calendar dropped old claim is rejected")
            check(
                await broker.snapshot() == releasedSnapshot,
                "calendar dropped old claim cannot mutate after successor release"
            )
            let prunedWork = await broker.workState()
            check(
                prunedWork.activeOwnershipCount == 0
                    && prunedWork.pendingOwnershipIntentCount == 0,
                "calendar stale high-water prunes after old claim settles"
            )

            let freshSource = ManualCalendarSource(authorization: .fullAccess)
            let freshMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-claim-fresh",
                title: "CALENDAR FRESH CLAIM",
                startDate: now.addingTimeInterval(90),
                endDate: now.addingTimeInterval(210)
            )
            await freshSource.setMeeting(freshMeeting)
            let fresh = CalendarGlanceProvider(
                broker: broker,
                source: freshSource,
                clock: ManualGlanceClock(now: now)
            )
            await fresh.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "CALENDAR FRESH CLAIM",
                "calendar capacity is reusable after stale high-water pruning"
            )
            await fresh.disable()
            check(
                await broker.workState().activeOwnershipCount == 0,
                "calendar fresh claim releases reusable capacity"
            )
        } catch {
            recordUnexpected(error, context: "calendar gated old claim versus drop")
        }

        do {
            let broker = GatedGlanceBroker()
            let oldTimer = try CountdownTimer(
                title: "Countdown pending claim disable",
                startedAt: now,
                endsAt: now.addingTimeInterval(120)
            )
            let oldProvider = CountdownGlanceProvider(
                broker: broker,
                clock: ManualGlanceClock(now: now)
            )
            await oldProvider.setCountdown(oldTimer)
            await broker.gateNextClaim()
            let oldEnable = Task { await oldProvider.enable() }
            check(
                await waitUntil { await broker.claimPending },
                "countdown disable gates old claim after synchronous intent admission"
            )
            await oldProvider.disable()
            check(await oldProvider.status() == .disabled, "countdown pending-claim disable completes")
            check(await oldProvider.workState().isIdle, "countdown pending-claim disable owns no work")

            let replacementTimer = try CountdownTimer(
                title: "COUNTDOWN CLAIM DISABLE REPLACEMENT",
                startedAt: now,
                endsAt: now.addingTimeInterval(180)
            )
            let replacement = CountdownGlanceProvider(
                broker: broker,
                clock: ManualGlanceClock(now: now)
            )
            await replacement.setCountdown(replacementTimer)
            await replacement.enable()
            let replacementSnapshot = await broker.snapshot()
            check(
                replacementSnapshot.current?.activity.presentation.title
                    == "COUNTDOWN CLAIM DISABLE REPLACEMENT",
                "countdown successor is visible before old claim release"
            )
            let pendingWork = await broker.workState()
            check(
                pendingWork.activeOwnershipCount == 1
                    && pendingWork.pendingOwnershipIntentCount == 0,
                "countdown disable retires its delayed intent while retaining the successor"
            )

            await broker.releaseClaim()
            await oldEnable.value
            check(
                await waitUntil { await broker.claimCompletionCount == 2 },
                "countdown delayed old claim settles"
            )
            check(await broker.lastClaimAccepted == false, "countdown delayed old claim is rejected")
            check(
                await broker.snapshot() == replacementSnapshot,
                "countdown rejected old claim performs no record mutation"
            )
            await replacement.disable()
            let finalWork = await broker.workState()
            check(
                finalWork.activeOwnershipCount == 0
                    && finalWork.pendingOwnershipIntentCount == 0,
                "countdown claim-disable cleanup releases all admission state"
            )
        } catch {
            recordUnexpected(error, context: "countdown gated old claim versus disable")
        }

        do {
            let broker = GatedGlanceBroker()
            let oldTimer = try CountdownTimer(
                title: "Countdown pending claim drop",
                startedAt: now,
                endsAt: now.addingTimeInterval(120)
            )
            var oldProvider: CountdownGlanceProvider? = CountdownGlanceProvider(
                broker: broker,
                clock: ManualGlanceClock(now: now)
            )
            await oldProvider?.setCountdown(oldTimer)
            let weakOldProvider = WeakProviderReference(oldProvider!)
            await broker.gateNextClaim()
            let oldEnable = Task { [weak provider = oldProvider] in
                await provider?.enable()
            }
            check(
                await waitUntil { await broker.claimPending },
                "countdown drop gates old claim after synchronous intent admission"
            )
            oldProvider = nil

            let replacementTimer = try CountdownTimer(
                title: "COUNTDOWN CLAIM DROP REPLACEMENT",
                startedAt: now,
                endsAt: now.addingTimeInterval(180)
            )
            let replacement = CountdownGlanceProvider(
                broker: broker,
                clock: ManualGlanceClock(now: now)
            )
            await replacement.setCountdown(replacementTimer)
            await replacement.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "COUNTDOWN CLAIM DROP REPLACEMENT",
                "countdown drop successor is visible before old claim release"
            )
            await replacement.disable()
            let releasedSnapshot = await broker.snapshot()
            let retainedWork = await broker.workState()
            check(
                retainedWork.activeOwnershipCount == 1
                    && retainedWork.pendingOwnershipIntentCount == 1,
                "countdown released successor retains bounded stale-claim high-water"
            )

            await broker.releaseClaim()
            await oldEnable.value
            check(
                await waitUntil { weakOldProvider.isReleased },
                "countdown dropped old provider releases after claim rejection"
            )
            check(await broker.lastClaimAccepted == false, "countdown dropped old claim is rejected")
            check(
                await broker.snapshot() == releasedSnapshot,
                "countdown dropped old claim cannot mutate after successor release"
            )
            let prunedWork = await broker.workState()
            check(
                prunedWork.activeOwnershipCount == 0
                    && prunedWork.pendingOwnershipIntentCount == 0,
                "countdown stale high-water prunes after old claim settles"
            )

            let freshTimer = try CountdownTimer(
                title: "COUNTDOWN FRESH CLAIM",
                startedAt: now,
                endsAt: now.addingTimeInterval(210)
            )
            let fresh = CountdownGlanceProvider(
                broker: broker,
                clock: ManualGlanceClock(now: now)
            )
            await fresh.setCountdown(freshTimer)
            await fresh.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "COUNTDOWN FRESH CLAIM",
                "countdown capacity is reusable after stale high-water pruning"
            )
            await fresh.disable()
            check(
                await broker.workState().activeOwnershipCount == 0,
                "countdown fresh claim releases reusable capacity"
            )
        } catch {
            recordUnexpected(error, context: "countdown gated old claim versus drop")
        }
    }

    mutating func verifyDisableDeinitOverlap() async {
        let now = Date(timeIntervalSinceReferenceDate: 57_000)

        do {
            let source = ManualCalendarSource(authorization: .fullAccess)
            let clock = ManualGlanceClock(now: now)
            let broker = GatedGlanceBroker()
            let meeting = try CalendarMeeting(
                eventIdentifier: "calendar-disable-drop",
                title: "Calendar disable drop",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(180)
            )
            await source.setMeeting(meeting)
            var provider: CalendarGlanceProvider? = CalendarGlanceProvider(
                broker: broker,
                source: source,
                clock: clock
            )
            await provider?.enable()
            let weakProvider = WeakProviderReference(provider!)
            await broker.gateNextCancel()
            let disable = Task { [provider] in
                await provider?.disable()
            }
            check(
                await waitUntil { await broker.cancelPending },
                "calendar disable-drop overlap gates explicit terminal clear"
            )
            let oldRevision = await broker.gatedConditionalExpectedRevision
            check(
                await broker.gatedConditionalComparisonMatched,
                "calendar disable gate observes the old revision before replacement"
            )
            provider = nil
            check(!weakProvider.isReleased, "calendar explicit disable owns provider until its drain completes")

            let replacementSource = ManualCalendarSource(authorization: .fullAccess)
            let replacementClock = ManualGlanceClock(now: now)
            let replacementMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-disable-replacement",
                title: "Calendar disable replacement survives",
                startDate: now.addingTimeInterval(90),
                endDate: now.addingTimeInterval(210)
            )
            await replacementSource.setMeeting(replacementMeeting)
            let replacement = CalendarGlanceProvider(
                broker: broker,
                source: replacementSource,
                clock: replacementClock
            )
            await replacement.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "Calendar disable replacement survives",
                "calendar replacement publishes during old disable/deinit overlap"
            )
            check(
                await broker.snapshot().current?.revision != oldRevision,
                "calendar disable replacement advances the broker revision"
            )
            await broker.releaseCancel()
            await disable.value
            check(
                await waitUntil { weakProvider.isReleased },
                "calendar provider releases after explicit disable drain"
            )
            await yieldSeveralTimes()
            check(await broker.cancelCallCount == 1, "calendar deinit does not duplicate old explicit clear")
            check(
                await broker.lastConditionalCancelResult == false,
                "calendar old disable removal fails closed after replacement"
            )
            check(await source.stopCount == 1, "calendar deinit does not duplicate explicit source stop")
            check(!(await source.isActive), "calendar disable-drop overlap leaves no observer")
            check(await clock.pendingCount == 0, "calendar disable-drop overlap leaves no boundary")
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "Calendar disable replacement survives",
                "calendar old disable cannot erase replacement revision"
            )
            await replacement.disable()
            check(await broker.cancelCallCount == 2, "calendar replacement clears only its own revision")
            check(await broker.snapshot().ordered.isEmpty, "calendar replacement disable leaves no activity")
            check(await replacement.workState().isIdle, "calendar replacement disable drains work")
        } catch {
            recordUnexpected(error, context: "calendar disable/deinit overlap")
        }

        do {
            let clock = ManualGlanceClock(now: now)
            let broker = GatedGlanceBroker()
            let timer = try CountdownTimer(
                title: "Countdown disable drop",
                startedAt: now,
                endsAt: now.addingTimeInterval(120)
            )
            var provider: CountdownGlanceProvider? = CountdownGlanceProvider(
                broker: broker,
                clock: clock
            )
            await provider?.setCountdown(timer)
            await provider?.enable()
            let weakProvider = WeakProviderReference(provider!)
            await broker.gateNextCancel()
            let disable = Task { [provider] in
                await provider?.disable()
            }
            check(
                await waitUntil { await broker.cancelPending },
                "countdown disable-drop overlap gates explicit terminal clear"
            )
            let oldRevision = await broker.gatedConditionalExpectedRevision
            check(
                await broker.gatedConditionalComparisonMatched,
                "countdown disable gate observes the old revision before replacement"
            )
            provider = nil
            check(!weakProvider.isReleased, "countdown explicit disable owns provider until its drain completes")

            let replacementClock = ManualGlanceClock(now: now)
            let replacementTimer = try CountdownTimer(
                title: "Countdown disable replacement survives",
                startedAt: now,
                endsAt: now.addingTimeInterval(180)
            )
            let replacement = CountdownGlanceProvider(
                broker: broker,
                clock: replacementClock
            )
            await replacement.setCountdown(replacementTimer)
            await replacement.enable()
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "Countdown disable replacement survives",
                "countdown replacement publishes during old disable/deinit overlap"
            )
            check(
                await broker.snapshot().current?.revision != oldRevision,
                "countdown disable replacement advances the broker revision"
            )
            await broker.releaseCancel()
            await disable.value
            check(
                await waitUntil { weakProvider.isReleased },
                "countdown provider releases after explicit disable drain"
            )
            await yieldSeveralTimes()
            check(await broker.cancelCallCount == 1, "countdown deinit does not duplicate old explicit clear")
            check(
                await broker.lastConditionalCancelResult == false,
                "countdown old disable removal fails closed after replacement"
            )
            check(await clock.pendingCount == 0, "countdown disable-drop overlap leaves no boundary")
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "Countdown disable replacement survives",
                "countdown old disable cannot erase replacement revision"
            )
            await replacement.disable()
            check(await broker.cancelCallCount == 2, "countdown replacement clears only its own revision")
            check(await broker.snapshot().ordered.isEmpty, "countdown replacement disable leaves no activity")
            check(await replacement.workState().isIdle, "countdown replacement disable drains work")
        } catch {
            recordUnexpected(error, context: "countdown disable/deinit overlap")
        }
    }

    mutating func verifyUnleasedReplacementFencing() async {
        let now = Date(timeIntervalSinceReferenceDate: 57_500)

        do {
            let broker = GatedGlanceBroker()
            let source = ManualCalendarSource(authorization: .fullAccess)
            let clock = ManualGlanceClock(now: now)
            let ownedMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-owned-disable",
                title: "Calendar owned before public replacement",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(180)
            )
            await source.setMeeting(ownedMeeting)
            let provider = CalendarGlanceProvider(
                broker: broker,
                source: source,
                clock: clock
            )
            await provider.enable()

            let publicMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-public-disable",
                title: "CALENDAR PUBLIC DISABLE SURVIVES",
                startDate: now.addingTimeInterval(90),
                endDate: now.addingTimeInterval(210)
            )
            _ = try await broker.submit(
                GlanceRequestFactory.meeting(publicMeeting, now: now)
            )
            check(
                await broker.workState().activeOwnershipCount == 0,
                "calendar public replacement invalidates provider admission"
            )
            await provider.disable()
            check(
                await broker.lastConditionalCancelResult == false,
                "calendar disable cannot cancel a later unleased record"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "CALENDAR PUBLIC DISABLE SURVIVES",
                "calendar unleased replacement survives old disable"
            )
            check(await provider.workState().isIdle, "calendar public replacement disable drains work")
            check(!(await source.isActive), "calendar public replacement disable stops observation")
            check(await clock.pendingCount == 0, "calendar public replacement disable stops its boundary")
            if let identity = await broker.snapshot().current?.activity.identity {
                _ = await broker.cancel(identity)
            }
            check(await broker.snapshot().ordered.isEmpty, "calendar public replacement fixture cleans up")
        } catch {
            recordUnexpected(error, context: "calendar unleased replacement versus disable")
        }

        do {
            let broker = GatedGlanceBroker()
            let source = ManualCalendarSource(authorization: .fullAccess)
            let clock = ManualGlanceClock(now: now)
            let ownedMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-owned-drop",
                title: "Calendar owned before public drop",
                startDate: now.addingTimeInterval(60),
                endDate: now.addingTimeInterval(180)
            )
            await source.setMeeting(ownedMeeting)
            var provider: CalendarGlanceProvider? = CalendarGlanceProvider(
                broker: broker,
                source: source,
                clock: clock
            )
            await provider?.enable()

            let publicMeeting = try CalendarMeeting(
                eventIdentifier: "calendar-public-drop",
                title: "CALENDAR PUBLIC DROP SURVIVES",
                startDate: now.addingTimeInterval(90),
                endDate: now.addingTimeInterval(210)
            )
            _ = try await broker.submit(
                GlanceRequestFactory.meeting(publicMeeting, now: now)
            )
            let weakProvider = WeakProviderReference(provider!)
            provider = nil
            check(
                await waitUntil { weakProvider.isReleased },
                "calendar owner releases after an unleased replacement"
            )
            check(
                await waitUntil { await broker.conditionalCancelCompletionCount == 1 },
                "calendar detached old cleanup settles after public replacement"
            )
            check(
                await broker.lastConditionalCancelResult == false,
                "calendar detached cleanup cannot cancel an unleased record"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "CALENDAR PUBLIC DROP SURVIVES",
                "calendar unleased replacement survives old deinit"
            )
            check(!(await source.isActive), "calendar public replacement deinit stops observation")
            check(
                await waitUntil { await clock.pendingCount == 0 },
                "calendar public replacement deinit stops its boundary"
            )
            check(
                await broker.workState().activeOwnershipCount == 0,
                "calendar public replacement deinit leaves no admission generation"
            )
            if let identity = await broker.snapshot().current?.activity.identity {
                _ = await broker.cancel(identity)
            }
            check(await broker.snapshot().ordered.isEmpty, "calendar public drop fixture cleans up")
        } catch {
            recordUnexpected(error, context: "calendar unleased replacement versus deinit")
        }

        do {
            let broker = GatedGlanceBroker()
            let clock = ManualGlanceClock(now: now)
            let ownedTimer = try CountdownTimer(
                title: "Countdown owned before public replacement",
                startedAt: now,
                endsAt: now.addingTimeInterval(120)
            )
            let provider = CountdownGlanceProvider(broker: broker, clock: clock)
            await provider.setCountdown(ownedTimer)
            await provider.enable()

            let publicTimer = try CountdownTimer(
                title: "COUNTDOWN PUBLIC DISABLE SURVIVES",
                startedAt: now,
                endsAt: now.addingTimeInterval(180)
            )
            _ = try await broker.submit(
                GlanceRequestFactory.countdown(publicTimer, now: now)
            )
            check(
                await broker.workState().activeOwnershipCount == 0,
                "countdown public replacement invalidates provider admission"
            )
            await provider.disable()
            check(
                await broker.lastConditionalCancelResult == false,
                "countdown disable cannot cancel a later unleased record"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "COUNTDOWN PUBLIC DISABLE SURVIVES",
                "countdown unleased replacement survives old disable"
            )
            check(await provider.workState().isIdle, "countdown public replacement disable drains work")
            check(await clock.pendingCount == 0, "countdown public replacement disable stops its boundary")
            if let identity = await broker.snapshot().current?.activity.identity {
                _ = await broker.cancel(identity)
            }
            check(await broker.snapshot().ordered.isEmpty, "countdown public replacement fixture cleans up")
        } catch {
            recordUnexpected(error, context: "countdown unleased replacement versus disable")
        }

        do {
            let broker = GatedGlanceBroker()
            let clock = ManualGlanceClock(now: now)
            let ownedTimer = try CountdownTimer(
                title: "Countdown owned before public drop",
                startedAt: now,
                endsAt: now.addingTimeInterval(120)
            )
            var provider: CountdownGlanceProvider? = CountdownGlanceProvider(
                broker: broker,
                clock: clock
            )
            await provider?.setCountdown(ownedTimer)
            await provider?.enable()

            let publicTimer = try CountdownTimer(
                title: "COUNTDOWN PUBLIC DROP SURVIVES",
                startedAt: now,
                endsAt: now.addingTimeInterval(180)
            )
            _ = try await broker.submit(
                GlanceRequestFactory.countdown(publicTimer, now: now)
            )
            let weakProvider = WeakProviderReference(provider!)
            provider = nil
            check(
                await waitUntil { weakProvider.isReleased },
                "countdown owner releases after an unleased replacement"
            )
            check(
                await waitUntil { await broker.conditionalCancelCompletionCount == 1 },
                "countdown detached old cleanup settles after public replacement"
            )
            check(
                await broker.lastConditionalCancelResult == false,
                "countdown detached cleanup cannot cancel an unleased record"
            )
            check(
                await broker.snapshot().current?.activity.presentation.title
                    == "COUNTDOWN PUBLIC DROP SURVIVES",
                "countdown unleased replacement survives old deinit"
            )
            check(
                await waitUntil { await clock.pendingCount == 0 },
                "countdown public replacement deinit stops its boundary"
            )
            check(
                await broker.workState().activeOwnershipCount == 0,
                "countdown public replacement deinit leaves no admission generation"
            )
            if let identity = await broker.snapshot().current?.activity.identity {
                _ = await broker.cancel(identity)
            }
            check(await broker.snapshot().ordered.isEmpty, "countdown public drop fixture cleans up")
        } catch {
            recordUnexpected(error, context: "countdown unleased replacement versus deinit")
        }
    }

    mutating func verifyLifecycleStress() async {
        let broker = makeBroker()
        let powerSource = ManualPowerSource()
        let calendarSource = ManualCalendarSource(authorization: .fullAccess)
        let clock = ManualGlanceClock(now: Date(timeIntervalSinceReferenceDate: 58_000))
        let power = PowerGlanceProvider(broker: broker, source: powerSource)
        let calendar = CalendarGlanceProvider(broker: broker, source: calendarSource, clock: clock)

        for cycle in 0..<50 {
            let firstPowerEnable = Task { await power.enable() }
            let secondPowerEnable = Task { await power.enable() }
            let firstCalendarEnable = Task { await calendar.enable() }
            let secondCalendarEnable = Task { await calendar.enable() }
            await firstPowerEnable.value
            await secondPowerEnable.value
            await firstCalendarEnable.value
            await secondCalendarEnable.value

            check(await powerSource.startCount == cycle + 1, "power stress cycle owns no duplicate observer")
            check(await calendarSource.startCount == cycle + 1, "calendar stress cycle owns no duplicate observer")
            check(await power.workState().activeConsumerTaskCount == 1, "power stress cycle owns one consumer")
            check(await calendar.workState().activeConsumerTaskCount == 1, "calendar stress cycle owns one consumer")
            check(
                await broker.workState().activeOwnershipCount == 1,
                "calendar rapid re-enable owns one bounded admission generation"
            )

            let firstPowerDisable = Task { await power.disable() }
            let secondPowerDisable = Task { await power.disable() }
            let firstCalendarDisable = Task { await calendar.disable() }
            let secondCalendarDisable = Task { await calendar.disable() }
            await firstPowerDisable.value
            await secondPowerDisable.value
            await firstCalendarDisable.value
            await secondCalendarDisable.value

            check(await power.workState().isIdle, "power stress disable fully drains")
            check(await calendar.workState().isIdle, "calendar stress disable fully drains")
            check(
                await broker.workState().activeOwnershipCount == 0,
                "calendar rapid disable prunes its admission generation"
            )
        }
        check(await powerSource.stopCount == 50, "power stress cycles stop every observer exactly once")
        check(await calendarSource.stopCount == 50, "calendar stress cycles stop every observer exactly once")
        check(await calendarSource.permissionRequestCount == 0, "calendar stress restore cycles never request permission")
    }

    mutating func verifyNormalizedFailureHealth() async {
        let powerSource = ManualPowerSource(failStart: true)
        let power = PowerGlanceProvider(broker: makeBroker(), source: powerSource)
        await power.enable()
        check(await power.status().capability == .unavailable, "observer registration failure reports unavailable capability")
        check(
            await power.status().health == .unavailable(.eventSourceUnavailable),
            "observer registration error is normalized"
        )
        check(await power.workState().isIdle, "failed observer registration owns no work")
        check(await powerSource.stopCallCount >= 1, "failed start performs defensive source cleanup")

        let calendarSource = ManualCalendarSource(authorization: .fullAccess, failQueries: true)
        let calendar = CalendarGlanceProvider(broker: makeBroker(), source: calendarSource, clock: ManualGlanceClock())
        await calendar.enable()
        check(
            await calendar.status().health == .degraded(.sourceQueryFailed),
            "calendar query error is normalized without exposing external text"
        )
        await calendar.disable()

        let permissionSource = ManualCalendarSource(
            authorization: .notDetermined,
            failPermissionRequest: true
        )
        let permission = CalendarGlanceProvider(broker: makeBroker(), source: permissionSource, clock: ManualGlanceClock())
        await permission.enable()
        check(
            await permission.status().health == .healthy,
            "prompt-free calendar enable reports healthy idle machinery"
        )
        do {
            _ = try await permission.requestFullAccess()
            check(false, "explicit permission failure throws a normalized error")
        } catch {
            check(error == .requestFailed, "explicit permission failure returns a typed normalized error")
        }
        check(
            await permission.status().health == .unavailable(.permissionRequestFailed),
            "permission request error is normalized"
        )
        check(await permissionSource.startCount == 0, "permission failure starts no observer")
    }

    private func makeBroker() -> ActivityBroker {
        ActivityBroker(expirationScheduler: ManualBrokerScheduler())
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            if await condition() { return true }
            try? await clock.sleep(for: .milliseconds(1))
        } while clock.now < deadline
        return false
    }

    private func yieldSeveralTimes() async {
        for _ in 0..<40 {
            await Task.yield()
        }
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
            print("Glance harness passed: \(checkCount) checks.")
            exit(EXIT_SUCCESS)
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        fputs("Glance harness failed: \(failures.count) of \(checkCount) checks.\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private actor CompletionFlag {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

private final class RelayPendingDeliveryGate: @unchecked Sendable {
    private let paused = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func pause() {
        paused.signal()
        resume.wait()
    }

    func waitUntilPaused() -> Bool {
        paused.wait(timeout: .now() + 1) == .success
    }

    func release() {
        resume.signal()
    }
}

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock { storage = true }
    }
}

private actor NaturalCompletionGate {
    private(set) var didStart = false
    private(set) var completedTimer: CountdownTimer?
    private(set) var completedOperationIdentity: CountdownOperationIdentity?
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(_ completion: CountdownNaturalCompletion) async {
        didStart = true
        completedTimer = completion.countdown
        completedOperationIdentity = completion.operationIdentity
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class WeakProviderReference<Value: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }

    var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == nil
    }
}

private actor LegacyGlanceBroker: GlanceActivityBroker {
    private let broker = ActivityBroker(expirationScheduler: ManualBrokerScheduler())
    private(set) var submitCallCount = 0
    private(set) var cancelCallCount = 0

    func submit(_ request: ActivityRequest) async throws -> ActivityBrokerSnapshot {
        submitCallCount += 1
        return try await broker.submit(request)
    }

    func cancel(_ identity: ActivityIdentity) async -> Bool {
        cancelCallCount += 1
        return await broker.cancel(identity)
    }

    func snapshot() async -> ActivityBrokerSnapshot {
        await broker.snapshot()
    }
}

private actor GatedGlanceBroker: GlanceOwnershipActivityBroker, GlanceRevisionActivityBroker {
    private let broker = ActivityBroker(expirationScheduler: ManualBrokerScheduler())
    private var shouldGateClaim = false
    private var shouldGateSubmit = false
    private var shouldGateCancel = false
    private var shouldGateRelease = false
    private var claimContinuation: CheckedContinuation<Void, Never>?
    private var submitContinuation: CheckedContinuation<Void, Never>?
    private var cancelContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var claimCallCount = 0
    private(set) var claimCompletionCount = 0
    private(set) var lastClaimAccepted: Bool?
    private(set) var submitCallCount = 0
    private(set) var ownedSubmitCompletionCount = 0
    private(set) var lastOwnedSubmitAccepted: Bool?
    private(set) var cancelCallCount = 0
    private(set) var conditionalCancelCompletionCount = 0
    private(set) var gatedConditionalExpectedRevision: UInt64?
    private(set) var gatedConditionalComparisonMatched = false
    private(set) var lastConditionalCancelResult: Bool?

    var claimPending: Bool { claimContinuation != nil }
    var submitPending: Bool { submitContinuation != nil }
    var cancelPending: Bool { cancelContinuation != nil }
    var releasePending: Bool { releaseContinuation != nil }
    var physicalCallCount: Int { submitCallCount + cancelCallCount }

    nonisolated var ownershipCoordinator: ActivityOwnershipCoordinator {
        broker.ownershipCoordinator
    }

    func claimOwnership(
        of identity: ActivityIdentity,
        admitting intent: ActivityOwnershipClaimIntent
    ) async -> ActivityOwnershipLease? {
        claimCallCount += 1
        if shouldGateClaim {
            shouldGateClaim = false
            await withCheckedContinuation { continuation in
                claimContinuation = continuation
            }
        }
        let lease = await broker.claimOwnership(of: identity, admitting: intent)
        lastClaimAccepted = lease != nil
        claimCompletionCount += 1
        return lease
    }

    func releaseOwnership(_ lease: ActivityOwnershipLease) async -> Bool {
        if shouldGateRelease {
            shouldGateRelease = false
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return await broker.releaseOwnership(lease)
    }

    func gateNextRelease() {
        shouldGateRelease = true
    }

    func releaseRelease() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func gateNextClaim() {
        shouldGateClaim = true
    }

    func releaseClaim() {
        claimContinuation?.resume()
        claimContinuation = nil
    }

    func gateNextSubmit() {
        shouldGateSubmit = true
    }

    func gateNextCancel() {
        shouldGateCancel = true
    }

    func releaseSubmit() {
        submitContinuation?.resume()
        submitContinuation = nil
    }

    func releaseCancel() {
        cancelContinuation?.resume()
        cancelContinuation = nil
    }

    func submit(_ request: ActivityRequest) async throws -> ActivityBrokerSnapshot {
        submitCallCount += 1
        if shouldGateSubmit {
            shouldGateSubmit = false
            await withCheckedContinuation { continuation in
                submitContinuation = continuation
            }
        }
        return try await broker.submit(request)
    }

    func submit(
        _ request: ActivityRequest,
        ifOwnedBy lease: ActivityOwnershipLease
    ) async throws -> ActivityBrokerSnapshot? {
        submitCallCount += 1
        if shouldGateSubmit {
            shouldGateSubmit = false
            await withCheckedContinuation { continuation in
                submitContinuation = continuation
            }
        }
        let result = try await broker.submit(request, ifOwnedBy: lease)
        lastOwnedSubmitAccepted = result != nil
        ownedSubmitCompletionCount += 1
        return result
    }

    func cancel(_ identity: ActivityIdentity) async -> Bool {
        cancelCallCount += 1
        if shouldGateCancel {
            shouldGateCancel = false
            await withCheckedContinuation { continuation in
                cancelContinuation = continuation
            }
        }
        return await broker.cancel(identity)
    }

    func cancel(_ identity: ActivityIdentity, ifRevision revision: UInt64) async -> Bool {
        cancelCallCount += 1
        if shouldGateCancel {
            shouldGateCancel = false
            let comparedRevision = await broker.snapshot().ordered.first {
                $0.activity.identity == identity
            }?.revision
            gatedConditionalExpectedRevision = revision
            gatedConditionalComparisonMatched = comparedRevision == revision
            await withCheckedContinuation { continuation in
                cancelContinuation = continuation
            }
        }
        let result = await broker.cancel(identity, ifRevision: revision)
        lastConditionalCancelResult = result
        conditionalCancelCompletionCount += 1
        return result
    }

    func cancel(
        _ identity: ActivityIdentity,
        ifOwnedBy lease: ActivityOwnershipLease
    ) async -> Bool {
        cancelCallCount += 1
        if shouldGateCancel {
            shouldGateCancel = false
            let comparedRevision = await broker.snapshot().ordered.first {
                $0.activity.identity == identity
            }?.revision
            gatedConditionalExpectedRevision = comparedRevision
            gatedConditionalComparisonMatched = comparedRevision != nil
            await withCheckedContinuation { continuation in
                cancelContinuation = continuation
            }
        }
        let result = await broker.cancel(identity, ifOwnedBy: lease)
        lastConditionalCancelResult = result
        conditionalCancelCompletionCount += 1
        return result
    }

    func snapshot() async -> ActivityBrokerSnapshot {
        await broker.snapshot()
    }

    func workState() async -> ActivityBrokerWorkState {
        await broker.workState()
    }
}

private actor CancellationRecordingBroker: GlanceOwnershipActivityBroker, GlanceRevisionActivityBroker {
    private let broker = ActivityBroker(expirationScheduler: ManualBrokerScheduler())
    private(set) var physicalCallCount = 0
    private(set) var cancelObservedCancellation = false

    nonisolated var ownershipCoordinator: ActivityOwnershipCoordinator {
        broker.ownershipCoordinator
    }

    func claimOwnership(
        of identity: ActivityIdentity,
        admitting intent: ActivityOwnershipClaimIntent
    ) async -> ActivityOwnershipLease? {
        await broker.claimOwnership(of: identity, admitting: intent)
    }

    func releaseOwnership(_ lease: ActivityOwnershipLease) async -> Bool {
        await broker.releaseOwnership(lease)
    }

    func submit(_ request: ActivityRequest) async throws -> ActivityBrokerSnapshot {
        physicalCallCount += 1
        return try await broker.submit(request)
    }

    func submit(
        _ request: ActivityRequest,
        ifOwnedBy lease: ActivityOwnershipLease
    ) async throws -> ActivityBrokerSnapshot? {
        physicalCallCount += 1
        return try await broker.submit(request, ifOwnedBy: lease)
    }

    func cancel(_ identity: ActivityIdentity) async -> Bool {
        physicalCallCount += 1
        cancelObservedCancellation = cancelObservedCancellation || Task.isCancelled
        return await broker.cancel(identity)
    }

    func cancel(_ identity: ActivityIdentity, ifRevision revision: UInt64) async -> Bool {
        physicalCallCount += 1
        cancelObservedCancellation = cancelObservedCancellation || Task.isCancelled
        return await broker.cancel(identity, ifRevision: revision)
    }

    func cancel(
        _ identity: ActivityIdentity,
        ifOwnedBy lease: ActivityOwnershipLease
    ) async -> Bool {
        physicalCallCount += 1
        cancelObservedCancellation = cancelObservedCancellation || Task.isCancelled
        return await broker.cancel(identity, ifOwnedBy: lease)
    }

    func snapshot() async -> ActivityBrokerSnapshot {
        await broker.snapshot()
    }
}

private actor ManualPowerSource: PowerEventSource {
    typealias Handler = @Sendable (PowerSourceEvent) -> Void

    private let failStart: Bool
    private var handlers: [Handler] = []
    private var activeHandlerIndex: Int?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var stopCallCount = 0
    private(set) var stopObservedCancellation = false

    init(failStart: Bool = false) {
        self.failStart = failStart
    }

    var handlerCount: Int { handlers.count }

    func start(handler: @escaping Handler) async throws {
        startCount += 1
        if failStart { throw GlanceEventSourceError.observerRegistrationFailed }
        handlers.append(handler)
        activeHandlerIndex = handlers.count - 1
    }

    func stop() async {
        stopObservedCancellation = stopObservedCancellation || Task.isCancelled
        stopCallCount += 1
        guard activeHandlerIndex != nil else { return }
        stopCount += 1
        activeHandlerIndex = nil
    }

    func emit(_ event: PowerSourceEvent, handlerIndex: Int? = nil) {
        guard let index = handlerIndex ?? activeHandlerIndex,
              handlers.indices.contains(index) else { return }
        handlers[index](event)
    }
}

private actor ManualVolumeSource: VolumeEventSource {
    typealias Handler = @Sendable (VolumeSourceEvent) -> Void

    private var handler: Handler?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var stopObservedCancellation = false
    private let initialEvent: VolumeSourceEvent?

    init(initialEvent: VolumeSourceEvent? = nil) {
        self.initialEvent = initialEvent
    }

    var isActive: Bool { handler != nil }

    func start(handler: @escaping Handler) async throws {
        guard self.handler == nil else { return }
        startCount += 1
        self.handler = handler
        if let initialEvent {
            handler(initialEvent)
        }
    }

    func stop() async {
        stopObservedCancellation = stopObservedCancellation || Task.isCancelled
        guard handler != nil else { return }
        stopCount += 1
        handler = nil
    }

    func emit(_ event: VolumeSourceEvent) {
        handler?(event)
    }

    func emitFlood(count: Int) {
        guard let handler else { return }
        for index in 0..<count {
            let scalar = Double(index % 101) / 100
            if let snapshot = try? VolumeSnapshot(
                deviceID: UInt32(index % 3 + 1),
                scalar: scalar,
                isMuted: index.isMultiple(of: 17)
            ) {
                handler(.snapshot(snapshot))
            }
        }
    }
}

private enum CalendarClearScenario: CaseIterable, Equatable {
    case noMeeting
    case distantMeeting
    case queryFailure

    var label: String {
        switch self {
        case .noMeeting:
            "nil meeting"
        case .distantMeeting:
            "distant meeting"
        case .queryFailure:
            "query failure"
        }
    }
}

private actor ManualCalendarSource: CalendarEventSource {
    typealias Handler = @Sendable (CalendarSourceEvent) -> Void

    private var authorization: CalendarAuthorization
    private let authorizationAfterRequest: CalendarAuthorization
    private let requestResult: Bool
    private let failPermissionRequest: Bool
    private let failStart: Bool
    private var failQueries: Bool
    private var meeting: CalendarMeeting?
    private var handler: Handler?
    private var handlers: [Handler] = []
    private(set) var permissionRequestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var queryCount = 0
    private(set) var stopObservedCancellation = false

    var isActive: Bool { handler != nil }

    init(
        authorization: CalendarAuthorization = .fullAccess,
        authorizationAfterRequest: CalendarAuthorization = .fullAccess,
        requestResult: Bool = true,
        failPermissionRequest: Bool = false,
        failStart: Bool = false,
        failQueries: Bool = false
    ) {
        self.authorization = authorization
        self.authorizationAfterRequest = authorizationAfterRequest
        self.requestResult = requestResult
        self.failPermissionRequest = failPermissionRequest
        self.failStart = failStart
        self.failQueries = failQueries
    }

    func authorizationStatus() async -> CalendarAuthorization {
        authorization
    }

    func requestFullAccess() async throws -> Bool {
        permissionRequestCount += 1
        if failPermissionRequest { throw GlanceEventSourceError.permissionRequestFailed }
        authorization = authorizationAfterRequest
        return requestResult
    }

    func start(changeHandler: @escaping @Sendable () -> Void) async throws {
        try installHandler { _ in changeHandler() }
    }

    func start(eventHandler: @escaping Handler) async throws {
        try installHandler(eventHandler)
    }

    private func installHandler(_ eventHandler: @escaping Handler) throws {
        guard handler == nil else { return }
        startCount += 1
        if failStart { throw GlanceEventSourceError.observerRegistrationFailed }
        handler = eventHandler
        handlers.append(eventHandler)
    }

    func stop() async {
        stopObservedCancellation = stopObservedCancellation || Task.isCancelled
        guard handler != nil else { return }
        stopCount += 1
        handler = nil
    }

    func nextMeeting(after startDate: Date, until endDate: Date) async throws -> CalendarMeeting? {
        queryCount += 1
        if failQueries { throw GlanceEventSourceError.observerRegistrationFailed }
        guard let meeting,
              meeting.endDate > startDate,
              meeting.startDate < endDate else { return nil }
        return meeting
    }

    func setMeeting(_ meeting: CalendarMeeting?) {
        self.meeting = meeting
    }

    func setFailQueries(_ failQueries: Bool) {
        self.failQueries = failQueries
    }

    func emitChange() {
        handler?(.eventStoreChanged)
    }

    func emit(_ event: CalendarSourceEvent) {
        handler?(event)
    }

    func emitStale(_ event: CalendarSourceEvent, handlerIndex: Int = 0) {
        guard handlers.indices.contains(handlerIndex) else { return }
        handlers[handlerIndex](event)
    }
}

private actor DeferredPowerSource: PowerEventSource {
    typealias Handler = @Sendable (PowerSourceEvent) -> Void

    private var handler: Handler?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isActive = false

    var startPending: Bool { startContinuation != nil }
    var stopPending: Bool { stopContinuation != nil }

    func start(handler: @escaping Handler) async throws {
        self.handler = handler
        startCount += 1
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
        isActive = true
    }

    func stop() async {
        guard isActive else { return }
        isActive = false
        stopCount += 1
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func finishStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func finishStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func emitStale(_ event: PowerSourceEvent) {
        handler?(event)
    }
}

private actor DeferredVolumeSource: VolumeEventSource {
    typealias Handler = @Sendable (VolumeSourceEvent) -> Void

    private var handler: Handler?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isActive = false

    var startPending: Bool { startContinuation != nil }
    var stopPending: Bool { stopContinuation != nil }

    func start(handler: @escaping Handler) async throws {
        self.handler = handler
        startCount += 1
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
        isActive = true
    }

    func stop() async {
        guard isActive else { return }
        isActive = false
        stopCount += 1
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func finishStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func finishStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func emitStale(_ event: VolumeSourceEvent) {
        handler?(event)
    }
}

private actor DeferredPermissionCalendarSource: CalendarEventSource {
    private var authorization: CalendarAuthorization = .notDetermined
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    private(set) var permissionRequestCount = 0

    var requestPending: Bool { permissionContinuation != nil }

    func authorizationStatus() async -> CalendarAuthorization {
        authorization
    }

    func requestFullAccess() async throws -> Bool {
        permissionRequestCount += 1
        return await withCheckedContinuation { continuation in
            permissionContinuation = continuation
        }
    }

    func start(changeHandler: @escaping @Sendable () -> Void) async throws {}

    func stop() async {}

    func nextMeeting(after startDate: Date, until endDate: Date) async throws -> CalendarMeeting? {
        nil
    }

    func finishPermission(granted: Bool) {
        authorization = granted ? .fullAccess : .denied
        permissionContinuation?.resume(returning: granted)
        permissionContinuation = nil
    }
}

private actor DeferredCalendarSource: CalendarEventSource {
    typealias Handler = @Sendable () -> Void

    private var handler: Handler?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isActive = false

    var startPending: Bool { startContinuation != nil }
    var stopPending: Bool { stopContinuation != nil }

    func authorizationStatus() async -> CalendarAuthorization {
        .fullAccess
    }

    func requestFullAccess() async throws -> Bool {
        true
    }

    func start(changeHandler: @escaping Handler) async throws {
        handler = changeHandler
        startCount += 1
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
        isActive = true
    }

    func stop() async {
        guard isActive else { return }
        isActive = false
        stopCount += 1
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func nextMeeting(after startDate: Date, until endDate: Date) async throws -> CalendarMeeting? {
        nil
    }

    func finishStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func finishStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func emitStale() {
        handler?()
    }
}

private actor ManualGlanceClock: GlanceClock {
    private struct Waiter {
        let identifier: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var currentDate: Date
    private var waiters: [Waiter] = []
    private var cancelledBeforeRegistration: Set<UUID> = []
    private(set) var cancellationCount = 0
    private(set) var totalSleepCount = 0

    init(now: Date = Date(timeIntervalSinceReferenceDate: 60_000)) {
        currentDate = now
    }

    var pendingCount: Int { waiters.count }

    var pendingDeadlines: [Date] { waiters.map(\.deadline).sorted() }

    func now() async -> Date {
        currentDate
    }

    func sleep(until deadline: Date) async throws {
        if deadline <= currentDate { return }
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                totalSleepCount += 1
                if cancelledBeforeRegistration.remove(identifier) != nil {
                    cancellationCount += 1
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(
                        Waiter(
                            identifier: identifier,
                            deadline: deadline,
                            continuation: continuation
                        )
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(identifier) }
        }
    }

    func advance(to date: Date) {
        currentDate = date
        let ready = waiters.filter { $0.deadline <= date }
        waiters.removeAll { $0.deadline <= date }
        ready.forEach { $0.continuation.resume() }
    }

    func setNow(_ date: Date) {
        currentDate = date
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

/// Deliberately ignores task cancellation so provider generation checks get exercised.
private actor NonCooperativeGlanceClock: GlanceClock {
    private struct Waiter {
        let identifier: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, Never>
    }

    private var currentDate: Date
    private var waiters: [Waiter] = []
    private(set) var totalSleepCount = 0
    private(set) var cancellationAttemptCount = 0

    init(now: Date) {
        currentDate = now
    }

    var waiterCount: Int { waiters.count }
    var pendingDeadlines: [Date] { waiters.map(\.deadline).sorted() }

    func now() async -> Date {
        currentDate
    }

    func sleep(until deadline: Date) async throws {
        guard deadline > currentDate else { return }
        let identifier = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                totalSleepCount += 1
                waiters.append(
                    Waiter(
                        identifier: identifier,
                        deadline: deadline,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.recordCancellationAttempt(identifier) }
        }
    }

    func setNow(_ date: Date) {
        currentDate = date
    }

    func fire(index: Int, at date: Date? = nil) {
        guard waiters.indices.contains(index) else { return }
        if let date { currentDate = date }
        waiters.remove(at: index).continuation.resume()
    }

    private func recordCancellationAttempt(_ identifier: UUID) {
        guard waiters.contains(where: { $0.identifier == identifier }) else { return }
        cancellationAttemptCount += 1
    }
}

private actor ManualBrokerScheduler: ActivityExpirationScheduling {
    private struct Waiter {
        let identifier: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Waiter] = []
    private var cancelledBeforeRegistration: Set<UUID> = []
    private(set) var totalSleepCount = 0

    var pendingCount: Int { waiters.count }

    func fireNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func sleep(for duration: Duration) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                totalSleepCount += 1
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

    private func cancel(_ identifier: UUID) {
        guard let index = waiters.firstIndex(where: { $0.identifier == identifier }) else {
            cancelledBeforeRegistration.insert(identifier)
            return
        }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
