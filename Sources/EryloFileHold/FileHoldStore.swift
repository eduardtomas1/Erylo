import Foundation

private final class FileHoldOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private enum FileHoldPresentationContext {
    @TaskLocal static var activeStoreIDs: Set<ObjectIdentifier> = []
}

public actor FileHoldStore {
    public nonisolated let rootURL: URL

    private let storage: SafeFileHoldStorage
    private let referenceCodec: any FileReferenceCoding
    private let expiryScheduler: any FileHoldExpiryScheduling
    private let limits: FileHoldIngestLimits
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> HeldFileID
    private let copyObserver: any FileHoldCopyObserving

    private var itemsByID: [HeldFileID: HeldFileItem] = [:]
    private var orderedIDs: [HeldFileID] = []
    private var availableIdentityOwners: [FileIdentity: [HeldFileID]] = [:]
    private var expiryTasks: [HeldFileID: Task<Void, Never>] = [:]
    private var expiryNonces: [HeldFileID: UInt64] = [:]
    private var nextExpiryNonce: UInt64 = 0
    private var reservedIDs: Set<HeldFileID> = []
    private var reservationGates: [HeldFileID: FileHoldOperationGate] = [:]
    private var reservedItemCount = 0
    private var reservedByteCount: Int64 = 0
    private var occupiedItemCount = 0
    private var occupiedByteCount: Int64 = 0
    private var activeTemporaryCopyLeases: [HeldFileID: Int] = [:]
    private var pendingCleanupDispositions: [HeldFileID: HeldFileTerminalDisposition] = [:]
    private var recoveryRecordsByID: [HeldFileID: FileHoldRecoveryRecord] = [:]
    private var committedRecoveryAccounting: [HeldFileID: FileHoldRecoveryAccounting] = [:]
    private var uncommittedRecoveryIDs: [HeldFileID] = []
    private var uncommittedRecoveryAccounting: [HeldFileID: FileHoldRecoveryAccounting] = [:]
    private var terminalIDs: [HeldFileID] = []
    private var shuttingDown = false
    private var workDrainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        rootURL: URL,
        limits: FileHoldIngestLimits = FileHoldIngestLimits(),
        referenceCodec: any FileReferenceCoding = SecurityScopedFileReferenceCodec(),
        expiryScheduler: any FileHoldExpiryScheduling = OneShotFileHoldExpiryScheduler(),
        copyObserver: any FileHoldCopyObserving = DisabledFileHoldCopyObserver(),
        storageObserver: any FileHoldStorageObserving = DisabledFileHoldStorageObserver(),
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> HeldFileID = {
            HeldFileID(rawValue: UUID().uuidString.lowercased())
        }
    ) throws {
        guard limits.isValid else {
            throw FileHoldError.invalidConfiguration
        }
        let storage = try SafeFileHoldStorage(rootURL: rootURL, observer: storageObserver)
        self.rootURL = storage.rootURL
        self.storage = storage
        self.limits = limits
        self.referenceCodec = referenceCodec
        self.expiryScheduler = expiryScheduler
        self.copyObserver = copyObserver
        self.now = now
        self.makeID = makeID
    }

    deinit {
        for task in expiryTasks.values {
            task.cancel()
        }
    }

    public func items() -> [HeldFileItem] {
        orderedIDs.compactMap { itemsByID[$0] }
    }

    public func availableItems() -> [HeldFileItem] {
        items().filter { $0.status.isAvailable }
    }

    public func item(id: HeldFileID) -> HeldFileItem? {
        itemsByID[id]
    }

    /// Ingests in input order. Validation, copy, and bookmark errors are isolated per input.
    /// Cancellation is represented in the report so callers retain completed-prefix evidence.
    public func ingest(
        _ sourceURLs: [URL],
        options: FileHoldIngestOptions
    ) async -> FileHoldIngestReport {
        var entries: [FileHoldIngestEntry] = []
        let representedCount: Int
        if sourceURLs.count > limits.maximumInputCount {
            representedCount = limits.maximumInputCount + 1
        } else {
            representedCount = sourceURLs.count
        }
        let representedURLs = sourceURLs.prefix(representedCount)
        entries.reserveCapacity(representedURLs.count)

        for (index, sourceURL) in representedURLs.enumerated() {
            if index >= limits.maximumInputCount {
                entries.append(failureEntry(
                    index: index,
                    url: sourceURL,
                    error: .tooManyInputs(maximum: limits.maximumInputCount)
                ))
                continue
            }
            if Task.isCancelled {
                entries.append(failureEntry(index: index, url: sourceURL, error: .cancelled))
                continue
            }
            if shuttingDown {
                entries.append(failureEntry(index: index, url: sourceURL, error: .storeShutDown))
                continue
            }
            let admittedAt = now()
            if let expiresAt = options.expiresAt,
               !isValidExpiry(expiresAt, relativeTo: admittedAt) {
                entries.append(failureEntry(index: index, url: sourceURL, error: .invalidExpiry))
                continue
            }

            let inspected: InspectedSource
            do {
                inspected = try storage.inspectSource(
                    sourceURL,
                    maximumPathBytes: limits.maximumPathBytes
                )
                guard inspected.metadata.byteCount <= limits.maximumItemBytes else {
                    throw FileHoldError.itemTooLarge(
                        maximumBytes: limits.maximumItemBytes,
                        actualBytes: inspected.metadata.byteCount
                    )
                }
                guard occupiedItemCount + reservedItemCount + uncommittedRecoveryIDs.count
                    < limits.maximumItemCount else {
                    throw FileHoldError.tooManyItems(maximum: limits.maximumItemCount)
                }
                let consumedBytes = totalConsumedBytes
                guard inspected.metadata.byteCount <= limits.maximumTotalBytes - consumedBytes else {
                    throw FileHoldError.totalSizeExceeded(
                        maximumBytes: limits.maximumTotalBytes
                    )
                }
                if options.duplicatePolicy == .reject,
                   let existingID = availableIdentityOwners[inspected.metadata.identity]?.first {
                    throw FileHoldError.duplicate(existingItemID: existingID)
                }
            } catch let error as FileHoldError {
                entries.append(failureEntry(index: index, url: sourceURL, error: error))
                continue
            } catch {
                entries.append(failureEntry(index: index, url: sourceURL, error: .sourceMissing))
                continue
            }

            let itemID: HeldFileID
            do {
                itemID = try allocateUniqueID()
            } catch let error as FileHoldError {
                entries.append(failureEntry(index: index, url: sourceURL, error: error))
                continue
            } catch {
                entries.append(failureEntry(
                    index: index,
                    url: sourceURL,
                    error: .identifierAllocationFailed
                ))
                continue
            }
            let operationGate = FileHoldOperationGate()
            reserve(itemID: itemID, source: inspected.metadata, gate: operationGate)
            let location: HeldFileLocation
            do {
                switch options.mode {
                case .temporaryCopy:
                    let expiration = options.expiresAt
                    let currentTime = now
                    let maximumExpiryInterval = limits.maximumExpiryInterval
                    let copy = try await storage.copySource(
                        inspected,
                        itemID: itemID,
                        observer: copyObserver,
                        shouldCommit: {
                            guard !Task.isCancelled else { return false }
                            guard !operationGate.isCancelled else { return false }
                            guard let expiration else { return true }
                            let observedTime = currentTime()
                            let interval = expiration.timeIntervalSince(observedTime)
                            return observedTime.timeIntervalSinceReferenceDate.isFinite
                                && observedTime >= admittedAt
                                && interval.isFinite
                                && interval > 0
                                && expiration.timeIntervalSince(admittedAt) <= maximumExpiryInterval
                        }
                    )
                    if Task.isCancelled {
                        try storage.removeCopy(copy: copy)
                        throw FileHoldError.cancelled
                    }
                    if let expiration,
                       !expiryRemainsValid(expiration, admittedAt: admittedAt) {
                        try storage.removeCopy(copy: copy)
                        throw FileHoldError.invalidExpiry
                    }
                    location = .temporaryCopy(copy)
                case .reference:
                    let bookmark: Data
                    do {
                        bookmark = try referenceCodec.makeBookmark(for: inspected.metadata.originalURL)
                    } catch let error as FileHoldError {
                        throw error
                    } catch {
                        throw FileHoldError.bookmarkCreationFailed
                    }
                    guard bookmark.count <= limits.maximumBookmarkBytes else {
                        throw FileHoldError.bookmarkTooLarge(
                            maximumBytes: limits.maximumBookmarkBytes
                        )
                    }
                    let reinspected = try storage.inspectSource(
                        inspected.metadata.originalURL,
                        maximumPathBytes: limits.maximumPathBytes
                    )
                    guard storage.sourceIsUnchanged(inspected, reinspected) else {
                        throw FileHoldError.sourceChangedDuringCopy
                    }
                    if Task.isCancelled {
                        throw FileHoldError.cancelled
                    }
                    if let expiresAt = options.expiresAt,
                       !expiryRemainsValid(expiresAt, admittedAt: admittedAt) {
                        throw FileHoldError.invalidExpiry
                    }
                    location = .reference(bookmark: bookmark)
                }
            } catch let error as FileHoldError {
                if case let .recoveryRequired(record) = error {
                    recordUncommittedRecovery(
                        itemID: itemID,
                        record: record
                    )
                }
                releaseReservation(itemID: itemID, source: inspected.metadata)
                let reportedError: FileHoldError
                if error == .invalidExpiry, Task.isCancelled {
                    reportedError = .cancelled
                } else if (shuttingDown || operationGate.isCancelled)
                    && (error == .invalidExpiry || error == .cancelled) {
                    reportedError = .storeShutDown
                } else {
                    reportedError = error
                }
                entries.append(failureEntry(index: index, url: sourceURL, error: reportedError))
                continue
            } catch {
                releaseReservation(itemID: itemID, source: inspected.metadata)
                entries.append(failureEntry(index: index, url: sourceURL, error: .copyFailed))
                continue
            }

            if shuttingDown || operationGate.isCancelled || Task.isCancelled {
                let cleanupError = cleanupUncommittedLocation(location)
                if case let .recoveryRequired(record)? = cleanupError {
                    recordUncommittedRecovery(
                        itemID: itemID,
                        record: record
                    )
                }
                releaseReservation(itemID: itemID, source: inspected.metadata)
                entries.append(failureEntry(
                    index: index,
                    url: sourceURL,
                    error: cleanupError ?? (shuttingDown ? .storeShutDown : .cancelled)
                ))
                continue
            }
            if let expiration = options.expiresAt,
               !expiryRemainsValid(expiration, admittedAt: admittedAt) {
                let cleanupError = cleanupUncommittedLocation(location)
                if case let .recoveryRequired(record)? = cleanupError {
                    recordUncommittedRecovery(
                        itemID: itemID,
                        record: record
                    )
                }
                releaseReservation(itemID: itemID, source: inspected.metadata)
                entries.append(failureEntry(
                    index: index,
                    url: sourceURL,
                    error: cleanupError ?? .invalidExpiry
                ))
                continue
            }

            let item = HeldFileItem(
                id: itemID,
                mode: options.mode,
                source: inspected.metadata,
                location: location,
                createdAt: now(),
                expiresAt: options.expiresAt,
                status: .available
            )
            itemsByID[itemID] = item
            commitReservation(itemID: itemID, source: inspected.metadata)
            orderedIDs.append(itemID)
            if let expiresAt = options.expiresAt {
                scheduleExpiry(for: itemID, at: expiresAt)
            }
            entries.append(FileHoldIngestEntry(
                inputIndex: index,
                sourceURL: sourceURL,
                outcome: .held(item)
            ))
        }

        return FileHoldIngestReport(
            entries: entries,
            unprocessedInputCount: sourceURLs.count - representedURLs.count
        )
    }

    @discardableResult
    public func updateExpiry(
        for itemID: HeldFileID,
        expiresAt: Date?
    ) throws -> HeldFileItem {
        guard !shuttingDown else {
            throw FileHoldError.storeShutDown
        }
        guard var item = itemsByID[itemID] else {
            throw FileHoldError.itemNotFound
        }
        guard item.status.isAvailable else {
            throw FileHoldError.itemUnavailable
        }
        if let expiresAt, !isValidExpiry(expiresAt, relativeTo: now()) {
            throw FileHoldError.invalidExpiry
        }

        cancelExpiry(for: itemID)
        item.expiresAt = expiresAt
        item.status = .available
        itemsByID[itemID] = item
        if let expiresAt {
            scheduleExpiry(for: itemID, at: expiresAt)
        }
        return item
    }

    @discardableResult
    public func remove(_ itemID: HeldFileID) -> FileHoldCleanupResult? {
        let disposition = pendingCleanupDispositions[itemID] ?? .removed(at: now())
        return cleanup(itemID, disposition: disposition)
    }

    public func recoveryEntries() -> [FileHoldRecoveryEntry] {
        (orderedIDs + uncommittedRecoveryIDs).compactMap { itemID in
            recoveryRecordsByID[itemID].map {
                FileHoldRecoveryEntry(itemID: itemID, record: $0)
            }
        }
    }

    /// Call only after the quarantined entry has been recovered or deliberately accepted by
    /// a higher-level recovery workflow. Ordinary remove retries preserve this signal.
    @discardableResult
    public func acknowledgeRecovery(for itemID: HeldFileID) throws -> HeldFileItem? {
        guard recoveryRecordsByID[itemID] != nil else {
            throw FileHoldError.itemNotFound
        }
        if itemsByID[itemID] == nil {
            recoveryRecordsByID[itemID] = nil
            uncommittedRecoveryIDs.removeAll { $0 == itemID }
            uncommittedRecoveryAccounting[itemID] = nil
            return nil
        }
        guard var item = itemsByID[itemID],
              let disposition = pendingCleanupDispositions[itemID] else {
            throw FileHoldError.itemNotFound
        }
        recoveryRecordsByID[itemID] = nil
        finalizeAccounting(for: itemID, item: item)
        item.status = disposition.status
        itemsByID[itemID] = item
        recordTerminal(itemID)
        return item
    }

    /// Disables new work, cancels every one-shot expiry, waits for active temporary-copy
    /// presentation leases, and attempts identity-proven cleanup of every retained item. Calling
    /// from the same dynamic presentation task throws; detached or legacy callback hops do not
    /// inherit that context and therefore must arrange shutdown only after the callback unwinds.
    public func shutdown() async throws -> FileHoldShutdownReport {
        guard !FileHoldPresentationContext.activeStoreIDs.contains(ObjectIdentifier(self)) else {
            throw FileHoldError.reentrantShutdownFromPresentation
        }
        shuttingDown = true
        for gate in reservationGates.values {
            gate.cancel()
        }
        for itemID in Array(expiryTasks.keys) {
            cancelExpiry(for: itemID)
        }
        if !activeTemporaryCopyLeases.isEmpty || !reservationGates.isEmpty {
            await withCheckedContinuation { continuation in
                workDrainWaiters.append(continuation)
            }
        }

        var results: [FileHoldCleanupResult] = []
        for itemID in Array(orderedIDs) {
            guard let item = itemsByID[itemID] else { continue }
            switch item.status {
            case .expired, .removed, .failed:
                continue
            case .available, .attentionRequired, .cleanupPending, .cleanupFailed:
                if let result = cleanup(itemID, disposition: .removed(at: now())) {
                    results.append(result)
                }
            }
        }
        return FileHoldShutdownReport(
            cleanupResults: results,
            recoveryEntries: recoveryEntries()
        )
    }

    /// The operation runs while all reference security scopes are held and releases every
    /// successfully started scope on success, thrown error, cancellation, or partial setup failure.
    public func withPresentationResources<Result: Sendable>(
        itemIDs: [HeldFileID],
        purpose _: FileHoldPresentationPurpose,
        operation: @Sendable ([FileHoldPresentationResource]) async throws -> Result
    ) async throws -> Result {
        guard !shuttingDown else {
            throw FileHoldError.storeShutDown
        }
        var resources: [FileHoldPresentationResource] = []
        var startedReferences: [ResolvedFileReference] = []
        var leasedTemporaryCopyIDs: [HeldFileID] = []

        do {
            for itemID in itemIDs {
                guard var item = itemsByID[itemID] else {
                    throw FileHoldError.itemNotFound
                }
                guard item.status.isAvailable else {
                    throw FileHoldError.itemUnavailable
                }

                let url: URL
                switch item.location {
                case let .temporaryCopy(copy):
                    url = try storage.validatedCopyURL(copy: copy)
                    activeTemporaryCopyLeases[itemID, default: 0] += 1
                    leasedTemporaryCopyIDs.append(itemID)
                case let .reference(bookmark):
                    let resolved: ResolvedFileReference
                    do {
                        resolved = try referenceCodec.resolveBookmark(bookmark)
                    } catch let error as FileHoldError {
                        throw error
                    } catch {
                        throw FileHoldError.bookmarkResolutionFailed
                    }
                    guard resolved.startAccessing() else {
                        throw FileHoldError.securityScopeDenied
                    }
                    startedReferences.append(resolved)
                    let refreshedSource = try storage.validateReferenceTarget(
                        resolved.url,
                        expectedSource: item.source,
                        maximumPathBytes: limits.maximumPathBytes,
                        maximumItemBytes: limits.maximumItemBytes
                    )
                    let byteDelta = refreshedSource.byteCount - item.source.byteCount
                    guard byteDelta <= limits.maximumTotalBytes - totalConsumedBytes else {
                        throw FileHoldError.totalSizeExceeded(
                            maximumBytes: limits.maximumTotalBytes
                        )
                    }
                    occupiedByteCount += byteDelta
                    item.source = refreshedSource
                    itemsByID[itemID] = item
                    url = refreshedSource.originalURL
                }
                resources.append(FileHoldPresentationResource(
                    itemID: item.id,
                    url: url,
                    displayName: item.source.displayName
                ))
            }
        } catch {
            for reference in startedReferences.reversed() {
                reference.stopAccessing()
            }
            releaseTemporaryCopyLeases(leasedTemporaryCopyIDs)
            throw error
        }

        defer {
            for reference in startedReferences.reversed() {
                reference.stopAccessing()
            }
            releaseTemporaryCopyLeases(leasedTemporaryCopyIDs)
        }
        var activeStoreIDs = FileHoldPresentationContext.activeStoreIDs
        activeStoreIDs.insert(ObjectIdentifier(self))
        return try await FileHoldPresentationContext.$activeStoreIDs.withValue(activeStoreIDs) {
            try await operation(resources)
        }
    }

    public func withAccessibleURL<Result: Sendable>(
        for itemID: HeldFileID,
        operation: @Sendable (URL) async throws -> Result
    ) async throws -> Result {
        try await withPresentationResources(
            itemIDs: [itemID],
            purpose: .quickLookPreview
        ) { resources in
            guard let resource = resources.first else {
                throw FileHoldError.itemNotFound
            }
            return try await operation(resource.url)
        }
    }

    private func cleanup(
        _ itemID: HeldFileID,
        disposition requestedDisposition: HeldFileTerminalDisposition
    ) -> FileHoldCleanupResult? {
        guard var item = itemsByID[itemID] else { return nil }
        switch item.status {
        case .expired, .removed, .failed:
            return FileHoldCleanupResult(item: item, outcome: .alreadyCleaned)
        case .available, .attentionRequired, .cleanupPending, .cleanupFailed:
            break
        }

        if let recoveryRecord = recoveryRecordsByID[itemID] {
            let error = FileHoldError.recoveryRequired(recoveryRecord)
            item.status = .cleanupFailed(
                error: error,
                disposition: pendingCleanupDispositions[itemID] ?? requestedDisposition,
                at: now()
            )
            itemsByID[itemID] = item
            return FileHoldCleanupResult(item: item, outcome: .failed(error))
        }

        let disposition = pendingCleanupDispositions[itemID] ?? requestedDisposition
        pendingCleanupDispositions[itemID] = disposition
        cancelExpiry(for: itemID)

        if case .temporaryCopy = item.location,
           activeTemporaryCopyLeases[itemID, default: 0] > 0 {
            item.status = .cleanupPending(disposition)
            itemsByID[itemID] = item
            return FileHoldCleanupResult(item: item, outcome: .deferredUntilLeaseEnds)
        }

        do {
            if case let .temporaryCopy(copy) = item.location {
                try storage.removeCopy(copy: copy)
            }
            finalizeAccounting(for: itemID, item: item)
            item.status = disposition.status
            itemsByID[itemID] = item
            recordTerminal(itemID)
            return FileHoldCleanupResult(item: item, outcome: .cleaned)
        } catch let error as FileHoldError {
            if case let .recoveryRequired(record) = error {
                if recoveryRecordsByID[itemID] == nil {
                    committedRecoveryAccounting[itemID] = record.accounting
                }
                recoveryRecordsByID[itemID] = record
            }
            item.status = .cleanupFailed(
                error: error,
                disposition: disposition,
                at: now()
            )
            itemsByID[itemID] = item
            return FileHoldCleanupResult(item: item, outcome: .failed(error))
        } catch {
            item.status = .cleanupFailed(
                error: .cleanupFailed,
                disposition: disposition,
                at: now()
            )
            itemsByID[itemID] = item
            return FileHoldCleanupResult(item: item, outcome: .failed(.cleanupFailed))
        }
    }

    private func scheduleExpiry(for itemID: HeldFileID, at deadline: Date) {
        guard nextExpiryNonce < UInt64.max else {
            markExpirySchedulerFailure(itemID)
            return
        }
        nextExpiryNonce += 1
        let nonce = nextExpiryNonce
        expiryNonces[itemID] = nonce
        let scheduler = expiryScheduler

        expiryTasks[itemID] = Task { [weak self] in
            do {
                try await scheduler.sleep(until: deadline)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await self?.expirySchedulerDidFail(itemID, nonce: nonce, deadline: deadline)
                return
            }
            guard !Task.isCancelled else { return }
            await self?.expire(itemID, nonce: nonce, deadline: deadline)
        }
    }

    private func cancelExpiry(for itemID: HeldFileID) {
        expiryTasks.removeValue(forKey: itemID)?.cancel()
        expiryNonces[itemID] = nil
    }

    private func expire(_ itemID: HeldFileID, nonce: UInt64, deadline: Date) {
        guard expiryNonces[itemID] == nonce,
              let item = itemsByID[itemID],
              item.status.isAvailable,
              item.expiresAt == deadline else {
            return
        }
        expiryTasks[itemID] = nil
        _ = cleanup(itemID, disposition: .expired(at: deadline))
    }

    private func expirySchedulerDidFail(
        _ itemID: HeldFileID,
        nonce: UInt64,
        deadline: Date
    ) {
        guard expiryNonces[itemID] == nonce,
              let item = itemsByID[itemID],
              item.status.isAvailable,
              item.expiresAt == deadline else {
            return
        }
        expiryTasks[itemID] = nil
        markExpirySchedulerFailure(itemID)
    }

    private func allocateUniqueID() throws -> HeldFileID {
        for _ in 0..<1_024 {
            let candidate = makeID()
            if itemsByID[candidate] == nil,
               recoveryRecordsByID[candidate] == nil,
               !reservedIDs.contains(candidate) {
                return candidate
            }
        }
        throw FileHoldError.identifierAllocationFailed
    }

    private func reserve(
        itemID: HeldFileID,
        source: HeldFileSource,
        gate: FileHoldOperationGate
    ) {
        reservedIDs.insert(itemID)
        reservationGates[itemID] = gate
        reservedItemCount += 1
        reservedByteCount += source.byteCount
        availableIdentityOwners[source.identity, default: []].append(itemID)
    }

    private func releaseReservation(itemID: HeldFileID, source: HeldFileSource) {
        reservedIDs.remove(itemID)
        reservationGates[itemID] = nil
        reservedItemCount -= 1
        reservedByteCount -= source.byteCount
        availableIdentityOwners[source.identity]?.removeAll { $0 == itemID }
        if availableIdentityOwners[source.identity]?.isEmpty == true {
            availableIdentityOwners[source.identity] = nil
        }
        resumeWorkDrainWaitersIfNeeded()
    }

    private func commitReservation(itemID: HeldFileID, source: HeldFileSource) {
        reservedIDs.remove(itemID)
        reservationGates[itemID] = nil
        reservedItemCount -= 1
        reservedByteCount -= source.byteCount
        occupiedItemCount += 1
        occupiedByteCount += source.byteCount
        resumeWorkDrainWaitersIfNeeded()
    }

    private func releaseTemporaryCopyLeases(_ itemIDs: [HeldFileID]) {
        for itemID in itemIDs {
            if let count = activeTemporaryCopyLeases[itemID], count > 1 {
                activeTemporaryCopyLeases[itemID] = count - 1
            } else {
                activeTemporaryCopyLeases[itemID] = nil
                if let disposition = pendingCleanupDispositions[itemID] {
                    _ = cleanup(itemID, disposition: disposition)
                }
            }
        }
        resumeWorkDrainWaitersIfNeeded()
    }

    private func isValidExpiry(_ expiration: Date, relativeTo currentTime: Date) -> Bool {
        guard expiration.timeIntervalSinceReferenceDate.isFinite,
              currentTime.timeIntervalSinceReferenceDate.isFinite else {
            return false
        }
        let interval = expiration.timeIntervalSince(currentTime)
        return interval.isFinite
            && interval > 0
            && interval <= limits.maximumExpiryInterval
    }

    private func expiryRemainsValid(_ expiration: Date, admittedAt: Date) -> Bool {
        let observedTime = now()
        return observedTime >= admittedAt
            && isValidExpiry(expiration, relativeTo: observedTime)
            && expiration.timeIntervalSince(admittedAt) <= limits.maximumExpiryInterval
    }

    private func cleanupUncommittedLocation(_ location: HeldFileLocation) -> FileHoldError? {
        guard case let .temporaryCopy(copy) = location else { return nil }
        do {
            try storage.removeCopy(copy: copy)
            return nil
        } catch let error as FileHoldError {
            return error
        } catch {
            return .cleanupFailed
        }
    }

    private func markExpirySchedulerFailure(_ itemID: HeldFileID) {
        guard var item = itemsByID[itemID], item.status.isAvailable else { return }
        expiryTasks[itemID] = nil
        expiryNonces[itemID] = nil
        item.status = .attentionRequired(error: .expirySchedulerFailed, at: now())
        itemsByID[itemID] = item
    }

    private func recordUncommittedRecovery(
        itemID: HeldFileID,
        record: FileHoldRecoveryRecord
    ) {
        if recoveryRecordsByID[itemID] == nil {
            uncommittedRecoveryIDs.append(itemID)
        }
        uncommittedRecoveryAccounting[itemID] = record.accounting
        recoveryRecordsByID[itemID] = record
    }

    private var totalConsumedBytes: Int64 {
        guard recoveryRecordsByID.count
            == committedRecoveryAccounting.count + uncommittedRecoveryAccounting.count,
              uncommittedRecoveryIDs.count == uncommittedRecoveryAccounting.count else {
            return Int64.max
        }
        var total = saturatedAdd(occupiedByteCount, reservedByteCount)
        for (itemID, accounting) in committedRecoveryAccounting {
            guard let item = itemsByID[itemID] else { return Int64.max }
            guard let recoveryByteCount = accounting.exactByteCount else {
                return Int64.max
            }
            total -= item.source.byteCount
            total = saturatedAdd(total, recoveryByteCount)
        }
        for accounting in uncommittedRecoveryAccounting.values {
            guard let recoveryByteCount = accounting.exactByteCount else {
                return Int64.max
            }
            total = saturatedAdd(total, recoveryByteCount)
        }
        return total
    }

    private func saturatedAdd(_ first: Int64, _ second: Int64) -> Int64 {
        let (sum, overflow) = first.addingReportingOverflow(second)
        return overflow ? Int64.max : sum
    }

    private func resumeWorkDrainWaitersIfNeeded() {
        guard activeTemporaryCopyLeases.isEmpty, reservationGates.isEmpty else { return }
        let waiters = workDrainWaiters
        workDrainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func finalizeAccounting(for itemID: HeldFileID, item: HeldFileItem) {
        availableIdentityOwners[item.source.identity]?.removeAll { $0 == itemID }
        if availableIdentityOwners[item.source.identity]?.isEmpty == true {
            availableIdentityOwners[item.source.identity] = nil
        }
        occupiedItemCount -= 1
        occupiedByteCount -= item.source.byteCount
        committedRecoveryAccounting[itemID] = nil
        pendingCleanupDispositions[itemID] = nil
        expiryNonces[itemID] = nil
    }

    private func recordTerminal(_ itemID: HeldFileID) {
        terminalIDs.append(itemID)
        while terminalIDs.count > limits.maximumTerminalHistoryCount {
            let removedID = terminalIDs.removeFirst()
            itemsByID[removedID] = nil
            orderedIDs.removeAll { $0 == removedID }
            expiryTasks.removeValue(forKey: removedID)?.cancel()
            expiryNonces[removedID] = nil
            pendingCleanupDispositions[removedID] = nil
            activeTemporaryCopyLeases[removedID] = nil
            recoveryRecordsByID[removedID] = nil
            committedRecoveryAccounting[removedID] = nil
        }
    }

    private func failureEntry(
        index: Int,
        url: URL,
        error: FileHoldError
    ) -> FileHoldIngestEntry {
        FileHoldIngestEntry(
            inputIndex: index,
            sourceURL: url,
            outcome: .failed(error)
        )
    }
}

private extension HeldFileTerminalDisposition {
    var status: HeldFileStatus {
        switch self {
        case let .expired(at):
            return .expired(at: at)
        case let .removed(at):
            return .removed(at: at)
        case let .failed(error, at):
            return .failed(error: error, at: at)
        }
    }
}
