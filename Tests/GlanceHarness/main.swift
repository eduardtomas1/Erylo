import Darwin
import EryloActivity
import EryloGlance
import Foundation

@main
enum GlanceHarnessMain {
    static func main() async {
        var harness = GlanceHarness()
        await harness.verifyConversionAndValidation()
        await harness.verifyDisabledStateAndLifecycleIdempotence()
        await harness.verifyConcurrentLifecycleRaces()
        await harness.verifyPowerDedupeAndStaleGenerations()
        await harness.verifyVolumeDeviceChangesAndFloodDisable()
        await harness.verifyCalendarChangesAndBoundaries()
        await harness.verifyCalendarPermissionSeams()
        await harness.verifyCountdownCancellationReplacementAndExpiry()
        await harness.verifyBoundaryAndMutationDraining()
        await harness.verifyNonCooperativeTimerGenerationBackstop()
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
        check(await calendarSource.permissionRequestCount == 1, "aggregate lifecycle requests calendar access only after enable")
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

    mutating func verifyPowerDedupeAndStaleGenerations() async {
        let broker = makeBroker()
        let source = ManualPowerSource()
        let provider = PowerGlanceProvider(broker: broker, source: source)
        do {
            let first = try PowerSnapshot(chargeLevel: 0.4, isCharging: false, isConnectedToPower: false)
            let changed = try PowerSnapshot(chargeLevel: 0.5, isCharging: false, isConnectedToPower: false)
            await provider.enable()
            await source.emit(.snapshot(first))
            check(await waitUntil { await broker.snapshot().version == 1 }, "power event reaches broker")
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

            await source.emit(.snapshot(changed), handlerIndex: 1)
            check(await waitUntil { !(await broker.snapshot().ordered.isEmpty) }, "current power callback can submit")
            await provider.disable()
        } catch {
            recordUnexpected(error, context: "power event lifecycle")
        }
    }

    mutating func verifyVolumeDeviceChangesAndFloodDisable() async {
        let scheduler = ManualBrokerScheduler()
        let broker = ActivityBroker(expirationScheduler: scheduler)
        let source = ManualVolumeSource()
        let provider = VolumeGlanceProvider(broker: broker, source: source)
        do {
            let builtIn = try VolumeSnapshot(deviceID: 1, scalar: 0.35, isMuted: false)
            let external = try VolumeSnapshot(deviceID: 2, scalar: 0.35, isMuted: false)
            let muted = try VolumeSnapshot(deviceID: 2, scalar: 0.35, isMuted: true)
            await provider.enable()
            await source.emit(.snapshot(builtIn))
            check(await waitUntil { await broker.snapshot().version == 1 }, "volume event reaches broker")
            let firstRevision = await broker.snapshot().current?.revision

            await source.emit(.snapshot(builtIn))
            await yieldSeveralTimes()
            check(await broker.snapshot().version == 1, "duplicate volume callback is deduplicated")

            await source.emit(.snapshot(external))
            check(await waitUntil { await broker.snapshot().version == 2 }, "default-device change refreshes volume activity")
            check(await broker.snapshot().current?.revision != firstRevision, "device change creates a new broker revision")

            await source.emit(.snapshot(muted))
            check(await waitUntil { await broker.snapshot().version == 3 }, "mute change refreshes volume activity")
            check(await broker.snapshot().current?.activity.presentation.detail == "Muted", "mute callback produces honest HUD detail")

            await source.emitFlood(count: 5_000)
            let floodWork = await provider.workState()
            check(floodWork.activeConsumerTaskCount == 1, "volume flood retains one bounded consumer task")
            await provider.disable()
            check(await broker.snapshot().ordered.isEmpty, "volume disable cancels broker activity after flood")
            check(await provider.workState().isIdle, "volume flood disable drains all provider work")
            check(!(await source.isActive), "volume flood disable removes source callback")
            check(await provider.status() == .disabled, "volume flood disable completes lifecycle state")
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
            check(await clock.pendingCount == 1, "calendar schedules one start boundary")
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
            check(await provider.workState().scheduledBoundaryCount == 0, "calendar expiry leaves no timer work")

            await provider.disable()
            check(await source.stopCount == 1, "calendar disable removes its observer")
            check(await provider.workState().isIdle, "calendar disable releases all work")
        } catch {
            recordUnexpected(error, context: "calendar changes")
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
        check(await granted.permissionRequestCount == 1, "explicit enable requests calendar permission exactly once")
        check(await granted.startCount == 1, "granted contextual request starts one observer")
        check(await grantedProvider.status().capability == .available, "granted calendar access becomes available")
        await grantedProvider.disable()

        let declined = ManualCalendarSource(
            authorization: .notDetermined,
            authorizationAfterRequest: .denied,
            requestResult: false
        )
        let declinedProvider = CalendarGlanceProvider(broker: makeBroker(), source: declined, clock: ManualGlanceClock())
        await declinedProvider.enable()
        check(await declined.permissionRequestCount == 1, "not-determined denial attempts one contextual request")
        check(await declined.startCount == 0, "declined request installs no observer")
        check(await declinedProvider.status().capability == .permissionDenied, "declined request reports denial")
    }

    mutating func verifyCountdownCancellationReplacementAndExpiry() async {
        let now = Date(timeIntervalSinceReferenceDate: 40_000)
        let clock = ManualGlanceClock(now: now)
        let broker = makeBroker()
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
            check(await clock.pendingCount == 1, "countdown schedules one expiry boundary")
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
            check(await broker.snapshot().ordered.isEmpty, "countdown expiry cancels broker activity")
            check(await provider.workState().isIdle, "expired countdown owns zero work")

            await provider.disable()
            await provider.disable()
            check(await provider.status() == .disabled, "countdown disable is idempotent")
        } catch {
            recordUnexpected(error, context: "countdown lifecycle")
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

            await countdownBroker.gateNextCancel()
            await countdownClock.advance(to: replacement.endsAt)
            check(
                await waitUntil { await countdownBroker.cancelPending },
                "countdown expiry reaches gated broker cancellation"
            )
            let expiryDisableFlag = CompletionFlag()
            let expiryDisable = Task {
                await countdown.disable()
                await expiryDisableFlag.markComplete()
            }
            await yieldSeveralTimes()
            check(
                !(await expiryDisableFlag.isComplete),
                "countdown disable drains expiry already inside broker cancellation"
            )
            await countdownBroker.releaseCancel()
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
            await clock.fire(index: 0)
            await replacementTask.value
            check(await provider.countdown() == replacement, "stale timer generation cannot expire replacement")
            check(await broker.snapshot().current?.activity.presentation.title == "New", "stale timer callback cannot cancel replacement activity")
            check(await waitUntil { await clock.waiterCount == 1 }, "replacement registers a new waiter after the old one drains")

            await clock.fire(index: 0)
            check(await waitUntil { await provider.countdown() == nil }, "current timer generation can expire")
            check(await broker.snapshot().ordered.isEmpty, "current expiry reaches broker cancellation")
        } catch {
            recordUnexpected(error, context: "timer generation backstop")
        }
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
            await permission.status().health == .unavailable(.permissionRequestFailed),
            "permission request error is normalized"
        )
        check(await permissionSource.startCount == 0, "permission failure starts no observer")
    }

    private func makeBroker() -> ActivityBroker {
        ActivityBroker(expirationScheduler: ManualBrokerScheduler())
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if await condition() { return true }
            await Task.yield()
        }
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

private actor GatedGlanceBroker: GlanceActivityBroker {
    private let broker = ActivityBroker(expirationScheduler: ManualBrokerScheduler())
    private var shouldGateSubmit = false
    private var shouldGateCancel = false
    private var submitContinuation: CheckedContinuation<Void, Never>?
    private var cancelContinuation: CheckedContinuation<Void, Never>?

    var submitPending: Bool { submitContinuation != nil }
    var cancelPending: Bool { cancelContinuation != nil }

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
        if shouldGateSubmit {
            shouldGateSubmit = false
            await withCheckedContinuation { continuation in
                submitContinuation = continuation
            }
        }
        return try await broker.submit(request)
    }

    func cancel(_ identity: ActivityIdentity) async -> Bool {
        if shouldGateCancel {
            shouldGateCancel = false
            await withCheckedContinuation { continuation in
                cancelContinuation = continuation
            }
        }
        return await broker.cancel(identity)
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

    var isActive: Bool { handler != nil }

    func start(handler: @escaping Handler) async throws {
        guard self.handler == nil else { return }
        startCount += 1
        self.handler = handler
    }

    func stop() async {
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

private actor ManualCalendarSource: CalendarEventSource {
    typealias Handler = @Sendable () -> Void

    private var authorization: CalendarAuthorization
    private let authorizationAfterRequest: CalendarAuthorization
    private let requestResult: Bool
    private let failPermissionRequest: Bool
    private let failQueries: Bool
    private var meeting: CalendarMeeting?
    private var handler: Handler?
    private(set) var permissionRequestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var queryCount = 0

    init(
        authorization: CalendarAuthorization = .fullAccess,
        authorizationAfterRequest: CalendarAuthorization = .fullAccess,
        requestResult: Bool = true,
        failPermissionRequest: Bool = false,
        failQueries: Bool = false
    ) {
        self.authorization = authorization
        self.authorizationAfterRequest = authorizationAfterRequest
        self.requestResult = requestResult
        self.failPermissionRequest = failPermissionRequest
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

    func start(changeHandler: @escaping Handler) async throws {
        guard handler == nil else { return }
        startCount += 1
        handler = changeHandler
    }

    func stop() async {
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

    func emitChange() {
        handler?()
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

    init(now: Date = Date(timeIntervalSinceReferenceDate: 60_000)) {
        currentDate = now
    }

    var pendingCount: Int { waiters.count }

    func now() async -> Date {
        currentDate
    }

    func sleep(until deadline: Date) async throws {
        if deadline <= currentDate { return }
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
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
    private var currentDate: Date
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(now: Date) {
        currentDate = now
    }

    var waiterCount: Int { continuations.count }

    func now() async -> Date {
        currentDate
    }

    func sleep(until deadline: Date) async throws {
        guard deadline > currentDate else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func fire(index: Int) {
        guard continuations.indices.contains(index) else { return }
        continuations.remove(at: index).resume()
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
