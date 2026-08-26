import Darwin
import Dispatch
import EryloCore
@_spi(Testing) import EryloIntegrations
import Foundation

@main
enum MediaHarnessMain {
    static func main() async {
        if await MediaProcessHelper.runIfRequested() {
            return
        }
        let harness = MediaHarness()
        await harness.run()
        harness.finish()
    }
}

@MainActor
private final class MediaHarness {
    private var checkCount = 0
    private var failures: [String] = []

    func run() async {
        await verifyCapabilityGatingAndValueBounds()
        await verifyStaleDedupeAndSourceRecovery()
        await verifyDisabledZeroWorkAndUnavailableApplication()
        await verifyCommandSerializationRevalidationAndBounds()
        await verifyLifecycleAndRefreshGenerations()
        await verifyRefreshAndConvenienceCancellationPrecedence()
        await verifyDesktopAdapterSerializationCapacityAndCancellation()
        await verifyAdapterCancellationDrainBarriers()
        await verifyAdapterErrorMappingAndScriptIsolation()
        verifyClosedProcessAPISurface()
        await verifyProcessRunnerBoundsAndTerminalRaces()
        await verifyArtworkBounds()
        await verifySubscriberLifecycleAndBounds()
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("Media harness passed: \(checkCount) checks.")
            exit(EXIT_SUCCESS)
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        fputs("Media harness failed: \(failures.count) of \(checkCount) checks.\n", stderr)
        exit(EXIT_FAILURE)
    }

    private func verifyCapabilityGatingAndValueBounds() async {
        let snapshot = try! makeSnapshot(
            sequence: 1,
            duration: 120,
            capabilities: [.play, .seek, .volume]
        )

        check(
            (try? MediaCommand.play.normalized(for: snapshot)) == .play,
            "supported play command passes"
        )
        await expectMediaError(
            .unsupportedCommand(source: .appleMusic, command: .pause),
            "unsupported pause command is capability-gated"
        ) {
            _ = try MediaCommand.pause.normalized(for: snapshot)
        }

        let negativeSeek = try! MediaCommand.seek(to: -50).normalized(for: snapshot)
        check(negativeSeek == .seek(to: 0), "negative seek clamps to zero")
        let longSeek = try! MediaCommand.seek(to: 500).normalized(for: snapshot)
        check(longSeek == .seek(to: 120), "seek clamps to duration")
        let loudVolume = try! MediaCommand.setVolume(2).normalized(for: snapshot)
        check(loudVolume == .setVolume(1), "volume clamps to one")
        let quietVolume = try! MediaCommand.setVolume(-2).normalized(for: snapshot)
        check(quietVolume == .setVolume(0), "volume clamps to zero")

        await expectMediaError(
            .invalidNumericValue(command: .seek),
            "non-finite seek is rejected"
        ) {
            _ = try MediaCommand.seek(to: .nan).normalized(for: snapshot)
        }
        await expectMediaError(
            .invalidNumericValue(command: .volume),
            "non-finite volume is rejected"
        ) {
            _ = try MediaCommand.setVolume(.infinity).normalized(for: snapshot)
        }

        await expectMediaError(
            .invalidSnapshot(source: .appleMusic),
            "oversized title is rejected"
        ) {
            _ = try makeSnapshot(
                sequence: 1,
                title: String(repeating: "a", count: MediaValueLimits.titleUTF8Bytes + 1)
            )
        }
        await expectMediaError(
            .invalidSnapshot(source: .appleMusic),
            "control characters in now-playing text are rejected"
        ) {
            _ = try makeSnapshot(sequence: 1, title: "unsafe\u{0001}title")
        }
        await expectMediaError(
            .invalidSnapshot(source: .appleMusic),
            "oversized track identifier is rejected"
        ) {
            _ = try makeSnapshot(
                sequence: 1,
                trackIdentifier: String(
                    repeating: "i",
                    count: MediaValueLimits.identifierUTF8Bytes + 1
                )
            )
        }

        do {
            _ = try MediaArtworkCacheKey(
                String(repeating: "k", count: MediaValueLimits.cacheKeyUTF8Bytes + 1)
            )
            check(false, "oversized artwork cache key is rejected")
        } catch {
            check(error as? MediaArtworkReferenceError == .invalidCacheKey, "oversized artwork cache key is rejected")
        }
    }

    private func verifyStaleDedupeAndSourceRecovery() async {
        let fresh = try! makeSnapshot(sequence: 2, title: "Fresh")
        let stale = try! makeSnapshot(sequence: 1, title: "Stale")
        let duplicate = try! makeSnapshot(sequence: 3, title: "Fresh")
        let recovered = try! makeSnapshot(sequence: 5, title: "Recovered")
        let adapter = TestMediaAdapter(
            source: .appleMusic,
            refreshActions: [
                .update(.snapshot(fresh)),
                .update(.snapshot(stale)),
                .update(.snapshot(duplicate)),
                .update(
                    .sourceDisappeared(
                        source: .appleMusic,
                        stamp: MediaUpdateStamp(sequence: 4)
                    )
                ),
                .update(.snapshot(recovered)),
            ]
        )
        let coordinator = MediaCoordinator(adapters: [adapter])
        await coordinator.setEnabled(true, for: .appleMusic)

        let recorder = EventRecorder()
        let stream = try! await coordinator.updates()
        let collector = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }

        _ = try! await coordinator.refresh(.appleMusic)
        _ = try! await coordinator.refresh(.appleMusic)
        _ = try! await coordinator.refresh(.appleMusic)
        await recorder.waitForSnapshotCount(1)

        let current = await coordinator.snapshot(for: .appleMusic)
        let publishedSnapshotCount = await recorder.snapshotCount
        check(current?.title == "Fresh", "stale snapshot cannot replace newer content")
        check(current?.stamp.sequence == 3, "semantic dedupe still advances observation sequence")
        check(publishedSnapshotCount == 1, "semantic duplicate snapshot is not republished")

        let disappeared = try! await coordinator.refresh(.appleMusic)
        let unavailableHealth = await coordinator.health(for: .appleMusic)
        check(disappeared == nil, "source disappearance clears current snapshot")
        check(
            unavailableHealth.availability == .unavailable,
            "source disappearance marks adapter unavailable"
        )

        let recoveredSnapshot = try! await coordinator.refresh(.appleMusic)
        let recoveredHealth = await coordinator.health(for: .appleMusic)
        check(recoveredSnapshot?.title == "Recovered", "source can recover after disappearance")
        check(
            recoveredHealth.availability == .available,
            "recovered source returns to available health"
        )

        collector.cancel()
        _ = await collector.result
        await coordinator.stop()
    }

    private func verifyDisabledZeroWorkAndUnavailableApplication() async {
        let adapter = TestMediaAdapter(source: .appleMusic)
        let coordinator = MediaCoordinator(adapters: [adapter])

        await expectMediaError(
            .disabled(source: .appleMusic),
            "disabled coordinator refresh is rejected"
        ) {
            _ = try await coordinator.refresh(.appleMusic)
        }
        var metrics = await adapter.metrics()
        check(metrics.totalCalls == 0, "disabled adapter performs zero work")

        await coordinator.setEnabled(true, for: .appleMusic)
        metrics = await adapter.metrics()
        check(metrics.activateCalls == 1, "explicit enable activates adapter once")
        check(metrics.updateStreamCalls == 1, "explicit enable attaches one update stream")
        check(metrics.refreshCalls == 0 && metrics.performCalls == 0, "enable does not refresh or command implicitly")
        await coordinator.stop()

        let applicationStatus = TestApplicationStatus(isRunning: false)
        let executor = RecordingScriptExecutor(actions: [.output(validScriptOutput())])
        let music = AppleMusicDesktopAdapter(
            applicationStatus: applicationStatus,
            scriptExecutor: executor
        )
        await music.activate()
        let update = try! await music.refresh()
        if case .sourceDisappeared(source: .appleMusic, _) = update {
            check(true, "unavailable desktop app maps to source disappearance")
        } else {
            check(false, "unavailable desktop app maps to source disappearance")
        }
        let unavailableRequests = await executor.requests()
        check(unavailableRequests.isEmpty, "unavailable app never invokes AppleScript")
        await music.deactivate()
    }

    private func verifyCommandSerializationRevalidationAndBounds() async {
        let commandGate = AsyncGate()
        let commandStarted = AsyncGate()
        let initial = try! makeSnapshot(
            sequence: 1,
            capabilities: [.play, .pause, .seek, .volume]
        )
        let reduced = try! makeSnapshot(sequence: 2, capabilities: [.play])
        let adapter = TestMediaAdapter(
            source: .appleMusic,
            refreshActions: [.update(.snapshot(initial)), .update(.snapshot(reduced))],
            commandGate: commandGate,
            commandStarted: commandStarted
        )
        let coordinator = MediaCoordinator(adapters: [adapter])
        await coordinator.setEnabled(true, for: .appleMusic)
        _ = try! await coordinator.refresh(.appleMusic)

        await expectMediaError(
            .invalidNumericValue(command: .volume),
            "coordinator validates numeric input before enqueue"
        ) {
            try await coordinator.perform(.setVolume(.nan), on: .appleMusic)
        }

        let first = Task { try await coordinator.perform(.play, on: .appleMusic) }
        await commandStarted.wait()
        let second = Task { try await coordinator.perform(.pause, on: .appleMusic) }
        for _ in 0 ..< 8 { await Task.yield() }

        var metrics = await adapter.metrics()
        check(metrics.performCalls == 1, "second command waits behind active command")
        check(metrics.maximumConcurrentCommands == 1, "commands are serialized")

        _ = try! await coordinator.refresh(.appleMusic)
        await commandGate.open()
        _ = await first.result
        let secondError = await mediaError(from: second.result)
        check(
            secondError == .unsupportedCommand(source: .appleMusic, command: .pause),
            "queued command revalidates against latest capabilities"
        )
        metrics = await adapter.metrics()
        check(metrics.performCalls == 1, "rejected stale-capability command never reaches adapter")
        await coordinator.stop()

        let boundedGate = AsyncGate()
        let boundedStarted = AsyncGate()
        let boundedAdapter = TestMediaAdapter(
            source: .spotify,
            refreshActions: [.update(.snapshot(try! makeSnapshot(source: .spotify, sequence: 1)))],
            commandGate: boundedGate,
            commandStarted: boundedStarted,
            openCommandGateOnCancel: true
        )
        let boundedCoordinator = MediaCoordinator(
            adapters: [boundedAdapter],
            policy: MediaCoordinatorPolicy(maximumPendingCommands: 1)
        )
        await boundedCoordinator.setEnabled(true, for: .spotify)
        _ = try! await boundedCoordinator.refresh(.spotify)
        let active = Task { try await boundedCoordinator.perform(.play, on: .spotify) }
        await boundedStarted.wait()

        await expectMediaError(
            .commandQueueFull(source: .spotify, limit: 1),
            "command queue enforces configured bound"
        ) {
            try await boundedCoordinator.perform(.next, on: .spotify)
        }

        await boundedCoordinator.setEnabled(false, for: .spotify)
        let activeError = await mediaError(from: active.result)
        check(activeError == .cancelled(source: .spotify), "disable cancels active target command")
        metrics = await boundedAdapter.metrics()
        check(metrics.cancelCalls >= 1, "disable reaches target adapter cancellation seam")
        await boundedCoordinator.stop()

        let alreadyCancelledAdapter = TestMediaAdapter(
            source: .appleMusic,
            refreshActions: [
                .update(.snapshot(try! makeSnapshot(sequence: 1))),
            ]
        )
        let alreadyCancelledCoordinator = MediaCoordinator(
            adapters: [alreadyCancelledAdapter]
        )
        await alreadyCancelledCoordinator.setEnabled(true, for: .appleMusic)
        _ = try! await alreadyCancelledCoordinator.refresh(.appleMusic)
        let alreadyCancelledCommand = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            try await alreadyCancelledCoordinator.perform(.play, on: .appleMusic)
        }
        let alreadyCancelledError = await mediaError(from: alreadyCancelledCommand.result)
        let alreadyCancelledMetrics = await alreadyCancelledAdapter.metrics()
        check(
            alreadyCancelledError == .cancelled(source: .appleMusic),
            "already-cancelled command is rejected before admission"
        )
        check(
            alreadyCancelledMetrics.performCalls == 0,
            "already-cancelled command cannot start adapter work"
        )
        await alreadyCancelledCoordinator.stop()

        let delayedCancellation = GatedCommandCancellationObserver()
        let failingCommandAdapter = GatedFailingCommandAdapter(source: .spotify)
        let cancellationPrecedenceCoordinator = MediaCoordinator(
            adapters: [failingCommandAdapter],
            policy: MediaCoordinatorPolicy(maximumPendingCommands: 1),
            commandCancellationObserver: delayedCancellation
        )
        await cancellationPrecedenceCoordinator.setEnabled(true, for: .spotify)
        _ = try! await cancellationPrecedenceCoordinator.refresh(.spotify)
        let failingCommand = Task {
            try await cancellationPrecedenceCoordinator.perform(.play, on: .spotify)
        }
        await failingCommandAdapter.firstCommandStarted.wait()
        failingCommand.cancel()
        await delayedCancellation.dispatchStarted.wait()
        await failingCommandAdapter.releaseFirstCommandFailure()
        let failingCommandError = await mediaError(from: failingCommand.result)
        check(
            failingCommandError == .cancelled(source: .spotify),
            "synchronous command cancellation latch wins over adapter failure"
        )
        let retainedSnapshot = await cancellationPrecedenceCoordinator.snapshot(for: .spotify)
        check(
            retainedSnapshot?.title == "Stable",
            "cancelled failing command cannot mutate the coordinator snapshot"
        )
        await delayedCancellation.releaseDispatch()
        await delayedCancellation.dispatchFinished.wait()
        try! await cancellationPrecedenceCoordinator.perform(.next, on: .spotify)
        let precedenceMetrics = await failingCommandAdapter.metrics()
        check(
            precedenceMetrics.performCalls == 2 && precedenceMetrics.cancelCalls == 0,
            "late cancel cleanup releases command capacity exactly once"
        )
        await cancellationPrecedenceCoordinator.stop()
    }

    private func verifyLifecycleAndRefreshGenerations() async {
        let cancelledRefreshAdapter = TestMediaAdapter(
            source: .appleMusic,
            refreshActions: [
                .update(.snapshot(try! makeSnapshot(sequence: 1))),
            ]
        )
        let cancelledRefreshCoordinator = MediaCoordinator(
            adapters: [cancelledRefreshAdapter]
        )
        await cancelledRefreshCoordinator.setEnabled(true, for: .appleMusic)
        let alreadyCancelledRefresh = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            return try await cancelledRefreshCoordinator.refresh(.appleMusic)
        }
        let alreadyCancelledRefreshError = await mediaError(from: alreadyCancelledRefresh.result)
        var cancelledRefreshMetrics = await cancelledRefreshAdapter.metrics()
        check(
            alreadyCancelledRefreshError == .cancelled(source: .appleMusic),
            "already-cancelled coordinator refresh is rejected at entry"
        )
        check(
            cancelledRefreshMetrics.refreshCalls == 0
                && cancelledRefreshMetrics.cancelCalls == 0,
            "already-cancelled coordinator refresh starts no adapter work"
        )
        _ = try! await cancelledRefreshCoordinator.refresh(.appleMusic)
        cancelledRefreshMetrics = await cancelledRefreshAdapter.metrics()
        check(
            cancelledRefreshMetrics.refreshCalls == 1,
            "cancelled refresh leaves no reservation that blocks later work"
        )
        await cancelledRefreshCoordinator.stop()

        let convenienceAdapter = TestMediaAdapter(
            source: .spotify,
            refreshActions: [
                .update(.snapshot(try! makeSnapshot(source: .spotify, sequence: 1))),
            ]
        )
        let erasedConvenienceAdapter: any MediaAdapter = convenienceAdapter
        let cancelledConvenienceRefresh = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            return try await erasedConvenienceAdapter.refresh()
        }
        let cancelledConvenienceCommand = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            try await erasedConvenienceAdapter.perform(.play)
        }
        let convenienceRefreshError = await mediaError(from: cancelledConvenienceRefresh.result)
        let convenienceCommandError = await mediaError(from: cancelledConvenienceCommand.result)
        let convenienceMetrics = await convenienceAdapter.metrics()
        check(
            convenienceRefreshError == .cancelled(source: .spotify)
                && convenienceCommandError == .cancelled(source: .spotify),
            "already-cancelled adapter convenience calls return typed cancellation"
        )
        check(
            convenienceMetrics.refreshCalls == 0
                && convenienceMetrics.performCalls == 0
                && convenienceMetrics.cancelCalls == 0,
            "adapter convenience cancellation guards invoke no conformer work"
        )

        let activationGate = AsyncGate()
        let activationStarted = AsyncGate()
        let adapter = TestMediaAdapter(
            source: .appleMusic,
            activationGate: activationGate,
            activationStarted: activationStarted
        )
        let coordinator = MediaCoordinator(adapters: [adapter])

        let enabling = Task { await coordinator.setEnabled(true, for: .appleMusic) }
        await activationStarted.wait()
        let disabling = Task(priority: .high) {
            await coordinator.setEnabled(false, for: .appleMusic)
        }
        for _ in 0 ..< 32 { await Task.yield() }
        await activationGate.open()
        await enabling.value
        await disabling.value

        var metrics = await adapter.metrics()
        let disabledHealth = await coordinator.health(for: .appleMusic)
        check(metrics.updateStreamCalls == 0, "stale activation cannot attach an update stream")
        check(metrics.deactivateCalls == 1, "disable completes after in-flight activation")
        check(
            disabledHealth.availability == .disabled,
            "stale activation cannot overwrite disabled health"
        )

        await coordinator.setEnabled(true, for: .appleMusic)
        metrics = await adapter.metrics()
        check(metrics.updateStreamCalls == 1, "source can re-enable with a fresh generation")
        await coordinator.stop()

        let refreshGate = AsyncGate()
        let refreshStarted = AsyncGate()
        let staleSnapshot = try! makeSnapshot(sequence: 1, title: "Old generation")
        let racingAdapter = TestMediaAdapter(
            source: .spotify,
            refreshActions: [.waiting(refreshGate, .snapshot(staleSnapshot))],
            refreshStarted: refreshStarted
        )
        let racingCoordinator = MediaCoordinator(adapters: [racingAdapter])
        await racingCoordinator.setEnabled(true, for: .spotify)

        let refresh = Task { try await racingCoordinator.refresh(.spotify) }
        await refreshStarted.wait()
        await racingCoordinator.setEnabled(false, for: .spotify)
        await racingCoordinator.setEnabled(true, for: .spotify)
        await refreshGate.open()

        let refreshError = await mediaError(from: refresh.result)
        let racingSnapshot = await racingCoordinator.snapshot(for: .spotify)
        let racingHealth = await racingCoordinator.health(for: .spotify)
        check(refreshError == .cancelled(source: .spotify), "old refresh result is cancelled after generation change")
        check(racingSnapshot == nil, "old refresh cannot repopulate re-enabled source")
        check(
            racingHealth.availability == .inactive,
            "old refresh cannot overwrite new generation health"
        )
        await racingCoordinator.stop()

        let statusGate = AsyncGate()
        let statusStarted = AsyncGate()
        let gatedStatus = GatedApplicationStatus(
            gate: statusGate,
            started: statusStarted,
            isRunning: true
        )
        let gatedExecutor = RecordingScriptExecutor(actions: [.output(validScriptOutput())])
        let directAdapter = AppleMusicDesktopAdapter(
            applicationStatus: gatedStatus,
            scriptExecutor: gatedExecutor
        )
        await directAdapter.activate()
        let directRefresh = Task { try await directAdapter.refresh() }
        await statusStarted.wait()
        await directAdapter.deactivate()
        await statusGate.open()
        let directRefreshError = await mediaError(from: directRefresh.result)
        let gatedRequests = await gatedExecutor.requests()
        check(
            directRefreshError == .cancelled(source: .appleMusic),
            "deactivation invalidates in-flight adapter refresh generation"
        )
        check(
            gatedRequests.isEmpty,
            "deactivated adapter cannot start new script work after an awaited status check"
        )
    }

    private func verifyRefreshAndConvenienceCancellationPrecedence() async {
        let coordinatorSuccessStarted = AsyncGate()
        let coordinatorSuccessRelease = AsyncGate()
        let coordinatorFailureStarted = AsyncGate()
        let coordinatorFailureRelease = AsyncGate()
        let coordinatorCancelRelease1 = AsyncGate()
        let coordinatorCancelRelease2 = AsyncGate()
        let stable = MediaAdapterUpdate.snapshot(
            try! makeSnapshot(source: .spotify, sequence: 1, title: "Stable")
        )
        let late = MediaAdapterUpdate.snapshot(
            try! makeSnapshot(source: .spotify, sequence: 2, title: "Late")
        )
        let reusable = MediaAdapterUpdate.snapshot(
            try! makeSnapshot(source: .spotify, sequence: 3, title: "Reusable")
        )
        let coordinatorAdapter = CancellationIgnoringMediaAdapter(
            source: .spotify,
            refreshSteps: [
                .immediateSuccess(stable),
                .gatedSuccess(
                    started: coordinatorSuccessStarted,
                    release: coordinatorSuccessRelease,
                    update: late
                ),
                .gatedFailure(
                    started: coordinatorFailureStarted,
                    release: coordinatorFailureRelease,
                    error: .automationFailed(source: .spotify, exitCode: 94)
                ),
                .immediateSuccess(reusable),
            ],
            commandSteps: [],
            cancellationGates: [coordinatorCancelRelease1, coordinatorCancelRelease2]
        )
        let coordinator = MediaCoordinator(adapters: [coordinatorAdapter])
        await coordinator.setEnabled(true, for: .spotify)
        _ = try! await coordinator.refresh(.spotify)
        let stableHealth = await coordinator.health(for: .spotify)

        let lateSuccess = Task { try await coordinator.refresh(.spotify) }
        await coordinatorSuccessStarted.wait()
        lateSuccess.cancel()
        await coordinatorAdapter.waitForCancellationCount(1)
        await coordinatorSuccessRelease.open()
        let lateSuccessError = await mediaError(from: lateSuccess.result)
        let snapshotAfterLateSuccess = await coordinator.snapshot(for: .spotify)
        let healthAfterLateSuccess = await coordinator.health(for: .spotify)
        check(
            lateSuccessError == .cancelled(source: .spotify),
            "coordinator cancellation latch wins over late refresh success"
        )
        check(
            snapshotAfterLateSuccess?.title == "Stable"
                && healthAfterLateSuccess == stableHealth,
            "late cancelled refresh success cannot publish snapshot or health"
        )
        await coordinatorCancelRelease1.open()
        await coordinatorAdapter.waitForCancellationSettlementCount(1)

        let lateFailure = Task { try await coordinator.refresh(.spotify) }
        await coordinatorFailureStarted.wait()
        lateFailure.cancel()
        await coordinatorAdapter.waitForCancellationCount(2)
        await coordinatorFailureRelease.open()
        let lateFailureError = await mediaError(from: lateFailure.result)
        let snapshotAfterLateFailure = await coordinator.snapshot(for: .spotify)
        let healthAfterLateFailure = await coordinator.health(for: .spotify)
        check(
            lateFailureError == .cancelled(source: .spotify),
            "coordinator cancellation latch wins over late refresh failure"
        )
        check(
            snapshotAfterLateFailure?.title == "Stable"
                && healthAfterLateFailure == stableHealth,
            "late cancelled refresh failure cannot publish stale health"
        )
        await coordinatorCancelRelease2.open()
        await coordinatorAdapter.waitForCancellationSettlementCount(2)
        let reusableSnapshot = try! await coordinator.refresh(.spotify)
        let coordinatorMetrics = await coordinatorAdapter.metrics()
        check(
            reusableSnapshot?.title == "Reusable"
                && coordinatorMetrics.activeOperations == 0
                && coordinatorMetrics.maximumConcurrentOperations == 1,
            "coordinator refresh cancellation settles exactly and reuses capacity"
        )
        await coordinator.stop()

        let convenienceRefreshSuccessStarted = AsyncGate()
        let convenienceRefreshSuccessRelease = AsyncGate()
        let convenienceRefreshFailureStarted = AsyncGate()
        let convenienceRefreshFailureRelease = AsyncGate()
        let convenienceRefreshCancel1 = AsyncGate()
        let convenienceRefreshCancel2 = AsyncGate()
        let convenienceRefreshAdapter = CancellationIgnoringMediaAdapter(
            source: .appleMusic,
            refreshSteps: [
                .gatedSuccess(
                    started: convenienceRefreshSuccessStarted,
                    release: convenienceRefreshSuccessRelease,
                    update: .snapshot(try! makeSnapshot(sequence: 1, title: "Late"))
                ),
                .gatedFailure(
                    started: convenienceRefreshFailureStarted,
                    release: convenienceRefreshFailureRelease,
                    error: .automationFailed(source: .appleMusic, exitCode: 95)
                ),
                .immediateSuccess(
                    .snapshot(try! makeSnapshot(sequence: 2, title: "Reusable"))
                ),
            ],
            commandSteps: [],
            cancellationGates: [convenienceRefreshCancel1, convenienceRefreshCancel2]
        )
        let erasedRefreshAdapter: any MediaAdapter = convenienceRefreshAdapter

        let convenienceRefreshSuccess = Task { try await erasedRefreshAdapter.refresh() }
        await convenienceRefreshSuccessStarted.wait()
        convenienceRefreshSuccess.cancel()
        await convenienceRefreshAdapter.waitForCancellationCount(1)
        await convenienceRefreshSuccessRelease.open()
        let convenienceRefreshSuccessError = await mediaError(
            from: convenienceRefreshSuccess.result
        )
        check(
            convenienceRefreshSuccessError == .cancelled(source: .appleMusic),
            "adapter refresh convenience cancellation wins over late success"
        )
        await convenienceRefreshCancel1.open()
        await convenienceRefreshAdapter.waitForCancellationSettlementCount(1)

        let convenienceRefreshFailure = Task { try await erasedRefreshAdapter.refresh() }
        await convenienceRefreshFailureStarted.wait()
        convenienceRefreshFailure.cancel()
        await convenienceRefreshAdapter.waitForCancellationCount(2)
        await convenienceRefreshFailureRelease.open()
        let convenienceRefreshFailureError = await mediaError(
            from: convenienceRefreshFailure.result
        )
        check(
            convenienceRefreshFailureError == .cancelled(source: .appleMusic),
            "adapter refresh convenience cancellation wins over late failure"
        )
        await convenienceRefreshCancel2.open()
        await convenienceRefreshAdapter.waitForCancellationSettlementCount(2)
        let convenienceRefreshReuse = try! await erasedRefreshAdapter.refresh()
        let convenienceRefreshMetrics = await convenienceRefreshAdapter.metrics()
        if case let .snapshot(snapshot) = convenienceRefreshReuse {
            check(
                snapshot.title == "Reusable"
                    && convenienceRefreshMetrics.activeOperations == 0
                    && convenienceRefreshMetrics.maximumConcurrentOperations == 1,
                "adapter refresh convenience settles and reuses capacity"
            )
        } else {
            check(false, "adapter refresh convenience settles and reuses capacity")
        }

        let convenienceCommandSuccessStarted = AsyncGate()
        let convenienceCommandSuccessRelease = AsyncGate()
        let convenienceCommandFailureStarted = AsyncGate()
        let convenienceCommandFailureRelease = AsyncGate()
        let convenienceCommandCancel1 = AsyncGate()
        let convenienceCommandCancel2 = AsyncGate()
        let convenienceCommandAdapter = CancellationIgnoringMediaAdapter(
            source: .spotify,
            refreshSteps: [],
            commandSteps: [
                .gatedSuccess(
                    started: convenienceCommandSuccessStarted,
                    release: convenienceCommandSuccessRelease
                ),
                .gatedFailure(
                    started: convenienceCommandFailureStarted,
                    release: convenienceCommandFailureRelease,
                    error: .automationFailed(source: .spotify, exitCode: 96)
                ),
                .immediateSuccess,
            ],
            cancellationGates: [convenienceCommandCancel1, convenienceCommandCancel2]
        )
        let erasedCommandAdapter: any MediaAdapter = convenienceCommandAdapter

        let convenienceCommandSuccess = Task {
            try await erasedCommandAdapter.perform(.play)
        }
        await convenienceCommandSuccessStarted.wait()
        convenienceCommandSuccess.cancel()
        await convenienceCommandAdapter.waitForCancellationCount(1)
        await convenienceCommandSuccessRelease.open()
        let convenienceCommandSuccessError = await mediaError(
            from: convenienceCommandSuccess.result
        )
        check(
            convenienceCommandSuccessError == .cancelled(source: .spotify),
            "adapter perform convenience cancellation wins over late success"
        )
        await convenienceCommandCancel1.open()
        await convenienceCommandAdapter.waitForCancellationSettlementCount(1)

        let convenienceCommandFailure = Task {
            try await erasedCommandAdapter.perform(.pause)
        }
        await convenienceCommandFailureStarted.wait()
        convenienceCommandFailure.cancel()
        await convenienceCommandAdapter.waitForCancellationCount(2)
        await convenienceCommandFailureRelease.open()
        let convenienceCommandFailureError = await mediaError(
            from: convenienceCommandFailure.result
        )
        check(
            convenienceCommandFailureError == .cancelled(source: .spotify),
            "adapter perform convenience cancellation wins over late failure"
        )
        await convenienceCommandCancel2.open()
        await convenienceCommandAdapter.waitForCancellationSettlementCount(2)
        try! await erasedCommandAdapter.perform(.next)
        let convenienceCommandMetrics = await convenienceCommandAdapter.metrics()
        check(
            convenienceCommandMetrics.activeOperations == 0
                && convenienceCommandMetrics.maximumConcurrentOperations == 1,
            "adapter perform convenience settles and reuses capacity"
        )
    }

    private func verifyDesktopAdapterSerializationCapacityAndCancellation() async {
        let running = TestApplicationStatus(isRunning: true)
        let floodStarted = AsyncGate()
        let floodGate = AsyncGate()
        let floodExecutor = RecordingScriptExecutor(
            actions: [
                .waiting(
                    started: floodStarted,
                    gate: floodGate,
                    output: validScriptOutput(title: "First")
                ),
                .output(validScriptOutput(title: "Second")),
                .output(validScriptOutput(title: "Reusable")),
            ]
        )
        let admissionObserver = GatedAdmissionObserver(
            passThroughAttempts: 1,
            gatedAttempts: 8
        )
        let floodCompletions = CompletionCounter()
        let floodAdapter = AppleMusicDesktopAdapter(
            applicationStatus: running,
            scriptExecutor: floodExecutor,
            maximumPendingOperations: 2,
            admissionObserver: admissionObserver
        )
        await floodAdapter.activate()
        let firstRefresh = Task {
            try await floodAdapter.refresh(operationID: MediaOperationID())
        }
        await floodStarted.wait()

        let floodedRefreshes = (0 ..< 8).map { _ in
            Task<Result<MediaAdapterUpdate, Error>, Never> {
                let result: Result<MediaAdapterUpdate, Error>
                do {
                    result = .success(
                        try await floodAdapter.refresh(operationID: MediaOperationID())
                    )
                } catch {
                    result = .failure(error)
                }
                await floodCompletions.recordCompletion()
                return result
            }
        }
        await admissionObserver.allGatedAttemptsArrived.wait()
        let heldRequestCount = await floodExecutor.requests().count
        check(heldRequestCount == 1, "same-source refresh execution is serialized")
        await admissionObserver.releaseGatedAttempts()
        await floodCompletions.waitForCount(7)
        await floodGate.open()
        _ = try! await firstRefresh.value

        var floodSuccesses = 0
        var floodCapacityFailures = 0
        for task in floodedRefreshes {
            switch await task.value {
            case .success:
                floodSuccesses += 1
            case let .failure(error):
                if error as? MediaError == .operationQueueFull(source: .appleMusic, limit: 2) {
                    floodCapacityFailures += 1
                }
            }
        }
        check(floodSuccesses == 1, "adapter admits at most one queued refresh behind active work")
        check(floodCapacityFailures == 7, "refresh flood receives typed capacity failures")

        let reusableUpdate = try! await floodAdapter.refresh(operationID: MediaOperationID())
        if case let .snapshot(snapshot) = reusableUpdate {
            check(snapshot.title == "Reusable", "adapter operation capacity is reusable")
        } else {
            check(false, "adapter operation capacity is reusable")
        }
        await floodAdapter.deactivate()

        let capabilityRefreshStarted = AsyncGate()
        let capabilityRefreshGate = AsyncGate()
        let capabilityExecutor = RecordingScriptExecutor(
            actions: [
                .output(validScriptOutput(duration: "180")),
                .waiting(
                    started: capabilityRefreshStarted,
                    gate: capabilityRefreshGate,
                    output: validScriptOutput(duration: "0")
                ),
            ]
        )
        let capabilityAdapter = AppleMusicDesktopAdapter(
            applicationStatus: running,
            scriptExecutor: capabilityExecutor
        )
        await capabilityAdapter.activate()
        _ = try! await capabilityAdapter.refresh()
        let reducingRefresh = Task { try await capabilityAdapter.refresh() }
        await capabilityRefreshStarted.wait()
        let staleSeek = Task { try await capabilityAdapter.perform(.seek(to: 90)) }
        await capabilityRefreshGate.open()
        _ = try! await reducingRefresh.value
        let staleSeekError = await mediaError(from: staleSeek.result)
        check(
            staleSeekError == .unsupportedCommand(source: .appleMusic, command: .seek),
            "desktop adapter revalidates the latest capability at the launch boundary"
        )
        let capabilityRoutes = await capabilityExecutor.requests().map(\.route)
        check(
            capabilityRoutes == [.appleMusicSnapshot, .appleMusicSnapshot],
            "capability rejection prevents command process launch"
        )
        await capabilityAdapter.deactivate()

        let cancelledStarted = AsyncGate()
        let cancelledGate = AsyncGate()
        let successorStarted = AsyncGate()
        let successorGate = AsyncGate()
        let cancellationExecutor = RecordingScriptExecutor(
            actions: [
                .output(validScriptOutput()),
                .waiting(started: cancelledStarted, gate: cancelledGate, output: ""),
                .waiting(started: successorStarted, gate: successorGate, output: ""),
                .output(validScriptOutput(title: "After cancellation")),
            ]
        )
        let cancellationAdapter = AppleMusicDesktopAdapter(
            applicationStatus: running,
            scriptExecutor: cancellationExecutor
        )
        await cancellationAdapter.activate()
        _ = try! await cancellationAdapter.refresh()
        let cancelledID = MediaOperationID()
        let cancelledCommand = Task {
            try await cancellationAdapter.perform(.play, operationID: cancelledID)
        }
        await cancelledStarted.wait()
        let successorCommand = Task {
            try await cancellationAdapter.perform(.next, operationID: MediaOperationID())
        }
        for _ in 0 ..< 16 { await Task.yield() }
        await cancellationAdapter.cancel(cancelledID)
        await successorStarted.wait()
        let concurrentRefresh = Task { try await cancellationAdapter.refresh() }
        for _ in 0 ..< 16 { await Task.yield() }
        await successorGate.open()

        let cancelledError = await mediaError(from: cancelledCommand.result)
        check(
            cancelledError == .cancelled(source: .appleMusic),
            "target cancellation marks only the active operation"
        )
        _ = try! await successorCommand.value
        _ = try! await concurrentRefresh.value
        let cancellationRoutes = await cancellationExecutor.requests().map(\.route)
        check(
            cancellationRoutes == [
                .appleMusicSnapshot,
                .appleMusicPlay,
                .appleMusicNext,
                .appleMusicSnapshot,
            ],
            "active cancellation preserves queued successor and concurrent refresh"
        )
        await cancellationAdapter.deactivate()

        let sharedAppleStarted = AsyncGate()
        let sharedAppleGate = AsyncGate()
        let sharedSpotifyStarted = AsyncGate()
        let sharedSpotifyGate = AsyncGate()
        let sharedExecutor = RecordingScriptExecutor(
            actions: [
                .waiting(
                    started: sharedAppleStarted,
                    gate: sharedAppleGate,
                    output: validScriptOutput(title: "Apple")
                ),
                .waiting(
                    started: sharedSpotifyStarted,
                    gate: sharedSpotifyGate,
                    output: validScriptOutput(title: "Spotify")
                ),
            ]
        )
        let sharedApple = AppleMusicDesktopAdapter(
            applicationStatus: running,
            scriptExecutor: sharedExecutor
        )
        let sharedSpotify = SpotifyDesktopAdapter(
            applicationStatus: running,
            scriptExecutor: sharedExecutor
        )
        await sharedApple.activate()
        await sharedSpotify.activate()
        let sharedAppleID = MediaOperationID()
        let sharedSpotifyID = MediaOperationID()
        let sharedAppleRefresh = Task {
            try await sharedApple.refresh(operationID: sharedAppleID)
        }
        await sharedAppleStarted.wait()
        let sharedSpotifyRefresh = Task {
            try await sharedSpotify.refresh(operationID: sharedSpotifyID)
        }
        await sharedSpotifyStarted.wait()
        await sharedApple.deactivate()

        let sharedAppleError = await mediaError(from: sharedAppleRefresh.result)
        let activeSharedIDs = await sharedExecutor.activeOperationIDs()
        check(
            sharedAppleError == .cancelled(source: .appleMusic),
            "disabling one adapter cancels its exact shared-executor operation"
        )
        check(
            activeSharedIDs.count == 1,
            "disabling Apple Music does not cancel shared-executor Spotify work"
        )
        await sharedSpotifyGate.open()
        _ = try! await sharedSpotifyRefresh.value
        await sharedSpotify.deactivate()

        await verifyPreRegistrationCancellation(running: running)
    }

    private func verifyPreRegistrationCancellation(
        running: TestApplicationStatus
    ) async {
        let cancellationRunner = PreRegistrationProcessRunner()
        let cancellationAdapter = AppleMusicDesktopAdapter(
            applicationStatus: running,
            scriptExecutor: ProcessMediaScriptExecutor(processRunner: cancellationRunner)
        )
        await cancellationAdapter.activate()
        let operationID = MediaOperationID()
        let refresh = Task {
            try await cancellationAdapter.refresh(operationID: operationID)
        }
        await cancellationRunner.registrationStarted.wait()
        await cancellationAdapter.cancel(operationID)
        await cancellationRunner.registrationGate.open()
        let cancellationError = await mediaError(from: refresh.result)
        let cancellationLaunches = await cancellationRunner.launchCount
        check(
            cancellationError == .cancelled(source: .appleMusic),
            "operation cancellation survives a pre-registration runner suspension"
        )
        check(cancellationLaunches == 0, "cancelled pre-registration work cannot launch later")
        await cancellationAdapter.deactivate()

        let disableRunner = PreRegistrationProcessRunner()
        let disableAdapter = AppleMusicDesktopAdapter(
            applicationStatus: running,
            scriptExecutor: ProcessMediaScriptExecutor(processRunner: disableRunner)
        )
        await disableAdapter.activate()
        let disabledRefresh = Task { try await disableAdapter.refresh() }
        await disableRunner.registrationStarted.wait()
        await disableAdapter.deactivate()
        await disableRunner.registrationGate.open()
        let disableError = await mediaError(from: disabledRefresh.result)
        let disableLaunches = await disableRunner.launchCount
        check(
            disableError == .cancelled(source: .appleMusic),
            "disable cancels the exact active task before runner registration"
        )
        check(disableLaunches == 0, "disabled pre-registration work cannot launch later")
    }

    private func verifyAdapterCancellationDrainBarriers() async {
        let executableURL = mediaHelperExecutableURL()
        let processRunner = FoundationMediaScriptProcessRunner(executableURL: executableURL)
        let readinessPath = temporaryMediaHelperMarkerPath()
        let processExecutor = IgnoreTermProcessExecutor(
            runner: processRunner,
            readinessPath: readinessPath,
            limits: MediaScriptProcessLimits(
                timeoutNanoseconds: 2_000_000_000,
                terminationGraceNanoseconds: 30_000_000,
                postTerminationDrainNanoseconds: 30_000_000
            )
        )
        let processAdapter = AppleMusicDesktopAdapter(
            applicationStatus: TestApplicationStatus(isRunning: true),
            scriptExecutor: processExecutor,
            cancellationDrainTimeoutNanoseconds: 1_000_000_000
        )
        await processAdapter.activate()
        let processRefresh = Task { try await processAdapter.refresh() }
        let helperReady = await waitForFile(atPath: readinessPath)
        check(helperReady, "ignore-signal helper reaches its ready state")
        await processAdapter.deactivate()
        let processRefreshError = await mediaError(from: processRefresh.result)
        let remainingProcesses = await processRunner.activeProcessCount
        let remainingReaders = await processRunner.activeReaderCount
        check(
            processRefreshError == .cancelled(source: .appleMusic),
            "deactivate drains an ignore-TERM operation as cancelled"
        )
        check(
            remainingProcesses == 0 && remainingReaders == 0,
            "deactivate returns only after the exact process is reaped and pipes drain"
        )
        try? FileManager.default.removeItem(atPath: readinessPath)

        let lateFailureExecutor = CancellationIgnoringFailureExecutor()
        let lateFailureAdapter = AppleMusicDesktopAdapter(
            applicationStatus: TestApplicationStatus(isRunning: true),
            scriptExecutor: lateFailureExecutor,
            maximumPendingOperations: 1,
            cancellationDrainTimeoutNanoseconds: 1_000_000_000
        )
        await lateFailureAdapter.activate()
        _ = try! await lateFailureAdapter.refresh()

        let explicitlyCancelledID = MediaOperationID()
        let explicitlyCancelledRefresh = Task {
            try await lateFailureAdapter.refresh(operationID: explicitlyCancelledID)
        }
        await lateFailureExecutor.firstFailureStarted.wait()
        let explicitCancellation = Task {
            await lateFailureAdapter.cancel(explicitlyCancelledID)
        }
        await lateFailureExecutor.waitForCancelCount(1)
        await lateFailureExecutor.releaseFirstFailure()
        await explicitCancellation.value
        let explicitFailureResult = await mediaError(from: explicitlyCancelledRefresh.result)
        let snapshotAfterExplicitCancel = await lateFailureAdapter.latestSnapshotForTesting
        let outstandingAfterExplicitCancel = await lateFailureAdapter.outstandingWorkCountForTesting
        check(
            explicitFailureResult == .cancelled(source: .appleMusic),
            "explicit cancellation wins over a later noncooperative executor failure"
        )
        check(
            snapshotAfterExplicitCancel?.title == "Stable"
                && outstandingAfterExplicitCancel == 0,
            "cancelled executor failure preserves state and releases capacity once"
        )

        let deactivatedRefresh = Task { try await lateFailureAdapter.refresh() }
        await lateFailureExecutor.secondFailureStarted.wait()
        let lateFailureDeactivation = Task { await lateFailureAdapter.deactivate() }
        await lateFailureExecutor.waitForCancelCount(2)
        await lateFailureExecutor.releaseSecondFailure()
        await lateFailureDeactivation.value
        let deactivatedFailureResult = await mediaError(from: deactivatedRefresh.result)
        let snapshotAfterFailureDeactivation = await lateFailureAdapter.latestSnapshotForTesting
        let outstandingAfterFailureDeactivation = await lateFailureAdapter
            .outstandingWorkCountForTesting
        check(
            deactivatedFailureResult == .cancelled(source: .appleMusic),
            "deactivation wins over a later noncooperative executor failure"
        )
        check(
            snapshotAfterFailureDeactivation == nil
                && outstandingAfterFailureDeactivation == 0,
            "deactivated executor failure cannot restore state or leak admission"
        )
        await lateFailureAdapter.activate()
        let replacementAfterFailures = try! await lateFailureAdapter.refresh()
        let lateFailurePeak = await lateFailureExecutor.maximumConcurrentExecutions
        if case let .snapshot(snapshot) = replacementAfterFailures {
            check(
                snapshot.title == "Replacement" && lateFailurePeak == 1,
                "failure cancellation capacity is reusable without duplicate release"
            )
        } else {
            check(false, "failure cancellation capacity is reusable without duplicate release")
        }
        await lateFailureAdapter.deactivate()

        let noncooperative = NonCooperativeScriptExecutor()
        let boundedAdapter = AppleMusicDesktopAdapter(
            applicationStatus: TestApplicationStatus(isRunning: true),
            scriptExecutor: noncooperative,
            cancellationDrainTimeoutNanoseconds: 20_000_000
        )
        await boundedAdapter.activate()
        let staleRefresh = Task { try await boundedAdapter.refresh() }
        await noncooperative.firstStarted.wait()
        let start = ContinuousClock.now
        await boundedAdapter.deactivate()
        let drainDuration = start.duration(to: .now)
        check(
            drainDuration < .seconds(1),
            "noncooperative injected cancellation is bounded"
        )

        await boundedAdapter.activate()
        let replacement = try! await boundedAdapter.refresh()
        if case let .snapshot(snapshot) = replacement {
            check(snapshot.title == "Replacement", "re-enable is not stranded behind retired work")
        } else {
            check(false, "re-enable is not stranded behind retired work")
        }
        await noncooperative.firstGate.open()
        let staleError = await mediaError(from: staleRefresh.result)
        check(
            staleError == .cancelled(source: .appleMusic),
            "late noncooperative completion remains generation-isolated"
        )
        await boundedAdapter.deactivate()

        let reusedIDExecutor = ReusedIDScriptExecutor()
        let reusedIDAdapter = AppleMusicDesktopAdapter(
            applicationStatus: TestApplicationStatus(isRunning: true),
            scriptExecutor: reusedIDExecutor,
            cancellationDrainTimeoutNanoseconds: 20_000_000
        )
        await reusedIDAdapter.activate()
        let reusedID = MediaOperationID()
        let retiredRefresh = Task {
            try await reusedIDAdapter.refresh(operationID: reusedID)
        }
        await reusedIDExecutor.firstStarted.wait()
        await reusedIDAdapter.cancel(reusedID)
        let retiredRefreshError = await mediaError(from: retiredRefresh.result)
        check(
            retiredRefreshError == .cancelled(source: .appleMusic),
            "timed-out cancellation completes the caller-facing operation"
        )
        let reusedRefresh = Task {
            try await reusedIDAdapter.refresh(operationID: reusedID)
        }
        await reusedIDExecutor.secondStarted.wait()
        await reusedIDExecutor.firstGate.open()
        var outstandingAfterRetiredSettlement = await reusedIDAdapter
            .outstandingWorkCountForTesting
        for _ in 0 ..< 1_000 {
            outstandingAfterRetiredSettlement = await reusedIDAdapter
                .outstandingWorkCountForTesting
            if outstandingAfterRetiredSettlement == 1 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        check(
            outstandingAfterRetiredSettlement == 1,
            "retired physical work settles before ABA state inspection"
        )
        let snapshotDuringReuse = await reusedIDAdapter.latestSnapshotForTesting
        check(
            snapshotDuringReuse == nil,
            "retired work cannot mutate state while its explicit operation ID is reused"
        )
        await reusedIDExecutor.secondGate.open()
        let reusedUpdate = try! await reusedRefresh.value
        if case let .snapshot(snapshot) = reusedUpdate {
            check(snapshot.title == "Replacement", "reused explicit ID belongs only to new admission")
        } else {
            check(false, "reused explicit ID belongs only to new admission")
        }
        await reusedIDAdapter.deactivate()

        let repeatedRetirementExecutor = RepeatedRetirementScriptExecutor()
        let repeatedRetirementAdapter = AppleMusicDesktopAdapter(
            applicationStatus: TestApplicationStatus(isRunning: true),
            scriptExecutor: repeatedRetirementExecutor,
            maximumPendingOperations: 2,
            cancellationDrainTimeoutNanoseconds: 10_000_000
        )
        await repeatedRetirementAdapter.activate()
        let firstRetiredID = MediaOperationID()
        let firstRetirement = Task {
            try await repeatedRetirementAdapter.refresh(operationID: firstRetiredID)
        }
        await repeatedRetirementExecutor.waitForStartCount(1)
        await repeatedRetirementAdapter.cancel(firstRetiredID)
        _ = await firstRetirement.result
        let secondRetiredID = MediaOperationID()
        let secondRetirement = Task {
            try await repeatedRetirementAdapter.refresh(operationID: secondRetiredID)
        }
        await repeatedRetirementExecutor.waitForStartCount(2)
        await repeatedRetirementAdapter.cancel(secondRetiredID)
        _ = await secondRetirement.result
        await expectMediaError(
            .operationQueueFull(source: .appleMusic, limit: 2),
            "retired noncooperative adapter work remains in admission accounting"
        ) {
            _ = try await repeatedRetirementAdapter.refresh()
        }
        let retiredPhysicalCount = await repeatedRetirementAdapter
            .outstandingWorkCountForTesting
        check(retiredPhysicalCount == 2, "repeated timeout retirement cannot hide physical work")
        await repeatedRetirementExecutor.releaseFirstTwo()
        for _ in 0 ..< 1_000 {
            if await repeatedRetirementAdapter.outstandingWorkCountForTesting == 0 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let settledPhysicalCount = await repeatedRetirementAdapter
            .outstandingWorkCountForTesting
        check(settledPhysicalCount == 0, "settled retired work releases adapter admission")
        _ = try! await repeatedRetirementAdapter.refresh()
        let repeatedRetirementPeak = await repeatedRetirementExecutor.maximumConcurrentExecutions
        check(repeatedRetirementPeak == 2, "noncooperative adapter execution stays physically bounded")
        await repeatedRetirementAdapter.deactivate()
    }

    private func verifyAdapterErrorMappingAndScriptIsolation() async {
        let running = TestApplicationStatus(isRunning: true)
        let permissionExecutor = RecordingScriptExecutor(actions: [.failure(.permissionDenied)])
        let permissionAdapter = AppleMusicDesktopAdapter(
            applicationStatus: running,
            scriptExecutor: permissionExecutor
        )
        await permissionAdapter.activate()
        await expectMediaError(
            .permissionDenied(source: .appleMusic),
            "automation denial maps to typed adapter error"
        ) {
            _ = try await permissionAdapter.refresh()
        }
        await permissionAdapter.deactivate()

        let malformedExecutor = RecordingScriptExecutor(actions: [.output("malformed")])
        let malformedAdapter = SpotifyDesktopAdapter(
            applicationStatus: running,
            scriptExecutor: malformedExecutor
        )
        await malformedAdapter.activate()
        await expectMediaError(
            .malformedResponse(source: .spotify),
            "malformed scripting output maps safely"
        ) {
            _ = try await malformedAdapter.refresh()
        }
        await malformedAdapter.deactivate()

        let invalidNumericTokens = ["alphabetic", "", "NaN", "+Inf", "-Inf", "1e9999"]
        var malformedNumericOutputs: [(field: String, token: String, output: String)] = []
        for token in invalidNumericTokens {
            malformedNumericOutputs.append(
                ("duration", token, validScriptOutput(duration: token))
            )
            malformedNumericOutputs.append(
                ("position", token, validScriptOutput(position: token))
            )
            malformedNumericOutputs.append(
                ("volume", token, validScriptOutput(volume: token))
            )
        }
        let numericExecutor = RecordingScriptExecutor(
            actions: [.output(validScriptOutput(title: "Stable"))]
                + malformedNumericOutputs.map { .output($0.output) }
                + [.output(validScriptOutput(title: "Reusable"))]
        )
        let numericAdapter = AppleMusicDesktopAdapter(
            applicationStatus: running,
            scriptExecutor: numericExecutor,
            maximumPendingOperations: 1
        )
        let numericCoordinator = MediaCoordinator(adapters: [numericAdapter])
        await numericCoordinator.setEnabled(true, for: .appleMusic)
        _ = try! await numericCoordinator.refresh(.appleMusic)
        for malformed in malformedNumericOutputs {
            let refreshResult = await result {
                try await numericCoordinator.refresh(.appleMusic)
            }
            check(
                mediaError(from: refreshResult) == .malformedResponse(source: .appleMusic),
                "\(malformed.field) rejects malformed numeric token '\(malformed.token)'"
            )
            let retainedSnapshot = await numericCoordinator.snapshot(for: .appleMusic)
            let malformedHealth = await numericCoordinator.health(for: .appleMusic)
            let outstanding = await numericAdapter.outstandingWorkCountForTesting
            check(
                retainedSnapshot?.title == "Stable"
                    && malformedHealth.availability == .degraded
                    && malformedHealth.lastError == .malformedResponse(source: .appleMusic)
                    && outstanding == 0,
                "\(malformed.field) malformed token cannot publish state or retain capacity"
            )
        }
        let numericReuse = try! await numericCoordinator.refresh(.appleMusic)
        let numericRequestCount = await numericExecutor.requests().count
        check(
            numericReuse?.title == "Reusable"
                && numericRequestCount == malformedNumericOutputs.count + 2,
            "malformed numeric response capacity is reusable after every rejection"
        )
        await numericCoordinator.stop()

        let invalidUTF8Runner = StaticResultProcessRunner(
            result: MediaScriptProcessResult(
                exitCode: 0,
                standardOutput: Data([0xff, 0xfe, 0x80]),
                standardError: Data()
            )
        )
        let invalidUTF8Executor = ProcessMediaScriptExecutor(
            processRunner: invalidUTF8Runner
        )
        let invalidUTF8Result = await result {
            try await invalidUTF8Executor.execute(
                MediaScriptRequest(route: .appleMusicSnapshot)
            )
        }
        let invalidUTF8Error: MediaScriptExecutionError?
        switch invalidUTF8Result {
        case .success:
            invalidUTF8Error = nil
        case let .failure(error):
            invalidUTF8Error = error as? MediaScriptExecutionError
        }
        let invalidUTF8Runs = await invalidUTF8Runner.runCount
        check(
            invalidUTF8Error == .malformedResponse && invalidUTF8Runs == 1,
            "process executor rejects replacement-decoded invalid UTF-8 stdout"
        )
        let invalidUTF8Adapter = AppleMusicDesktopAdapter(
            applicationStatus: running,
            scriptExecutor: invalidUTF8Executor,
            maximumPendingOperations: 1
        )
        await invalidUTF8Adapter.activate()
        await expectMediaError(
            .malformedResponse(source: .appleMusic),
            "invalid UTF-8 process output maps to typed adapter malformed response"
        ) {
            _ = try await invalidUTF8Adapter.refresh()
        }
        let invalidUTF8Outstanding = await invalidUTF8Adapter.outstandingWorkCountForTesting
        let mappedInvalidUTF8Runs = await invalidUTF8Runner.runCount
        check(
            invalidUTF8Outstanding == 0 && mappedInvalidUTF8Runs == 2,
            "invalid UTF-8 adapter failure releases process and adapter capacity"
        )
        await invalidUTF8Adapter.deactivate()

        let maliciousTitle = "Song \"; quit application \"Music\"; --"
        let isolatedExecutor = RecordingScriptExecutor(
            actions: [
                .output(validScriptOutput(title: maliciousTitle)),
                .output(""),
            ]
        )
        let isolatedAdapter = AppleMusicDesktopAdapter(
            applicationStatus: running,
            scriptExecutor: isolatedExecutor
        )
        await isolatedAdapter.activate()
        _ = try! await isolatedAdapter.refresh()
        try! await isolatedAdapter.perform(.setVolume(9))

        let requests = await isolatedExecutor.requests()
        check(
            requests.map(\.route) == [.appleMusicSnapshot, .appleMusicVolume],
            "adapter selects only closed fixed script routes"
        )
        check(requests.last?.arguments == ["100"], "validated numeric value is passed only through argv")
        check(
            requests.allSatisfy { request in
                !request.arguments.contains { $0.contains(maliciousTitle) }
            },
            "now-playing text is never interpolated into a script or argv"
        )
        await isolatedAdapter.deactivate()

        let processExecutor = ProcessMediaScriptExecutor()
        do {
            _ = try await processExecutor.execute(
                MediaScriptRequest(
                    route: .appleMusicSeek,
                    arguments: ["0; quit application \"Music\""]
                )
            )
            check(false, "process boundary rejects nonnumeric command argv before launch")
        } catch {
            check(
                error as? MediaScriptExecutionError == .failed(exitCode: nil),
                "process boundary rejects nonnumeric command argv before launch"
            )
        }
    }

    private func verifyClosedProcessAPISurface() {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let processSourceURL = repository.appendingPathComponent(
            "Sources/EryloIntegrations/MediaScriptProcess.swift"
        )
        let adapterSourceURL = repository.appendingPathComponent(
            "Sources/EryloIntegrations/DesktopMediaAdapters.swift"
        )
        let processSource = (try? String(contentsOf: processSourceURL, encoding: .utf8)) ?? ""
        let adapterSource = (try? String(contentsOf: adapterSourceURL, encoding: .utf8)) ?? ""
        check(
            processSource.contains(
                "@_spi(Testing) public protocol MediaScriptProcessRunning"
            ),
            "raw argv runner protocol remains testing SPI"
        )
        check(
            processSource.contains(
                "@_spi(Testing) public actor FoundationMediaScriptProcessRunner"
            ),
            "raw argv runner implementation remains testing SPI"
        )
        check(
            adapterSource.contains(
                "public init(limits: MediaScriptProcessLimits = MediaScriptProcessLimits())"
            ) && adapterSource.contains(
                "@_spi(Testing)\n    public init(\n        processRunner: any MediaScriptProcessRunning"
            ),
            "production executor exposes only validated requests, not raw argv injection"
        )
    }

    private func verifyProcessRunnerBoundsAndTerminalRaces() async {
        let executableURL = URL(
            fileURLWithPath: CommandLine.arguments[0],
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardizedFileURL
        let normalLimits = MediaScriptProcessLimits(
            maximumStandardOutputBytes: 512 * 1_024,
            maximumStandardErrorBytes: 512 * 1_024,
            timeoutNanoseconds: 2_000_000_000,
            terminationGraceNanoseconds: 50_000_000
        )

        let normalRunner = FoundationMediaScriptProcessRunner(executableURL: executableURL)
        let normalID = MediaOperationID()
        let normal = try! await normalRunner.run(
            arguments: [MediaProcessHelper.flag, "normal"],
            operationID: normalID,
            limits: normalLimits
        )
        check(normal.standardOutput == Data("stdout".utf8), "process runner captures stdout")
        check(normal.standardError == Data("stderr".utf8), "process runner captures stderr")
        let exitOne = try! await normalRunner.run(
            arguments: [MediaProcessHelper.flag, "exit-one"],
            operationID: MediaOperationID(),
            limits: normalLimits
        )
        check(exitOne.exitCode == 1, "process runner decodes wait status into an exit code")

        let collisionDescriptorsBefore = openFileDescriptorCount()
        var collisionRunsAreSafe = true
        for mask in ["0", "1", "2", "01", "02", "12", "012"] {
            do {
                let result = try await normalRunner.run(
                    arguments: [MediaProcessHelper.flag, "stdio-collision", mask],
                    operationID: MediaOperationID(),
                    limits: normalLimits
                )
                collisionRunsAreSafe = collisionRunsAreSafe
                    && result.exitCode == 0
                    && result.standardOutput == Data("23\tstdout|fds=0\tstderr".utf8)
                    && result.standardError.isEmpty
            } catch {
                collisionRunsAreSafe = false
            }
        }
        check(
            collisionRunsAreSafe,
            "closed or remapped host stdio cannot collide with child pipe actions"
        )
        let collisionDescriptorsAfter = openFileDescriptorCount()
        let collisionProcesses = await normalRunner.activeProcessCount
        let collisionReaders = await normalRunner.activeReaderCount
        check(
            collisionDescriptorsAfter == collisionDescriptorsBefore
                && collisionProcesses == 0
                && collisionReaders == 0,
            "all low-descriptor collision runs close pipes, readers, and processes"
        )
        await normalRunner.cancel(normalID)
        let normalRemaining = await normalRunner.activeProcessCount
        check(normalRemaining == 0, "late process cancellation leaves no tombstone")

        let failingSpawnSystem = FailingSpawnPOSIXProcessSystem()
        let failingSpawnRunner = FoundationMediaScriptProcessRunner(
            executableURL: executableURL,
            system: failingSpawnSystem
        )
        _ = await result {
            try await failingSpawnRunner.run(
                arguments: [MediaProcessHelper.flag, "normal"],
                operationID: MediaOperationID(),
                limits: normalLimits
            )
        }
        let descriptorsBeforeFailures = openFileDescriptorCount()
        var allLaunchesFailedSafely = true
        for _ in 0 ..< 32 {
            let launchResult = await result {
                try await failingSpawnRunner.run(
                    arguments: [MediaProcessHelper.flag, "normal"],
                    operationID: MediaOperationID(),
                    limits: normalLimits
                )
            }
            allLaunchesFailedSafely = allLaunchesFailedSafely
                && processError(from: launchResult) == .launchFailed
        }
        check(allLaunchesFailedSafely, "spawn failure maps to a typed launch failure")
        let descriptorsAfterFailures = openFileDescriptorCount()
        let failedLaunchProcesses = await failingSpawnRunner.activeProcessCount
        check(
            descriptorsAfterFailures == descriptorsBeforeFailures
                && failedLaunchProcesses == 0,
            "spawn failures release partially prepared pipes and admission"
        )

        let outputRunner = FoundationMediaScriptProcessRunner(executableURL: executableURL)
        let outputResult = await result {
            try await outputRunner.run(
                arguments: [MediaProcessHelper.flag, "stdout-flood"],
                operationID: MediaOperationID(),
                limits: MediaScriptProcessLimits(
                    maximumStandardOutputBytes: 4_096,
                    maximumStandardErrorBytes: 4_096,
                    timeoutNanoseconds: 2_000_000_000
                )
            )
        }
        check(
            processError(from: outputResult)
                == .standardOutputLimitExceeded(maximumBytes: 4_096),
            "stdout is hard-capped while draining"
        )

        let errorRunner = FoundationMediaScriptProcessRunner(executableURL: executableURL)
        let errorResult = await result {
            try await errorRunner.run(
                arguments: [MediaProcessHelper.flag, "stderr-flood"],
                operationID: MediaOperationID(),
                limits: MediaScriptProcessLimits(
                    maximumStandardOutputBytes: 4_096,
                    maximumStandardErrorBytes: 4_096,
                    timeoutNanoseconds: 2_000_000_000
                )
            )
        }
        check(
            processError(from: errorResult)
                == .standardErrorLimitExceeded(maximumBytes: 4_096),
            "stderr is hard-capped while draining"
        )

        let interleavedRunner = FoundationMediaScriptProcessRunner(executableURL: executableURL)
        let interleaved = try! await interleavedRunner.run(
            arguments: [MediaProcessHelper.flag, "interleaved"],
            operationID: MediaOperationID(),
            limits: normalLimits
        )
        check(
            interleaved.standardOutput.count == 128 * 1_024
                && interleaved.standardError.count == 128 * 1_024,
            "stdout and stderr drain concurrently without pipe deadlock"
        )

        let inheritedCleanupPath = temporaryMediaHelperMarkerPath()
        let inheritedReadyPath = temporaryMediaHelperMarkerPath()
        let inheritedSettledPath = temporaryMediaHelperMarkerPath()
        let inheritedPipeRunner = FoundationMediaScriptProcessRunner(executableURL: executableURL)
        let inheritedPipeStart = ContinuousClock.now
        let inheritedPipeResult = try! await inheritedPipeRunner.run(
            arguments: [
                MediaProcessHelper.flag,
                "descendant-holds-fds",
                inheritedCleanupPath,
                inheritedReadyPath,
                inheritedSettledPath,
            ],
            operationID: MediaOperationID(),
            limits: MediaScriptProcessLimits(
                timeoutNanoseconds: 2_000_000_000,
                postTerminationDrainNanoseconds: 30_000_000
            )
        )
        let inheritedPipeDuration = inheritedPipeStart.duration(to: .now)
        let inheritedProcesses = await inheritedPipeRunner.activeProcessCount
        let inheritedReaders = await inheritedPipeRunner.activeReaderCount
        check(inheritedPipeResult.exitCode == 0, "direct child exit is retained with inherited pipes")
        check(
            inheritedPipeDuration < .seconds(1),
            "descendant-held pipes use the configured deadline, not ten-second EOF"
        )
        check(
            inheritedProcesses == 0 && inheritedReaders == 0,
            "bounded inherited-pipe completion leaves no process or reader work"
        )
        let inheritedReady = await waitForFile(atPath: inheritedReadyPath)
        _ = FileManager.default.createFile(atPath: inheritedCleanupPath, contents: Data())
        let inheritedSettled = await waitForFile(atPath: inheritedSettledPath)
        let inheritedHelpersExited = await waitForRecordedProcessesToExit(
            atPath: inheritedReadyPath
        )
        check(
            inheritedReady && inheritedSettled && inheritedHelpersExited,
            "descendant-held-pipe helper is explicitly stopped and reaped"
        )
        removeMediaHelperFiles([
            inheritedCleanupPath,
            inheritedReadyPath,
            inheritedSettledPath,
        ])

        let trickleCleanupPath = temporaryMediaHelperMarkerPath()
        let trickleReadyPath = temporaryMediaHelperMarkerPath()
        let trickleSettledPath = temporaryMediaHelperMarkerPath()
        let trickleRunner = FoundationMediaScriptProcessRunner(executableURL: executableURL)
        let trickleStart = ContinuousClock.now
        _ = try! await trickleRunner.run(
            arguments: [
                MediaProcessHelper.flag,
                "descendant-trickle",
                trickleCleanupPath,
                trickleReadyPath,
                trickleSettledPath,
            ],
            operationID: MediaOperationID(),
            limits: MediaScriptProcessLimits(
                maximumStandardOutputBytes: 512 * 1_024,
                maximumStandardErrorBytes: 512 * 1_024,
                timeoutNanoseconds: 2_000_000_000,
                postTerminationDrainNanoseconds: 30_000_000
            )
        )
        check(
            trickleStart.duration(to: .now) < .seconds(1),
            "post-exit absolute deadline bounds successful-read trickle before ten-second EOF"
        )
        let trickleReady = await waitForFile(atPath: trickleReadyPath)
        _ = FileManager.default.createFile(atPath: trickleCleanupPath, contents: Data())
        let trickleSettled = await waitForFile(atPath: trickleSettledPath)
        let trickleHelpersExited = await waitForRecordedProcessesToExit(
            atPath: trickleReadyPath
        )
        let trickleProcesses = await trickleRunner.activeProcessCount
        let trickleReaders = await trickleRunner.activeReaderCount
        check(
            trickleReady && trickleSettled && trickleHelpersExited
                && trickleProcesses == 0 && trickleReaders == 0,
            "trickle descendant is explicitly reaped without reader or process leaks"
        )
        removeMediaHelperFiles([
            trickleCleanupPath,
            trickleReadyPath,
            trickleSettledPath,
        ])

        let timeoutRunner = FoundationMediaScriptProcessRunner(executableURL: executableURL)
        let timeoutResult = await result {
            try await timeoutRunner.run(
                arguments: [MediaProcessHelper.flag, "hang"],
                operationID: MediaOperationID(),
                limits: MediaScriptProcessLimits(
                    timeoutNanoseconds: 30_000_000,
                    terminationGraceNanoseconds: 30_000_000
                )
            )
        }
        check(processError(from: timeoutResult) == .timedOut, "hung process times out")

        let escalationRunner = FoundationMediaScriptProcessRunner(executableURL: executableURL)
        let escalationReadinessPath = temporaryMediaHelperMarkerPath()
        let escalationResult = await result {
            try await escalationRunner.run(
                arguments: [
                    MediaProcessHelper.flag,
                    "ignore-term-int-hang",
                    escalationReadinessPath,
                ],
                operationID: MediaOperationID(),
                limits: MediaScriptProcessLimits(
                    timeoutNanoseconds: 500_000_000,
                    terminationGraceNanoseconds: 30_000_000
                )
            )
        }
        check(
            processError(from: escalationResult) == .timedOut,
            "timeout cause wins after forced escalation"
        )
        check(
            FileManager.default.fileExists(atPath: escalationReadinessPath),
            "ignore-signal helper installed both signal handlers before timeout"
        )
        try? FileManager.default.removeItem(atPath: escalationReadinessPath)
        check(true, "ignored TERM and INT escalate to owned SIGKILL and reap")

        let capacityRunner = FoundationMediaScriptProcessRunner(
            executableURL: executableURL,
            maximumActiveProcesses: 1
        )
        let heldID = MediaOperationID()
        let heldProcess = Task {
            try await capacityRunner.run(
                arguments: [MediaProcessHelper.flag, "hang"],
                operationID: heldID,
                limits: normalLimits
            )
        }
        await waitForActiveProcess(in: capacityRunner)
        let capacityResult = await result {
            try await capacityRunner.run(
                arguments: [MediaProcessHelper.flag, "normal"],
                operationID: MediaOperationID(),
                limits: normalLimits
            )
        }
        check(
            processError(from: capacityResult) == .capacityExceeded(limit: 1),
            "process runner enforces active-process admission"
        )
        await capacityRunner.cancel(heldID)
        let heldError = processError(from: await heldProcess.result)
        check(heldError == .cancelled, "active process cancellation reports its first terminal cause")
        let reusableProcess = try! await capacityRunner.run(
            arguments: [MediaProcessHelper.flag, "normal"],
            operationID: MediaOperationID(),
            limits: normalLimits
        )
        check(reusableProcess.exitCode == 0, "process admission capacity is reusable")

        await verifyOwnedPOSIXLifecycle()

        let childMissingSystem = ScriptedPOSIXProcessSystem(
            waitResults: [.failed(errno: ECHILD)]
        )
        let childMissingRunner = FoundationMediaScriptProcessRunner(
            executableURL: executableURL,
            system: childMissingSystem
        )
        let childMissingResult = await result {
            try await childMissingRunner.run(
                arguments: [MediaProcessHelper.flag, "normal"],
                operationID: MediaOperationID(),
                limits: normalLimits
            )
        }
        check(
            processError(from: childMissingResult) == .processLifecycleFailed(errno: ECHILD),
            "ECHILD is a typed fatal lifecycle failure"
        )
        let childMissingProcesses = await childMissingRunner.activeProcessCount
        let childMissingReaders = await childMissingRunner.activeReaderCount
        check(
            childMissingProcesses == 0 && childMissingReaders == 0,
            "lifecycle failure joins readers before returning"
        )
    }

    private func verifyOwnedPOSIXLifecycle() async {
        let interruptedSystem = ScriptedPOSIXProcessSystem(
            waitResults: [
                .failed(errno: EINTR),
                .exited(rawStatus: 1 << 8),
            ]
        )
        let interruptedProcess = OwnedMediaProcess(
            system: interruptedSystem,
            terminationGraceNanoseconds: 100_000_000
        )
        interruptedProcess.markStarted(4_201)
        let decodedExit = try! await interruptedProcess.waitForExit()
        check(decodedExit == 1, "owned wait retries EINTR and decodes WEXITSTATUS semantics")
        check(interruptedSystem.waitCallCount == 2, "EINTR is retried without a false reap")

        let naturalSystem = ScriptedPOSIXProcessSystem(
            waitResults: [.exited(rawStatus: 0)]
        )
        let naturalProcess = OwnedMediaProcess(
            system: naturalSystem,
            terminationGraceNanoseconds: 20_000_000
        )
        naturalProcess.markStarted(4_202)
        _ = try! await naturalProcess.waitForExit()
        naturalProcess.requestStop(.timedOut)
        naturalProcess.requestStop(.cancelled)
        check(
            naturalProcess.stopReason == nil && naturalSystem.signals.isEmpty,
            "late timeout or cancellation cannot replace a reaped natural exit"
        )

        let stoppedSystem = ScriptedPOSIXProcessSystem(
            waitResults: [.exited(rawStatus: SIGKILL)]
        )
        let stoppedProcess = OwnedMediaProcess(
            system: stoppedSystem,
            terminationGraceNanoseconds: 100_000_000
        )
        stoppedProcess.markStarted(4_203)
        stoppedProcess.requestStop(.cancelled)
        stoppedProcess.requestStop(.timedOut)
        let signalExit = try! await stoppedProcess.waitForExit()
        check(stoppedProcess.stopReason == .cancelled, "first requested terminal cause remains stable")
        check(signalExit == 128 + SIGKILL, "signal termination decodes WTERMSIG semantics")

        let earlyExitSystem = ScriptedPOSIXProcessSystem(
            waitResults: [.exited(rawStatus: 0)]
        )
        let earlyExitScheduler = GatedEscalationScheduler()
        let earlyExitProcess = OwnedMediaProcess(
            system: earlyExitSystem,
            terminationGraceNanoseconds: 20_000_000,
            escalationScheduler: earlyExitScheduler
        )
        earlyExitProcess.markStarted(4_204)
        earlyExitProcess.requestStop(.timedOut)
        await earlyExitScheduler.waitUntilStarted()
        _ = try! await earlyExitProcess.waitForExit()
        await earlyExitScheduler.release()
        await earlyExitScheduler.waitUntilSettled()
        check(
            earlyExitSystem.signals == [SIGTERM],
            "reaped natural exit deterministically cancels the pending hard stop"
        )

        let fatalSystem = ScriptedPOSIXProcessSystem(
            waitResults: [
                .failed(errno: EIO),
                .exited(rawStatus: SIGKILL),
            ]
        )
        let fatalProcess = OwnedMediaProcess(
            system: fatalSystem,
            terminationGraceNanoseconds: 100_000_000
        )
        fatalProcess.markStarted(4_205)
        let fatalResult = await result { try await fatalProcess.waitForExit() }
        check(
            processError(from: fatalResult) == .processLifecycleFailed(errno: EIO),
            "non-EINTR wait failure is typed after the owned child is hard-stopped and reaped"
        )
        check(
            fatalSystem.signals == [SIGKILL],
            "fatal wait failure does not silently orphan the owned child"
        )

        let lifecycleFirstSystem = ScriptedPOSIXProcessSystem(
            waitResults: [
                .failed(errno: EIO),
                .running,
            ]
        )
        let lifecycleFirstProcess = OwnedMediaProcess(
            system: lifecycleFirstSystem,
            terminationGraceNanoseconds: 100_000_000
        )
        lifecycleFirstProcess.markStarted(4_207)
        let lifecycleFirstWaiter = Task {
            try await lifecycleFirstProcess.waitForExit()
        }
        for _ in 0 ..< 1_000 {
            if lifecycleFirstSystem.waitCallCount >= 1 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        lifecycleFirstProcess.requestStop(.timedOut)
        lifecycleFirstSystem.appendWaitResult(.exited(rawStatus: SIGKILL))
        let lifecycleFirstResult = await lifecycleFirstWaiter.result
        check(
            processError(from: lifecycleFirstResult) == .processLifecycleFailed(errno: EIO)
                && lifecycleFirstProcess.stopReason == nil,
            "later timeout cannot replace an earlier fatal lifecycle cause"
        )

        let cancellationFirstSystem = ScriptedPOSIXProcessSystem(
            waitResults: [
                .failed(errno: EIO),
                .exited(rawStatus: SIGKILL),
            ]
        )
        let cancellationFirstProcess = OwnedMediaProcess(
            system: cancellationFirstSystem,
            terminationGraceNanoseconds: 100_000_000
        )
        cancellationFirstProcess.markStarted(4_208)
        cancellationFirstProcess.requestStop(.cancelled)
        _ = try! await cancellationFirstProcess.waitForExit()
        check(
            cancellationFirstProcess.stopReason == .cancelled,
            "later lifecycle failure cannot replace an earlier cancellation cause"
        )

        let raceSystem = BlockingKillPOSIXProcessSystem()
        let raceProcess = OwnedMediaProcess(
            system: raceSystem,
            terminationGraceNanoseconds: 10_000_000
        )
        raceProcess.markStarted(4_206)
        raceProcess.requestStop(.timedOut)
        let raceWaiter = Task { try await raceProcess.waitForExit() }
        await raceSystem.killStarted.wait()
        raceSystem.allowExit()
        check(
            raceSystem.reapCount == 0 && raceSystem.generation == 1,
            "reap cannot win after the final ownership check but before SIGKILL"
        )
        raceSystem.releaseKill()
        _ = try! await raceWaiter.value
        check(
            raceSystem.signalGenerations.allSatisfy { $0 == 1 }
                && raceSystem.generation == 2,
            "owned signaling cannot target a reused PID generation"
        )
    }

    private func verifyArtworkBounds() async {
        let key = try! MediaArtworkCacheKey("spotify:artwork")
        let reference = try! MediaArtworkReference(
            remoteURL: URL(string: "https://example.invalid/artwork.jpg")!,
            cacheKey: key
        )
        let loader = TestArtworkLoader(
            data: Data([0, 1, 2, 3, 4]),
            honorsMaximum: false
        )
        let decoder = TestArtworkDecoder()
        let pipeline = BoundedMediaArtworkPipeline(
            loader: loader,
            decoder: decoder,
            maximumEncodedBytes: 4,
            maximumTotalDecodedBytes: 8,
            maximumCachedEntryBytes: 8
        )

        do {
            _ = try await pipeline.artwork(for: reference)
            check(false, "oversized artwork is rejected before decoding")
        } catch {
            check(
                error as? MediaArtworkPipelineError == .payloadTooLarge(maximumBytes: 4),
                "oversized artwork is rejected before decoding"
            )
        }
        let oversizedDecodeCalls = await decoder.decodeCalls
        let receivedMaximums = await loader.receivedMaximumBytes
        let oversizedCachedBytes = await pipeline.cachedByteCount
        check(oversizedDecodeCalls == 0, "oversized artwork never reaches decoder")
        check(receivedMaximums == [4], "loader receives its materialization byte bound")
        check(oversizedCachedBytes == 0, "oversized artwork is not cached")

        let boundedLoader = TestArtworkLoader(data: Data([0, 1, 2, 3]))
        let boundedDecoder = TestArtworkDecoder()
        let boundedPipeline = BoundedMediaArtworkPipeline(
            loader: boundedLoader,
            decoder: boundedDecoder,
            maximumEncodedBytes: 4,
            maximumTotalDecodedBytes: 4,
            maximumCachedEntryBytes: 4,
            maximumEntryCount: 1
        )
        _ = try! await boundedPipeline.artwork(for: reference)
        let secondKey = try! MediaArtworkCacheKey("spotify:artwork-2")
        let secondReference = try! MediaArtworkReference(
            remoteURL: URL(string: "https://example.invalid/artwork-2.jpg")!,
            cacheKey: secondKey
        )
        _ = try! await boundedPipeline.artwork(for: secondReference)
        let boundedCachedBytes = await boundedPipeline.cachedByteCount
        let boundedEntryCount = await boundedPipeline.cachedEntryCount
        check(boundedCachedBytes == 4, "memory artwork cache stays within byte bound")
        check(boundedEntryCount == 1, "memory artwork cache evicts least-recent entry")
        await boundedPipeline.removeAll()
        let purgedCachedBytes = await boundedPipeline.cachedByteCount
        check(purgedCachedBytes == 0, "artwork memory history can be purged")

        let bombDecoder = TestArtworkDecoder(
            pixelWidth: 8_192,
            pixelHeight: 8_192,
            decodedByteCost: 1
        )
        let bombPipeline = BoundedMediaArtworkPipeline(
            loader: TestArtworkLoader(data: Data([1])),
            decoder: bombDecoder,
            maximumEncodedBytes: 4,
            decodeLimits: MediaArtworkDecodeLimits(
                maximumPixelWidth: 1_024,
                maximumPixelHeight: 1_024,
                maximumPixelCount: 1_048_576,
                maximumDecodedByteCost: 4 * 1_024 * 1_024
            )
        )
        do {
            _ = try await bombPipeline.artwork(for: reference)
            check(false, "decoded artwork dimensions are defensively validated")
        } catch {
            check(
                error as? MediaArtworkPipelineError == .invalidDecodedDimensions,
                "decoded artwork dimensions are defensively validated"
            )
        }

        let coalesceGate = AsyncGate()
        let coalesceStarted = AsyncGate()
        let coalesceLoader = TestArtworkLoader(
            data: Data([1, 2]),
            gate: coalesceGate,
            started: coalesceStarted
        )
        let coalesceDecoder = TestArtworkDecoder()
        let coalescePipeline = BoundedMediaArtworkPipeline(
            loader: coalesceLoader,
            decoder: coalesceDecoder,
            maximumEncodedBytes: 4,
            maximumInFlightLoads: 1
        )
        let firstCoalesced = Task { try await coalescePipeline.artwork(for: reference) }
        await coalesceStarted.wait()
        let secondCoalesced = Task { try await coalescePipeline.artwork(for: reference) }
        for _ in 0 ..< 8 { await Task.yield() }
        let coalescedInFlightCount = await coalescePipeline.inFlightLoadCount
        check(coalescedInFlightCount == 1, "same-key artwork misses coalesce")
        await coalesceGate.open()
        _ = try! await firstCoalesced.value
        _ = try! await secondCoalesced.value
        let coalescedLoadCalls = await coalesceLoader.loadCalls
        let coalescedDecodeCalls = await coalesceDecoder.decodeCalls
        check(coalescedLoadCalls == 1, "coalesced artwork performs one bounded load")
        check(coalescedDecodeCalls == 1, "coalesced artwork performs one decode")

        let inFlightGate = AsyncGate()
        let inFlightStarted = AsyncGate()
        let inFlightPipeline = BoundedMediaArtworkPipeline(
            loader: TestArtworkLoader(
                data: Data([1]),
                gate: inFlightGate,
                started: inFlightStarted
            ),
            decoder: TestArtworkDecoder(),
            maximumEncodedBytes: 4,
            maximumInFlightLoads: 1
        )
        let heldLoad = Task { try await inFlightPipeline.artwork(for: reference) }
        await inFlightStarted.wait()
        do {
            _ = try await inFlightPipeline.artwork(for: secondReference)
            check(false, "distinct in-flight artwork loads are bounded")
        } catch {
            check(
                error as? MediaArtworkPipelineError == .tooManyInFlightLoads(limit: 1),
                "distinct in-flight artwork loads are bounded"
            )
        }
        await inFlightGate.open()
        _ = try! await heldLoad.value

        let purgeLoader = PurgeRaceArtworkLoader(data: Data([9]))
        let purgePipeline = BoundedMediaArtworkPipeline(
            loader: purgeLoader,
            decoder: TestArtworkDecoder(),
            maximumEncodedBytes: 4
        )
        let staleLoad = Task { try await purgePipeline.artwork(for: reference) }
        await purgeLoader.firstStarted.wait()
        await purgePipeline.removeAll()
        let replacementLoad = Task { try await purgePipeline.artwork(for: reference) }
        await purgeLoader.secondStarted.wait()
        await purgeLoader.firstGate.open()
        let staleResult = await staleLoad.result
        let stalePipelineError: MediaArtworkPipelineError? = switch staleResult {
        case .success:
            nil
        case let .failure(error):
            error as? MediaArtworkPipelineError
        }
        check(stalePipelineError == .cancelled, "purge invalidates a non-cooperative stale load")
        let staleCachedEntryCount = await purgePipeline.cachedEntryCount
        check(staleCachedEntryCount == 0, "stale post-purge completion cannot repopulate cache")
        await purgeLoader.secondGate.open()
        _ = try! await replacementLoad.value
        let replacementCachedEntryCount = await purgePipeline.cachedEntryCount
        check(replacementCachedEntryCount == 1, "fresh same-key load can populate after purge")

        let repeatedPurgeLoader = RepeatedPurgeArtworkLoader(data: Data([7]))
        let repeatedPurgePipeline = BoundedMediaArtworkPipeline(
            loader: repeatedPurgeLoader,
            decoder: TestArtworkDecoder(),
            maximumEncodedBytes: 4,
            maximumInFlightLoads: 2
        )
        let firstPurged = Task { try await repeatedPurgePipeline.artwork(for: reference) }
        await repeatedPurgeLoader.waitForStartCount(1)
        await repeatedPurgePipeline.removeAll()
        let secondPurged = Task { try await repeatedPurgePipeline.artwork(for: reference) }
        await repeatedPurgeLoader.waitForStartCount(2)
        await repeatedPurgePipeline.removeAll()
        do {
            _ = try await repeatedPurgePipeline.artwork(for: reference)
            check(false, "cancelled-but-unsettled artwork remains in admission accounting")
        } catch {
            check(
                error as? MediaArtworkPipelineError == .tooManyInFlightLoads(limit: 2),
                "cancelled-but-unsettled artwork remains in admission accounting"
            )
        }
        let purgedOutstanding = await repeatedPurgePipeline.inFlightLoadCount
        check(purgedOutstanding == 2, "repeated purge cannot hide physical artwork work")
        await repeatedPurgeLoader.releaseFirstTwo()
        let firstPurgedError = await artworkError(from: firstPurged.result)
        let secondPurgedError = await artworkError(from: secondPurged.result)
        check(
            firstPurgedError == .cancelled && secondPurgedError == .cancelled,
            "noncooperative purged artwork completes only as cancelled"
        )
        let settledOutstanding = await repeatedPurgePipeline.inFlightLoadCount
        check(settledOutstanding == 0, "settled purged artwork releases global admission")
        _ = try! await repeatedPurgePipeline.artwork(for: reference)
        let physicalPeak = await repeatedPurgeLoader.maximumConcurrentLoads
        check(physicalPeak == 2, "repeated purge never exceeds configured physical load capacity")
    }

    private func verifySubscriberLifecycleAndBounds() async {
        let coordinator = MediaCoordinator(
            adapters: [],
            policy: MediaCoordinatorPolicy(maximumSubscribers: 1)
        )
        let stream = try! await coordinator.updates()
        let registeredSubscriberCount = await coordinator.activeSubscriberCount
        check(registeredSubscriberCount == 1, "subscriber is registered")

        await expectMediaError(
            .subscriberLimitReached(limit: 1),
            "subscriber count enforces configured bound"
        ) {
            _ = try await coordinator.updates()
        }

        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        _ = await consumer.result
        for _ in 0 ..< 16 { await Task.yield() }
        let cancelledSubscriberCount = await coordinator.activeSubscriberCount
        check(cancelledSubscriberCount == 0, "cancelled subscriber is removed")

        do {
            let replacement = try await coordinator.updates()
            check(true, "subscriber capacity is reusable after cancellation")
            let replacementConsumer = Task { for await _ in replacement {} }
            replacementConsumer.cancel()
            _ = await replacementConsumer.result
        } catch {
            check(false, "subscriber capacity is reusable after cancellation")
        }
        await coordinator.stop()
    }

    private func expectMediaError(
        _ expected: MediaError,
        _ name: String,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            check(false, name)
        } catch let error as MediaError {
            check(error == expected, name)
        } catch {
            check(false, name)
        }
    }

    private func mediaError<Success>(from result: Result<Success, Error>) -> MediaError? {
        switch result {
        case .success:
            nil
        case let .failure(error):
            error as? MediaError
        }
    }

    private func processError<Success>(
        from result: Result<Success, Error>
    ) -> MediaScriptProcessError? {
        switch result {
        case .success:
            nil
        case let .failure(error):
            error as? MediaScriptProcessError
        }
    }

    private func artworkError<Success>(
        from result: Result<Success, Error>
    ) -> MediaArtworkPipelineError? {
        switch result {
        case .success:
            nil
        case let .failure(error):
            error as? MediaArtworkPipelineError
        }
    }

    private func result<Success: Sendable>(
        operation: () async throws -> Success
    ) async -> Result<Success, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checkCount += 1
        if !condition() {
            failures.append(name)
        }
    }
}

private func makeSnapshot(
    source: MediaSource = .appleMusic,
    sequence: UInt64,
    trackIdentifier: String? = "track-1",
    title: String? = "Track",
    duration: TimeInterval? = 180,
    capabilities: MediaCapabilities = [.transport, .seek, .volume]
) throws -> NowPlayingSnapshot {
    try NowPlayingSnapshot(
        source: source,
        stamp: MediaUpdateStamp(sequence: sequence),
        trackIdentifier: trackIdentifier,
        title: title,
        artist: "Artist",
        album: "Album",
        duration: duration,
        position: 30,
        playbackState: .playing,
        volume: 0.5,
        capabilities: capabilities
    )
}

private func validScriptOutput(
    title: String = "Track",
    duration: String = "180",
    position: String = "30",
    volume: String = "50"
) -> String {
    [
        "playing",
        title,
        "Artist",
        "Album",
        "track-1",
        duration,
        position,
        volume,
        "sourceAsset",
        "track-1",
    ].joined(separator: "\t")
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

private actor GatedAdmissionObserver: MediaAdapterAdmissionObserving {
    let allGatedAttemptsArrived = AsyncGate()
    private let releaseGate = AsyncGate()
    private let passThroughAttempts: Int
    private let gatedAttempts: Int
    private var attemptCount = 0

    init(passThroughAttempts: Int, gatedAttempts: Int) {
        self.passThroughAttempts = passThroughAttempts
        self.gatedAttempts = gatedAttempts
    }

    func willAttemptAdmission(
        source: MediaSource,
        operationID: MediaOperationID
    ) async {
        attemptCount += 1
        let gatedAttempt = attemptCount - passThroughAttempts
        guard gatedAttempt > 0 else { return }
        if gatedAttempt == gatedAttempts {
            await allGatedAttemptsArrived.open()
        }
        await releaseGate.wait()
    }

    func releaseGatedAttempts() async {
        await releaseGate.open()
    }
}

private actor CompletionCounter {
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func recordCompletion() {
        count += 1
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }

    func waitForCount(_ expected: Int) async {
        guard count < expected else { return }
        await withCheckedContinuation { continuation in
            waiters.append((expected, continuation))
        }
    }
}

private actor GatedCommandCancellationObserver: MediaCoordinatorCancellationObserving {
    let dispatchStarted = AsyncGate()
    let dispatchFinished = AsyncGate()
    private let dispatchGate = AsyncGate()

    func willDispatchCommandCancellation() async {
        await dispatchStarted.open()
        await dispatchGate.wait()
        await dispatchFinished.open()
    }

    func releaseDispatch() async {
        await dispatchGate.open()
    }
}

private struct GatedFailingCommandMetrics: Sendable {
    let performCalls: Int
    let cancelCalls: Int
}

private enum CancellationIgnoringRefreshStep: Sendable {
    case immediateSuccess(MediaAdapterUpdate)
    case gatedSuccess(started: AsyncGate, release: AsyncGate, update: MediaAdapterUpdate)
    case gatedFailure(started: AsyncGate, release: AsyncGate, error: MediaError)
}

private enum CancellationIgnoringCommandStep: Sendable {
    case immediateSuccess
    case gatedSuccess(started: AsyncGate, release: AsyncGate)
    case gatedFailure(started: AsyncGate, release: AsyncGate, error: MediaError)
}

private struct CancellationIgnoringMediaMetrics: Sendable {
    let activeOperations: Int
    let maximumConcurrentOperations: Int
}

private actor CancellationIgnoringMediaAdapter: MediaAdapter {
    let source: MediaSource
    private var refreshSteps: [CancellationIgnoringRefreshStep]
    private var commandSteps: [CancellationIgnoringCommandStep]
    private let cancellationGates: [AsyncGate]
    private let cancellationStarts = CompletionCounter()
    private let cancellationSettlements = CompletionCounter()
    private var cancellationCount = 0
    private var activeOperations = 0
    private var maximumConcurrentOperations = 0

    init(
        source: MediaSource,
        refreshSteps: [CancellationIgnoringRefreshStep],
        commandSteps: [CancellationIgnoringCommandStep],
        cancellationGates: [AsyncGate]
    ) {
        self.source = source
        self.refreshSteps = refreshSteps
        self.commandSteps = commandSteps
        self.cancellationGates = cancellationGates
    }

    func activate() async {}
    func deactivate() async {}

    func updates() async -> AsyncStream<MediaAdapterUpdate> {
        AsyncStream { continuation in continuation.finish() }
    }

    func refresh(operationID: MediaOperationID) async throws -> MediaAdapterUpdate {
        activeOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperations)
        defer { activeOperations -= 1 }
        guard !refreshSteps.isEmpty else {
            throw MediaError.sourceUnavailable(source: source)
        }
        switch refreshSteps.removeFirst() {
        case let .immediateSuccess(update):
            return update
        case let .gatedSuccess(started, release, update):
            await started.open()
            await release.wait()
            return update
        case let .gatedFailure(started, release, error):
            await started.open()
            await release.wait()
            throw error
        }
    }

    func perform(_ command: MediaCommand, operationID: MediaOperationID) async throws {
        activeOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperations)
        defer { activeOperations -= 1 }
        guard !commandSteps.isEmpty else {
            throw MediaError.sourceUnavailable(source: source)
        }
        switch commandSteps.removeFirst() {
        case .immediateSuccess:
            return
        case let .gatedSuccess(started, release):
            await started.open()
            await release.wait()
        case let .gatedFailure(started, release, error):
            await started.open()
            await release.wait()
            throw error
        }
    }

    func cancel(_ operationID: MediaOperationID) async {
        let index = cancellationCount
        cancellationCount += 1
        await cancellationStarts.recordCompletion()
        if index < cancellationGates.count {
            await cancellationGates[index].wait()
        }
        await cancellationSettlements.recordCompletion()
    }

    func cancelAllPendingWork() async {}

    func waitForCancellationCount(_ count: Int) async {
        await cancellationStarts.waitForCount(count)
    }

    func waitForCancellationSettlementCount(_ count: Int) async {
        await cancellationSettlements.waitForCount(count)
    }

    func metrics() -> CancellationIgnoringMediaMetrics {
        CancellationIgnoringMediaMetrics(
            activeOperations: activeOperations,
            maximumConcurrentOperations: maximumConcurrentOperations
        )
    }
}

private actor GatedFailingCommandAdapter: MediaAdapter {
    let source: MediaSource
    let firstCommandStarted = AsyncGate()
    private let firstCommandFailureGate = AsyncGate()
    private var performCalls = 0
    private var cancelCalls = 0

    init(source: MediaSource) {
        self.source = source
    }

    func activate() async {}
    func deactivate() async {}

    func updates() async -> AsyncStream<MediaAdapterUpdate> {
        AsyncStream { continuation in continuation.finish() }
    }

    func refresh(operationID: MediaOperationID) async throws -> MediaAdapterUpdate {
        .snapshot(try makeSnapshot(source: source, sequence: 1, title: "Stable"))
    }

    func perform(_ command: MediaCommand, operationID: MediaOperationID) async throws {
        performCalls += 1
        if performCalls == 1 {
            await firstCommandStarted.open()
            await firstCommandFailureGate.wait()
            throw MediaError.automationFailed(source: source, exitCode: 91)
        }
    }

    func cancel(_ operationID: MediaOperationID) async {
        cancelCalls += 1
    }

    func cancelAllPendingWork() async {}

    func releaseFirstCommandFailure() async {
        await firstCommandFailureGate.open()
    }

    func metrics() -> GatedFailingCommandMetrics {
        GatedFailingCommandMetrics(
            performCalls: performCalls,
            cancelCalls: cancelCalls
        )
    }
}

private enum TestRefreshAction: Sendable {
    case update(MediaAdapterUpdate)
    case failure(MediaError)
    case waiting(AsyncGate, MediaAdapterUpdate)
}

private struct TestAdapterMetrics: Sendable {
    let activateCalls: Int
    let deactivateCalls: Int
    let updateStreamCalls: Int
    let refreshCalls: Int
    let performCalls: Int
    let cancelCalls: Int
    let maximumConcurrentCommands: Int

    var totalCalls: Int {
        activateCalls + deactivateCalls + updateStreamCalls + refreshCalls + performCalls + cancelCalls
    }
}

private actor TestMediaAdapter: MediaAdapter {
    let source: MediaSource
    private var refreshActions: [TestRefreshAction]
    private let activationGate: AsyncGate?
    private let activationStarted: AsyncGate?
    private let refreshStarted: AsyncGate?
    private let commandGate: AsyncGate?
    private let commandStarted: AsyncGate?
    private let openCommandGateOnCancel: Bool
    private var activateCalls = 0
    private var deactivateCalls = 0
    private var updateStreamCalls = 0
    private var refreshCalls = 0
    private var performCalls = 0
    private var cancelCalls = 0
    private var activeCommands = 0
    private var maximumConcurrentCommands = 0
    private var performedCommands: [MediaCommand] = []

    init(
        source: MediaSource,
        refreshActions: [TestRefreshAction] = [],
        activationGate: AsyncGate? = nil,
        activationStarted: AsyncGate? = nil,
        refreshStarted: AsyncGate? = nil,
        commandGate: AsyncGate? = nil,
        commandStarted: AsyncGate? = nil,
        openCommandGateOnCancel: Bool = false
    ) {
        self.source = source
        self.refreshActions = refreshActions
        self.activationGate = activationGate
        self.activationStarted = activationStarted
        self.refreshStarted = refreshStarted
        self.commandGate = commandGate
        self.commandStarted = commandStarted
        self.openCommandGateOnCancel = openCommandGateOnCancel
    }

    func activate() async {
        activateCalls += 1
        await activationStarted?.open()
        await activationGate?.wait()
    }

    func deactivate() {
        deactivateCalls += 1
    }

    func updates() -> AsyncStream<MediaAdapterUpdate> {
        updateStreamCalls += 1
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func refresh() async throws -> MediaAdapterUpdate {
        try await refresh(operationID: MediaOperationID())
    }

    func refresh(operationID: MediaOperationID) async throws -> MediaAdapterUpdate {
        refreshCalls += 1
        await refreshStarted?.open()
        guard !refreshActions.isEmpty else {
            throw MediaError.sourceUnavailable(source: source)
        }
        let action = refreshActions.removeFirst()
        switch action {
        case let .update(update):
            return update
        case let .failure(error):
            throw error
        case let .waiting(gate, update):
            await gate.wait()
            return update
        }
    }

    func perform(_ command: MediaCommand, operationID: MediaOperationID) async throws {
        performCalls += 1
        performedCommands.append(command)
        activeCommands += 1
        maximumConcurrentCommands = max(maximumConcurrentCommands, activeCommands)
        await commandStarted?.open()
        if let commandGate {
            await commandGate.wait()
        } else {
            for _ in 0 ..< 16 { await Task.yield() }
        }
        activeCommands -= 1
    }

    func cancel(_ operationID: MediaOperationID) async {
        cancelCalls += 1
        if openCommandGateOnCancel {
            await commandGate?.open()
        }
    }

    func cancelAllPendingWork() async {
        cancelCalls += 1
        if openCommandGateOnCancel {
            await commandGate?.open()
        }
    }

    func metrics() -> TestAdapterMetrics {
        TestAdapterMetrics(
            activateCalls: activateCalls,
            deactivateCalls: deactivateCalls,
            updateStreamCalls: updateStreamCalls,
            refreshCalls: refreshCalls,
            performCalls: performCalls,
            cancelCalls: cancelCalls,
            maximumConcurrentCommands: maximumConcurrentCommands
        )
    }
}

private actor EventRecorder {
    private var events: [MediaCoordinatorEvent] = []
    private var snapshotWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func append(_ event: MediaCoordinatorEvent) {
        events.append(event)
        let count = snapshotCount
        let ready = snapshotWaiters.filter { $0.0 <= count }
        snapshotWaiters.removeAll { $0.0 <= count }
        for waiter in ready {
            waiter.1.resume()
        }
    }

    var snapshotCount: Int {
        events.reduce(into: 0) { count, event in
            if case .snapshot = event { count += 1 }
        }
    }

    func waitForSnapshotCount(_ count: Int) async {
        guard snapshotCount < count else { return }
        await withCheckedContinuation { continuation in
            snapshotWaiters.append((count, continuation))
        }
    }
}

private actor TestApplicationStatus: MediaApplicationStatusChecking {
    private var running: Bool
    private(set) var calls = 0

    init(isRunning: Bool) {
        running = isRunning
    }

    func isRunning(bundleIdentifier: String) -> Bool {
        calls += 1
        return running
    }
}

private actor GatedApplicationStatus: MediaApplicationStatusChecking {
    private let gate: AsyncGate
    private let started: AsyncGate
    private let running: Bool

    init(gate: AsyncGate, started: AsyncGate, isRunning: Bool) {
        self.gate = gate
        self.started = started
        running = isRunning
    }

    func isRunning(bundleIdentifier: String) async -> Bool {
        await started.open()
        await gate.wait()
        return running
    }
}

private enum ScriptAction: Sendable {
    case output(String)
    case failure(MediaScriptExecutionError)
    case waiting(started: AsyncGate, gate: AsyncGate, output: String)
}

private actor RecordingScriptExecutor: MediaScriptExecuting {
    private var actions: [ScriptAction]
    private var recordedRequests: [MediaScriptRequest] = []
    private var activeGates: [MediaOperationID: AsyncGate] = [:]
    private(set) var cancelCalls = 0

    init(actions: [ScriptAction]) {
        self.actions = actions
    }

    func execute(
        _ request: MediaScriptRequest,
        operationID: MediaOperationID
    ) async throws -> String {
        recordedRequests.append(request)
        guard !actions.isEmpty else { return "" }
        switch actions.removeFirst() {
        case let .output(output):
            return output
        case let .failure(error):
            throw error
        case let .waiting(started, gate, output):
            activeGates[operationID] = gate
            await started.open()
            await gate.wait()
            activeGates.removeValue(forKey: operationID)
            return output
        }
    }

    func cancel(_ operationID: MediaOperationID) async {
        guard let gate = activeGates.removeValue(forKey: operationID) else { return }
        cancelCalls += 1
        await gate.open()
    }

    func requests() -> [MediaScriptRequest] {
        recordedRequests
    }

    func activeOperationIDs() -> Set<MediaOperationID> {
        Set(activeGates.keys)
    }
}

private actor StaticResultProcessRunner: MediaScriptProcessRunning {
    private let result: MediaScriptProcessResult
    private(set) var runCount = 0

    init(result: MediaScriptProcessResult) {
        self.result = result
    }

    func run(
        arguments: [String],
        operationID: MediaOperationID,
        limits: MediaScriptProcessLimits
    ) async throws -> MediaScriptProcessResult {
        runCount += 1
        return result
    }

    func cancel(_ operationID: MediaOperationID) async {}
}

private actor PreRegistrationProcessRunner: MediaScriptProcessRunning {
    let registrationStarted = AsyncGate()
    let registrationGate = AsyncGate()
    private(set) var launchCount = 0

    func run(
        arguments: [String],
        operationID: MediaOperationID,
        limits: MediaScriptProcessLimits
    ) async throws -> MediaScriptProcessResult {
        await registrationStarted.open()
        await registrationGate.wait()
        guard !Task.isCancelled else {
            throw MediaScriptProcessError.cancelled
        }
        launchCount += 1
        return MediaScriptProcessResult(
            exitCode: 0,
            standardOutput: Data(validScriptOutput().utf8),
            standardError: Data()
        )
    }

    func cancel(_ operationID: MediaOperationID) async {
        await registrationGate.open()
    }
}

private final class ScriptedPOSIXProcessSystem: MediaPOSIXProcessSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var waitResults: [MediaPOSIXWaitResult]
    private var storedSignals: [Int32] = []
    private var storedWaitCallCount = 0

    init(waitResults: [MediaPOSIXWaitResult]) {
        self.waitResults = waitResults
    }

    var signals: [Int32] {
        lock.withLock { storedSignals }
    }

    var waitCallCount: Int {
        lock.withLock { storedWaitCallCount }
    }

    func appendWaitResult(_ result: MediaPOSIXWaitResult) {
        lock.withLock { waitResults.append(result) }
    }

    func spawn(
        executablePath: String,
        arguments: [String],
        standardOutput: Int32,
        standardError: Int32
    ) throws -> pid_t {
        9_001
    }

    func sendSignal(_ signal: Int32, to processIdentifier: pid_t) -> Int32 {
        lock.withLock { storedSignals.append(signal) }
        return 0
    }

    func waitNonBlocking(for processIdentifier: pid_t) -> MediaPOSIXWaitResult {
        lock.withLock {
            storedWaitCallCount += 1
            guard !waitResults.isEmpty else { return .running }
            return waitResults.removeFirst()
        }
    }
}

private actor GatedEscalationScheduler: MediaProcessEscalationScheduling {
    private let started = AsyncGate()
    private let deadline = AsyncGate()
    private let settled = AsyncGate()

    func waitForEscalation(afterNanoseconds: UInt64) async -> Bool {
        await started.open()
        await deadline.wait()
        let shouldEscalate = !Task.isCancelled
        await settled.open()
        return shouldEscalate
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func release() async {
        await deadline.open()
    }

    func waitUntilSettled() async {
        await settled.wait()
    }
}

private struct FailingSpawnPOSIXProcessSystem: MediaPOSIXProcessSystem {
    func spawn(
        executablePath: String,
        arguments: [String],
        standardOutput: Int32,
        standardError: Int32
    ) throws -> pid_t {
        throw MediaScriptProcessError.launchFailed
    }

    func sendSignal(_ signal: Int32, to processIdentifier: pid_t) -> Int32 {
        -1
    }

    func waitNonBlocking(for processIdentifier: pid_t) -> MediaPOSIXWaitResult {
        .failed(errno: ECHILD)
    }
}

private final class BlockingKillPOSIXProcessSystem: MediaPOSIXProcessSystem, @unchecked Sendable {
    let killStarted = AsyncGate()
    private let lock = NSLock()
    private let killRelease = DispatchSemaphore(value: 0)
    private var mayExit = false
    private var storedGeneration = 1
    private var storedReapCount = 0
    private var storedSignalGenerations: [Int] = []

    var generation: Int { lock.withLock { storedGeneration } }
    var reapCount: Int { lock.withLock { storedReapCount } }
    var signalGenerations: [Int] { lock.withLock { storedSignalGenerations } }

    func spawn(
        executablePath: String,
        arguments: [String],
        standardOutput: Int32,
        standardError: Int32
    ) throws -> pid_t {
        9_002
    }

    func sendSignal(_ signal: Int32, to processIdentifier: pid_t) -> Int32 {
        if signal == SIGKILL {
            Task { await killStarted.open() }
            killRelease.wait()
        }
        lock.withLock { storedSignalGenerations.append(storedGeneration) }
        return 0
    }

    func waitNonBlocking(for processIdentifier: pid_t) -> MediaPOSIXWaitResult {
        lock.withLock {
            guard mayExit else { return .running }
            storedReapCount += 1
            storedGeneration = 2
            mayExit = false
            return .exited(rawStatus: SIGKILL)
        }
    }

    func allowExit() {
        lock.withLock { mayExit = true }
    }

    func releaseKill() {
        killRelease.signal()
    }
}

private enum MediaProcessHelper {
    static let flag = "--media-process-helper"

    static func runIfRequested() async -> Bool {
        guard CommandLine.arguments.count >= 3,
              CommandLine.arguments[1] == flag else { return false }

        let mode = CommandLine.arguments[2]
        if mode == "stdio-collision" {
            await runStdioCollision()
            return true
        }

        let output = FileHandle.standardOutput
        let error = FileHandle.standardError
        switch mode {
        case "normal":
            output.write(Data("stdout".utf8))
            error.write(Data("stderr".utf8))
        case "exit-one":
            exit(1)
        case "stdout-flood":
            output.write(Data(repeating: 0x6f, count: 128 * 1_024))
        case "stderr-flood":
            error.write(Data(repeating: 0x65, count: 128 * 1_024))
        case "interleaved":
            let outputChunk = Data(repeating: 0x6f, count: 4 * 1_024)
            let errorChunk = Data(repeating: 0x65, count: 4 * 1_024)
            for _ in 0 ..< 32 {
                output.write(outputChunk)
                error.write(errorChunk)
            }
        case "ignore-term-int-hang":
            _ = Darwin.signal(SIGTERM, SIG_IGN)
            _ = Darwin.signal(SIGINT, SIG_IGN)
            guard CommandLine.arguments.count == 4 else { exit(65) }
            let marker = Darwin.open(
                CommandLine.arguments[3],
                O_WRONLY | O_CREAT | O_TRUNC,
                S_IRUSR | S_IWUSR
            )
            guard marker >= 0 else { exit(66) }
            _ = Darwin.close(marker)
            while true { _ = Darwin.pause() }
        case "descendant-holds-fds", "descendant-trickle":
            guard CommandLine.arguments.count == 6 else { exit(67) }
            let leafMode = mode == "descendant-holds-fds" ? "hold-fds-leaf" : "trickle-leaf"
            guard spawnDescendant(
                mode: "supervise-fd-leaf",
                additionalArguments: [
                    leafMode,
                    CommandLine.arguments[3],
                    CommandLine.arguments[4],
                    CommandLine.arguments[5],
                ]
            ) != nil else { exit(68) }
        case "supervise-fd-leaf":
            superviseFDLeaf()
        case "hold-fds-leaf", "trickle-leaf":
            guard CommandLine.arguments.count == 4 else { exit(69) }
            let cleanupPath = CommandLine.arguments[3]
            let trickles = mode == "trickle-leaf"
            let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
            var byte: UInt8 = 0x74
            while !FileManager.default.fileExists(atPath: cleanupPath),
                  DispatchTime.now().uptimeNanoseconds < deadline {
                if trickles {
                    _ = Darwin.write(STDOUT_FILENO, &byte, 1)
                    _ = Darwin.write(STDERR_FILENO, &byte, 1)
                }
                _ = Darwin.usleep(1_000)
            }
        case "fd-audit":
            let inherited = (STDERR_FILENO + 1 ..< 256).filter {
                fcntl($0, F_GETFD) >= 0
            }
            output.write(Data("stdout|fds=\(inherited.count)".utf8))
            error.write(Data("stderr".utf8))
            exit(23)
        case "hang":
            while true { _ = Darwin.pause() }
        default:
            exit(64)
        }
        return true
    }

    private static func runStdioCollision() async {
        guard CommandLine.arguments.count == 4 else { exit(70) }
        let controlDescriptor = fcntl(
            STDOUT_FILENO,
            F_DUPFD_CLOEXEC,
            STDERR_FILENO + 1
        )
        guard controlDescriptor >= STDERR_FILENO + 1 else { exit(71) }
        defer { _ = Darwin.close(controlDescriptor) }

        for scalar in CommandLine.arguments[3].unicodeScalars {
            guard let descriptor = Int32(String(scalar)),
                  descriptor >= STDIN_FILENO,
                  descriptor <= STDERR_FILENO else { exit(72) }
            _ = Darwin.close(descriptor)
        }

        let runner = FoundationMediaScriptProcessRunner(
            executableURL: mediaHelperExecutableURL()
        )
        do {
            let result = try await runner.run(
                arguments: [flag, "fd-audit"],
                operationID: MediaOperationID(),
                limits: MediaScriptProcessLimits(
                    maximumStandardOutputBytes: 1_024,
                    maximumStandardErrorBytes: 1_024,
                    timeoutNanoseconds: 2_000_000_000
                )
            )
            let report = [
                String(result.exitCode),
                String(decoding: result.standardOutput, as: UTF8.self),
                String(decoding: result.standardError, as: UTF8.self),
            ].joined(separator: "\t")
            guard writeAll(Data(report.utf8), to: controlDescriptor) else { exit(73) }
        } catch {
            _ = writeAll(Data("error:\(error)".utf8), to: controlDescriptor)
            exit(74)
        }
    }

    private static func superviseFDLeaf() -> Never {
        guard CommandLine.arguments.count == 7 else { exit(75) }
        let leafMode = CommandLine.arguments[3]
        let cleanupPath = CommandLine.arguments[4]
        let readyPath = CommandLine.arguments[5]
        let settledPath = CommandLine.arguments[6]
        guard let leafPID = spawnDescendant(
            mode: leafMode,
            additionalArguments: [cleanupPath]
        ) else { exit(76) }
        let ready = Data("\(getpid()) \(leafPID)".utf8)
        guard FileManager.default.createFile(atPath: readyPath, contents: ready) else {
            _ = Darwin.kill(leafPID, SIGKILL)
            exit(77)
        }
        _ = Darwin.close(STDOUT_FILENO)
        _ = Darwin.close(STDERR_FILENO)
        var status: Int32 = 0
        while Darwin.waitpid(leafPID, &status, 0) < 0 {
            if errno != EINTR { exit(78) }
        }
        guard FileManager.default.createFile(
            atPath: settledPath,
            contents: Data("reaped".utf8)
        ) else { exit(79) }
        exit(0)
    }

    private static func spawnDescendant(
        mode: String,
        additionalArguments: [String] = []
    ) -> pid_t? {
        let executable = mediaHelperExecutableURL().path
        let argumentStrings: [String] = [executable, flag, mode] + additionalArguments
        let argumentStorage: [UnsafeMutablePointer<CChar>?] = argumentStrings.map {
            strdup($0)
        }
        guard argumentStorage.allSatisfy({ $0 != nil }) else {
            for pointer in argumentStorage { free(pointer) }
            return nil
        }
        defer { for pointer in argumentStorage { free(pointer) } }
        var arguments = argumentStorage + [nil]
        var processIdentifier: pid_t = 0
        let result = arguments.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(
                &processIdentifier,
                executable,
                nil,
                nil,
                buffer.baseAddress,
                environ
            )
        }
        return result == 0 ? processIdentifier : nil
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else { return true }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, address, remaining)
                if count > 0 {
                    remaining -= count
                    address = address.advanced(by: count)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

private func mediaHelperExecutableURL() -> URL {
    URL(
        fileURLWithPath: CommandLine.arguments[0],
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardizedFileURL
}

private func openFileDescriptorCount() -> Int {
    (0 ..< 1_024).reduce(into: 0) { count, descriptor in
        if fcntl(Int32(descriptor), F_GETFD) >= 0 {
            count += 1
        }
    }
}

private func temporaryMediaHelperMarkerPath() -> String {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("erylo-media-helper-\(UUID().uuidString)")
        .path
}

private func removeMediaHelperFiles(_ paths: [String]) {
    for path in paths where FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func waitForFile(atPath path: String) async -> Bool {
    for _ in 0 ..< 1_000 {
        if FileManager.default.fileExists(atPath: path) { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

private func waitForRecordedProcessesToExit(atPath path: String) async -> Bool {
    guard let data = FileManager.default.contents(atPath: path),
          let contents = String(data: data, encoding: .utf8) else { return false }
    let processIdentifiers = contents.split(separator: " ").compactMap {
        pid_t($0)
    }
    guard processIdentifiers.count == 2 else { return false }

    for _ in 0 ..< 1_000 {
        let allExited = processIdentifiers.allSatisfy { processIdentifier in
            errno = 0
            return Darwin.kill(processIdentifier, 0) < 0 && errno == ESRCH
        }
        if allExited { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

private func waitForActiveProcess(
    in runner: FoundationMediaScriptProcessRunner
) async {
    for _ in 0 ..< 1_000 {
        if await runner.activeProcessCount > 0 { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

private actor IgnoreTermProcessExecutor: MediaScriptExecuting {
    private let runner: FoundationMediaScriptProcessRunner
    private let readinessPath: String
    private let limits: MediaScriptProcessLimits

    init(
        runner: FoundationMediaScriptProcessRunner,
        readinessPath: String,
        limits: MediaScriptProcessLimits
    ) {
        self.runner = runner
        self.readinessPath = readinessPath
        self.limits = limits
    }

    func execute(
        _ request: MediaScriptRequest,
        operationID: MediaOperationID
    ) async throws -> String {
        do {
            _ = try await runner.run(
                arguments: [
                    MediaProcessHelper.flag,
                    "ignore-term-int-hang",
                    readinessPath,
                ],
                operationID: operationID,
                limits: limits
            )
            return validScriptOutput()
        } catch MediaScriptProcessError.cancelled {
            throw MediaScriptExecutionError.cancelled
        } catch {
            throw MediaScriptExecutionError.failed(exitCode: nil)
        }
    }

    func cancel(_ operationID: MediaOperationID) async {
        await runner.cancel(operationID)
    }
}

private actor CancellationIgnoringFailureExecutor: MediaScriptExecuting {
    let firstFailureStarted = AsyncGate()
    let secondFailureStarted = AsyncGate()
    private let firstFailureGate = AsyncGate()
    private let secondFailureGate = AsyncGate()
    private let cancellations = CompletionCounter()
    private var callCount = 0
    private var activeExecutions = 0
    private(set) var maximumConcurrentExecutions = 0

    func execute(
        _ request: MediaScriptRequest,
        operationID: MediaOperationID
    ) async throws -> String {
        callCount += 1
        let call = callCount
        activeExecutions += 1
        maximumConcurrentExecutions = max(maximumConcurrentExecutions, activeExecutions)
        defer { activeExecutions -= 1 }

        switch call {
        case 1:
            return validScriptOutput(title: "Stable")
        case 2:
            await firstFailureStarted.open()
            await firstFailureGate.wait()
            throw MediaScriptExecutionError.failed(exitCode: 92)
        case 3:
            await secondFailureStarted.open()
            await secondFailureGate.wait()
            throw MediaScriptExecutionError.failed(exitCode: 93)
        default:
            return validScriptOutput(title: "Replacement")
        }
    }

    func cancel(_ operationID: MediaOperationID) async {
        await cancellations.recordCompletion()
    }

    func waitForCancelCount(_ count: Int) async {
        await cancellations.waitForCount(count)
    }

    func releaseFirstFailure() async {
        await firstFailureGate.open()
    }

    func releaseSecondFailure() async {
        await secondFailureGate.open()
    }
}

private actor NonCooperativeScriptExecutor: MediaScriptExecuting {
    let firstStarted = AsyncGate()
    let firstGate = AsyncGate()
    private var callCount = 0

    func execute(
        _ request: MediaScriptRequest,
        operationID: MediaOperationID
    ) async throws -> String {
        callCount += 1
        if callCount == 1 {
            await firstStarted.open()
            await firstGate.wait()
            return validScriptOutput(title: "Stale")
        }
        return validScriptOutput(title: "Replacement")
    }

    func cancel(_ operationID: MediaOperationID) async {}
}

private actor ReusedIDScriptExecutor: MediaScriptExecuting {
    let firstStarted = AsyncGate()
    let secondStarted = AsyncGate()
    let firstGate = AsyncGate()
    let secondGate = AsyncGate()
    private var callCount = 0

    func execute(
        _ request: MediaScriptRequest,
        operationID: MediaOperationID
    ) async throws -> String {
        callCount += 1
        if callCount == 1 {
            await firstStarted.open()
            await firstGate.wait()
            return validScriptOutput(title: "Retired")
        }
        await secondStarted.open()
        await secondGate.wait()
        return validScriptOutput(title: "Replacement")
    }

    func cancel(_ operationID: MediaOperationID) async {}
}

private actor RepeatedRetirementScriptExecutor: MediaScriptExecuting {
    private let firstGate = AsyncGate()
    private let secondGate = AsyncGate()
    private let starts = CompletionCounter()
    private var callCount = 0
    private var activeExecutions = 0
    private(set) var maximumConcurrentExecutions = 0

    func execute(
        _ request: MediaScriptRequest,
        operationID: MediaOperationID
    ) async throws -> String {
        callCount += 1
        let call = callCount
        activeExecutions += 1
        maximumConcurrentExecutions = max(maximumConcurrentExecutions, activeExecutions)
        await starts.recordCompletion()
        if call == 1 {
            await firstGate.wait()
        } else if call == 2 {
            await secondGate.wait()
        }
        activeExecutions -= 1
        return validScriptOutput(title: "Execution \(call)")
    }

    func cancel(_ operationID: MediaOperationID) async {}

    func waitForStartCount(_ count: Int) async {
        await starts.waitForCount(count)
    }

    func releaseFirstTwo() async {
        await firstGate.open()
        await secondGate.open()
    }
}

private actor TestArtworkLoader: MediaArtworkDataLoading {
    private let data: Data
    private let gate: AsyncGate?
    private let started: AsyncGate?
    private let honorsMaximum: Bool
    private(set) var loadCalls = 0
    private(set) var receivedMaximumBytes: [Int] = []

    init(
        data: Data,
        gate: AsyncGate? = nil,
        started: AsyncGate? = nil,
        honorsMaximum: Bool = true
    ) {
        self.data = data
        self.gate = gate
        self.started = started
        self.honorsMaximum = honorsMaximum
    }

    func loadData(
        for reference: MediaArtworkReference,
        maximumBytes: Int
    ) async throws -> Data {
        loadCalls += 1
        receivedMaximumBytes.append(maximumBytes)
        await started?.open()
        await gate?.wait()
        if honorsMaximum, data.count > maximumBytes {
            throw MediaArtworkPipelineError.payloadTooLarge(maximumBytes: maximumBytes)
        }
        return data
    }
}

private actor PurgeRaceArtworkLoader: MediaArtworkDataLoading {
    let firstStarted = AsyncGate()
    let secondStarted = AsyncGate()
    let firstGate = AsyncGate()
    let secondGate = AsyncGate()
    private let data: Data
    private var calls = 0

    init(data: Data) {
        self.data = data
    }

    func loadData(
        for reference: MediaArtworkReference,
        maximumBytes: Int
    ) async throws -> Data {
        calls += 1
        if calls == 1 {
            await firstStarted.open()
            await firstGate.wait()
        } else {
            await secondStarted.open()
            await secondGate.wait()
        }
        // Intentionally ignores task cancellation to exercise purge-generation protection.
        return data
    }
}

private actor RepeatedPurgeArtworkLoader: MediaArtworkDataLoading {
    private let firstGate = AsyncGate()
    private let secondGate = AsyncGate()
    private let starts = CompletionCounter()
    private let data: Data
    private var calls = 0
    private var activeLoads = 0
    private(set) var maximumConcurrentLoads = 0

    init(data: Data) {
        self.data = data
    }

    func loadData(
        for reference: MediaArtworkReference,
        maximumBytes: Int
    ) async throws -> Data {
        calls += 1
        let call = calls
        activeLoads += 1
        maximumConcurrentLoads = max(maximumConcurrentLoads, activeLoads)
        await starts.recordCompletion()
        if call == 1 {
            await firstGate.wait()
        } else if call == 2 {
            await secondGate.wait()
        }
        activeLoads -= 1
        // The first two loads intentionally ignore cancellation.
        return data
    }

    func waitForStartCount(_ count: Int) async {
        await starts.waitForCount(count)
    }

    func releaseFirstTwo() async {
        await firstGate.open()
        await secondGate.open()
    }
}

private actor TestArtworkDecoder: MediaArtworkDecoding {
    typealias DecodedArtwork = Int
    private(set) var decodeCalls = 0
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let decodedByteCost: Int

    init(
        pixelWidth: Int = 1,
        pixelHeight: Int = 1,
        decodedByteCost: Int? = nil
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.decodedByteCost = decodedByteCost ?? max(1, pixelWidth * pixelHeight * 4)
    }

    func decode(
        _ data: Data,
        limits: MediaArtworkDecodeLimits
    ) -> DecodedMediaArtwork<Int> {
        decodeCalls += 1
        return DecodedMediaArtwork(
            artwork: data.count,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            decodedByteCost: decodedByteCost
        )
    }
}
