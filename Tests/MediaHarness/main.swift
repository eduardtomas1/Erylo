import Darwin
import Dispatch
import EryloCore
@_spi(Testing) import EryloIntegrations
import Foundation

@main
enum MediaHarnessMain {
    static func main() async {
        if MediaProcessHelper.runIfRequested() {
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
        await verifyDesktopAdapterSerializationCapacityAndCancellation()
        await verifyAdapterErrorMappingAndScriptIsolation()
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
    }

    private func verifyLifecycleAndRefreshGenerations() async {
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
            activeSharedIDs == [sharedSpotifyID],
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

        let normalController = TestProcessController()
        let normalRunner = FoundationMediaScriptProcessRunner(
            executableURL: executableURL,
            processController: normalController
        )
        let normalID = MediaOperationID()
        let normal = try! await normalRunner.run(
            arguments: [MediaProcessHelper.flag, "normal"],
            operationID: normalID,
            limits: normalLimits
        )
        check(normal.standardOutput == Data("stdout".utf8), "process runner captures stdout")
        check(normal.standardError == Data("stderr".utf8), "process runner captures stderr")
        await normalRunner.cancel(normalID)
        let lateCancelCounts = normalController.counts
        check(
            lateCancelCounts.terminate == 0 && lateCancelCounts.kill == 0,
            "late process cancellation leaves no tombstone or signal"
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

        let timeoutController = TestProcessController()
        let timeoutRunner = FoundationMediaScriptProcessRunner(
            executableURL: executableURL,
            processController: timeoutController
        )
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
        let timeoutCounts = timeoutController.counts
        check(processError(from: timeoutResult) == .timedOut, "hung process times out")
        check(
            timeoutCounts.terminate == 1 && timeoutCounts.kill == 0,
            "timeout first requests graceful termination"
        )

        let escalationController = TestProcessController()
        let escalationRunner = FoundationMediaScriptProcessRunner(
            executableURL: executableURL,
            processController: escalationController
        )
        let escalationResult = await result {
            try await escalationRunner.run(
                arguments: [MediaProcessHelper.flag, "ignore-term-hang"],
                operationID: MediaOperationID(),
                limits: MediaScriptProcessLimits(
                    timeoutNanoseconds: 30_000_000,
                    terminationGraceNanoseconds: 30_000_000
                )
            )
        }
        let escalationCounts = escalationController.counts
        check(
            processError(from: escalationResult) == .timedOut,
            "timeout cause wins after forced escalation"
        )
        check(
            escalationCounts.terminate == 1 && escalationCounts.kill == 1,
            "ignored termination escalates through the injected process seam"
        )

        let capacityStarted = AsyncGate()
        let capacityController = TestProcessController(started: capacityStarted)
        let capacityRunner = FoundationMediaScriptProcessRunner(
            executableURL: executableURL,
            processController: capacityController,
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
        await capacityStarted.wait()
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

        let terminalController = TestProcessController(assumedRunning: false)
        let finishedFirst = RunningMediaProcess(
            process: Process(),
            processController: terminalController,
            terminationGraceNanoseconds: 10_000_000
        )
        finishedFirst.markFinished()
        finishedFirst.requestStop(.timedOut)
        finishedFirst.requestStop(.cancelled)
        check(
            finishedFirst.stopReason == nil,
            "timeout or cancellation cannot retroactively replace natural completion"
        )

        let stopFirst = RunningMediaProcess(
            process: Process(),
            processController: terminalController,
            terminationGraceNanoseconds: 10_000_000
        )
        stopFirst.markStarted()
        stopFirst.requestStop(.cancelled)
        stopFirst.requestStop(.timedOut)
        stopFirst.markFinished()
        check(stopFirst.stopReason == .cancelled, "first requested terminal cause remains stable")

        let naturalExitController = TestProcessController(assumedRunning: true)
        let naturalExit = RunningMediaProcess(
            process: Process(),
            processController: naturalExitController,
            terminationGraceNanoseconds: 20_000_000
        )
        naturalExit.markStarted()
        naturalExit.requestStop(.timedOut)
        naturalExit.markFinished()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let naturalExitCounts = naturalExitController.counts
        check(
            naturalExitCounts.kill == 0,
            "natural exit cancels pending escalation for the exact process"
        )

        let escalationRaceController = EscalationRaceProcessController()
        let escalationRace = RunningMediaProcess(
            process: Process(),
            processController: escalationRaceController,
            terminationGraceNanoseconds: 10_000_000
        )
        escalationRace.markStarted()
        escalationRace.requestStop(.timedOut)
        await escalationRaceController.escalationCheckStarted.wait()
        escalationRace.markFinished()
        escalationRaceController.releaseEscalationCheck()
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(
            escalationRaceController.killCount == 0,
            "finish winning the escalation race prevents a late kill"
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
    duration: String = "180"
) -> String {
    [
        "playing",
        title,
        "Artist",
        "Album",
        "track-1",
        duration,
        "30",
        "50",
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

    func cancel(_ operationID: MediaOperationID) {}
}

private struct TestProcessControllerCounts: Sendable {
    let started: Int
    let terminate: Int
    let kill: Int
}

private final class TestProcessController: MediaProcessControlling, @unchecked Sendable {
    private let lock = NSLock()
    private let startedGate: AsyncGate?
    private let assumedRunning: Bool?
    private var startedCount = 0
    private var terminateCount = 0
    private var killCount = 0

    init(started: AsyncGate? = nil, assumedRunning: Bool? = nil) {
        startedGate = started
        self.assumedRunning = assumedRunning
    }

    var counts: TestProcessControllerCounts {
        lock.lock()
        defer { lock.unlock() }
        return TestProcessControllerCounts(
            started: startedCount,
            terminate: terminateCount,
            kill: killCount
        )
    }

    func didStart(_ process: Process) {
        lock.lock()
        startedCount += 1
        let gate = startedGate
        lock.unlock()
        if let gate {
            Task { await gate.open() }
        }
    }

    func isRunning(_ process: Process) -> Bool {
        assumedRunning ?? process.isRunning
    }

    func terminate(_ process: Process) {
        lock.lock()
        terminateCount += 1
        lock.unlock()
        guard assumedRunning == nil else { return }
        process.terminate()
    }

    func kill(_ process: Process) {
        lock.lock()
        killCount += 1
        lock.unlock()
        guard assumedRunning == nil else { return }
        process.interrupt()
    }
}

private final class EscalationRaceProcessController: MediaProcessControlling, @unchecked Sendable {
    let escalationCheckStarted = AsyncGate()
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var runningChecks = 0
    private var storedKillCount = 0

    var killCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedKillCount
    }

    func didStart(_ process: Process) {}

    func isRunning(_ process: Process) -> Bool {
        lock.lock()
        runningChecks += 1
        let check = runningChecks
        lock.unlock()
        if check > 1 {
            Task { await escalationCheckStarted.open() }
            releaseSemaphore.wait()
        }
        return true
    }

    func terminate(_ process: Process) {}

    func kill(_ process: Process) {
        lock.lock()
        storedKillCount += 1
        lock.unlock()
    }

    func releaseEscalationCheck() {
        releaseSemaphore.signal()
    }
}

private enum MediaProcessHelper {
    static let flag = "--media-process-helper"

    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.count == 3,
              CommandLine.arguments[1] == flag else { return false }

        let output = FileHandle.standardOutput
        let error = FileHandle.standardError
        switch CommandLine.arguments[2] {
        case "normal":
            output.write(Data("stdout".utf8))
            error.write(Data("stderr".utf8))
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
        case "ignore-term-hang":
            _ = Darwin.signal(SIGTERM, SIG_IGN)
            while true { _ = Darwin.pause() }
        case "hang":
            while true { _ = Darwin.pause() }
        default:
            exit(64)
        }
        return true
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
