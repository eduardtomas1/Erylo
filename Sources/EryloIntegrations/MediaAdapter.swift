import EryloCore
import Foundation

public enum MediaAdapterUpdate: Equatable, Sendable {
    case snapshot(NowPlayingSnapshot)
    case sourceDisappeared(source: MediaSource, stamp: MediaUpdateStamp)
    case failure(source: MediaSource, error: MediaError, stamp: MediaUpdateStamp)

    public var source: MediaSource {
        switch self {
        case let .snapshot(snapshot):
            snapshot.source
        case let .sourceDisappeared(source, _), let .failure(source, _, _):
            source
        }
    }

    public var stamp: MediaUpdateStamp {
        switch self {
        case let .snapshot(snapshot):
            snapshot.stamp
        case let .sourceDisappeared(_, stamp), let .failure(_, _, stamp):
            stamp
        }
    }
}

/// A lazy media source boundary. `activate()` must not request permission or start polling.
public protocol MediaAdapter: Sendable {
    var source: MediaSource { get }

    func activate() async
    func deactivate() async
    func updates() async -> AsyncStream<MediaAdapterUpdate>
    func refresh() async throws -> MediaAdapterUpdate
    func perform(_ command: MediaCommand) async throws
    func cancelPendingWork() async
}

/// An explicit disabled adapter. Every entry point is zero-work and no stream remains open.
public struct DisabledMediaAdapter: MediaAdapter {
    public let source: MediaSource

    public init(source: MediaSource) {
        self.source = source
    }

    public func activate() async {}
    public func deactivate() async {}

    public func updates() async -> AsyncStream<MediaAdapterUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func refresh() async throws -> MediaAdapterUpdate {
        throw MediaError.disabled(source: source)
    }

    public func perform(_ command: MediaCommand) async throws {
        throw MediaError.disabled(source: source)
    }

    public func cancelPendingWork() async {}
}

public enum MediaCoordinatorEvent: Equatable, Sendable {
    case snapshot(NowPlayingSnapshot)
    case sourceDisappeared(MediaSource)
    case healthChanged(MediaAdapterHealth)
}

public struct MediaCoordinatorPolicy: Equatable, Sendable {
    public let maximumPendingCommands: Int
    public let maximumSubscribers: Int
    public let subscriberBufferSize: Int

    public init(
        maximumPendingCommands: Int = 32,
        maximumSubscribers: Int = 16,
        subscriberBufferSize: Int = 32
    ) {
        self.maximumPendingCommands = max(1, maximumPendingCommands)
        self.maximumSubscribers = max(1, maximumSubscribers)
        self.subscriberBufferSize = max(1, subscriberBufferSize)
    }
}

/// Owns enabled-state, stale-update rejection, snapshot dedupe, subscriptions, and command ordering.
public actor MediaCoordinator {
    private struct QueuedCommand {
        let identifier: UUID
        let source: MediaSource
        let generation: UInt64
        let command: MediaCommand
        let continuation: CheckedContinuation<Void, Error>
    }

    private let adapters: [MediaSource: any MediaAdapter]
    private let policy: MediaCoordinatorPolicy
    private var requestedEnabledSources: Set<MediaSource> = []
    private var sourceGenerations: [MediaSource: UInt64] = [:]
    private var activeGenerations: [MediaSource: UInt64] = [:]
    private var lifecycleTails: [MediaSource: Task<Void, Never>] = [:]
    private var eventTasks: [MediaSource: Task<Void, Never>] = [:]
    private var snapshots: [MediaSource: NowPlayingSnapshot] = [:]
    private var healthBySource: [MediaSource: MediaAdapterHealth] = [:]
    private var lastSequence: [MediaSource: UInt64] = [:]
    private var subscribers: [UUID: AsyncStream<MediaCoordinatorEvent>.Continuation] = [:]
    private var commandQueue: [QueuedCommand] = []
    private var commandWorker: Task<Void, Never>?
    private var activeCommand: QueuedCommand?
    private var cancelledCommandIdentifiers: Set<UUID> = []

    public init(
        adapters: [any MediaAdapter],
        policy: MediaCoordinatorPolicy = MediaCoordinatorPolicy()
    ) {
        var bySource: [MediaSource: any MediaAdapter] = [:]
        for adapter in adapters where bySource[adapter.source] == nil {
            bySource[adapter.source] = adapter
        }
        self.adapters = bySource
        self.policy = policy
        for source in bySource.keys {
            healthBySource[source] = MediaAdapterHealth(source: source, availability: .disabled)
        }
    }

    public func setEnabled(_ enabled: Bool, for source: MediaSource) async {
        guard adapters[source] != nil else { return }
        let wasRequested = requestedEnabledSources.contains(source)
        if wasRequested == enabled {
            await lifecycleTails[source]?.value
            return
        }

        let generation = (sourceGenerations[source] ?? 0) &+ 1
        sourceGenerations[source] = generation

        if enabled {
            requestedEnabledSources.insert(source)
        } else {
            requestedEnabledSources.remove(source)
            invalidateEnabledState(for: source)
        }

        let previous = lifecycleTails[source]
        let operation = Task { [weak self] in
            await previous?.value
            await self?.applyLifecycle(enabled, source: source, generation: generation)
        }
        lifecycleTails[source] = operation
        await operation.value
        if sourceGenerations[source] == generation {
            lifecycleTails.removeValue(forKey: source)
        }
    }

    @discardableResult
    public func refresh(_ source: MediaSource) async throws -> NowPlayingSnapshot? {
        guard let generation = activeGenerations[source],
              requestedEnabledSources.contains(source),
              let adapter = adapters[source] else {
            throw MediaError.disabled(source: source)
        }

        do {
            let update = try await adapter.refresh()
            guard activeGenerations[source] == generation,
                  requestedEnabledSources.contains(source) else {
                throw MediaError.cancelled(source: source)
            }
            receive(update, expectedSource: source, generation: generation)
            return snapshots[source]
        } catch let error as MediaError {
            guard activeGenerations[source] == generation,
                  requestedEnabledSources.contains(source) else {
                throw MediaError.cancelled(source: source)
            }
            setHealth(health(for: source, after: error))
            throw error
        } catch is CancellationError {
            guard activeGenerations[source] == generation,
                  requestedEnabledSources.contains(source) else {
                throw MediaError.cancelled(source: source)
            }
            let error = MediaError.cancelled(source: source)
            setHealth(health(for: source, after: error))
            throw error
        } catch {
            guard activeGenerations[source] == generation,
                  requestedEnabledSources.contains(source) else {
                throw MediaError.cancelled(source: source)
            }
            let mapped = MediaError.automationFailed(source: source, exitCode: nil)
            setHealth(health(for: source, after: mapped))
            throw mapped
        }
    }

    public func perform(_ command: MediaCommand, on source: MediaSource) async throws {
        guard let generation = activeGenerations[source], adapters[source] != nil else {
            throw MediaError.disabled(source: source)
        }
        guard let snapshot = snapshots[source] else {
            throw MediaError.sourceUnavailable(source: source)
        }
        let normalized = try command.normalized(for: snapshot)
        let pendingCount = commandQueue.count + (activeCommand == nil ? 0 : 1)
        guard pendingCount < policy.maximumPendingCommands else {
            throw MediaError.commandQueueFull(
                source: source,
                limit: policy.maximumPendingCommands
            )
        }

        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                commandQueue.append(
                    QueuedCommand(
                        identifier: identifier,
                        source: source,
                        generation: generation,
                        command: normalized,
                        continuation: continuation
                    )
                )
                startCommandWorkerIfNeeded()
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelCommand(identifier, source: source)
            }
        }
    }

    public func snapshot(for source: MediaSource) -> NowPlayingSnapshot? {
        snapshots[source]
    }

    public func health(for source: MediaSource) -> MediaAdapterHealth {
        healthBySource[source]
            ?? MediaAdapterHealth(source: source, availability: .disabled)
    }

    public func updates() throws -> AsyncStream<MediaCoordinatorEvent> {
        guard subscribers.count < policy.maximumSubscribers else {
            throw MediaError.subscriberLimitReached(limit: policy.maximumSubscribers)
        }

        let identifier = UUID()
        return AsyncStream(
            bufferingPolicy: .bufferingNewest(policy.subscriberBufferSize)
        ) { continuation in
            subscribers[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeSubscriber(identifier)
                }
            }
        }
    }

    public var activeSubscriberCount: Int {
        subscribers.count
    }

    public func stop() async {
        let sources = Array(requestedEnabledSources)
        for source in sources {
            await setEnabled(false, for: source)
        }

        commandWorker?.cancel()
        let queued = commandQueue
        commandQueue.removeAll(keepingCapacity: false)
        for command in queued {
            cancelledCommandIdentifiers.remove(command.identifier)
            command.continuation.resume(throwing: MediaError.cancelled(source: command.source))
        }
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll(keepingCapacity: false)
    }

    private func applyLifecycle(
        _ enabled: Bool,
        source: MediaSource,
        generation: UInt64
    ) async {
        guard sourceGenerations[source] == generation,
              requestedEnabledSources.contains(source) == enabled,
              let adapter = adapters[source] else { return }

        if enabled {
            await adapter.activate()
            guard sourceGenerations[source] == generation,
                  requestedEnabledSources.contains(source) else { return }

            let stream = await adapter.updates()
            guard sourceGenerations[source] == generation,
                  requestedEnabledSources.contains(source) else { return }

            activeGenerations[source] = generation
            setHealth(MediaAdapterHealth(source: source, availability: .inactive))
            eventTasks[source] = Task { [weak self] in
                for await update in stream {
                    guard !Task.isCancelled else { break }
                    await self?.receive(
                        update,
                        expectedSource: source,
                        generation: generation
                    )
                }
            }
        } else {
            await adapter.cancelPendingWork()
            await adapter.deactivate()
            guard sourceGenerations[source] == generation,
                  !requestedEnabledSources.contains(source) else { return }
        }
    }

    private func invalidateEnabledState(for source: MediaSource) {
        activeGenerations.removeValue(forKey: source)
        eventTasks.removeValue(forKey: source)?.cancel()
        lastSequence.removeValue(forKey: source)
        cancelQueuedCommands(for: source, error: MediaError.disabled(source: source))

        if let activeCommand, activeCommand.source == source {
            cancelledCommandIdentifiers.insert(activeCommand.identifier)
        }
        if snapshots.removeValue(forKey: source) != nil {
            publish(.sourceDisappeared(source))
        }
        setHealth(MediaAdapterHealth(source: source, availability: .disabled))
    }

    private func receive(
        _ update: MediaAdapterUpdate,
        expectedSource: MediaSource,
        generation: UInt64
    ) {
        guard activeGenerations[expectedSource] == generation,
              requestedEnabledSources.contains(expectedSource) else { return }
        guard update.source == expectedSource else {
            setHealth(
                MediaAdapterHealth(
                    source: expectedSource,
                    availability: .degraded,
                    lastError: .malformedResponse(source: expectedSource),
                    checkedAt: Date()
                )
            )
            return
        }

        let sequence = update.stamp.sequence
        guard sequence > (lastSequence[expectedSource] ?? 0) else { return }
        lastSequence[expectedSource] = sequence

        switch update {
        case let .snapshot(snapshot):
            let previous = snapshots.updateValue(snapshot, forKey: expectedSource)
            setHealth(
                MediaAdapterHealth(
                    source: expectedSource,
                    availability: .available,
                    checkedAt: snapshot.stamp.observedAt
                )
            )
            if previous?.hasSameContent(as: snapshot) != true {
                publish(.snapshot(snapshot))
            }

        case let .sourceDisappeared(_, stamp):
            let existed = snapshots.removeValue(forKey: expectedSource) != nil
            setHealth(
                MediaAdapterHealth(
                    source: expectedSource,
                    availability: .unavailable,
                    lastError: .sourceUnavailable(source: expectedSource),
                    checkedAt: stamp.observedAt
                )
            )
            if existed {
                publish(.sourceDisappeared(expectedSource))
            }

        case let .failure(_, error, stamp):
            setHealth(
                MediaAdapterHealth(
                    source: expectedSource,
                    availability: availability(for: error),
                    lastError: error,
                    checkedAt: stamp.observedAt
                )
            )
        }
    }

    private func setHealth(_ health: MediaAdapterHealth) {
        let previous = healthBySource.updateValue(health, forKey: health.source)
        if previous?.availability != health.availability || previous?.lastError != health.lastError {
            publish(.healthChanged(health))
        }
    }

    private func health(for source: MediaSource, after error: MediaError) -> MediaAdapterHealth {
        MediaAdapterHealth(
            source: source,
            availability: availability(for: error),
            lastError: error,
            checkedAt: Date()
        )
    }

    private func availability(for error: MediaError) -> MediaAdapterAvailability {
        switch error {
        case .disabled:
            .disabled
        case .sourceUnavailable:
            .unavailable
        default:
            .degraded
        }
    }

    private func publish(_ event: MediaCoordinatorEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func removeSubscriber(_ identifier: UUID) {
        subscribers.removeValue(forKey: identifier)
    }

    private func startCommandWorkerIfNeeded() {
        guard commandWorker == nil else { return }
        commandWorker = Task { [weak self] in
            await self?.drainCommandQueue()
        }
    }

    private func drainCommandQueue() async {
        while !Task.isCancelled, !commandQueue.isEmpty {
            let queued = commandQueue.removeFirst()
            activeCommand = queued

            let result: Result<Void, Error>
            if cancelledCommandIdentifiers.contains(queued.identifier) {
                result = .failure(MediaError.cancelled(source: queued.source))
            } else if activeGenerations[queued.source] != queued.generation {
                result = .failure(MediaError.cancelled(source: queued.source))
            } else if let adapter = adapters[queued.source],
                      let latestSnapshot = snapshots[queued.source] {
                do {
                    let revalidated = try queued.command.normalized(for: latestSnapshot)
                    try await adapter.perform(revalidated)
                    if activeGenerations[queued.source] != queued.generation
                        || cancelledCommandIdentifiers.contains(queued.identifier) {
                        result = .failure(MediaError.cancelled(source: queued.source))
                    } else {
                        result = .success(())
                    }
                } catch let error as MediaError {
                    result = .failure(error)
                } catch is CancellationError {
                    result = .failure(MediaError.cancelled(source: queued.source))
                } catch {
                    result = .failure(
                        MediaError.automationFailed(source: queued.source, exitCode: nil)
                    )
                }
            } else {
                result = .failure(MediaError.sourceUnavailable(source: queued.source))
            }

            let wasCancelled = cancelledCommandIdentifiers.remove(queued.identifier) != nil
            activeCommand = nil
            if wasCancelled {
                queued.continuation.resume(throwing: MediaError.cancelled(source: queued.source))
            } else {
                queued.continuation.resume(with: result)
            }
        }

        commandWorker = nil
        if !commandQueue.isEmpty {
            startCommandWorkerIfNeeded()
        }
    }

    private func cancelCommand(_ identifier: UUID, source: MediaSource) async {
        if let index = commandQueue.firstIndex(where: { $0.identifier == identifier }) {
            let queued = commandQueue.remove(at: index)
            cancelledCommandIdentifiers.remove(identifier)
            queued.continuation.resume(throwing: MediaError.cancelled(source: source))
            return
        }

        guard activeCommand?.identifier == identifier,
              activeCommand?.source == source else {
            cancelledCommandIdentifiers.remove(identifier)
            return
        }
        cancelledCommandIdentifiers.insert(identifier)
        await adapters[source]?.cancelPendingWork()
    }

    private func cancelQueuedCommands(for source: MediaSource, error: MediaError) {
        let cancelled = commandQueue.filter { $0.source == source }
        commandQueue.removeAll { $0.source == source }
        for queued in cancelled {
            cancelledCommandIdentifiers.remove(queued.identifier)
            queued.continuation.resume(throwing: error)
        }
    }
}
