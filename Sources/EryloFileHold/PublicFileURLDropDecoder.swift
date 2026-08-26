import Darwin
import Foundation
import UniformTypeIdentifiers

public protocol FileHoldDropTimeoutScheduling: Sendable {
    func waitForTimeout() async throws
}

/// Coordinates access to a provider-owned file representation. Implementations must invoke the
/// accessor synchronously while the coordinated read is active.
public protocol FileHoldDropFileCoordinating: Sendable {
    func coordinateReadingFileURL(
        _ representationURL: URL,
        accessor: @escaping @Sendable (URL) -> Result<URL, FileHoldError>
    ) throws -> Result<URL, FileHoldError>
}

public struct FoundationFileHoldDropFileCoordinator: FileHoldDropFileCoordinating {
    public init() {}

    public func coordinateReadingFileURL(
        _ representationURL: URL,
        accessor: @escaping @Sendable (URL) -> Result<URL, FileHoldError>
    ) throws -> Result<URL, FileHoldError> {
        guard representationURL.isFileURL else {
            throw FileHoldError.invalidDragRepresentation
        }

        // Provider URLs can be security scoped in a signed sandbox. Keep any successfully opened
        // scope alive across coordination and the complete descriptor-based read.
        let startedSecurityScope = representationURL.startAccessingSecurityScopedResource()
        defer {
            if startedSecurityScope {
                representationURL.stopAccessingSecurityScopedResource()
            }
        }

        let resultState = CoordinatedDropResultState()
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: representationURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            resultState.store(accessor(coordinatedURL))
        }
        guard coordinationError == nil, let result = resultState.result else {
            throw FileHoldError.invalidDragRepresentation
        }
        return result
    }
}

/// A narrow deterministic seam for observing when provider Progress cancellation is available.
public protocol FileHoldDropLoadObserving: Sendable {
    func didInstallProviderProgress()
}

public struct DisabledFileHoldDropLoadObserver: FileHoldDropLoadObserving {
    public init() {}

    public func didInstallProviderProgress() {}
}

public struct OneShotFileHoldDropTimeoutScheduler: FileHoldDropTimeoutScheduling {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64 = 5_000_000_000) {
        self.nanoseconds = nanoseconds
    }

    public func waitForTimeout() async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public struct FileHoldDropEntry: Equatable, Sendable {
    public let providerIndex: Int
    public let outcome: Result<URL, FileHoldError>

    public init(providerIndex: Int, outcome: Result<URL, FileHoldError>) {
        self.providerIndex = providerIndex
        self.outcome = outcome
    }
}

public struct FileHoldDropReport: Equatable, Sendable {
    public let entries: [FileHoldDropEntry]
    public let unprocessedProviderCount: Int

    public init(entries: [FileHoldDropEntry], unprocessedProviderCount: Int = 0) {
        self.entries = entries
        self.unprocessedProviderCount = unprocessedProviderCount
    }

    public var fileURLs: [URL] {
        entries.compactMap { try? $0.outcome.get() }
    }
}

/// Converts the public `UTType.fileURL` drag representation into validated ingest inputs.
/// Provider interaction stays on the main actor; the store performs all filesystem work elsewhere.
@MainActor
public struct PublicFileURLDropDecoder {
    public nonisolated static let hardMaximumProviderCount = 256
    public nonisolated static let hardMaximumRepresentationBytes = 64 * 1_024

    public let maximumProviderCount: Int
    public let maximumRepresentationBytes: Int

    private let timeoutScheduler: any FileHoldDropTimeoutScheduling
    private let fileCoordinator: any FileHoldDropFileCoordinating
    private let loadObserver: any FileHoldDropLoadObserving

    public init(
        maximumProviderCount: Int = 64,
        maximumRepresentationBytes: Int = 16 * 1_024,
        timeoutScheduler: any FileHoldDropTimeoutScheduling = OneShotFileHoldDropTimeoutScheduler(),
        fileCoordinator: any FileHoldDropFileCoordinating = FoundationFileHoldDropFileCoordinator(),
        loadObserver: any FileHoldDropLoadObserving = DisabledFileHoldDropLoadObserver()
    ) {
        self.maximumProviderCount = max(
            0,
            min(maximumProviderCount, Self.hardMaximumProviderCount)
        )
        self.maximumRepresentationBytes = max(
            1,
            min(maximumRepresentationBytes, Self.hardMaximumRepresentationBytes)
        )
        self.timeoutScheduler = timeoutScheduler
        self.fileCoordinator = fileCoordinator
        self.loadObserver = loadObserver
    }

    public func decode(_ providers: [NSItemProvider]) async -> FileHoldDropReport {
        var entries: [FileHoldDropEntry] = []
        let acceptedProviders = providers.prefix(maximumProviderCount)
        entries.reserveCapacity(acceptedProviders.count)

        for (index, provider) in acceptedProviders.enumerated() {
            if Task.isCancelled {
                entries.append(FileHoldDropEntry(
                    providerIndex: index,
                    outcome: .failure(.cancelled)
                ))
                continue
            }
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                entries.append(FileHoldDropEntry(
                    providerIndex: index,
                    outcome: .failure(.unsupportedDragRepresentation)
                ))
                continue
            }

            let outcome = await loadFileURL(from: provider)
            entries.append(FileHoldDropEntry(providerIndex: index, outcome: outcome))
        }
        return FileHoldDropReport(
            entries: entries,
            unprocessedProviderCount: providers.count - acceptedProviders.count
        )
    }

    private func loadFileURL(
        from provider: NSItemProvider
    ) async -> Result<URL, FileHoldError> {
        let state = DragRepresentationLoadState()
        let byteLimit = maximumRepresentationBytes
        let scheduler = timeoutScheduler
        let fileCoordinator = fileCoordinator
        let loadObserver = loadObserver

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.installAndBegin(continuation) else { return }

                let timeoutTask = Task {
                    do {
                        try await scheduler.waitForTimeout()
                    } catch is CancellationError {
                        return
                    } catch {
                        state.finish(
                            with: .failure(.dragTimeoutSchedulingFailed),
                            cancelProgress: true
                        )
                        return
                    }
                    state.finish(
                        with: .failure(.dragRepresentationTimedOut),
                        cancelProgress: true
                    )
                }
                state.setTimeoutTask(timeoutTask)

                let progress = provider.loadInPlaceFileRepresentation(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) { representationURL, _, error in
                    guard let representationURL, error == nil else {
                        state.finish(
                            with: .failure(.invalidDragRepresentation),
                            cancelProgress: false
                        )
                        return
                    }
                    let result: Result<URL, FileHoldError>
                    do {
                        result = try fileCoordinator.coordinateReadingFileURL(
                            representationURL
                        ) { coordinatedURL in
                            Self.decodeRepresentationFile(
                                coordinatedURL,
                                byteLimit: byteLimit
                            )
                        }
                    } catch {
                        result = .failure(.invalidDragRepresentation)
                    }
                    state.finish(with: result, cancelProgress: Self.isOversized(result))
                }
                state.setProgress(progress)
                loadObserver.didInstallProviderProgress()
            }
        } onCancel: {
            state.finish(with: .failure(.cancelled), cancelProgress: true)
        }
    }

    private nonisolated static func validateDecodedURL(
        _ url: URL,
        byteLimit: Int
    ) -> Result<URL, FileHoldError> {
        guard url.absoluteString.utf8.count <= byteLimit else {
            return .failure(.dragRepresentationTooLarge(maximumBytes: byteLimit))
        }
        guard url.isFileURL else {
            return .failure(.invalidDragRepresentation)
        }
        return .success(url)
    }

    private nonisolated static func isOversized(
        _ result: Result<URL, FileHoldError>
    ) -> Bool {
        guard case let .failure(error) = result,
              case .dragRepresentationTooLarge = error else {
            return false
        }
        return true
    }

    private nonisolated static func decodeRepresentationFile(
        _ representationURL: URL,
        byteLimit: Int
    ) -> Result<URL, FileHoldError> {
        guard representationURL.isFileURL else {
            return .failure(.invalidDragRepresentation)
        }
        var pathStat = stat()
        guard lstat(representationURL.path, &pathStat) == 0,
              pathStat.st_mode & S_IFMT == S_IFREG else {
            return .failure(.invalidDragRepresentation)
        }
        guard pathStat.st_size >= 0, pathStat.st_size <= byteLimit else {
            return .failure(.dragRepresentationTooLarge(maximumBytes: byteLimit))
        }

        let descriptor = open(
            representationURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            return .failure(.invalidDragRepresentation)
        }
        defer { close(descriptor) }

        var openedStat = stat()
        guard fstat(descriptor, &openedStat) == 0,
              openedStat.st_mode & S_IFMT == S_IFREG,
              sameRepresentation(pathStat, openedStat) else {
            return .failure(.invalidDragRepresentation)
        }
        guard openedStat.st_size <= byteLimit else {
            return .failure(.dragRepresentationTooLarge(maximumBytes: byteLimit))
        }

        var bytes = [UInt8](repeating: 0, count: byteLimit + 1)
        let readResult = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { return result == 0 ? offset : -1 }
                offset += result
            }
            return offset
        }
        guard readResult >= 0 else {
            return .failure(.invalidDragRepresentation)
        }
        guard readResult <= byteLimit else {
            return .failure(.dragRepresentationTooLarge(maximumBytes: byteLimit))
        }
        var finalStat = stat()
        guard fstat(descriptor, &finalStat) == 0,
              sameRepresentation(openedStat, finalStat),
              finalStat.st_size == readResult else {
            return .failure(.invalidDragRepresentation)
        }
        guard let url = URL(
            dataRepresentation: Data(bytes.prefix(readResult)),
            relativeTo: nil
        ) else {
            return .failure(.invalidDragRepresentation)
        }
        return validateDecodedURL(url, byteLimit: byteLimit)
    }

    private nonisolated static func sameRepresentation(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev
            && first.st_ino == second.st_ino
            && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}

private final class CoordinatedDropResultState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<URL, FileHoldError>?

    var result: Result<URL, FileHoldError>? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    func store(_ result: Result<URL, FileHoldError>) {
        lock.lock()
        storedResult = result
        lock.unlock()
    }
}

private final class DragRepresentationLoadState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<URL, FileHoldError>, Never>?
    private var finishedResult: Result<URL, FileHoldError>?
    private var progress: Progress?
    private var timeoutTask: Task<Void, Never>?
    private var cancelProgressWhenInstalled = false

    func installAndBegin(
        _ continuation: CheckedContinuation<Result<URL, FileHoldError>, Never>
    ) -> Bool {
        lock.lock()
        if let finishedResult {
            lock.unlock()
            continuation.resume(returning: finishedResult)
            return false
        } else {
            self.continuation = continuation
            lock.unlock()
            return true
        }
    }

    func setProgress(_ progress: Progress?) {
        lock.lock()
        let alreadyFinished = finishedResult != nil
        let shouldCancel = alreadyFinished && cancelProgressWhenInstalled
        if !alreadyFinished {
            self.progress = progress
        }
        lock.unlock()
        if shouldCancel {
            progress?.cancel()
        }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = finishedResult != nil
        if !shouldCancel {
            timeoutTask = task
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func finish(
        with result: Result<URL, FileHoldError>,
        cancelProgress: Bool
    ) {
        let continuationToResume: CheckedContinuation<Result<URL, FileHoldError>, Never>?
        let progressToCancel: Progress?
        let timeoutTaskToCancel: Task<Void, Never>?

        lock.lock()
        guard finishedResult == nil else {
            lock.unlock()
            return
        }
        finishedResult = result
        cancelProgressWhenInstalled = cancelProgress
        continuationToResume = continuation
        continuation = nil
        progressToCancel = cancelProgress ? progress : nil
        progress = nil
        timeoutTaskToCancel = timeoutTask
        timeoutTask = nil
        lock.unlock()

        timeoutTaskToCancel?.cancel()
        progressToCancel?.cancel()
        continuationToResume?.resume(returning: result)
    }
}
