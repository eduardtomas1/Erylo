import Darwin
import Dispatch
import Foundation

public struct MediaScriptProcessLimits: Equatable, Sendable {
    public let maximumStandardOutputBytes: Int
    public let maximumStandardErrorBytes: Int
    public let timeoutNanoseconds: UInt64
    public let terminationGraceNanoseconds: UInt64
    public let postTerminationDrainNanoseconds: UInt64

    public init(
        maximumStandardOutputBytes: Int = 48 * 1_024,
        maximumStandardErrorBytes: Int = 16 * 1_024,
        timeoutNanoseconds: UInt64 = 30_000_000_000,
        terminationGraceNanoseconds: UInt64 = 250_000_000,
        postTerminationDrainNanoseconds: UInt64 = 250_000_000
    ) {
        self.maximumStandardOutputBytes = min(max(1, maximumStandardOutputBytes), 1_024 * 1_024)
        self.maximumStandardErrorBytes = min(max(1, maximumStandardErrorBytes), 1_024 * 1_024)
        self.timeoutNanoseconds = min(max(10_000_000, timeoutNanoseconds), 60_000_000_000)
        self.terminationGraceNanoseconds = min(max(10_000_000, terminationGraceNanoseconds), 1_000_000_000)
        self.postTerminationDrainNanoseconds = min(max(10_000_000, postTerminationDrainNanoseconds), 1_000_000_000)
    }
}

@_spi(Testing) public struct MediaScriptProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(exitCode: Int32, standardOutput: Data, standardError: Data) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

@_spi(Testing) public enum MediaScriptProcessError: Error, Equatable, Sendable {
    case duplicateOperation
    case capacityExceeded(limit: Int)
    case launchFailed
    case timedOut
    case cancelled
    case standardOutputLimitExceeded(maximumBytes: Int)
    case standardErrorLimitExceeded(maximumBytes: Int)
    case streamReadFailed
    case processLifecycleFailed(errno: Int32)
}

@_spi(Testing) public enum MediaPOSIXWaitResult: Equatable, Sendable {
    case running
    case exited(rawStatus: Int32)
    case failed(errno: Int32)
}

@_spi(Testing) public protocol MediaScriptProcessRunning: Sendable {
    func run(
        arguments: [String],
        operationID: MediaOperationID,
        limits: MediaScriptProcessLimits
    ) async throws -> MediaScriptProcessResult
    func cancel(_ operationID: MediaOperationID) async
}

@_spi(Testing) public protocol MediaPOSIXProcessSystem: Sendable {
    func spawn(
        executablePath: String,
        arguments: [String],
        standardOutput: Int32,
        standardError: Int32
    ) throws -> pid_t
    func sendSignal(_ signal: Int32, to processIdentifier: pid_t) -> Int32
    func waitNonBlocking(for processIdentifier: pid_t) -> MediaPOSIXWaitResult
}

@_spi(Testing)
public protocol MediaProcessEscalationScheduling: Sendable {
    /// Returns true only when the deadline elapsed without cancellation.
    func waitForEscalation(afterNanoseconds: UInt64) async -> Bool
}

private struct TaskMediaProcessEscalationScheduler: MediaProcessEscalationScheduling {
    func waitForEscalation(afterNanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: afterNanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

/// Raw argv access is testing SPI only. Production clients use `ProcessMediaScriptExecutor`.
@_spi(Testing) public actor FoundationMediaScriptProcessRunner: MediaScriptProcessRunning {
    private struct ActiveProcess: Sendable {
        let process: OwnedMediaProcess
        let completion: ProcessCompletionBarrier
    }

    private let executableURL: URL
    private let system: any MediaPOSIXProcessSystem
    private let maximumActiveProcesses: Int
    private let readerAccounting = MediaProcessReaderAccounting()
    private var activeProcesses: [MediaOperationID: ActiveProcess] = [:]

    init(maximumActiveProcesses: Int = 4) {
        executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        system = DarwinMediaPOSIXProcessSystem()
        self.maximumActiveProcesses = min(max(1, maximumActiveProcesses), 16)
    }

    @_spi(Testing)
    public init(executableURL: URL, maximumActiveProcesses: Int = 4) {
        self.executableURL = executableURL
        system = DarwinMediaPOSIXProcessSystem()
        self.maximumActiveProcesses = min(max(1, maximumActiveProcesses), 16)
    }

    @_spi(Testing)
    public init(
        executableURL: URL,
        system: any MediaPOSIXProcessSystem,
        maximumActiveProcesses: Int = 4
    ) {
        self.executableURL = executableURL
        self.system = system
        self.maximumActiveProcesses = min(max(1, maximumActiveProcesses), 16)
    }

    public func run(
        arguments: [String],
        operationID: MediaOperationID,
        limits: MediaScriptProcessLimits
    ) async throws -> MediaScriptProcessResult {
        guard !Task.isCancelled else { throw MediaScriptProcessError.cancelled }
        guard activeProcesses[operationID] == nil else { throw MediaScriptProcessError.duplicateOperation }
        guard activeProcesses.count < maximumActiveProcesses else {
            throw MediaScriptProcessError.capacityExceeded(limit: maximumActiveProcesses)
        }

        let outputPipe = try MediaPOSIXPipe()
        let errorPipe = try MediaPOSIXPipe()
        try outputPipe.makeReadEndNonblocking()
        try errorPipe.makeReadEndNonblocking()
        let completion = ProcessCompletionBarrier()
        let process = OwnedMediaProcess(
            system: system,
            terminationGraceNanoseconds: limits.terminationGraceNanoseconds
        )
        activeProcesses[operationID] = ActiveProcess(process: process, completion: completion)
        var timeoutTask: Task<Void, Never>?
        defer {
            timeoutTask?.cancel()
            process.finish()
            outputPipe.closeAll()
            errorPipe.closeAll()
            activeProcesses.removeValue(forKey: operationID)
            completion.resolve()
        }

        guard !Task.isCancelled else { throw MediaScriptProcessError.cancelled }
        let processIdentifier: pid_t
        do {
            processIdentifier = try system.spawn(
                executablePath: executableURL.path,
                arguments: arguments,
                standardOutput: outputPipe.writeDescriptor,
                standardError: errorPipe.writeDescriptor
            )
        } catch {
            throw MediaScriptProcessError.launchFailed
        }
        outputPipe.closeWriteEnd()
        errorPipe.closeWriteEnd()
        process.markStarted(processIdentifier)

        let drainDeadline = MediaProcessDrainDeadline()
        let accounting = readerAccounting
        let outputTask = Task.detached(priority: .utility) {
            accounting.begin()
            defer { accounting.end() }
            return try Self.drain(
                descriptor: outputPipe.readDescriptor,
                maximumBytes: limits.maximumStandardOutputBytes,
                limitError: .standardOutputLimitExceeded(maximumBytes: limits.maximumStandardOutputBytes),
                stopReason: .standardOutputLimit,
                process: process,
                deadline: drainDeadline
            )
        }
        let errorTask = Task.detached(priority: .utility) {
            accounting.begin()
            defer { accounting.end() }
            return try Self.drain(
                descriptor: errorPipe.readDescriptor,
                maximumBytes: limits.maximumStandardErrorBytes,
                limitError: .standardErrorLimitExceeded(maximumBytes: limits.maximumStandardErrorBytes),
                stopReason: .standardErrorLimit,
                process: process,
                deadline: drainDeadline
            )
        }
        let waiter = Task.detached(priority: .utility) { try await process.waitForExit() }
        timeoutTask = Task.detached {
            do {
                try await Task.sleep(nanoseconds: limits.timeoutNanoseconds)
                process.requestStop(.timedOut)
            } catch {}
        }

        let exitResult = await waiter.result
        timeoutTask?.cancel()
        drainDeadline.begin(afterNanoseconds: limits.postTerminationDrainNanoseconds)
        let outputResult = await outputTask.result
        let errorResult = await errorTask.result
        if let stopReason = process.stopReason {
            throw stopReason.error(
                outputLimit: limits.maximumStandardOutputBytes,
                errorLimit: limits.maximumStandardErrorBytes
            )
        }
        let exitCode: Int32
        switch exitResult {
        case let .success(code):
            exitCode = code
        case let .failure(error):
            throw error
        }
        return MediaScriptProcessResult(
            exitCode: exitCode,
            standardOutput: try Self.value(from: outputResult),
            standardError: try Self.value(from: errorResult)
        )
    }

    public func cancel(_ operationID: MediaOperationID) async {
        guard let active = activeProcesses[operationID] else { return }
        active.process.requestStop(.cancelled)
        await active.completion.wait()
    }

    @_spi(Testing) public var activeProcessCount: Int { activeProcesses.count }
    @_spi(Testing) public var activeReaderCount: Int { readerAccounting.count }

    private nonisolated static func value(from result: Result<Data, Error>) throws -> Data {
        switch result {
        case let .success(data): return data
        case let .failure(error): throw (error as? MediaScriptProcessError) ?? .streamReadFailed
        }
    }

    private nonisolated static func drain(
        descriptor: Int32,
        maximumBytes: Int,
        limitError: MediaScriptProcessError,
        stopReason: MediaProcessStopReason,
        process: OwnedMediaProcess,
        deadline: MediaProcessDrainDeadline
    ) throws -> Data {
        var collected = Data()
        collected.reserveCapacity(min(maximumBytes, 16 * 1_024))
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            if deadline.hasExpired { return collected }
            let byteCount = Darwin.read(descriptor, &buffer, buffer.count)
            if byteCount == 0 { return collected }
            if byteCount < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if deadline.hasExpired { return collected }
                    var state = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                    _ = Darwin.poll(&state, 1, deadline.pollTimeoutMilliseconds)
                    continue
                }
                process.requestStop(.streamReadFailure)
                throw MediaScriptProcessError.streamReadFailed
            }
            let chunk = Data(buffer[0 ..< Int(byteCount)])
            guard collected.count <= maximumBytes - chunk.count else {
                process.requestStop(stopReason)
                throw limitError
            }
            collected.append(chunk)
        }
    }
}

@_spi(Testing) public enum MediaProcessStopReason: Equatable, Sendable {
    case cancelled
    case timedOut
    case standardOutputLimit
    case standardErrorLimit
    case streamReadFailure

    func error(outputLimit: Int, errorLimit: Int) -> MediaScriptProcessError {
        switch self {
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .standardOutputLimit: .standardOutputLimitExceeded(maximumBytes: outputLimit)
        case .standardErrorLimit: .standardErrorLimitExceeded(maximumBytes: errorLimit)
        case .streamReadFailure: .streamReadFailed
        }
    }
}

/// Owns the only reap path. `waitpid` and `kill` execute under the same lock.
@_spi(Testing) public final class OwnedMediaProcess: @unchecked Sendable {
    private let system: any MediaPOSIXProcessSystem
    private let terminationGraceNanoseconds: UInt64
    private let escalationScheduler: any MediaProcessEscalationScheduling
    private let lock = NSLock()
    private var processIdentifier: pid_t?
    private var isReaped = false
    private var terminationRequested = false
    private var storedStopReason: MediaProcessStopReason?
    private var storedLifecycleError: Int32?
    private var lifecycleHardStopRequested = false
    private var escalationTask: Task<Void, Never>?

    @_spi(Testing)
    public init(system: any MediaPOSIXProcessSystem, terminationGraceNanoseconds: UInt64) {
        self.system = system
        self.terminationGraceNanoseconds = terminationGraceNanoseconds
        escalationScheduler = TaskMediaProcessEscalationScheduler()
    }

    @_spi(Testing)
    public init(
        system: any MediaPOSIXProcessSystem,
        terminationGraceNanoseconds: UInt64,
        escalationScheduler: any MediaProcessEscalationScheduling
    ) {
        self.system = system
        self.terminationGraceNanoseconds = terminationGraceNanoseconds
        self.escalationScheduler = escalationScheduler
    }

    @_spi(Testing) public var stopReason: MediaProcessStopReason? {
        lock.lock(); defer { lock.unlock() }
        return storedStopReason
    }

    @_spi(Testing) public func markStarted(_ processIdentifier: pid_t) {
        lock.lock()
        self.processIdentifier = processIdentifier
        let shouldStop = storedStopReason != nil && !terminationRequested && !isReaped
        lock.unlock()
        if shouldStop { requestTerminationAndEscalation() }
    }

    @_spi(Testing) public func requestStop(_ reason: MediaProcessStopReason) {
        lock.lock()
        guard !isReaped else { lock.unlock(); return }
        if storedStopReason == nil, storedLifecycleError == nil {
            storedStopReason = reason
        }
        let shouldStop = processIdentifier != nil && !terminationRequested
        lock.unlock()
        if shouldStop { requestTerminationAndEscalation() }
    }

    @_spi(Testing) public func waitForExit() async throws -> Int32 {
        while true {
            if let status = try pollAndReap() { return status }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @_spi(Testing) public func finish() {
        lock.lock()
        let task = escalationTask
        escalationTask = nil
        lock.unlock()
        task?.cancel()
    }

    private func requestTerminationAndEscalation() {
        lock.lock()
        guard let processIdentifier, !isReaped, !terminationRequested else {
            lock.unlock(); return
        }
        terminationRequested = true
        _ = system.sendSignal(SIGTERM, to: processIdentifier)
        let scheduler = escalationScheduler
        let task = Task.detached { [weak self, terminationGraceNanoseconds] in
            guard await scheduler.waitForEscalation(
                afterNanoseconds: terminationGraceNanoseconds
            ), !Task.isCancelled else { return }
            self?.forceStopIfOwned()
        }
        escalationTask = task
        lock.unlock()
    }

    private func forceStopIfOwned() {
        lock.lock()
        guard let processIdentifier, !isReaped else { lock.unlock(); return }
        _ = system.sendSignal(SIGKILL, to: processIdentifier)
        lock.unlock()
    }

    private func pollAndReap() throws -> Int32? {
        lock.lock()
        guard let processIdentifier, !isReaped else { lock.unlock(); return nil }
        while true {
            switch system.waitNonBlocking(for: processIdentifier) {
            case .running:
                lock.unlock()
                return nil
            case let .failed(errorNumber) where errorNumber == EINTR:
                continue
            case let .failed(errorNumber):
                // ECHILD means there is no longer an owned child to signal or reap. Any
                // other fixed-call failure is fatal; retain ownership, request a hard
                // stop, and keep attempting to reap before publishing the failure.
                if errorNumber != ECHILD {
                    if storedLifecycleError == nil, storedStopReason == nil {
                        storedLifecycleError = errorNumber
                    }
                    if !lifecycleHardStopRequested {
                        lifecycleHardStopRequested = true
                        terminationRequested = true
                        _ = system.sendSignal(SIGKILL, to: processIdentifier)
                    }
                    lock.unlock()
                    return nil
                }
                isReaped = true
                let task = escalationTask
                escalationTask = nil
                let lifecycleError = storedLifecycleError ?? errorNumber
                lock.unlock()
                task?.cancel()
                throw MediaScriptProcessError.processLifecycleFailed(errno: lifecycleError)
            case let .exited(rawStatus):
                isReaped = true
                let task = escalationTask
                escalationTask = nil
                let lifecycleError = storedLifecycleError
                lock.unlock()
                task?.cancel()
                if let lifecycleError {
                    throw MediaScriptProcessError.processLifecycleFailed(errno: lifecycleError)
                }
                return Self.decodeExitCode(rawStatus)
            }
        }
    }

    private static func decodeExitCode(_ rawStatus: Int32) -> Int32 {
        // Swift cannot import wait.h's function-like WIFEXITED/WEXITSTATUS and
        // WIFSIGNALED/WTERMSIG macros, so apply their Darwin definitions here.
        let terminationStatus = rawStatus & 0x7f
        if terminationStatus == 0 {
            return (rawStatus >> 8) & 0xff
        }
        if terminationStatus != 0x7f {
            return 128 + terminationStatus
        }
        return 128 + SIGSTOP
    }
}

private struct DarwinMediaPOSIXProcessSystem: MediaPOSIXProcessSystem {
    func spawn(
        executablePath: String,
        arguments: [String],
        standardOutput: Int32,
        standardError: Int32
    ) throws -> pid_t {
        let storage = ([executablePath] + arguments).map { strdup($0) }
        guard storage.allSatisfy({ $0 != nil }) else {
            for pointer in storage { free(pointer) }
            throw MediaScriptProcessError.launchFailed
        }
        defer { for pointer in storage { free(pointer) } }
        let environmentStorage = ProcessInfo.processInfo.environment.map {
            strdup("\($0.key)=\($0.value)")
        }
        guard environmentStorage.allSatisfy({ $0 != nil }) else {
            for pointer in environmentStorage { free(pointer) }
            throw MediaScriptProcessError.launchFailed
        }
        defer { for pointer in environmentStorage { free(pointer) } }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw MediaScriptProcessError.launchFailed
        }
        guard posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        ) == 0 else {
            _ = posix_spawnattr_destroy(&attributes)
            throw MediaScriptProcessError.launchFailed
        }

        // Darwin's close-on-exec default makes the file actions below the
        // complete descriptor allowlist for the child. In particular, host
        // files, sockets, and locks that forgot FD_CLOEXEC cannot cross this
        // process boundary.
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            _ = posix_spawnattr_destroy(&attributes)
            throw MediaScriptProcessError.launchFailed
        }
        guard posix_spawn_file_actions_adddup2(
            &actions,
            standardOutput,
            STDOUT_FILENO
        ) == 0,
        posix_spawn_file_actions_adddup2(
            &actions,
            standardError,
            STDERR_FILENO
        ) == 0,
        posix_spawn_file_actions_addclose(&actions, standardOutput) == 0,
        posix_spawn_file_actions_addclose(&actions, standardError) == 0 else {
            _ = posix_spawn_file_actions_destroy(&actions)
            _ = posix_spawnattr_destroy(&attributes)
            throw MediaScriptProcessError.launchFailed
        }

        var argv = storage + [nil]
        var environment = environmentStorage + [nil]
        var processIdentifier: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { buffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processIdentifier,
                    executablePath,
                    &actions,
                    &attributes,
                    buffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
        let actionsDestroyResult = posix_spawn_file_actions_destroy(&actions)
        let attributesDestroyResult = posix_spawnattr_destroy(&attributes)
        guard result == 0 else { throw MediaScriptProcessError.launchFailed }
        guard actionsDestroyResult == 0, attributesDestroyResult == 0 else {
            Self.hardStopAndReap(processIdentifier)
            throw MediaScriptProcessError.launchFailed
        }
        return processIdentifier
    }

    private static func hardStopAndReap(_ processIdentifier: pid_t) {
        _ = Darwin.kill(processIdentifier, SIGKILL)
        var status: Int32 = 0
        while Darwin.waitpid(processIdentifier, &status, 0) < 0 {
            if errno != EINTR { return }
        }
    }

    func sendSignal(_ signal: Int32, to processIdentifier: pid_t) -> Int32 {
        Darwin.kill(processIdentifier, signal)
    }

    func waitNonBlocking(for processIdentifier: pid_t) -> MediaPOSIXWaitResult {
        var status: Int32 = 0
        let result = Darwin.waitpid(processIdentifier, &status, WNOHANG)
        if result == processIdentifier { return .exited(rawStatus: status) }
        if result == 0 { return .running }
        return .failed(errno: errno)
    }
}

private final class MediaPOSIXPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var readStorage: Int32
    private var writeStorage: Int32

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else { throw MediaScriptProcessError.launchFailed }
        var ownedRead = descriptors[0]
        var ownedWrite = descriptors[1]
        guard Self.normalize(&ownedRead), Self.normalize(&ownedWrite) else {
            if ownedRead >= 0 { _ = Darwin.close(ownedRead) }
            if ownedWrite >= 0 { _ = Darwin.close(ownedWrite) }
            throw MediaScriptProcessError.launchFailed
        }
        readStorage = ownedRead
        writeStorage = ownedWrite
    }

    deinit { closeAll() }

    var readDescriptor: Int32 { lock.withLock { readStorage } }
    var writeDescriptor: Int32 { lock.withLock { writeStorage } }

    func makeReadEndNonblocking() throws {
        let descriptor = readDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw MediaScriptProcessError.streamReadFailed
        }
    }

    func closeWriteEnd() { close(&writeStorage) }
    func closeAll() { close(&readStorage); close(&writeStorage) }

    private static func normalize(_ descriptor: inout Int32) -> Bool {
        if descriptor <= STDERR_FILENO {
            let duplicated = fcntl(
                descriptor,
                F_DUPFD_CLOEXEC,
                STDERR_FILENO + 1
            )
            guard duplicated >= STDERR_FILENO + 1 else { return false }
            _ = Darwin.close(descriptor)
            descriptor = duplicated
            return true
        }

        let flags = fcntl(descriptor, F_GETFD)
        return flags >= 0
            && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) >= 0
    }

    private func close(_ storage: inout Int32) {
        lock.lock()
        let descriptor = storage
        storage = -1
        lock.unlock()
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }
}

private final class ProcessCompletionBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isComplete { lock.unlock(); continuation.resume() }
            else { continuations.append(continuation); lock.unlock() }
        }
    }

    func resolve() {
        lock.lock()
        guard !isComplete else { lock.unlock(); return }
        isComplete = true
        let current = continuations
        continuations.removeAll(keepingCapacity: false)
        lock.unlock()
        for continuation in current { continuation.resume() }
    }
}

private final class MediaProcessDrainDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var expirationNanoseconds: UInt64?
    var hasExpired: Bool {
        lock.withLock {
            guard let expirationNanoseconds else { return false }
            return DispatchTime.now().uptimeNanoseconds >= expirationNanoseconds
        }
    }
    var pollTimeoutMilliseconds: Int32 {
        lock.withLock {
            guard let expirationNanoseconds else { return 50 }
            let now = DispatchTime.now().uptimeNanoseconds
            guard expirationNanoseconds > now else { return 0 }
            return Int32(min(max(1, (expirationNanoseconds - now) / 1_000_000), 50))
        }
    }
    func begin(afterNanoseconds duration: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock { expirationNanoseconds = now > UInt64.max - duration ? UInt64.max : now + duration }
    }
}

private final class MediaProcessReaderAccounting: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0
    var count: Int { lock.withLock { storedCount } }
    func begin() { lock.withLock { storedCount += 1 } }
    func end() { lock.withLock { storedCount -= 1 } }
}
