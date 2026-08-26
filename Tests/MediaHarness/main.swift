import Darwin
import EryloCore
import EryloIntegrations
import Foundation

@main
enum MediaHarnessMain {
    static func main() async {
        let harness = await MediaHarness()
        await harness.run()
        await harness.finish()
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
        await verifyAdapterErrorMappingAndScriptIsolation()
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
            capabilities: [.play, .seek, .volume],
            duration: 120
        )

        check(try? MediaCommand.play.normalized(for: snapshot) == .play, "supported play command passes")
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
        check(current?.title == "Fresh", "stale snapshot cannot replace newer content")
        check(current?.stamp.sequence == 3, "semantic dedupe still advances observation sequence")
        check(await recorder.snapshotCount == 1, "semantic duplicate snapshot is not republished")

        let disappeared = try! await coordinator.refresh(.appleMusic)
        check(disappeared == nil, "source disappearance clears current snapshot")
        check(
            await coordinator.health(for: .appleMusic).availability == .unavailable,
            "source disappearance marks adapter unavailable"
        )

        let recoveredSnapshot = try! await coordinator.refresh(.appleMusic)
        check(recoveredSnapshot?.title == "Recovered", "source can recover after disappearance")
        check(
            await coordinator.health(for: .appleMusic).availability == .available,
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
        check(await executor.requests().isEmpty, "unavailable app never invokes AppleScript")
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
        check(metrics.updateStreamCalls == 0, "stale activation cannot attach an update stream")
        check(metrics.deactivateCalls == 1, "disable completes after in-flight activation")
        check(
            await coordinator.health(for: .appleMusic).availability == .disabled,
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
        check(refreshError == .cancelled(source: .spotify), "old refresh result is cancelled after generation change")
        check(await racingCoordinator.snapshot(for: .spotify) == nil, "old refresh cannot repopulate re-enabled source")
        check(
            await racingCoordinator.health(for: .spotify).availability == .inactive,
            "old refresh cannot overwrite new generation health"
        )
        await racingCoordinator.stop()
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
    }

    private func verifyArtworkBounds() async {
        let key = try! MediaArtworkCacheKey("spotify:artwork")
        let reference = try! MediaArtworkReference(
            remoteURL: URL(string: "https://example.invalid/artwork.jpg")!,
            cacheKey: key
        )
        let loader = TestArtworkLoader(data: Data([0, 1, 2, 3, 4]))
        let decoder = TestArtworkDecoder()
        let pipeline = BoundedMediaArtworkPipeline(
            loader: loader,
            decoder: decoder,
            maximumTotalBytes: 8,
            maximumEntryBytes: 8,
            maximumDecodeBytes: 4
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
        check(await decoder.decodeCalls == 0, "oversized artwork never reaches decoder")
        check(await pipeline.cachedByteCount == 0, "oversized artwork is not cached")

        let boundedLoader = TestArtworkLoader(data: Data([0, 1, 2, 3]))
        let boundedDecoder = TestArtworkDecoder()
        let boundedPipeline = BoundedMediaArtworkPipeline(
            loader: boundedLoader,
            decoder: boundedDecoder,
            maximumTotalBytes: 4,
            maximumEntryBytes: 4,
            maximumDecodeBytes: 4
        )
        _ = try! await boundedPipeline.artwork(for: reference)
        let secondKey = try! MediaArtworkCacheKey("spotify:artwork-2")
        let secondReference = try! MediaArtworkReference(
            remoteURL: URL(string: "https://example.invalid/artwork-2.jpg")!,
            cacheKey: secondKey
        )
        _ = try! await boundedPipeline.artwork(for: secondReference)
        check(await boundedPipeline.cachedByteCount == 4, "memory artwork cache stays within byte bound")
        check(await boundedPipeline.cachedEntryCount == 1, "memory artwork cache evicts least-recent entry")
        await boundedPipeline.removeAll()
        check(await boundedPipeline.cachedByteCount == 0, "artwork memory history can be purged")
    }

    private func verifySubscriberLifecycleAndBounds() async {
        let coordinator = MediaCoordinator(
            adapters: [],
            policy: MediaCoordinatorPolicy(maximumSubscribers: 1)
        )
        let stream = try! await coordinator.updates()
        check(await coordinator.activeSubscriberCount == 1, "subscriber is registered")

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
        check(await coordinator.activeSubscriberCount == 0, "cancelled subscriber is removed")

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

private func validScriptOutput(title: String = "Track") -> String {
    [
        "playing",
        title,
        "Artist",
        "Album",
        "track-1",
        "180",
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

    func perform(_ command: MediaCommand) async throws {
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

    func cancelPendingWork() async {
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

private enum ScriptAction: Sendable {
    case output(String)
    case failure(MediaScriptExecutionError)
}

private actor RecordingScriptExecutor: MediaScriptExecuting {
    private var actions: [ScriptAction]
    private var recordedRequests: [MediaScriptRequest] = []
    private(set) var cancelCalls = 0

    init(actions: [ScriptAction]) {
        self.actions = actions
    }

    func execute(_ request: MediaScriptRequest) throws -> String {
        recordedRequests.append(request)
        guard !actions.isEmpty else { return "" }
        switch actions.removeFirst() {
        case let .output(output):
            return output
        case let .failure(error):
            throw error
        }
    }

    func cancelAll() {
        cancelCalls += 1
    }

    func requests() -> [MediaScriptRequest] {
        recordedRequests
    }
}

private actor TestArtworkLoader: MediaArtworkDataLoading {
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func loadData(for reference: MediaArtworkReference) -> Data {
        data
    }
}

private actor TestArtworkDecoder: MediaArtworkDecoding {
    typealias DecodedArtwork = Int
    private(set) var decodeCalls = 0

    func decode(_ data: Data) -> Int {
        decodeCalls += 1
        return data.count
    }
}
