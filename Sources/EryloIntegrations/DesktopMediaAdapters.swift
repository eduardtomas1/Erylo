import AppKit
import EryloCore
import Foundation

public protocol MediaApplicationStatusChecking: Sendable {
    func isRunning(bundleIdentifier: String) async -> Bool
}

@_spi(Testing)
public protocol MediaAdapterAdmissionObserving: Sendable {
    func willAttemptAdmission(
        source: MediaSource,
        operationID: MediaOperationID
    ) async
}

public struct SystemMediaApplicationStatus: MediaApplicationStatusChecking {
    public init() {}

    public func isRunning(bundleIdentifier: String) async -> Bool {
        await MainActor.run {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).isEmpty
        }
    }
}

public enum MediaScriptRoute: String, Equatable, Sendable {
    case appleMusicSnapshot
    case appleMusicPlay
    case appleMusicPause
    case appleMusicNext
    case appleMusicPrevious
    case appleMusicSeek
    case appleMusicVolume
    case spotifySnapshot
    case spotifyPlay
    case spotifyPause
    case spotifyNext
    case spotifyPrevious
    case spotifySeek
    case spotifyVolume
}

/// The script body is selected internally from a closed route; values are only separate argv entries.
public struct MediaScriptRequest: Equatable, Sendable {
    public let route: MediaScriptRoute
    public let arguments: [String]

    public init(route: MediaScriptRoute, arguments: [String] = []) {
        self.route = route
        self.arguments = arguments
    }
}

public enum MediaScriptExecutionError: Error, Equatable, Sendable {
    case permissionDenied
    case applicationUnavailable
    case malformedResponse
    case timedOut
    case responseTooLarge
    case failed(exitCode: Int32?)
    case cancelled
}

public protocol MediaScriptExecuting: Sendable {
    func execute(
        _ request: MediaScriptRequest,
        operationID: MediaOperationID
    ) async throws -> String
    func cancel(_ operationID: MediaOperationID) async
}

public extension MediaScriptExecuting {
    func execute(_ request: MediaScriptRequest) async throws -> String {
        let operationID = MediaOperationID()
        return try await withTaskCancellationHandler {
            try await execute(request, operationID: operationID)
        } onCancel: {
            Task { await cancel(operationID) }
        }
    }
}

/// A killable, no-shell subprocess boundary around the documented `osascript` tool.
public actor ProcessMediaScriptExecutor: MediaScriptExecuting {
    private let processRunner: any MediaScriptProcessRunning
    private let limits: MediaScriptProcessLimits

    public init(limits: MediaScriptProcessLimits = MediaScriptProcessLimits()) {
        processRunner = FoundationMediaScriptProcessRunner()
        self.limits = limits
    }

    @_spi(Testing)
    public init(
        processRunner: any MediaScriptProcessRunning,
        limits: MediaScriptProcessLimits = MediaScriptProcessLimits()
    ) {
        self.processRunner = processRunner
        self.limits = limits
    }

    public func execute(
        _ request: MediaScriptRequest,
        operationID: MediaOperationID
    ) async throws -> String {
        guard !Task.isCancelled else {
            throw MediaScriptExecutionError.cancelled
        }
        let validatedArguments = try Self.validatedArguments(for: request)
        let arguments = ["-e", MediaAppleScripts.source(for: request.route), "--"]
            + validatedArguments
        let completed: MediaScriptProcessResult
        do {
            completed = try await withTaskCancellationHandler {
                try await processRunner.run(
                    arguments: arguments,
                    operationID: operationID,
                    limits: limits
                )
            } onCancel: {
                Task { await processRunner.cancel(operationID) }
            }
        } catch MediaScriptProcessError.cancelled {
            throw MediaScriptExecutionError.cancelled
        } catch MediaScriptProcessError.timedOut {
            throw MediaScriptExecutionError.timedOut
        } catch MediaScriptProcessError.standardOutputLimitExceeded,
                MediaScriptProcessError.standardErrorLimitExceeded {
            throw MediaScriptExecutionError.responseTooLarge
        } catch {
            throw MediaScriptExecutionError.failed(exitCode: nil)
        }

        if Task.isCancelled {
            throw MediaScriptExecutionError.cancelled
        }

        guard completed.exitCode == 0 else {
            let errorText = String(decoding: completed.standardError, as: UTF8.self)
            if errorText.contains("-1743")
                || errorText.localizedCaseInsensitiveContains("not authorized to send apple events") {
                throw MediaScriptExecutionError.permissionDenied
            }
            if errorText.contains("-600")
                || errorText.localizedCaseInsensitiveContains("isn't running") {
                throw MediaScriptExecutionError.applicationUnavailable
            }
            throw MediaScriptExecutionError.failed(exitCode: completed.exitCode)
        }

        guard let output = String(data: completed.standardOutput, encoding: .utf8) else {
            throw MediaScriptExecutionError.malformedResponse
        }
        return output.trimmingCharacters(in: .newlines)
    }

    public func cancel(_ operationID: MediaOperationID) async {
        await processRunner.cancel(operationID)
    }

    private static func validatedArguments(
        for request: MediaScriptRequest
    ) throws -> [String] {
        switch request.route {
        case .appleMusicSnapshot, .appleMusicPlay, .appleMusicPause,
             .appleMusicNext, .appleMusicPrevious,
             .spotifySnapshot, .spotifyPlay, .spotifyPause,
             .spotifyNext, .spotifyPrevious:
            guard request.arguments.isEmpty else {
                throw MediaScriptExecutionError.failed(exitCode: nil)
            }
            return []

        case .appleMusicSeek, .spotifySeek, .appleMusicVolume, .spotifyVolume:
            guard request.arguments.count == 1,
                  request.arguments[0].utf8.count <= 64,
                  let value = Double(request.arguments[0]),
                  value.isFinite,
                  value >= 0 else {
                throw MediaScriptExecutionError.failed(exitCode: nil)
            }
            if request.route == .appleMusicVolume || request.route == .spotifyVolume {
                guard value <= 100 else {
                    throw MediaScriptExecutionError.failed(exitCode: nil)
                }
            }
            return [String(value)]
        }
    }
}

public actor AppleMusicDesktopAdapter: MediaAdapter {
    public let source = MediaSource.appleMusic
    private let implementation: ScriptedDesktopMediaAdapter

    public init(
        applicationStatus: any MediaApplicationStatusChecking = SystemMediaApplicationStatus(),
        scriptExecutor: any MediaScriptExecuting = ProcessMediaScriptExecutor(),
        maximumPendingOperations: Int = 16,
        cancellationDrainTimeoutNanoseconds: UInt64 = 2_000_000_000
    ) {
        implementation = ScriptedDesktopMediaAdapter(
            source: .appleMusic,
            applicationStatus: applicationStatus,
            scriptExecutor: scriptExecutor,
            maximumPendingOperations: maximumPendingOperations,
            cancellationDrainTimeoutNanoseconds: cancellationDrainTimeoutNanoseconds,
            admissionObserver: nil
        )
    }

    @_spi(Testing)
    public init(
        applicationStatus: any MediaApplicationStatusChecking,
        scriptExecutor: any MediaScriptExecuting,
        maximumPendingOperations: Int,
        admissionObserver: any MediaAdapterAdmissionObserving,
        cancellationDrainTimeoutNanoseconds: UInt64 = 2_000_000_000
    ) {
        implementation = ScriptedDesktopMediaAdapter(
            source: .appleMusic,
            applicationStatus: applicationStatus,
            scriptExecutor: scriptExecutor,
            maximumPendingOperations: maximumPendingOperations,
            cancellationDrainTimeoutNanoseconds: cancellationDrainTimeoutNanoseconds,
            admissionObserver: admissionObserver
        )
    }

    public func activate() async { await implementation.activate() }
    public func deactivate() async { await implementation.deactivate() }
    public func updates() async -> AsyncStream<MediaAdapterUpdate> { await implementation.updates() }
    public func refresh(operationID: MediaOperationID) async throws -> MediaAdapterUpdate {
        try await implementation.refresh(operationID: operationID)
    }
    public func perform(_ command: MediaCommand, operationID: MediaOperationID) async throws {
        try await implementation.perform(command, operationID: operationID)
    }
    public func cancel(_ operationID: MediaOperationID) async {
        await implementation.cancel(operationID)
    }
    public func cancelAllPendingWork() async { await implementation.cancelAllPendingWork() }
    @_spi(Testing) public var latestSnapshotForTesting: NowPlayingSnapshot? {
        get async { await implementation.currentSnapshot }
    }
    @_spi(Testing) public var outstandingWorkCountForTesting: Int {
        get async { await implementation.outstandingWorkCount }
    }
}

public actor SpotifyDesktopAdapter: MediaAdapter {
    public let source = MediaSource.spotify
    private let implementation: ScriptedDesktopMediaAdapter

    public init(
        applicationStatus: any MediaApplicationStatusChecking = SystemMediaApplicationStatus(),
        scriptExecutor: any MediaScriptExecuting = ProcessMediaScriptExecutor(),
        maximumPendingOperations: Int = 16,
        cancellationDrainTimeoutNanoseconds: UInt64 = 2_000_000_000
    ) {
        implementation = ScriptedDesktopMediaAdapter(
            source: .spotify,
            applicationStatus: applicationStatus,
            scriptExecutor: scriptExecutor,
            maximumPendingOperations: maximumPendingOperations,
            cancellationDrainTimeoutNanoseconds: cancellationDrainTimeoutNanoseconds,
            admissionObserver: nil
        )
    }

    public func activate() async { await implementation.activate() }
    public func deactivate() async { await implementation.deactivate() }
    public func updates() async -> AsyncStream<MediaAdapterUpdate> { await implementation.updates() }
    public func refresh(operationID: MediaOperationID) async throws -> MediaAdapterUpdate {
        try await implementation.refresh(operationID: operationID)
    }
    public func perform(_ command: MediaCommand, operationID: MediaOperationID) async throws {
        try await implementation.perform(command, operationID: operationID)
    }
    public func cancel(_ operationID: MediaOperationID) async {
        await implementation.cancel(operationID)
    }
    public func cancelAllPendingWork() async { await implementation.cancelAllPendingWork() }
    @_spi(Testing) public var latestSnapshotForTesting: NowPlayingSnapshot? {
        get async { await implementation.currentSnapshot }
    }
    @_spi(Testing) public var outstandingWorkCountForTesting: Int {
        get async { await implementation.outstandingWorkCount }
    }
}

private final class MediaWorkCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let current = continuation
        continuation = nil
        return current
    }
}

private extension MediaWorkCompletion where Value == Void {
    func resume() {
        resume(returning: ())
    }
}

private final class MediaWorkSettlement: @unchecked Sendable {
    private let lock = NSLock()
    private var isSettled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isSettled {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func resolve() {
        lock.lock()
        guard !isSettled else {
            lock.unlock()
            return
        }
        isSettled = true
        let current = continuations
        continuations.removeAll(keepingCapacity: false)
        lock.unlock()
        for continuation in current {
            continuation.resume()
        }
    }
}

private enum MediaBoundedWait {
    static func wait(
        for task: Task<Void, Never>,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let resolution = MediaBooleanResolution(continuation)
            let completionTask = Task {
                await task.value
                resolution.resolve(true)
            }
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                resolution.resolve(false)
            }
            resolution.register([completionTask, timeoutTask])
        }
    }
}

private final class MediaBooleanResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var tasks: [Task<Void, Never>] = []

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: Bool) {
        lock.lock()
        let current = continuation
        continuation = nil
        let currentTasks = tasks
        tasks.removeAll(keepingCapacity: false)
        lock.unlock()
        for task in currentTasks { task.cancel() }
        current?.resume(returning: value)
    }

    func register(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            for task in tasks { task.cancel() }
            return
        }
        self.tasks = tasks
        lock.unlock()
    }
}

private actor ScriptedDesktopMediaAdapter {
    private enum ActiveWorkResult: Sendable {
        case refresh(MediaAdapterUpdate)
        case command
    }

    private enum WorkItem {
        case refresh(
            operationID: MediaOperationID,
            executionID: MediaOperationID,
            generation: UInt64,
            completion: MediaWorkCompletion<MediaAdapterUpdate>
        )
        case command(
            operationID: MediaOperationID,
            executionID: MediaOperationID,
            generation: UInt64,
            command: MediaCommand,
            completion: MediaWorkCompletion<Void>
        )

        var operationID: MediaOperationID {
            switch self {
            case let .refresh(operationID, _, _, _),
                 let .command(operationID, _, _, _, _):
                operationID
            }
        }

        var executionID: MediaOperationID {
            switch self {
            case let .refresh(_, executionID, _, _),
                 let .command(_, executionID, _, _, _):
                executionID
            }
        }

        var generation: UInt64 {
            switch self {
            case let .refresh(_, _, generation, _),
                 let .command(_, _, generation, _, _):
                generation
            }
        }
    }

    let source: MediaSource
    private let applicationStatus: any MediaApplicationStatusChecking
    private let scriptExecutor: any MediaScriptExecuting
    private let maximumPendingOperations: Int
    private let cancellationDrainTimeoutNanoseconds: UInt64
    private let requiresExactCancellationDrain: Bool
    private let admissionObserver: (any MediaAdapterAdmissionObserving)?
    private var isActive = false
    private var activationGeneration: UInt64 = 0
    private var sequence: UInt64 = 0
    private var latestSnapshot: NowPlayingSnapshot?
    private var workQueue: [WorkItem] = []
    private var workTask: Task<Void, Never>?
    private var workerEpoch: UInt64 = 0
    private var activeWorkTask: Task<ActiveWorkResult, Error>?
    private var activeWork: WorkItem?
    private var activeSettlement: MediaWorkSettlement?
    private var activeOperationID: MediaOperationID?
    private var activeExecutionID: MediaOperationID?
    private var cancelledExecutionIDs: Set<MediaOperationID> = []
    private var unsettledExecutionIDs: Set<MediaOperationID> = []
    private var workSettledWhileCancelling: Set<MediaOperationID> = []
    private var pendingCancellationExecutionIDs: Set<MediaOperationID> = []
    private var cancellationDrainTasks: [MediaOperationID: Task<Void, Never>] = [:]

    init(
        source: MediaSource,
        applicationStatus: any MediaApplicationStatusChecking,
        scriptExecutor: any MediaScriptExecuting,
        maximumPendingOperations: Int,
        cancellationDrainTimeoutNanoseconds: UInt64,
        admissionObserver: (any MediaAdapterAdmissionObserving)?
    ) {
        self.source = source
        self.applicationStatus = applicationStatus
        self.scriptExecutor = scriptExecutor
        self.maximumPendingOperations = min(max(1, maximumPendingOperations), 64)
        self.cancellationDrainTimeoutNanoseconds = min(
            max(10_000_000, cancellationDrainTimeoutNanoseconds),
            5_000_000_000
        )
        requiresExactCancellationDrain = scriptExecutor is ProcessMediaScriptExecutor
        self.admissionObserver = admissionObserver
    }

    func activate() {
        activationGeneration &+= 1
        isActive = true
    }

    func deactivate() async {
        activationGeneration &+= 1
        isActive = false
        latestSnapshot = nil
        await cancelAllPendingWork()
    }

    /// The public desktop scripting dictionaries expose no reliable change notification seam.
    func updates() -> AsyncStream<MediaAdapterUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func refresh(operationID: MediaOperationID) async throws -> MediaAdapterUpdate {
        guard !Task.isCancelled else { throw MediaError.cancelled(source: source) }
        guard isActive else { throw MediaError.disabled(source: source) }
        guard !containsOperation(operationID) else {
            throw MediaError.automationFailed(source: source, exitCode: nil)
        }
        let generation = activationGeneration
        await admissionObserver?.willAttemptAdmission(
            source: source,
            operationID: operationID
        )
        guard !Task.isCancelled, isActive, activationGeneration == generation else {
            throw MediaError.cancelled(source: source)
        }
        guard !containsOperation(operationID) else {
            throw MediaError.automationFailed(source: source, exitCode: nil)
        }
        guard admittedOperationCount < maximumPendingOperations else {
            throw MediaError.operationQueueFull(
                source: source,
                limit: maximumPendingOperations
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            let completion = MediaWorkCompletion(continuation)
            workQueue.append(
                .refresh(
                    operationID: operationID,
                    executionID: MediaOperationID(),
                    generation: generation,
                    completion: completion
                )
            )
            startWorkerIfNeeded()
        }
    }

    func perform(_ command: MediaCommand, operationID: MediaOperationID) async throws {
        guard !Task.isCancelled else { throw MediaError.cancelled(source: source) }
        guard isActive else { throw MediaError.disabled(source: source) }
        guard !containsOperation(operationID) else {
            throw MediaError.automationFailed(source: source, exitCode: nil)
        }
        let generation = activationGeneration
        await admissionObserver?.willAttemptAdmission(
            source: source,
            operationID: operationID
        )
        guard !Task.isCancelled, isActive, activationGeneration == generation else {
            throw MediaError.cancelled(source: source)
        }
        guard !containsOperation(operationID) else {
            throw MediaError.automationFailed(source: source, exitCode: nil)
        }
        guard admittedOperationCount < maximumPendingOperations else {
            throw MediaError.operationQueueFull(
                source: source,
                limit: maximumPendingOperations
            )
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let completion = MediaWorkCompletion(continuation)
            workQueue.append(
                .command(
                    operationID: operationID,
                    executionID: MediaOperationID(),
                    generation: generation,
                    command: command,
                    completion: completion
                )
            )
            startWorkerIfNeeded()
        }
    }

    func cancel(_ operationID: MediaOperationID) async {
        if let index = workQueue.firstIndex(where: { $0.operationID == operationID }) {
            let work = workQueue.remove(at: index)
            resume(work, throwing: MediaError.cancelled(source: source))
            return
        }

        guard activeOperationID == operationID else {
            // A late cancellation is a no-op and leaves no tombstone.
            return
        }
        await cancelActiveOperation(operationID)
    }

    func cancelAllPendingWork() async {
        let queued = workQueue
        workQueue.removeAll(keepingCapacity: false)
        for work in queued {
            resume(work, throwing: MediaError.cancelled(source: source))
        }
        if let activeOperationID {
            await cancelActiveOperation(activeOperationID)
        }
    }

    private func startWorkerIfNeeded() {
        guard workTask == nil else { return }
        workerEpoch &+= 1
        let epoch = workerEpoch
        workTask = Task { [weak self] in
            await self?.drainWorkQueue(epoch: epoch)
        }
    }

    private func drainWorkQueue(epoch: UInt64) async {
        while !Task.isCancelled, workerEpoch == epoch, !workQueue.isEmpty {
            let work = workQueue.removeFirst()
            let operationID = work.operationID
            let executionID = work.executionID
            let settlement = MediaWorkSettlement()
            activeOperationID = operationID
            activeExecutionID = executionID
            unsettledExecutionIDs.insert(executionID)
            activeWork = work
            activeSettlement = settlement

            let task = Task<ActiveWorkResult, Error> { [weak self] in
                guard let self else { throw CancellationError() }
                switch work {
                case let .refresh(_, _, generation, _):
                    let update = try await self.loadSnapshot(
                        operationID: operationID,
                        executionID: executionID,
                        generation: generation
                    )
                    return .refresh(update)
                case let .command(_, _, generation, command, _):
                    try await self.runCommand(
                        command,
                        operationID: operationID,
                        executionID: executionID,
                        generation: generation
                    )
                    return .command
                }
            }
            activeWorkTask = task
            let result = await task.result

            guard workerEpoch == epoch,
                  activeOperationID == operationID,
                  activeExecutionID == executionID else {
                markWorkSettled(executionID)
                resume(work, throwing: MediaError.cancelled(source: source))
                settlement.resolve()
                return
            }
            activeWorkTask = nil
            activeWork = nil
            activeSettlement = nil
            activeOperationID = nil
            activeExecutionID = nil
            markWorkSettled(executionID)

            switch (work, result) {
            case let (.refresh(_, _, generation, continuation), .success(.refresh(update))):
                if consumeCancellation(for: executionID, generation: generation) {
                    continuation.resume(throwing: MediaError.cancelled(source: source))
                } else {
                    continuation.resume(returning: update)
                }
            case let (.command(_, _, generation, _, continuation), .success(.command)):
                if consumeCancellation(for: executionID, generation: generation) {
                    continuation.resume(throwing: MediaError.cancelled(source: source))
                } else {
                    continuation.resume()
                }
            case let (.refresh(_, _, generation, continuation), .failure(error)):
                if consumeCancellation(for: executionID, generation: generation) {
                    continuation.resume(throwing: MediaError.cancelled(source: source))
                } else {
                    continuation.resume(throwing: map(error))
                }
            case let (.command(_, _, generation, _, continuation), .failure(error)):
                if consumeCancellation(for: executionID, generation: generation) {
                    continuation.resume(throwing: MediaError.cancelled(source: source))
                } else {
                    continuation.resume(throwing: map(error))
                }
            default:
                resume(work, throwing: MediaError.automationFailed(source: source, exitCode: nil))
            }
            settlement.resolve()
        }

        guard workerEpoch == epoch else { return }
        workTask = nil
        if !workQueue.isEmpty {
            startWorkerIfNeeded()
        }
    }

    private func cancelActiveOperation(_ operationID: MediaOperationID) async {
        guard activeOperationID == operationID,
              let executionID = activeExecutionID,
              let settlement = activeSettlement else { return }
        cancelledExecutionIDs.insert(executionID)
        activeWorkTask?.cancel()

        let drain: Task<Void, Never>
        if let existing = cancellationDrainTasks[executionID] {
            drain = existing
        } else {
            pendingCancellationExecutionIDs.insert(executionID)
            let executor = scriptExecutor
            drain = Task.detached { [weak self] in
                await executor.cancel(executionID)
                await self?.cancellationCallSettled(executionID)
                await settlement.wait()
                await self?.cancellationDrainSettled(executionID)
            }
            cancellationDrainTasks[executionID] = drain
        }
        if requiresExactCancellationDrain {
            await drain.value
            return
        }
        if await MediaBoundedWait.wait(
            for: drain,
            timeoutNanoseconds: cancellationDrainTimeoutNanoseconds
        ) {
            return
        }

        retireActiveOperation(
            operationID,
            executionID: executionID,
            settlement: settlement
        )
    }

    private func retireActiveOperation(
        _ operationID: MediaOperationID,
        executionID: MediaOperationID,
        settlement: MediaWorkSettlement
    ) {
        guard activeOperationID == operationID,
              activeExecutionID == executionID,
              activeSettlement === settlement else { return }
        workerEpoch &+= 1
        workTask?.cancel()
        activeWorkTask?.cancel()
        if let activeWork {
            resume(activeWork, throwing: MediaError.cancelled(source: source))
        }
        activeWork = nil
        activeWorkTask = nil
        activeSettlement = nil
        activeOperationID = nil
        activeExecutionID = nil
        workTask = nil
        cancelledExecutionIDs.remove(executionID)
        if isActive, !workQueue.isEmpty {
            startWorkerIfNeeded()
        }
    }

    private func loadSnapshot(
        operationID: MediaOperationID,
        executionID: MediaOperationID,
        generation: UInt64
    ) async throws -> MediaAdapterUpdate {
        try ensureCurrent(
            operationID: operationID,
            executionID: executionID,
            generation: generation
        )
        let applicationIsRunning = await applicationStatus.isRunning(
            bundleIdentifier: source.bundleIdentifier
        )
        try ensureCurrent(
            operationID: operationID,
            executionID: executionID,
            generation: generation
        )
        guard applicationIsRunning else {
            latestSnapshot = nil
            return .sourceDisappeared(source: source, stamp: nextStamp())
        }

        do {
            let output = try await scriptExecutor.execute(
                snapshotRequest,
                operationID: executionID
            )
            try ensureCurrent(
                operationID: operationID,
                executionID: executionID,
                generation: generation
            )
            let snapshot = try MediaSnapshotParser.parse(
                output,
                source: source,
                stamp: nextStamp()
            )
            latestSnapshot = snapshot
            return .snapshot(snapshot)
        } catch MediaScriptExecutionError.applicationUnavailable {
            try ensureCurrent(
                operationID: operationID,
                executionID: executionID,
                generation: generation
            )
            latestSnapshot = nil
            return .sourceDisappeared(source: source, stamp: nextStamp())
        } catch {
            throw map(error)
        }
    }

    private func runCommand(
        _ command: MediaCommand,
        operationID: MediaOperationID,
        executionID: MediaOperationID,
        generation: UInt64
    ) async throws {
        try ensureCurrent(
            operationID: operationID,
            executionID: executionID,
            generation: generation
        )
        if latestSnapshot == nil {
            let update = try await loadSnapshot(
                operationID: operationID,
                executionID: executionID,
                generation: generation
            )
            guard case .snapshot = update else {
                throw MediaError.sourceUnavailable(source: source)
            }
        }

        let applicationIsRunning = await applicationStatus.isRunning(
            bundleIdentifier: source.bundleIdentifier
        )
        try ensureCurrent(
            operationID: operationID,
            executionID: executionID,
            generation: generation
        )
        guard applicationIsRunning else {
            latestSnapshot = nil
            throw MediaError.sourceUnavailable(source: source)
        }

        // There is no await between this latest-state validation and the fixed-route launch call.
        guard let latestSnapshot else {
            throw MediaError.sourceUnavailable(source: source)
        }
        let revalidated = try command.normalized(for: latestSnapshot)
        try ensureCurrent(
            operationID: operationID,
            executionID: executionID,
            generation: generation
        )
        _ = try await scriptExecutor.execute(
            commandRequest(for: revalidated),
            operationID: executionID
        )
        try ensureCurrent(
            operationID: operationID,
            executionID: executionID,
            generation: generation
        )
    }

    private func ensureCurrent(
        operationID: MediaOperationID,
        executionID: MediaOperationID,
        generation: UInt64
    ) throws {
        guard !Task.isCancelled,
              isActive,
              activationGeneration == generation,
              activeOperationID == operationID,
              activeExecutionID == executionID,
              !cancelledExecutionIDs.contains(executionID) else {
            throw MediaError.cancelled(source: source)
        }
    }

    private func consumeCancellation(
        for executionID: MediaOperationID,
        generation: UInt64
    ) -> Bool {
        let wasCancelled = cancelledExecutionIDs.remove(executionID) != nil
        return wasCancelled || !isActive || activationGeneration != generation
    }

    private func containsOperation(_ operationID: MediaOperationID) -> Bool {
        activeOperationID == operationID
            || workQueue.contains { $0.operationID == operationID }
    }

    private var admittedOperationCount: Int {
        workQueue.count + unsettledExecutionIDs.count
    }

    private func markWorkSettled(_ executionID: MediaOperationID) {
        if pendingCancellationExecutionIDs.contains(executionID) {
            workSettledWhileCancelling.insert(executionID)
        } else {
            unsettledExecutionIDs.remove(executionID)
        }
    }

    private func cancellationCallSettled(_ executionID: MediaOperationID) {
        pendingCancellationExecutionIDs.remove(executionID)
        if workSettledWhileCancelling.remove(executionID) != nil {
            unsettledExecutionIDs.remove(executionID)
        }
    }

    private func cancellationDrainSettled(_ executionID: MediaOperationID) {
        cancellationDrainTasks.removeValue(forKey: executionID)
    }

    var currentSnapshot: NowPlayingSnapshot? { latestSnapshot }
    var outstandingWorkCount: Int { unsettledExecutionIDs.count }

    private func resume(_ work: WorkItem, throwing error: Error) {
        cancelledExecutionIDs.remove(work.executionID)
        switch work {
        case let .refresh(_, _, _, continuation):
            continuation.resume(throwing: error)
        case let .command(_, _, _, _, continuation):
            continuation.resume(throwing: error)
        }
    }

    private var snapshotRequest: MediaScriptRequest {
        MediaScriptRequest(
            route: source == .appleMusic ? .appleMusicSnapshot : .spotifySnapshot
        )
    }

    private func commandRequest(for command: MediaCommand) -> MediaScriptRequest {
        let route: MediaScriptRoute
        let arguments: [String]

        switch (source, command) {
        case (.appleMusic, .play):
            route = .appleMusicPlay
            arguments = []
        case (.appleMusic, .pause):
            route = .appleMusicPause
            arguments = []
        case (.appleMusic, .next):
            route = .appleMusicNext
            arguments = []
        case (.appleMusic, .previous):
            route = .appleMusicPrevious
            arguments = []
        case let (.appleMusic, .seek(position)):
            route = .appleMusicSeek
            arguments = [String(position)]
        case let (.appleMusic, .setVolume(volume)):
            route = .appleMusicVolume
            arguments = [String(Int((volume * 100).rounded()))]
        case (.spotify, .play):
            route = .spotifyPlay
            arguments = []
        case (.spotify, .pause):
            route = .spotifyPause
            arguments = []
        case (.spotify, .next):
            route = .spotifyNext
            arguments = []
        case (.spotify, .previous):
            route = .spotifyPrevious
            arguments = []
        case let (.spotify, .seek(position)):
            route = .spotifySeek
            arguments = [String(position)]
        case let (.spotify, .setVolume(volume)):
            route = .spotifyVolume
            arguments = [String(Int((volume * 100).rounded()))]
        }

        return MediaScriptRequest(route: route, arguments: arguments)
    }

    private func nextStamp() -> MediaUpdateStamp {
        sequence &+= 1
        return MediaUpdateStamp(sequence: sequence)
    }

    private func map(_ error: Error) -> MediaError {
        if let mediaError = error as? MediaError {
            return mediaError
        }
        if error is CancellationError {
            return .cancelled(source: source)
        }
        guard let scriptError = error as? MediaScriptExecutionError else {
            return .automationFailed(source: source, exitCode: nil)
        }

        return switch scriptError {
        case .permissionDenied:
            .permissionDenied(source: source)
        case .applicationUnavailable:
            .sourceUnavailable(source: source)
        case .malformedResponse:
            .malformedResponse(source: source)
        case .timedOut:
            .automationTimedOut(source: source)
        case .responseTooLarge:
            .responseTooLarge(source: source)
        case let .failed(exitCode):
            .automationFailed(source: source, exitCode: exitCode)
        case .cancelled:
            .cancelled(source: source)
        }
    }
}

private enum MediaSnapshotParser {
    private static let expectedFieldCount = 10

    static func parse(
        _ output: String,
        source: MediaSource,
        stamp: MediaUpdateStamp
    ) throws -> NowPlayingSnapshot {
        guard output.utf8.count <= 48 * 1_024 else {
            throw MediaError.malformedResponse(source: source)
        }
        let rawFields = output.split(separator: "\t", omittingEmptySubsequences: false)
        guard rawFields.count == expectedFieldCount else {
            throw MediaError.malformedResponse(source: source)
        }
        let fields = rawFields.map { unescape(String($0)) }

        let playbackState: MediaPlaybackState = switch fields[0].lowercased() {
        case "playing", "fast forwarding", "rewinding":
            .playing
        case "paused":
            .paused
        case "stopped":
            .stopped
        default:
            throw MediaError.malformedResponse(source: source)
        }

        guard let rawDuration = Double(fields[5]),
              rawDuration.isFinite,
              rawDuration >= 0,
              let rawPosition = Double(fields[6]),
              rawPosition.isFinite,
              let rawVolume = Double(fields[7]),
              rawVolume.isFinite else {
            throw MediaError.malformedResponse(source: source)
        }
        let durationScale = source == .spotify ? 0.001 : 1.0
        let duration = rawDuration * durationScale
        let volume = rawVolume / 100

        var capabilities: MediaCapabilities = [.transport, .volume]
        if duration > 0 {
            capabilities.insert(.seek)
        }

        let trackIdentifier = nilIfEmpty(fields[4])
        let artwork = artworkReference(
            kind: fields[8],
            value: fields[9],
            trackIdentifier: trackIdentifier,
            source: source
        )

        return try NowPlayingSnapshot(
            source: source,
            stamp: stamp,
            trackIdentifier: trackIdentifier,
            title: nilIfEmpty(fields[1]),
            artist: nilIfEmpty(fields[2]),
            album: nilIfEmpty(fields[3]),
            duration: duration,
            position: rawPosition,
            playbackState: playbackState,
            volume: volume,
            capabilities: capabilities,
            artwork: artwork
        )
    }

    private static func artworkReference(
        kind: String,
        value: String,
        trackIdentifier: String?,
        source: MediaSource
    ) -> MediaArtworkReference? {
        guard !value.isEmpty else { return nil }
        let stableIdentifier = trackIdentifier ?? value
        guard let cacheKey = try? MediaArtworkCacheKey(
            "\(source.rawValue):\(stableIdentifier)"
        ) else { return nil }

        switch kind {
        case "sourceAsset":
            return try? MediaArtworkReference(
                sourceAssetIdentifier: value,
                cacheKey: cacheKey
            )
        case "remoteURL":
            guard let url = URL(string: value) else {
                return nil
            }
            return try? MediaArtworkReference(remoteURL: url, cacheKey: cacheKey)
        default:
            return nil
        }
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var isEscaped = false

        for character in value {
            if isEscaped {
                switch character {
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                default:
                    result.append("\\")
                    result.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        if isEscaped {
            result.append("\\")
        }
        return result
    }
}

private enum MediaAppleScripts {
    static func source(for route: MediaScriptRoute) -> String {
        switch route {
        case .appleMusicSnapshot:
            appleMusicSnapshot
        case .spotifySnapshot:
            spotifySnapshot
        case .appleMusicPlay:
            appleMusicPlay
        case .appleMusicPause:
            appleMusicPause
        case .appleMusicNext:
            appleMusicNext
        case .appleMusicPrevious:
            appleMusicPrevious
        case .spotifyPlay:
            spotifyPlay
        case .spotifyPause:
            spotifyPause
        case .spotifyNext:
            spotifyNext
        case .spotifyPrevious:
            spotifyPrevious
        case .appleMusicSeek:
            appleMusicSeek
        case .spotifySeek:
            spotifySeek
        case .appleMusicVolume:
            appleMusicVolume
        case .spotifyVolume:
            spotifyVolume
        }
    }

    private static let appleMusicPlay = #"""
    if application id "com.apple.Music" is not running then error number -600
    tell application id "com.apple.Music" to play
    """#

    private static let appleMusicPause = #"""
    if application id "com.apple.Music" is not running then error number -600
    tell application id "com.apple.Music" to pause
    """#

    private static let appleMusicNext = #"""
    if application id "com.apple.Music" is not running then error number -600
    tell application id "com.apple.Music" to next track
    """#

    private static let appleMusicPrevious = #"""
    if application id "com.apple.Music" is not running then error number -600
    tell application id "com.apple.Music" to previous track
    """#

    private static let spotifyPlay = #"""
    if application id "com.spotify.client" is not running then error number -600
    tell application id "com.spotify.client" to play
    """#

    private static let spotifyPause = #"""
    if application id "com.spotify.client" is not running then error number -600
    tell application id "com.spotify.client" to pause
    """#

    private static let spotifyNext = #"""
    if application id "com.spotify.client" is not running then error number -600
    tell application id "com.spotify.client" to next track
    """#

    private static let spotifyPrevious = #"""
    if application id "com.spotify.client" is not running then error number -600
    tell application id "com.spotify.client" to previous track
    """#

    private static let appleMusicSeek = #"""
    on run argv
        if (count of argv) is not 1 then error number -1700
        set requestedValue to item 1 of argv as real
        if requestedValue < 0 then error number -1700
        if application id "com.apple.Music" is not running then error number -600
        tell application id "com.apple.Music" to set player position to requestedValue
    end run
    """#

    private static let spotifySeek = #"""
    on run argv
        if (count of argv) is not 1 then error number -1700
        set requestedValue to item 1 of argv as real
        if requestedValue < 0 then error number -1700
        if application id "com.spotify.client" is not running then error number -600
        tell application id "com.spotify.client" to set player position to requestedValue
    end run
    """#

    private static let appleMusicVolume = #"""
    on run argv
        if (count of argv) is not 1 then error number -1700
        set requestedValue to item 1 of argv as real
        if requestedValue < 0 or requestedValue > 100 then error number -1700
        if application id "com.apple.Music" is not running then error number -600
        tell application id "com.apple.Music" to set sound volume to requestedValue
    end run
    """#

    private static let spotifyVolume = #"""
    on run argv
        if (count of argv) is not 1 then error number -1700
        set requestedValue to item 1 of argv as real
        if requestedValue < 0 or requestedValue > 100 then error number -1700
        if application id "com.spotify.client" is not running then error number -600
        tell application id "com.spotify.client" to set sound volume to requestedValue
    end run
    """#

    private static let handlers = #"""
    on replaceText(findText, replacementText, sourceText)
        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to findText
        set sourceItems to text items of sourceText
        set AppleScript's text item delimiters to replacementText
        set joinedText to sourceItems as text
        set AppleScript's text item delimiters to previousDelimiters
        return joinedText
    end replaceText

    on escaped(sourceValue)
        set valueText to sourceValue as text
        if (count characters of valueText) > 2048 then set valueText to text 1 thru 2048 of valueText
        set valueText to my replaceText("\\", "\\\\", valueText)
        set valueText to my replaceText(tab, "\\t", valueText)
        set valueText to my replaceText(linefeed, "\\n", valueText)
        set valueText to my replaceText(return, "\\r", valueText)
        return valueText
    end escaped

    on joinFields(fieldValues)
        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to tab
        set joinedText to fieldValues as text
        set AppleScript's text item delimiters to previousDelimiters
        return joinedText
    end joinFields
    """#

    private static let appleMusicSnapshot = handlers + #"""

    if application id "com.apple.Music" is not running then error number -600
    tell application id "com.apple.Music"
        set stateText to (get player state) as text
        set titleText to ""
        set artistText to ""
        set albumText to ""
        set identifierText to ""
        set durationText to "0"
        set positionText to "0"
        set volumeText to (get sound volume) as text
        set artworkKindText to ""
        set artworkValueText to ""
        try
            set selectedTrack to current track
            set titleText to name of selectedTrack as text
            set artistText to artist of selectedTrack as text
            set albumText to album of selectedTrack as text
            set identifierText to persistent ID of selectedTrack as text
            set durationText to duration of selectedTrack as text
            set positionText to (get player position) as text
            if identifierText is not "" and (count of artworks of selectedTrack) > 0 then
                set artworkKindText to "sourceAsset"
                set artworkValueText to identifierText
            end if
        end try
        return my joinFields({my escaped(stateText), my escaped(titleText), my escaped(artistText), my escaped(albumText), my escaped(identifierText), my escaped(durationText), my escaped(positionText), my escaped(volumeText), my escaped(artworkKindText), my escaped(artworkValueText)})
    end tell
    """#

    private static let spotifySnapshot = handlers + #"""

    if application id "com.spotify.client" is not running then error number -600
    tell application id "com.spotify.client"
        set stateText to (get player state) as text
        set titleText to ""
        set artistText to ""
        set albumText to ""
        set identifierText to ""
        set durationText to "0"
        set positionText to "0"
        set volumeText to (get sound volume) as text
        set artworkKindText to ""
        set artworkValueText to ""
        try
            set selectedTrack to current track
            set titleText to name of selectedTrack as text
            set artistText to artist of selectedTrack as text
            set albumText to album of selectedTrack as text
            set identifierText to spotify url of selectedTrack as text
            set durationText to duration of selectedTrack as text
            set positionText to (get player position) as text
            set artworkValueText to artwork url of selectedTrack as text
            if artworkValueText is not "" then set artworkKindText to "remoteURL"
        end try
        return my joinFields({my escaped(stateText), my escaped(titleText), my escaped(artistText), my escaped(albumText), my escaped(identifierText), my escaped(durationText), my escaped(positionText), my escaped(volumeText), my escaped(artworkKindText), my escaped(artworkValueText)})
    end tell
    """#
}
