import Darwin
import Foundation

public struct MediaScriptProcessLimits: Equatable, Sendable {
    public let maximumStandardOutputBytes: Int
    public let maximumStandardErrorBytes: Int
    public let timeoutNanoseconds: UInt64
    public let terminationGraceNanoseconds: UInt64

    public init(
        maximumStandardOutputBytes: Int = 48 * 1_024,
        maximumStandardErrorBytes: Int = 16 * 1_024,
        timeoutNanoseconds: UInt64 = 30_000_000_000,
        terminationGraceNanoseconds: UInt64 = 250_000_000
    ) {
        self.maximumStandardOutputBytes = min(max(1, maximumStandardOutputBytes), 1_024 * 1_024)
        self.maximumStandardErrorBytes = min(max(1, maximumStandardErrorBytes), 1_024 * 1_024)
        self.timeoutNanoseconds = min(max(10_000_000, timeoutNanoseconds), 60_000_000_000)
        self.terminationGraceNanoseconds = min(
            max(10_000_000, terminationGraceNanoseconds),
            1_000_000_000
        )
    }
}

public struct MediaScriptProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(exitCode: Int32, standardOutput: Data, standardError: Data) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum MediaScriptProcessError: Error, Equatable, Sendable {
    case duplicateOperation
    case capacityExceeded(limit: Int)
    case launchFailed
    case timedOut
    case cancelled
    case standardOutputLimitExceeded(maximumBytes: Int)
    case standardErrorLimitExceeded(maximumBytes: Int)
    case streamReadFailed
}

/// Injectable process seam. The production implementation fixes its executable to `/usr/bin/osascript`.
public protocol MediaScriptProcessRunning: Sendable {
    func run(
        arguments: [String],
        operationID: MediaOperationID,
        limits: MediaScriptProcessLimits
    ) async throws -> MediaScriptProcessResult

    func cancel(_ operationID: MediaOperationID) async
}

@_spi(Testing)
public protocol MediaProcessControlling: Sendable {
    func didStart(_ process: Process)
    func isRunning(_ process: Process) -> Bool
    func terminate(_ process: Process)
    func kill(_ process: Process)
}

/// Concurrently drains both pipes with hard caps and owns timeout plus TERM-to-KILL escalation.
public actor FoundationMediaScriptProcessRunner: MediaScriptProcessRunning {
    private let executableURL: URL
    private let processController: any MediaProcessControlling
    private let maximumActiveProcesses: Int
    private var activeProcesses: [MediaOperationID: RunningMediaProcess] = [:]

    public init(maximumActiveProcesses: Int = 4) {
        executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        processController = SystemMediaProcessController()
        self.maximumActiveProcesses = min(max(1, maximumActiveProcesses), 16)
    }

    @_spi(Testing)
    public init(executableURL: URL, maximumActiveProcesses: Int = 4) {
        self.executableURL = executableURL
        processController = SystemMediaProcessController()
        self.maximumActiveProcesses = min(max(1, maximumActiveProcesses), 16)
    }

    @_spi(Testing)
    public init(
        executableURL: URL,
        processController: any MediaProcessControlling,
        maximumActiveProcesses: Int = 4
    ) {
        self.executableURL = executableURL
        self.processController = processController
        self.maximumActiveProcesses = min(max(1, maximumActiveProcesses), 16)
    }

    public func run(
        arguments: [String],
        operationID: MediaOperationID,
        limits: MediaScriptProcessLimits
    ) async throws -> MediaScriptProcessResult {
        guard activeProcesses[operationID] == nil else {
            throw MediaScriptProcessError.duplicateOperation
        }
        guard activeProcesses.count < maximumActiveProcesses else {
            throw MediaScriptProcessError.capacityExceeded(limit: maximumActiveProcesses)
        }
        guard !Task.isCancelled else {
            throw MediaScriptProcessError.cancelled
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let termination = ProcessTerminationWaiter()
        let running = RunningMediaProcess(
            process: process,
            processController: processController,
            terminationGraceNanoseconds: limits.terminationGraceNanoseconds
        )

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { completedProcess in
            running.markFinished()
            termination.resolve(completedProcess.terminationStatus)
        }

        activeProcesses[operationID] = running
        var timeoutTask: Task<Void, Never>?
        defer {
            timeoutTask?.cancel()
            running.finish()
            activeProcesses.removeValue(forKey: operationID)
            process.terminationHandler = nil
            try? standardOutput.fileHandleForReading.close()
            try? standardError.fileHandleForReading.close()
        }

        do {
            guard !Task.isCancelled else {
                throw MediaScriptProcessError.cancelled
            }
            try process.run()
        } catch let error as MediaScriptProcessError {
            termination.resolve(-1)
            throw error
        } catch {
            termination.resolve(-1)
            throw MediaScriptProcessError.launchFailed
        }
        running.markStarted()

        let outputTask = Task.detached(priority: .utility) {
            try Self.drain(
                standardOutput.fileHandleForReading,
                maximumBytes: limits.maximumStandardOutputBytes,
                limitError: .standardOutputLimitExceeded(
                    maximumBytes: limits.maximumStandardOutputBytes
                ),
                stopReason: .standardOutputLimit,
                running: running
            )
        }
        let errorTask = Task.detached(priority: .utility) {
            try Self.drain(
                standardError.fileHandleForReading,
                maximumBytes: limits.maximumStandardErrorBytes,
                limitError: .standardErrorLimitExceeded(
                    maximumBytes: limits.maximumStandardErrorBytes
                ),
                stopReason: .standardErrorLimit,
                running: running
            )
        }
        timeoutTask = Task.detached {
            do {
                try await Task.sleep(nanoseconds: limits.timeoutNanoseconds)
                running.requestStop(.timedOut)
            } catch {
                // The one-shot timeout is cancelled on every terminal path.
            }
        }

        let exitCode = await termination.wait()
        timeoutTask?.cancel()
        let outputResult = await outputTask.result
        let errorResult = await errorTask.result

        if let stopReason = running.stopReason {
            throw stopReason.error(
                outputLimit: limits.maximumStandardOutputBytes,
                errorLimit: limits.maximumStandardErrorBytes
            )
        }

        let output: Data
        switch outputResult {
        case let .success(data):
            output = data
        case let .failure(error):
            throw (error as? MediaScriptProcessError) ?? .streamReadFailed
        }
        let errorData: Data
        switch errorResult {
        case let .success(data):
            errorData = data
        case let .failure(error):
            throw (error as? MediaScriptProcessError) ?? .streamReadFailed
        }

        return MediaScriptProcessResult(
            exitCode: exitCode,
            standardOutput: output,
            standardError: errorData
        )
    }

    public func cancel(_ operationID: MediaOperationID) {
        // Late cancellation is a no-op; no ID is retained after its live request leaves the table.
        activeProcesses[operationID]?.requestStop(.cancelled)
    }

    private nonisolated static func drain(
        _ handle: FileHandle,
        maximumBytes: Int,
        limitError: MediaScriptProcessError,
        stopReason: MediaProcessStopReason,
        running: RunningMediaProcess
    ) throws -> Data {
        var collected = Data()
        collected.reserveCapacity(min(maximumBytes, 16 * 1_024))

        do {
            while let chunk = try handle.read(upToCount: 8 * 1_024), !chunk.isEmpty {
                guard collected.count <= maximumBytes - chunk.count else {
                    running.requestStop(stopReason)
                    throw limitError
                }
                collected.append(chunk)
            }
            return collected
        } catch let error as MediaScriptProcessError {
            throw error
        } catch {
            running.requestStop(.streamReadFailure)
            throw MediaScriptProcessError.streamReadFailed
        }
    }
}

@_spi(Testing)
public enum MediaProcessStopReason: Equatable, Sendable {
    case cancelled
    case timedOut
    case standardOutputLimit
    case standardErrorLimit
    case streamReadFailure

    func error(outputLimit: Int, errorLimit: Int) -> MediaScriptProcessError {
        switch self {
        case .cancelled:
            .cancelled
        case .timedOut:
            .timedOut
        case .standardOutputLimit:
            .standardOutputLimitExceeded(maximumBytes: outputLimit)
        case .standardErrorLimit:
            .standardErrorLimitExceeded(maximumBytes: errorLimit)
        case .streamReadFailure:
            .streamReadFailed
        }
    }
}

@_spi(Testing)
public final class RunningMediaProcess: @unchecked Sendable {
    private let process: Process
    private let processController: any MediaProcessControlling
    private let terminationGraceNanoseconds: UInt64
    private let lock = NSLock()
    private var hasStarted = false
    private var hasFinished = false
    private var storedStopReason: MediaProcessStopReason?
    private var isEscalating = false
    private var escalationTask: Task<Void, Never>?

    @_spi(Testing)
    public init(
        process: Process,
        processController: any MediaProcessControlling,
        terminationGraceNanoseconds: UInt64
    ) {
        self.process = process
        self.processController = processController
        self.terminationGraceNanoseconds = terminationGraceNanoseconds
    }

    @_spi(Testing)
    public var stopReason: MediaProcessStopReason? {
        lock.lock()
        defer { lock.unlock() }
        return storedStopReason
    }

    @_spi(Testing)
    public func markStarted() {
        let shouldStop: Bool
        lock.lock()
        hasStarted = true
        shouldStop = storedStopReason != nil && !hasFinished && !isEscalating
        lock.unlock()
        processController.didStart(process)
        if shouldStop {
            terminateAndScheduleEscalation()
        }
    }

    @_spi(Testing)
    public func markFinished() {
        lock.lock()
        hasFinished = true
        isEscalating = false
        let task = escalationTask
        escalationTask = nil
        lock.unlock()
        task?.cancel()
    }

    @_spi(Testing)
    public func requestStop(_ reason: MediaProcessStopReason) {
        let shouldStop: Bool
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        if storedStopReason == nil {
            storedStopReason = reason
        }
        shouldStop = hasStarted && !hasFinished && !isEscalating
        lock.unlock()
        if shouldStop {
            terminateAndScheduleEscalation()
        }
    }

    @_spi(Testing)
    public func finish() {
        markFinished()
    }

    private func terminateAndScheduleEscalation() {
        lock.lock()
        guard hasStarted, !hasFinished, !isEscalating else {
            lock.unlock()
            return
        }
        isEscalating = true
        let task = Task.detached { [weak self, terminationGraceNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: terminationGraceNanoseconds)
                self?.escalateIfStillRunning()
            } catch {
                // Natural completion cancels escalation.
            }
        }
        escalationTask = task
        lock.unlock()

        guard processController.isRunning(process) else {
            markFinished()
            return
        }
        processController.terminate(process)
    }

    private func escalateIfStillRunning() {
        lock.lock()
        guard hasStarted, !hasFinished, isEscalating else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Re-check this exact Process object immediately before the injected kill operation.
        guard processController.isRunning(process) else {
            markFinished()
            return
        }
        lock.lock()
        guard hasStarted, !hasFinished, isEscalating else {
            lock.unlock()
            return
        }
        lock.unlock()
        processController.kill(process)
    }
}

private struct SystemMediaProcessController: MediaProcessControlling {
    func didStart(_ process: Process) {}

    func isRunning(_ process: Process) -> Bool {
        process.isRunning
    }

    func terminate(_ process: Process) {
        process.terminate()
    }

    func kill(_ process: Process) {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
}

private final class ProcessTerminationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?
    private var resolvedStatus: Int32?

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let resolvedStatus {
                lock.unlock()
                continuation.resume(returning: resolvedStatus)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ status: Int32) {
        lock.lock()
        guard resolvedStatus == nil else {
            lock.unlock()
            return
        }
        resolvedStatus = status
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: status)
    }
}
