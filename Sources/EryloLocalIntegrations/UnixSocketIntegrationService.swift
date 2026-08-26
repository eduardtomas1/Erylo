import Darwin
import Foundation

public protocol UnixSocketPeerValidating: Sendable {
    func allows(socketDescriptor: Int32, expectedEffectiveUserID: uid_t) -> Bool
}

public struct EffectiveUserPeerValidator: UnixSocketPeerValidating {
    public init() {}

    public func allows(socketDescriptor: Int32, expectedEffectiveUserID: uid_t) -> Bool {
        var peerUserID: uid_t = 0
        var peerGroupID: gid_t = 0
        guard getpeereid(socketDescriptor, &peerUserID, &peerGroupID) == 0 else { return false }
        return peerUserID == expectedEffectiveUserID
    }
}

public struct UnixSocketIntegrationConfiguration: Equatable, Sendable {
    public var enabled: Bool
    public var directoryURL: URL
    public var maximumConcurrentClients: Int
    public var maximumRequestsPerConnection: Int
    public var clientIOTimeoutMilliseconds: Int
    public var clientSocketBufferBytes: Int

    public init(
        enabled: Bool = false,
        directoryURL: URL = Self.defaultDirectoryURL,
        maximumConcurrentClients: Int = 8,
        maximumRequestsPerConnection: Int = 16,
        clientIOTimeoutMilliseconds: Int = 2_000,
        clientSocketBufferBytes: Int = 64 * 1_024
    ) {
        self.enabled = enabled
        self.directoryURL = directoryURL
        self.maximumConcurrentClients = maximumConcurrentClients
        self.maximumRequestsPerConnection = maximumRequestsPerConnection
        self.clientIOTimeoutMilliseconds = clientIOTimeoutMilliseconds
        self.clientSocketBufferBytes = clientSocketBufferBytes
    }

    public static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Erylo-Integration", isDirectory: true)
    }
}

public enum UnixSocketIntegrationStartResult: Equatable, Sendable {
    case disabled
    case started(URL)
    case alreadyRunning(URL)
}

public struct UnixSocketIntegrationWorkState: Equatable, Sendable {
    public let listenerActive: Bool
    public let activeClientCount: Int
    public let socketURL: URL?
    public let lastAcceptError: Int32?

    public init(
        listenerActive: Bool,
        activeClientCount: Int,
        socketURL: URL?,
        lastAcceptError: Int32?
    ) {
        self.listenerActive = listenerActive
        self.activeClientCount = activeClientCount
        self.socketURL = socketURL
        self.lastAcceptError = lastAcceptError
    }
}

public enum UnixSocketIntegrationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidConfiguration
    case unsafeDirectory
    case socketPathTooLong
    case serviceAlreadyActive
    case anotherServiceIsRunning
    case systemCall(String, Int32)

    public var description: String {
        switch self {
        case .invalidConfiguration:
            "invalid Unix socket configuration"
        case .unsafeDirectory:
            "Unix socket directory failed ownership, permission, symlink, or identity validation"
        case .socketPathTooLong:
            "Unix socket path exceeds the platform limit"
        case .serviceAlreadyActive:
            "Unix socket service is already active"
        case .anotherServiceIsRunning:
            "another Erylo Unix socket service owns the directory"
        case let .systemCall(name, code):
            "\(name) failed with errno \(code)"
        }
    }
}

@_spi(Testing)
public enum UnixSocketIntegrationTestingPublicationStage: Sendable {
    case beforeBind
    case boundBeforeIdentity
    case identityCaptured
    case permissionApplied
    case beforePublication
    case publishedBeforeIdentity
}

@_spi(Testing)
public enum UnixSocketIntegrationTestingWakeWriteResult: Equatable, Sendable {
    case written
    case interrupted
    case wouldBlock
    case zero
    case failed
}

@_spi(Testing)
public struct UnixSocketIntegrationTestingHooks: @unchecked Sendable {
    public var afterDirectoryPrepared: (@Sendable (URL) -> Void)?
    public var duringSocketPublication: (@Sendable (
        UnixSocketIntegrationTestingPublicationStage,
        URL,
        URL
    ) -> Void)?
    public var beforeStaleSocketCleanup: (@Sendable (URL) -> Void)?
    public var beforeSocketCleanup: (@Sendable (URL) -> Void)?
    public var nextWakeWriteResult: (@Sendable () -> UnixSocketIntegrationTestingWakeWriteResult)?

    public init(
        afterDirectoryPrepared: (@Sendable (URL) -> Void)? = nil,
        duringSocketPublication: (@Sendable (
            UnixSocketIntegrationTestingPublicationStage,
            URL,
            URL
        ) -> Void)? = nil,
        beforeStaleSocketCleanup: (@Sendable (URL) -> Void)? = nil,
        beforeSocketCleanup: (@Sendable (URL) -> Void)? = nil,
        nextWakeWriteResult: (@Sendable () -> UnixSocketIntegrationTestingWakeWriteResult)? = nil
    ) {
        self.afterDirectoryPrepared = afterDirectoryPrepared
        self.duringSocketPublication = duringSocketPublication
        self.beforeStaleSocketCleanup = beforeStaleSocketCleanup
        self.beforeSocketCleanup = beforeSocketCleanup
        self.nextWakeWriteResult = nextWakeWriteResult
    }
}

@_spi(Testing)
public struct UnixSocketIntegrationTestingConnection: Equatable, Sendable {
    public let token: UUID
    public let descriptor: Int32

    public init(token: UUID, descriptor: Int32) {
        self.token = token
        self.descriptor = descriptor
    }
}

private final class DispatchResponseAwaitable: @unchecked Sendable {
    private let lock = NSLock()
    private var resolvedResponse: ActivityIntegrationResponse?
    private var continuation: CheckedContinuation<ActivityIntegrationResponse, Never>?

    func response() async -> ActivityIntegrationResponse {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let resolvedResponse {
                lock.unlock()
                continuation.resume(returning: resolvedResponse)
            } else {
                precondition(self.continuation == nil)
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ response: ActivityIntegrationResponse) {
        lock.lock()
        guard resolvedResponse == nil else {
            lock.unlock()
            return
        }
        resolvedResponse = response
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: response)
    }
}

public actor UnixSocketActivityIntegrationService {
    public static let socketFileName = "activity-v1.sock"

    private enum Lifecycle {
        case stopped
        case running
        case stopping
    }

    private enum Admission {
        case accepted
        case rejected(ActivityIntegrationResponse)
    }

    private struct ConnectionRecord {
        let descriptor: OwnedSocketDescriptor
        let task: Task<Void, Never>
    }

    private struct DispatchRecord {
        let connectionToken: UUID
        let generation: UInt64
        let lease: ActivityIntegrationLease
        let task: Task<Void, Never>
        let responseAwaitable: DispatchResponseAwaitable
    }

    private final class Runtime: @unchecked Sendable {
        weak var service: UnixSocketActivityIntegrationService?
        let listener: OwnedSocketDescriptor
        let cancellation: AcceptCancellation
        let generation: UInt64
        let timeoutMilliseconds: Int

        init(
            service: UnixSocketActivityIntegrationService,
            listener: OwnedSocketDescriptor,
            cancellation: AcceptCancellation,
            generation: UInt64,
            timeoutMilliseconds: Int
        ) {
            self.service = service
            self.listener = listener
            self.cancellation = cancellation
            self.generation = generation
            self.timeoutMilliseconds = timeoutMilliseconds
        }
    }

    private let handler: any ActivityIntegrationHandling
    private let configuration: UnixSocketIntegrationConfiguration
    private let peerValidator: any UnixSocketPeerValidating
    private let testingHooks: UnixSocketIntegrationTestingHooks
    private var lifecycle = Lifecycle.stopped
    private var generation: UInt64 = 0
    private var listener: OwnedSocketDescriptor?
    private var acceptCancellation: AcceptCancellation?
    private var directoryDescriptor: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private var socketURL: URL?
    private var socketIdentity: FileIdentity?
    private var activeConnections: [UUID: ConnectionRecord] = [:]
    private var closingConnectionTokens: Set<UUID> = []
    private var dispatches: [UUID: DispatchRecord] = [:]
    private var acceptLoopActive = false
    private var drainContinuation: CheckedContinuation<Void, Never>?
    private var stoppedContinuations: [CheckedContinuation<Void, Never>] = []
    private var lastAcceptError: Int32?

    public init(
        handler: any ActivityIntegrationHandling,
        configuration: UnixSocketIntegrationConfiguration = UnixSocketIntegrationConfiguration(),
        peerValidator: any UnixSocketPeerValidating = EffectiveUserPeerValidator()
    ) {
        self.handler = handler
        self.configuration = configuration
        self.peerValidator = peerValidator
        testingHooks = UnixSocketIntegrationTestingHooks()
    }

    @_spi(Testing)
    public init(
        handler: any ActivityIntegrationHandling,
        configuration: UnixSocketIntegrationConfiguration,
        peerValidator: any UnixSocketPeerValidating = EffectiveUserPeerValidator(),
        testingHooks: UnixSocketIntegrationTestingHooks
    ) {
        self.handler = handler
        self.configuration = configuration
        self.peerValidator = peerValidator
        self.testingHooks = testingHooks
    }

    deinit {
        acceptCancellation?.signal(errorCode: nil)
        for record in dispatches.values {
            record.lease.invalidateNow()
            record.task.cancel()
            record.responseAwaitable.resolve(
                .failure(code: .cancelled, message: "service stopped")
            )
        }
        for record in activeConnections.values {
            record.task.cancel()
            record.descriptor.shutdownOnly()
        }
        if directoryDescriptor >= 0, let socketIdentity {
            if let socketURL { testingHooks.beforeSocketCleanup?(socketURL) }
            _ = SecureSocketDirectory.quarantineAndRemoveIfIdentical(
                directoryDescriptor: directoryDescriptor,
                socketFileName: Self.socketFileName,
                identity: socketIdentity
            )
        }
        if lockDescriptor >= 0 {
            _ = flock(lockDescriptor, LOCK_UN)
            _ = Darwin.close(lockDescriptor)
        }
        if directoryDescriptor >= 0 { _ = Darwin.close(directoryDescriptor) }
    }

    public func start() throws -> UnixSocketIntegrationStartResult {
        guard configuration.enabled else { return .disabled }
        guard configuration.maximumConcurrentClients > 0,
              configuration.maximumConcurrentClients <= 64,
              configuration.maximumRequestsPerConnection > 0,
              configuration.maximumRequestsPerConnection <= 256,
              (50...30_000).contains(configuration.clientIOTimeoutMilliseconds),
              (4_096...ActivityIntegrationAPI.maximumResponseBodyBytes).contains(
                configuration.clientSocketBufferBytes
              ) else {
            throw UnixSocketIntegrationError.invalidConfiguration
        }
        switch lifecycle {
        case .running:
            guard let socketURL else { throw UnixSocketIntegrationError.serviceAlreadyActive }
            return .alreadyRunning(socketURL)
        case .stopping:
            throw UnixSocketIntegrationError.serviceAlreadyActive
        case .stopped:
            break
        }

        let prepared = try SecureSocketDirectory.prepare(
            directoryURL: configuration.directoryURL,
            socketFileName: Self.socketFileName,
            beforeStaleSocketCleanup: testingHooks.beforeStaleSocketCleanup
        )
        do {
            testingHooks.afterDirectoryPrepared?(prepared.socketURL)
            try prepared.revalidate()
            // Build the owned wake channel before bind. If pipe/fcntl setup
            // fails, no filesystem socket identity exists to clean up.
            let cancellation = try AcceptCancellation(
                testingWriteResult: testingHooks.nextWakeWriteResult
            )
            let bound = try Self.makeListener(
                in: prepared,
                backlog: configuration.maximumConcurrentClients,
                testingHooks: testingHooks
            )
            directoryDescriptor = prepared.directoryDescriptor
            lockDescriptor = prepared.lockDescriptor
            listener = bound.descriptor
            acceptCancellation = cancellation
            socketURL = prepared.socketURL
            socketIdentity = bound.socketIdentity
            lifecycle = .running
            lastAcceptError = nil
            generation &+= 1
            acceptLoopActive = true

            let runtime = Runtime(
                service: self,
                listener: bound.descriptor,
                cancellation: cancellation,
                generation: generation,
                timeoutMilliseconds: configuration.clientIOTimeoutMilliseconds
            )
            Task.detached { await Self.runAcceptLoop(runtime: runtime) }
            return .started(prepared.socketURL)
        } catch {
            prepared.close()
            throw error
        }
    }

    public func stop() async {
        switch lifecycle {
        case .stopped:
            return
        case .stopping:
            await withCheckedContinuation { stoppedContinuations.append($0) }
            return
        case .running:
            lifecycle = .stopping
        }

        acceptCancellation?.signal(errorCode: nil)
        for record in activeConnections.values {
            record.task.cancel()
            record.descriptor.shutdownOnly()
        }
        await cancelDispatches()
        await waitForDrain()
        finishStop()
    }

    public func workState() -> UnixSocketIntegrationWorkState {
        UnixSocketIntegrationWorkState(
            listenerActive: lifecycle == .running && listener?.isOpen == true,
            activeClientCount: activeConnections.count + closingConnectionTokens.count,
            socketURL: socketURL,
            lastAcceptError: lastAcceptError
        )
    }

    @_spi(Testing)
    public func forceUnexpectedAcceptFailure() {
        guard lifecycle == .running else { return }
        acceptCancellation?.signal(errorCode: EIO)
    }

    @_spi(Testing)
    public func testingConnections() -> [UnixSocketIntegrationTestingConnection] {
        activeConnections.compactMap { token, record in
            record.descriptor.rawDescriptor.map {
                UnixSocketIntegrationTestingConnection(token: token, descriptor: $0)
            }
        }.sorted { $0.token.uuidString < $1.token.uuidString }
    }

    @_spi(Testing)
    public func simulateStaleCompletion(token: UUID) {
        guard activeConnections[token] != nil else { return }
        activeConnections.removeValue(forKey: token)
    }

    @_spi(Testing)
    public func testingDispatchCount() -> Int {
        dispatches.count
    }

    private func admit(_ descriptor: OwnedSocketDescriptor, runtime: Runtime) -> Admission {
        guard lifecycle == .running, runtime.generation == generation else {
            return .rejected(.failure(code: .cancelled, message: "service is stopping"))
        }
        guard let rawDescriptor = descriptor.rawDescriptor,
              peerValidator.allows(
                socketDescriptor: rawDescriptor,
                expectedEffectiveUserID: geteuid()
              ) else {
            return .rejected(
                .failure(code: .peerRejected, message: "peer effective user ID was rejected")
            )
        }
        guard activeConnections.count < configuration.maximumConcurrentClients else {
            return .rejected(
                .failure(code: .serverBusy, message: "concurrent client capacity reached")
            )
        }

        let token = UUID()
        let maximumRequests = configuration.maximumRequestsPerConnection
        let task = Task.detached {
            await Self.handleConnection(
                descriptor,
                token: token,
                runtime: runtime,
                maximumRequests: maximumRequests
            )
        }
        activeConnections[token] = ConnectionRecord(descriptor: descriptor, task: task)
        return .accepted
    }

    private func beginDispatch(
        _ request: ActivityIntegrationRequest,
        connectionToken: UUID,
        runtime: Runtime
    ) -> DispatchResponseAwaitable {
        let responseAwaitable = DispatchResponseAwaitable()
        guard lifecycle == .running,
              runtime.generation == generation,
              activeConnections[connectionToken] != nil else {
            responseAwaitable.resolve(
                .failure(code: .cancelled, message: "service stopped")
            )
            return responseAwaitable
        }
        let dispatchIdentifier = UUID()
        let lease = ActivityIntegrationLease()
        let handler = self.handler
        let task = Task.detached {
            let response = await handler.handle(request, lease: lease)
            if let service = runtime.service {
                await service.finishDispatch(
                    dispatchIdentifier,
                    response: response
                )
            }
        }
        dispatches[dispatchIdentifier] = DispatchRecord(
            connectionToken: connectionToken,
            generation: runtime.generation,
            lease: lease,
            task: task,
            responseAwaitable: responseAwaitable
        )
        return responseAwaitable
    }

    private func finishDispatch(
        _ identifier: UUID,
        response: ActivityIntegrationResponse
    ) async {
        guard let record = dispatches.removeValue(forKey: identifier) else { return }
        await record.lease.invalidateAndWait()
        let isCurrent = lifecycle == .running
            && record.generation == generation
            && activeConnections[record.connectionToken] != nil
        record.responseAwaitable.resolve(
            isCurrent
                ? response
                : .failure(code: .cancelled, message: "service stopped")
        )
    }

    private func cancelDispatches() async {
        let records = Array(dispatches.values)
        dispatches.removeAll()
        for record in records {
            record.lease.invalidateNow()
            record.task.cancel()
            record.responseAwaitable.resolve(
                .failure(code: .cancelled, message: "service stopped")
            )
        }
        for record in records { await record.lease.invalidateAndWait() }
    }

    private func connectionFinishing(token: UUID, generation: UInt64) {
        guard generation == self.generation,
              activeConnections.removeValue(forKey: token) != nil else { return }
        closingConnectionTokens.insert(token)
    }

    private func connectionClosed(token: UUID, generation: UInt64) {
        guard generation == self.generation else { return }
        closingConnectionTokens.remove(token)
        resumeDrainIfReady()
    }

    private func acceptLoopFinished(generation: UInt64, errorCode: Int32?) async {
        guard generation == self.generation else { return }
        acceptLoopActive = false
        listener = nil
        acceptCancellation = nil
        if lifecycle == .running, let errorCode {
            lastAcceptError = errorCode
            lifecycle = .stopping
            for record in activeConnections.values {
                record.task.cancel()
                record.descriptor.shutdownOnly()
            }
            await cancelDispatches()
            await waitForDrain()
            finishStop()
        } else {
            resumeDrainIfReady()
        }
    }

    private func waitForDrain() async {
        guard acceptLoopActive || !activeConnections.isEmpty || !closingConnectionTokens.isEmpty else {
            return
        }
        await withCheckedContinuation { drainContinuation = $0 }
    }

    private func resumeDrainIfReady() {
        guard !acceptLoopActive,
              activeConnections.isEmpty,
              closingConnectionTokens.isEmpty,
              let continuation = drainContinuation else { return }
        drainContinuation = nil
        continuation.resume()
    }

    private func finishStop() {
        cleanupSocketResources()
        lifecycle = .stopped
        let continuations = stoppedContinuations
        stoppedContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func cleanupSocketResources() {
        if directoryDescriptor >= 0, let socketIdentity {
            if let socketURL { testingHooks.beforeSocketCleanup?(socketURL) }
            _ = SecureSocketDirectory.quarantineAndRemoveIfIdentical(
                directoryDescriptor: directoryDescriptor,
                socketFileName: Self.socketFileName,
                identity: socketIdentity
            )
        }
        socketIdentity = nil
        acceptCancellation = nil
        if lockDescriptor >= 0 {
            _ = flock(lockDescriptor, LOCK_UN)
            _ = Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
        if directoryDescriptor >= 0 {
            _ = Darwin.close(directoryDescriptor)
            directoryDescriptor = -1
        }
        socketURL = nil
    }

    private nonisolated static func runAcceptLoop(runtime: Runtime) async {
        var terminalError: Int32?
        acceptLoop: while let listenerDescriptor = runtime.listener.rawDescriptor,
                          let cancellationDescriptor = runtime.cancellation.readDescriptor {
            var pollDescriptors = [
                pollfd(fd: listenerDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: cancellationDescriptor, events: Int16(POLLIN), revents: 0),
            ]
            let pollResult = Darwin.poll(&pollDescriptors, 2, -1)
            if pollResult < 0 {
                if errno == EINTR { continue }
                terminalError = errno
                break
            }
            if pollDescriptors[1].revents != 0 {
                terminalError = runtime.cancellation.errorCode
                break
            }
            guard pollDescriptors[0].revents != 0 else { continue }

            while true {
                if runtime.cancellation.isCancellationRequested {
                    terminalError = runtime.cancellation.errorCode
                    break acceptLoop
                }
                let accepted = Darwin.accept(listenerDescriptor, nil, nil)
                if accepted < 0 {
                    if errno == EINTR { continue }
                    if errno == ECONNABORTED { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    terminalError = errno
                    break acceptLoop
                }
                let descriptor = OwnedSocketDescriptor(accepted)
                do {
                    try configureClientSocket(
                        accepted,
                        bufferBytes: runtime.service?.configuration.clientSocketBufferBytes ?? 64 * 1_024
                    )
                    guard let service = runtime.service else {
                        descriptor.closeByOwner()
                        break acceptLoop
                    }
                    switch await service.admit(descriptor, runtime: runtime) {
                    case .accepted:
                        break
                    case let .rejected(response):
                        _ = writeImmediateResponse(response, to: descriptor)
                        descriptor.closeByOwner()
                    }
                } catch {
                    descriptor.closeByOwner()
                }
            }
        }
        runtime.listener.closeByOwner()
        runtime.cancellation.closeByOwner()
        if let service = runtime.service {
            await service.acceptLoopFinished(generation: runtime.generation, errorCode: terminalError)
        }
    }

    private nonisolated static func handleConnection(
        _ descriptor: OwnedSocketDescriptor,
        token: UUID,
        runtime: Runtime,
        maximumRequests: Int
    ) async {
        guard let rawDescriptor = descriptor.rawDescriptor else { return }
        var decoder = LengthPrefixedFrameDecoder()
        var requestCount = 0
        var frameDeadline = MonotonicDeadline(milliseconds: runtime.timeoutMilliseconds)
        var bytes = [UInt8](repeating: 0, count: 4_096)

        connectionLoop: while !Task.isCancelled {
            switch waitForEvent(
                descriptor: rawDescriptor,
                events: Int16(POLLIN),
                deadline: frameDeadline
            ) {
            case .timedOut:
                let message = decoder.hasPartialFrame ? "partial frame timed out" : "request timed out"
                _ = writeResponse(
                    .failure(code: .requestTimeout, message: message),
                    to: rawDescriptor,
                    timeoutMilliseconds: runtime.timeoutMilliseconds
                )
                break connectionLoop
            case .failed:
                break connectionLoop
            case .ready:
                break
            }

            let received = bytes.withUnsafeMutableBytes { storage in
                Darwin.recv(rawDescriptor, storage.baseAddress, storage.count, 0)
            }
            if received == 0 {
                do {
                    try decoder.finish()
                } catch LengthPrefixedFrameError.truncatedFrame {
                    _ = writeResponse(
                        .failure(code: .invalidRequest, message: "truncated length-prefixed frame"),
                        to: rawDescriptor,
                        timeoutMilliseconds: runtime.timeoutMilliseconds
                    )
                } catch {
                    _ = writeResponse(
                        .failure(code: .invalidRequest, message: "invalid length-prefixed frame"),
                        to: rawDescriptor,
                        timeoutMilliseconds: runtime.timeoutMilliseconds
                    )
                }
                break
            }
            if received < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                break
            }

            do {
                let frames = try decoder.append(Data(bytes.prefix(received)))
                for frame in frames {
                    requestCount += 1
                    guard requestCount <= maximumRequests else {
                        _ = writeResponse(
                            .failure(
                                code: .requestLimitExceeded,
                                message: "per-connection request limit reached"
                            ),
                            to: rawDescriptor,
                            timeoutMilliseconds: runtime.timeoutMilliseconds
                        )
                        break connectionLoop
                    }
                    guard !Task.isCancelled else {
                        break connectionLoop
                    }
                    let response: ActivityIntegrationResponse
                    do {
                        let request = try ActivityIntegrationCodec.decodeRequest(frame)
                        guard let responseAwaitable = await runtime.service?.beginDispatch(
                            request,
                            connectionToken: token,
                            runtime: runtime
                        ) else {
                            break connectionLoop
                        }
                        // Await independently of the service actor. Its deinit
                        // can now resolve cancellation without a suspended
                        // actor instance method retaining `self`.
                        response = await responseAwaitable.response()
                    } catch {
                        response = ActivityIntegrationCodec.response(for: error)
                    }
                    guard !Task.isCancelled,
                          runtime.service != nil,
                          writeResponse(
                            response,
                            to: rawDescriptor,
                            timeoutMilliseconds: runtime.timeoutMilliseconds
                          ) else {
                        break connectionLoop
                    }
                    frameDeadline = MonotonicDeadline(milliseconds: runtime.timeoutMilliseconds)
                }
            } catch let error as LengthPrefixedFrameError {
                let code: ActivityIntegrationErrorCode
                if case .frameTooLarge = error { code = .frameTooLarge } else { code = .invalidRequest }
                _ = writeResponse(
                    .failure(code: code, message: "invalid length-prefixed frame"),
                    to: rawDescriptor,
                    timeoutMilliseconds: runtime.timeoutMilliseconds
                )
                break
            } catch {
                break
            }
        }

        if let service = runtime.service {
            await service.connectionFinishing(token: token, generation: runtime.generation)
        }
        descriptor.closeByOwner()
        if let service = runtime.service {
            await service.connectionClosed(token: token, generation: runtime.generation)
        }
    }

    @discardableResult
    private nonisolated static func writeImmediateResponse(
        _ response: ActivityIntegrationResponse,
        to descriptor: OwnedSocketDescriptor
    ) -> Bool {
        guard let rawDescriptor = descriptor.rawDescriptor,
              let frame = try? LengthPrefixedFrameDecoder.encode(
                ActivityIntegrationCodec.encodeResponse(response),
                maximumBodyBytes: ActivityIntegrationAPI.maximumResponseBodyBytes
              ) else { return false }
        return frame.withUnsafeBytes { storage in
            guard let baseAddress = storage.baseAddress else { return false }
            return Darwin.send(rawDescriptor, baseAddress, storage.count, 0) == storage.count
        }
    }

    @discardableResult
    private nonisolated static func writeResponse(
        _ response: ActivityIntegrationResponse,
        to descriptor: Int32,
        timeoutMilliseconds: Int
    ) -> Bool {
        let body = ActivityIntegrationCodec.encodeResponse(response)
        guard let frame = try? LengthPrefixedFrameDecoder.encode(
            body,
            maximumBodyBytes: ActivityIntegrationAPI.maximumResponseBodyBytes
        ) else { return false }
        let deadline = MonotonicDeadline(milliseconds: timeoutMilliseconds)
        return frame.withUnsafeBytes { storage in
            guard let baseAddress = storage.baseAddress else { return false }
            var sent = 0
            while sent < storage.count {
                switch waitForEvent(
                    descriptor: descriptor,
                    events: Int16(POLLOUT),
                    deadline: deadline
                ) {
                case .ready:
                    break
                case .timedOut, .failed:
                    return false
                }
                let result = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: sent),
                    storage.count - sent,
                    0
                )
                if result < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    return false
                }
                if result == 0 { return false }
                sent += result
            }
            return true
        }
    }

    private nonisolated static func makeListener(
        in prepared: SecureSocketDirectory,
        backlog: Int,
        testingHooks: UnixSocketIntegrationTestingHooks
    ) throws -> (descriptor: OwnedSocketDescriptor, socketIdentity: FileIdentity) {
        let rawDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard rawDescriptor >= 0 else {
            throw UnixSocketIntegrationError.systemCall("socket", errno)
        }
        let stagingFileName = SecureSocketDirectory.makeStagingFileName()
        let stagingURL = prepared.directoryURL.appendingPathComponent(stagingFileName)
        var boundIdentity: FileIdentity?
        var wasPublished = false
        do {
            try configureBaseSocket(rawDescriptor)
            try prepared.revalidate()
            try prepared.requireAbsent(fileName: stagingFileName)
            testingHooks.duringSocketPublication?(
                .beforeBind,
                stagingURL,
                prepared.socketURL
            )
            var address = try unixAddress(for: stagingURL.path)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(rawDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                throw UnixSocketIntegrationError.systemCall("bind", errno)
            }
            testingHooks.duringSocketPublication?(
                .boundBeforeIdentity,
                stagingURL,
                prepared.socketURL
            )
            // The unique staging name is not public. Record its raw pathname
            // identity before ACL policy validation so even an unsafe bound
            // vnode can be quarantined and compared without a blind unlink.
            boundIdentity = try prepared.captureSocketPathIdentity(
                fileName: stagingFileName,
                absoluteURL: stagingURL
            )
            guard let boundIdentity else { throw UnixSocketIntegrationError.unsafeDirectory }
            guard try prepared.captureSocketIdentity(
                fileName: stagingFileName,
                absoluteURL: stagingURL
            ) == boundIdentity else {
                throw UnixSocketIntegrationError.unsafeDirectory
            }
            testingHooks.duringSocketPublication?(
                .identityCaptured,
                stagingURL,
                prepared.socketURL
            )
            // Operate relative to the validated directory descriptor and
            // never follow a replacement symlink.
            guard fchmodat(
                prepared.directoryDescriptor,
                stagingFileName,
                S_IRUSR | S_IWUSR,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw UnixSocketIntegrationError.systemCall("fchmodat", errno)
            }
            try prepared.revalidate()
            let verifiedIdentity = try prepared.captureSocketIdentity(
                fileName: stagingFileName,
                absoluteURL: stagingURL,
                requireMode: 0o600
            )
            guard verifiedIdentity == boundIdentity else {
                throw UnixSocketIntegrationError.unsafeDirectory
            }
            testingHooks.duringSocketPublication?(
                .permissionApplied,
                stagingURL,
                prepared.socketURL
            )
            guard Darwin.listen(rawDescriptor, Int32(backlog)) == 0 else {
                throw UnixSocketIntegrationError.systemCall("listen", errno)
            }
            let statusFlags = fcntl(rawDescriptor, F_GETFL)
            guard statusFlags >= 0,
                  fcntl(rawDescriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
                throw UnixSocketIntegrationError.systemCall("fcntl", errno)
            }
            testingHooks.duringSocketPublication?(
                .beforePublication,
                stagingURL,
                prepared.socketURL
            )
            try prepared.revalidate()
            guard renameatx_np(
                prepared.directoryDescriptor,
                stagingFileName,
                prepared.directoryDescriptor,
                UnixSocketActivityIntegrationService.socketFileName,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw UnixSocketIntegrationError.unsafeDirectory
            }
            wasPublished = true
            testingHooks.duringSocketPublication?(
                .publishedBeforeIdentity,
                stagingURL,
                prepared.socketURL
            )
            try prepared.revalidate()
            let publishedIdentity = try prepared.captureSocketIdentity(
                fileName: UnixSocketActivityIntegrationService.socketFileName,
                absoluteURL: prepared.socketURL,
                requireMode: 0o600
            )
            guard publishedIdentity == boundIdentity else {
                throw UnixSocketIntegrationError.unsafeDirectory
            }
            return (OwnedSocketDescriptor(rawDescriptor), publishedIdentity)
        } catch {
            _ = Darwin.close(rawDescriptor)
            if let boundIdentity {
                _ = SecureSocketDirectory.quarantineAndRemoveIfIdentical(
                    directoryDescriptor: prepared.directoryDescriptor,
                    socketFileName: wasPublished ? Self.socketFileName : stagingFileName,
                    identity: boundIdentity
                )
            }
            throw error
        }
    }

    private nonisolated static func unixAddress(for path: String) throws -> sockaddr_un {
        guard !path.utf8.contains(0) else { throw UnixSocketIntegrationError.unsafeDirectory }
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw UnixSocketIntegrationError.socketPathTooLong
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            storage.initializeMemory(as: UInt8.self, repeating: 0)
            storage.copyBytes(from: bytes)
        }
        return address
    }

    private nonisolated static func configureBaseSocket(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw UnixSocketIntegrationError.systemCall("fcntl", errno)
        }
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw UnixSocketIntegrationError.systemCall("setsockopt", errno)
        }
    }

    private nonisolated static func configureClientSocket(
        _ descriptor: Int32,
        bufferBytes: Int
    ) throws {
        try configureBaseSocket(descriptor)
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard statusFlags >= 0,
              fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            throw UnixSocketIntegrationError.systemCall("fcntl", errno)
        }
        var buffer = Int32(bufferBytes)
        let bufferSize = socklen_t(MemoryLayout<Int32>.size)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &buffer, bufferSize) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &buffer, bufferSize) == 0 else {
            throw UnixSocketIntegrationError.systemCall("setsockopt", errno)
        }
    }
}

private final class OwnedSocketDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private var shutdownRequested = false

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        lock.lock()
        let owned = descriptor
        descriptor = -1
        lock.unlock()
        if owned >= 0 { _ = Darwin.close(owned) }
    }

    var rawDescriptor: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0 ? descriptor : nil
    }

    var isOpen: Bool { rawDescriptor != nil }

    func shutdownOnly() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, !shutdownRequested else {
            return
        }
        shutdownRequested = true
        // shutdown(2) is nonblocking. Keeping this short lock held makes it
        // exclusive with the I/O owner's final close, so the integer cannot
        // be closed and reused between validation and the syscall.
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    /// Called only by the task that owns accept/recv/send for this descriptor.
    func closeByOwner() {
        lock.lock()
        guard descriptor >= 0 else {
            lock.unlock()
            return
        }
        let owned = descriptor
        descriptor = -1
        lock.unlock()
        _ = Darwin.close(owned)
    }
}

private final class AcceptCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var readFileDescriptor: Int32
    private var writeFileDescriptor: Int32
    private var cancellationRequested = false
    private var signalled = false
    private var storedErrorCode: Int32?
    private let testingWriteResult: (@Sendable () -> UnixSocketIntegrationTestingWakeWriteResult)?

    init(
        testingWriteResult: (@Sendable () -> UnixSocketIntegrationTestingWakeWriteResult)? = nil
    ) throws {
        self.testingWriteResult = testingWriteResult
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw UnixSocketIntegrationError.systemCall("pipe", errno)
        }
        do {
            for descriptor in descriptors {
                let descriptorFlags = fcntl(descriptor, F_GETFD)
                let statusFlags = fcntl(descriptor, F_GETFL)
                guard descriptorFlags >= 0,
                      statusFlags >= 0,
                      fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
                      fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
                    throw UnixSocketIntegrationError.systemCall("fcntl", errno)
                }
            }
            readFileDescriptor = descriptors[0]
            writeFileDescriptor = descriptors[1]
        } catch {
            descriptors.forEach { if $0 >= 0 { _ = Darwin.close($0) } }
            throw error
        }
    }

    deinit { closeByOwner() }

    var readDescriptor: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return readFileDescriptor >= 0 ? readFileDescriptor : nil
    }

    var errorCode: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedErrorCode
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    @discardableResult
    func signal(errorCode: Int32?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancellationRequested, writeFileDescriptor >= 0 else {
            return signalled
        }
        cancellationRequested = true
        storedErrorCode = errorCode
        while true {
            let result: UnixSocketIntegrationTestingWakeWriteResult
            let injected = testingWriteResult?()
            if let injected, injected != .written {
                result = injected
            } else {
                var byte: UInt8 = 1
                let written = Darwin.write(writeFileDescriptor, &byte, 1)
                if written == 1 {
                    result = .written
                } else if written == 0 {
                    result = .zero
                } else if errno == EINTR {
                    result = .interrupted
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    result = .wouldBlock
                } else {
                    result = .failed
                }
            }

            switch result {
            case .written, .wouldBlock:
                // EAGAIN on this private nonblocking pipe means readable data
                // is already buffered. Publish state only after either proof.
                signalled = true
                return true
            case .interrupted, .zero:
                continue
            case .failed:
                // Closing the owned write end produces POLLHUP on the read
                // end. This is the failure fallback; `signalled` remains
                // false because no byte/EAGAIN proof exists.
                let failedDescriptor = writeFileDescriptor
                writeFileDescriptor = -1
                _ = Darwin.close(failedDescriptor)
                return false
            }
        }
    }

    func closeByOwner() {
        lock.lock()
        let readDescriptor = readFileDescriptor
        let writeDescriptor = writeFileDescriptor
        readFileDescriptor = -1
        writeFileDescriptor = -1
        lock.unlock()
        if readDescriptor >= 0 { _ = Darwin.close(readDescriptor) }
        if writeDescriptor >= 0 { _ = Darwin.close(writeDescriptor) }
    }
}

private enum EventWaitResult {
    case ready
    case timedOut
    case failed
}

private struct MonotonicDeadline {
    let nanoseconds: UInt64

    init(milliseconds: Int) {
        let now = Self.nowNanoseconds()
        let delta = UInt64(milliseconds) * 1_000_000
        nanoseconds = now.addingReportingOverflow(delta).overflow ? UInt64.max : now + delta
    }

    func remainingMilliseconds() -> Int32? {
        let now = Self.nowNanoseconds()
        guard now < nanoseconds else { return nil }
        let remaining = nanoseconds - now
        let roundedUp = (remaining + 999_999) / 1_000_000
        return Int32(min(roundedUp, UInt64(Int32.max)))
    }

    private static func nowNanoseconds() -> UInt64 {
        var value = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &value) == 0 else { return 0 }
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }
}

private func waitForEvent(
    descriptor: Int32,
    events: Int16,
    deadline: MonotonicDeadline
) -> EventWaitResult {
    while true {
        guard let remaining = deadline.remainingMilliseconds() else { return .timedOut }
        var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
        let result = Darwin.poll(&pollDescriptor, 1, remaining)
        if result > 0 { return .ready }
        if result == 0 { return .timedOut }
        if errno != EINTR { return .failed }
    }
}

private struct FileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let fileType: mode_t

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        fileType = metadata.st_mode & S_IFMT
    }
}

private struct SecureSocketDirectory: @unchecked Sendable {
    let directoryDescriptor: Int32
    let directoryIdentity: FileIdentity
    let lockDescriptor: Int32
    let directoryURL: URL
    let socketURL: URL

    static func makeStagingFileName() -> String {
        var randomBytes = [UInt8](repeating: 0, count: 10)
        randomBytes.withUnsafeMutableBytes { storage in
            arc4random_buf(storage.baseAddress, storage.count)
        }
        let token = Data(randomBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        // Fifteen bytes including the dot: shorter than the public filename,
        // while retaining 80 bits of randomness.
        return ".\(token)"
    }

    func close() {
        _ = flock(lockDescriptor, LOCK_UN)
        _ = Darwin.close(lockDescriptor)
        _ = Darwin.close(directoryDescriptor)
    }

    func revalidate() throws {
        var held = stat()
        var path = stat()
        guard fstat(directoryDescriptor, &held) == 0,
              lstat(directoryURL.path, &path) == 0,
              FileIdentity(held) == directoryIdentity,
              FileIdentity(path) == directoryIdentity,
              path.st_uid == geteuid(),
              path.st_mode & 0o777 == 0o700,
              path.st_mode & S_IFMT == S_IFDIR else {
            throw UnixSocketIntegrationError.unsafeDirectory
        }
        try Self.validateExtendedDirectoryACL(directoryDescriptor)
    }

    func requireAbsent(fileName: String) throws {
        var metadata = stat()
        guard fstatat(directoryDescriptor, fileName, &metadata, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else {
            throw UnixSocketIntegrationError.unsafeDirectory
        }
    }

    func captureSocketIdentity(
        fileName: String,
        absoluteURL: URL,
        requireMode: mode_t? = nil
    ) throws -> FileIdentity {
        let identity = try captureSocketPathIdentity(
            fileName: fileName,
            absoluteURL: absoluteURL,
            requireMode: requireMode
        )
        try Self.validateExtendedSocketACL(absoluteURL)

        // Filesystem socket ACLs are exposed only through a pathname API.
        // Sandwich that read between held-directory and absolute-path
        // identity checks so a replacement is never accepted as the bound
        // endpoint.
        guard try captureSocketPathIdentity(
            fileName: fileName,
            absoluteURL: absoluteURL,
            requireMode: requireMode
        ) == identity else {
            throw UnixSocketIntegrationError.unsafeDirectory
        }
        return identity
    }

    func captureSocketPathIdentity(
        fileName: String,
        absoluteURL: URL,
        requireMode: mode_t? = nil
    ) throws -> FileIdentity {
        var heldPath = stat()
        var absolutePath = stat()
        guard fstatat(
            directoryDescriptor,
            fileName,
            &heldPath,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              lstat(absoluteURL.path, &absolutePath) == 0,
              FileIdentity(heldPath) == FileIdentity(absolutePath),
              heldPath.st_uid == geteuid(),
              heldPath.st_mode & S_IFMT == S_IFSOCK else {
            throw UnixSocketIntegrationError.unsafeDirectory
        }
        if let requireMode, heldPath.st_mode & 0o777 != requireMode {
            throw UnixSocketIntegrationError.unsafeDirectory
        }
        let identity = FileIdentity(heldPath)
        var revalidatedHeldPath = stat()
        var revalidatedAbsolutePath = stat()
        guard fstatat(
            directoryDescriptor,
            fileName,
            &revalidatedHeldPath,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              lstat(absoluteURL.path, &revalidatedAbsolutePath) == 0,
              FileIdentity(revalidatedHeldPath) == identity,
              FileIdentity(revalidatedAbsolutePath) == identity,
              revalidatedHeldPath.st_uid == geteuid(),
              revalidatedHeldPath.st_mode & S_IFMT == S_IFSOCK else {
            throw UnixSocketIntegrationError.unsafeDirectory
        }
        if let requireMode, revalidatedHeldPath.st_mode & 0o777 != requireMode {
            throw UnixSocketIntegrationError.unsafeDirectory
        }
        return identity
    }

    static func prepare(
        directoryURL: URL,
        socketFileName: String,
        beforeStaleSocketCleanup: (@Sendable (URL) -> Void)?
    ) throws -> Self {
        guard directoryURL.isFileURL,
              directoryURL.path.hasPrefix("/"),
              !directoryURL.path.utf8.contains(0),
              !socketFileName.isEmpty,
              !socketFileName.utf8.contains(0),
              !socketFileName.contains("/") else {
            throw UnixSocketIntegrationError.unsafeDirectory
        }
        // `standardizedFileURL` consults the filesystem and can rewrite
        // `/private/tmp` to the `/tmp` symlink after the directory exists.
        // Normalize lexically so every component is still opened and checked
        // with O_NOFOLLOW below.
        let standardizedURL = directoryURL.standardized
        guard !standardizedURL.path.utf8.contains(0) else {
            throw UnixSocketIntegrationError.unsafeDirectory
        }
        let components = standardizedURL.pathComponents.filter { $0 != "/" }
        guard let finalComponent = components.last, finalComponent != ".", finalComponent != ".." else {
            throw UnixSocketIntegrationError.unsafeDirectory
        }

        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw UnixSocketIntegrationError.systemCall("open", errno) }
        do {
            try validateAncestor(current)
            for component in components.dropLast() {
                guard !component.utf8.contains(0) else { throw UnixSocketIntegrationError.unsafeDirectory }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw UnixSocketIntegrationError.unsafeDirectory }
                do {
                    try validateAncestor(next)
                } catch {
                    _ = Darwin.close(next)
                    throw error
                }
                _ = Darwin.close(current)
                current = next
            }
            if mkdirat(current, finalComponent, 0o700) != 0, errno != EEXIST {
                throw UnixSocketIntegrationError.systemCall("mkdirat", errno)
            }
            let directoryDescriptor = openat(
                current,
                finalComponent,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard directoryDescriptor >= 0 else { throw UnixSocketIntegrationError.unsafeDirectory }
            _ = Darwin.close(current)
            current = -1

            do {
                var metadata = stat()
                guard fstat(directoryDescriptor, &metadata) == 0,
                      metadata.st_uid == geteuid(),
                      metadata.st_mode & S_IFMT == S_IFDIR,
                      metadata.st_mode & 0o777 == 0o700 else {
                    throw UnixSocketIntegrationError.unsafeDirectory
                }
                try validateExtendedDirectoryACL(directoryDescriptor)
                let identity = FileIdentity(metadata)
                let lockDescriptor = openat(
                    directoryDescriptor,
                    ".erylo-v1.lock",
                    O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                    0o600
                )
                guard lockDescriptor >= 0 else { throw UnixSocketIntegrationError.unsafeDirectory }
                do {
                    try validateLock(lockDescriptor)
                    guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                        throw UnixSocketIntegrationError.anotherServiceIsRunning
                    }
                    try removeOwnedStaleSocket(
                        directoryDescriptor: directoryDescriptor,
                        socketFileName: socketFileName,
                        socketURL: standardizedURL.appendingPathComponent(socketFileName),
                        beforeQuarantine: beforeStaleSocketCleanup
                    )
                    let prepared = Self(
                        directoryDescriptor: directoryDescriptor,
                        directoryIdentity: identity,
                        lockDescriptor: lockDescriptor,
                        directoryURL: standardizedURL,
                        socketURL: standardizedURL.appendingPathComponent(socketFileName)
                    )
                    try prepared.revalidate()
                    let address = sockaddr_un()
                    guard prepared.socketURL.path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
                        throw UnixSocketIntegrationError.socketPathTooLong
                    }
                    return prepared
                } catch {
                    _ = Darwin.close(lockDescriptor)
                    throw error
                }
            } catch {
                _ = Darwin.close(directoryDescriptor)
                throw error
            }
        } catch {
            if current >= 0 { _ = Darwin.close(current) }
            throw error
        }
    }

    static func quarantineAndRemoveIfIdentical(
        directoryDescriptor: Int32,
        socketFileName: String,
        identity: FileIdentity
    ) -> Bool {
        let quarantineFileName = ".erylo-quarantine-\(UUID().uuidString.lowercased())"
        guard renameatx_np(
            directoryDescriptor,
            socketFileName,
            directoryDescriptor,
            quarantineFileName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            return errno == ENOENT
        }

        var metadata = stat()
        guard fstatat(
            directoryDescriptor,
            quarantineFileName,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              FileIdentity(metadata) == identity,
              metadata.st_mode & S_IFMT == S_IFSOCK else {
            // A replacement was moved, not deleted. Restore it exclusively;
            // if a new public entry won the race, retain the replacement under
            // its unpredictable quarantine name rather than unlinking it.
            _ = renameatx_np(
                directoryDescriptor,
                quarantineFileName,
                directoryDescriptor,
                socketFileName,
                UInt32(RENAME_EXCL)
            )
            return false
        }
        // Only the verified object is now outside the public pathname under a
        // freshly unpredictable name. A cleanup failure preserves it there.
        return unlinkat(directoryDescriptor, quarantineFileName, 0) == 0
    }

    private static func validateAncestor(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw UnixSocketIntegrationError.unsafeDirectory
        }
        let permissions = metadata.st_mode & 0o7777
        let callerOwnedAndClosed = metadata.st_uid == geteuid() && permissions & 0o022 == 0
        let rootOwnedSticky = metadata.st_uid == 0
            && (permissions & 0o022 == 0 || permissions & S_ISVTX != 0)
        guard callerOwnedAndClosed || rootOwnedSticky else {
            throw UnixSocketIntegrationError.unsafeDirectory
        }
        try validateExtendedDirectoryACL(descriptor)
    }

    private static func validateExtendedDirectoryACL(_ descriptor: Int32) throws {
        // A trusted ancestor or 0700 final directory needs no access-expanding
        // allow ACE. Reject every nonempty current or future permission mask,
        // including ACL/bootstrap/ownership writes, while permitting deny-only
        // entries that can only narrow access.
        try validateExtendedACL(
            descriptor: descriptor,
            dangerousPermissions: acl_permset_mask_t.max
        )
    }

    private static func validateExtendedPrivateObjectACL(_ descriptor: Int32) throws {
        try validateExtendedACL(
            descriptor: descriptor,
            dangerousPermissions: privateObjectDangerousPermissions
        )
    }

    private static func validateExtendedSocketACL(_ socketURL: URL) throws {
        errno = 0
        guard let accessControlList = acl_get_link_np(socketURL.path, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw UnixSocketIntegrationError.unsafeDirectory }
            return
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(accessControlList)) }
        try validateExtendedACL(
            accessControlList,
            dangerousPermissions: privateObjectDangerousPermissions
        )
    }

    private static func validateExtendedACL(
        descriptor: Int32,
        dangerousPermissions: acl_permset_mask_t
    ) throws {
        errno = 0
        guard let accessControlList = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // macOS reports ENOENT when no extended ACL is present.
            guard errno == ENOENT else { throw UnixSocketIntegrationError.unsafeDirectory }
            return
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(accessControlList)) }
        try validateExtendedACL(
            accessControlList,
            dangerousPermissions: dangerousPermissions
        )
    }

    private static func validateExtendedACL(
        _ accessControlList: acl_t,
        dangerousPermissions: acl_permset_mask_t
    ) throws {
        var entryIdentifier = ACL_FIRST_ENTRY.rawValue
        while true {
            var entry: acl_entry_t?
            errno = 0
            let result = acl_get_entry(accessControlList, entryIdentifier, &entry)
            if result != 0, errno == EINVAL { return }
            guard result == 0, let entry else {
                throw UnixSocketIntegrationError.unsafeDirectory
            }
            var tag = ACL_UNDEFINED_TAG
            var permissionMask: acl_permset_mask_t = 0
            guard acl_get_tag_type(entry, &tag) == 0,
                  acl_get_permset_mask_np(entry, &permissionMask) == 0 else {
                throw UnixSocketIntegrationError.unsafeDirectory
            }
            if tag == ACL_EXTENDED_ALLOW,
               permissionMask & dangerousPermissions != 0 {
                throw UnixSocketIntegrationError.unsafeDirectory
            }
            // Deny entries only narrow access, including the standard
            // deny-delete ACE Finder commonly installs on protected folders.
            guard tag == ACL_EXTENDED_ALLOW || tag == ACL_EXTENDED_DENY else {
                throw UnixSocketIntegrationError.unsafeDirectory
            }
            entryIdentifier = ACL_NEXT_ENTRY.rawValue
        }
    }

    private static func validateLock(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o777 == 0o600 else {
            throw UnixSocketIntegrationError.unsafeDirectory
        }
        try validateExtendedPrivateObjectACL(descriptor)
    }

    // A 0600 lock or socket needs no access-expanding allow ACE. Reject every
    // nonempty allow permission mask, including future bits unknown to this
    // SDK, while continuing to permit deny-only ACLs.
    private static let privateObjectDangerousPermissions = acl_permset_mask_t.max

    private static func removeOwnedStaleSocket(
        directoryDescriptor: Int32,
        socketFileName: String,
        socketURL: URL,
        beforeQuarantine: (@Sendable (URL) -> Void)?
    ) throws {
        var metadata = stat()
        if fstatat(directoryDescriptor, socketFileName, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            let identity = FileIdentity(metadata)
            guard metadata.st_uid == geteuid(),
                  metadata.st_mode & S_IFMT == S_IFSOCK,
                  metadata.st_mode & 0o777 == 0o600 else {
                throw UnixSocketIntegrationError.unsafeDirectory
            }
            try validateExtendedSocketACL(socketURL)
            var revalidatedMetadata = stat()
            var revalidatedAbsoluteMetadata = stat()
            guard fstatat(
                directoryDescriptor,
                socketFileName,
                &revalidatedMetadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                  lstat(socketURL.path, &revalidatedAbsoluteMetadata) == 0,
                  FileIdentity(revalidatedMetadata) == identity,
                  FileIdentity(revalidatedAbsoluteMetadata) == identity,
                  revalidatedMetadata.st_uid == geteuid(),
                  revalidatedMetadata.st_mode & S_IFMT == S_IFSOCK,
                  revalidatedMetadata.st_mode & 0o777 == 0o600 else {
                throw UnixSocketIntegrationError.unsafeDirectory
            }
            beforeQuarantine?(socketURL)
            guard quarantineAndRemoveIfIdentical(
                directoryDescriptor: directoryDescriptor,
                socketFileName: socketFileName,
                identity: identity
            ) else {
                throw UnixSocketIntegrationError.unsafeDirectory
            }
        } else if errno != ENOENT {
            throw UnixSocketIntegrationError.systemCall("fstatat", errno)
        }
    }
}
