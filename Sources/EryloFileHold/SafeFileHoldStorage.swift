import Darwin
import Foundation

struct InspectedSource: Sendable {
    let metadata: HeldFileSource
    let path: String
    fileprivate let fingerprint: SourceFingerprint
}

fileprivate struct SourceFingerprint: Equatable, Sendable {
    let identity: FileIdentity
    let byteCount: Int64
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let statusChangeSeconds: Int
    let statusChangeNanoseconds: Int

    init(_ value: stat) {
        identity = FileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino)
        )
        byteCount = Int64(value.st_size)
        modificationSeconds = value.st_mtimespec.tv_sec
        modificationNanoseconds = value.st_mtimespec.tv_nsec
        statusChangeSeconds = value.st_ctimespec.tv_sec
        statusChangeNanoseconds = value.st_ctimespec.tv_nsec
    }
}

final class SafeFileHoldStorage: @unchecked Sendable {
    private static let markerName = ".erylo-file-hold-root"
    private static let markerBytes = Array("Erylo File Hold Root v1\n".utf8)

    let rootURL: URL

    private let rootDescriptor: Int32
    private let rootIdentity: FileIdentity
    private let observer: any FileHoldStorageObserving

    init(
        rootURL: URL,
        observer: any FileHoldStorageObserving
    ) throws {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
            throw FileHoldError.unsafeStorage
        }

        let requestedURL = rootURL.standardizedFileURL
        let parentURL = requestedURL.deletingLastPathComponent()
        let leafName = requestedURL.lastPathComponent
        guard requestedURL != parentURL,
              Self.isSafeRelativeName(leafName) else {
            throw FileHoldError.unsafeStorage
        }

        let parentDescriptor = open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw FileHoldError.unsafeStorage
        }
        defer { close(parentDescriptor) }

        let mkdirResult = leafName.withCString {
            mkdirat(parentDescriptor, $0, S_IRWXU)
        }
        let createdDirectory: Bool
        if mkdirResult == 0 {
            createdDirectory = true
        } else if errno == EEXIST {
            createdDirectory = false
        } else {
            throw FileHoldError.unsafeStorage
        }

        let descriptor = leafName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw FileHoldError.unsafeStorage
        }

        var openedStat = stat()
        var pathStat = stat()
        guard fstat(descriptor, &openedStat) == 0,
              openedStat.st_mode & S_IFMT == S_IFDIR,
              openedStat.st_uid == geteuid(),
              lstat(requestedURL.path, &pathStat) == 0,
              pathStat.st_mode & S_IFMT == S_IFDIR,
              openedStat.st_dev == pathStat.st_dev,
              openedStat.st_ino == pathStat.st_ino else {
            if createdDirectory {
                Self.rollbackNewDirectory(
                    parentDescriptor: parentDescriptor,
                    rootDescriptor: descriptor,
                    leafName: leafName,
                    expectedIdentity: SourceFingerprint(openedStat).identity,
                    markerIdentity: nil
                )
            }
            close(descriptor)
            throw FileHoldError.unsafeStorage
        }

        let permissions = openedStat.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
        if createdDirectory {
            let rootIdentity = SourceFingerprint(openedStat).identity
            guard (permissions == S_IRWXU || fchmod(descriptor, S_IRWXU) == 0),
                  let markerIdentity = Self.createMarker(rootDescriptor: descriptor),
                  fsync(descriptor) == 0,
                  fsync(parentDescriptor) == 0 else {
                let markerIdentity = Self.markerIdentity(rootDescriptor: descriptor)
                Self.rollbackNewDirectory(
                    parentDescriptor: parentDescriptor,
                    rootDescriptor: descriptor,
                    leafName: leafName,
                    expectedIdentity: rootIdentity,
                    markerIdentity: markerIdentity
                )
                close(descriptor)
                throw FileHoldError.unsafeStorage
            }
            _ = markerIdentity
        } else {
            guard permissions == S_IRWXU,
                  Self.verifyMarker(rootDescriptor: descriptor) else {
                close(descriptor)
                throw FileHoldError.unsafeStorage
            }
        }

        self.rootURL = requestedURL
        self.observer = observer
        rootDescriptor = descriptor
        rootIdentity = FileIdentity(
            device: UInt64(openedStat.st_dev),
            inode: UInt64(openedStat.st_ino)
        )
    }

    deinit {
        close(rootDescriptor)
    }

    func inspectSource(_ url: URL, maximumPathBytes: Int) throws -> InspectedSource {
        guard url.isFileURL else {
            throw FileHoldError.notFileURL
        }
        if let host = url.host, !host.isEmpty, host != "localhost" {
            throw FileHoldError.nonLocalFileURL
        }

        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path
        guard path.hasPrefix("/") else {
            throw FileHoldError.nonLocalFileURL
        }
        guard path.utf8.count <= maximumPathBytes else {
            throw FileHoldError.pathTooLong(maximumBytes: maximumPathBytes)
        }

        var sourceStat = stat()
        guard lstat(path, &sourceStat) == 0 else {
            throw FileHoldError.sourceMissing
        }

        switch sourceStat.st_mode & S_IFMT {
        case S_IFLNK:
            throw FileHoldError.sourceIsSymbolicLink
        case S_IFREG:
            break
        default:
            throw FileHoldError.sourceIsNotRegularFile
        }

        let modificationDate = Date(
            timeIntervalSince1970: TimeInterval(sourceStat.st_mtimespec.tv_sec)
                + TimeInterval(sourceStat.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        let fingerprint = SourceFingerprint(sourceStat)
        let metadata = HeldFileSource(
            originalURL: standardizedURL,
            displayName: standardizedURL.lastPathComponent,
            byteCount: fingerprint.byteCount,
            modificationDate: modificationDate,
            identity: fingerprint.identity
        )
        return InspectedSource(metadata: metadata, path: path, fingerprint: fingerprint)
    }

    func sourceIsUnchanged(_ original: InspectedSource, _ current: InspectedSource) -> Bool {
        original.fingerprint == current.fingerprint
    }

    func validateReferenceTarget(
        _ url: URL,
        expectedSource: HeldFileSource,
        maximumPathBytes: Int,
        maximumItemBytes: Int64
    ) throws -> HeldFileSource {
        let inspected = try inspectSource(url, maximumPathBytes: maximumPathBytes)
        guard inspected.metadata.identity == expectedSource.identity else {
            throw FileHoldError.referenceTargetChanged
        }
        guard inspected.metadata.byteCount <= maximumItemBytes else {
            throw FileHoldError.itemTooLarge(
                maximumBytes: maximumItemBytes,
                actualBytes: inspected.metadata.byteCount
            )
        }
        return inspected.metadata
    }

    func copySource(
        _ source: InspectedSource,
        itemID: HeldFileID,
        observer: any FileHoldCopyObserving,
        shouldCommit: @Sendable () -> Bool
    ) async throws -> HeldFileCopy {
        guard rootIsUnchanged() else {
            throw FileHoldError.unsafeStorage
        }
        if Task.isCancelled {
            throw FileHoldError.cancelled
        }

        let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw FileHoldError.copyFailed
        }
        defer { close(sourceDescriptor) }

        var sourceStat = stat()
        guard fstat(sourceDescriptor, &sourceStat) == 0,
              sourceStat.st_mode & S_IFMT == S_IFREG else {
            throw FileHoldError.copyFailed
        }
        guard SourceFingerprint(sourceStat) == source.fingerprint else {
            throw FileHoldError.sourceChangedDuringCopy
        }

        let (stageName, stageDescriptor) = try createStage(itemID: itemID)
        defer { close(stageDescriptor) }

        var initialStageStat = stat()
        guard fstat(stageDescriptor, &initialStageStat) == 0,
              initialStageStat.st_mode & S_IFMT == S_IFREG else {
            throw FileHoldError.copyFailed
        }
        let stageIdentity = FileIdentity(
            device: UInt64(initialStageStat.st_dev),
            inode: UInt64(initialStageStat.st_ino)
        )
        var ownedPublishedName: String? = stageName

        do {
            let copiedByteCount = try await copyBytes(
                from: sourceDescriptor,
                to: stageDescriptor,
                maximumBytes: source.metadata.byteCount,
                observer: observer,
                shouldCommit: shouldCommit
            )
            var finalSourceStat = stat()
            guard copiedByteCount == source.metadata.byteCount,
                  fstat(sourceDescriptor, &finalSourceStat) == 0,
                  SourceFingerprint(finalSourceStat) == source.fingerprint else {
                throw FileHoldError.sourceChangedDuringCopy
            }
            guard fsync(stageDescriptor) == 0 else {
                throw FileHoldError.copyFailed
            }
            if Task.isCancelled {
                throw FileHoldError.cancelled
            }
            guard shouldCommit() else {
                throw FileHoldError.invalidExpiry
            }

            var storedStat = stat()
            guard fstat(stageDescriptor, &storedStat) == 0,
                  storedStat.st_mode & S_IFMT == S_IFREG,
                  storedStat.st_nlink == 1,
                  FileIdentity(
                      device: UInt64(storedStat.st_dev),
                      inode: UInt64(storedStat.st_ino)
                  ) == stageIdentity,
                  Int64(storedStat.st_size) == source.metadata.byteCount else {
                throw FileHoldError.copyFailed
            }

            var collisionIndex = 1
            while collisionIndex <= 1_024 {
                guard shouldCommit() else {
                    throw FileHoldError.invalidExpiry
                }
                let destinationName = collisionSafeName(
                    source.metadata.displayName,
                    collisionIndex: collisionIndex
                )
                let result = stageName.withCString { stage in
                    destinationName.withCString { destination in
                        renameatx_np(
                            rootDescriptor,
                            stage,
                            rootDescriptor,
                            destination,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                if result == 0 {
                    ownedPublishedName = destinationName
                    await observer.didPublishCandidate(relativeName: destinationName)
                    if Task.isCancelled {
                        throw FileHoldError.cancelled
                    }
                    guard shouldCommit() else {
                        throw FileHoldError.invalidExpiry
                    }

                    var postPublishSourceStat = stat()
                    var destinationStat = stat()
                    let destinationInspection = destinationName.withCString {
                        fstatat(rootDescriptor, $0, &destinationStat, AT_SYMLINK_NOFOLLOW)
                    }
                    guard fstat(sourceDescriptor, &postPublishSourceStat) == 0,
                          SourceFingerprint(postPublishSourceStat) == source.fingerprint,
                          destinationInspection == 0,
                          destinationStat.st_mode & S_IFMT == S_IFREG,
                          destinationStat.st_nlink == 1,
                          FileIdentity(
                              device: UInt64(destinationStat.st_dev),
                              inode: UInt64(destinationStat.st_ino)
                          ) == stageIdentity,
                          Int64(destinationStat.st_size) == source.metadata.byteCount else {
                        throw FileHoldError.sourceChangedDuringCopy
                    }
                    guard shouldCommit() else {
                        throw FileHoldError.invalidExpiry
                    }
                    ownedPublishedName = nil
                    return HeldFileCopy(
                        relativeName: destinationName,
                        identity: stageIdentity,
                        byteCount: source.metadata.byteCount
                    )
                }
                guard errno == EEXIST else {
                    throw FileHoldError.copyFailed
                }
                collisionIndex += 1
            }
            throw FileHoldError.copyFailed
        } catch let error as FileHoldError {
            if let ownedPublishedName {
                do {
                    try removeExpectedEntry(
                        relativeName: ownedPublishedName,
                        expectedIdentity: stageIdentity,
                        expectedByteCount: nil
                    )
                } catch let cleanupError as FileHoldError {
                    throw cleanupError
                }
            }
            throw error
        } catch {
            if let ownedPublishedName {
                do {
                    try removeExpectedEntry(
                        relativeName: ownedPublishedName,
                        expectedIdentity: stageIdentity,
                        expectedByteCount: nil
                    )
                } catch let cleanupError as FileHoldError {
                    throw cleanupError
                }
            }
            throw FileHoldError.copyFailed
        }
    }

    func validatedCopyURL(copy: HeldFileCopy) throws -> URL {
        guard rootIsUnchanged(), Self.isSafeRelativeName(copy.relativeName) else {
            throw FileHoldError.unsafeStorage
        }

        var itemStat = stat()
        let result = copy.relativeName.withCString {
            fstatat(rootDescriptor, $0, &itemStat, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              itemStat.st_mode & S_IFMT == S_IFREG,
              Self.matches(itemStat, copy: copy) else {
            throw FileHoldError.unsafeStorage
        }
        return rootURL.appendingPathComponent(copy.relativeName, isDirectory: false)
    }

    func removeCopy(copy: HeldFileCopy) throws {
        guard rootIsUnchanged(), Self.isSafeRelativeName(copy.relativeName) else {
            throw FileHoldError.unsafeStorage
        }
        try removeExpectedEntry(
            relativeName: copy.relativeName,
            expectedIdentity: copy.identity,
            expectedByteCount: copy.byteCount
        )
    }

    private func rootIsUnchanged() -> Bool {
        var pathStat = stat()
        var descriptorStat = stat()
        guard lstat(rootURL.path, &pathStat) == 0,
              pathStat.st_mode & S_IFMT == S_IFDIR,
              fstat(rootDescriptor, &descriptorStat) == 0,
              descriptorStat.st_mode & S_IFMT == S_IFDIR,
              descriptorStat.st_uid == geteuid(),
              descriptorStat.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO) == S_IRWXU,
              Self.verifyMarker(rootDescriptor: rootDescriptor) else {
            return false
        }
        let pathIdentity = FileIdentity(
            device: UInt64(pathStat.st_dev),
            inode: UInt64(pathStat.st_ino)
        )
        let descriptorIdentity = FileIdentity(
            device: UInt64(descriptorStat.st_dev),
            inode: UInt64(descriptorStat.st_ino)
        )
        return rootIdentity == pathIdentity && rootIdentity == descriptorIdentity
    }

    private func createStage(itemID: HeldFileID) throws -> (name: String, descriptor: Int32) {
        let safeID = itemID.rawValue.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let prefix = ".erylo-stage-"
        for index in 1...1_024 {
            let suffix = "-\(index)"
            let identifierBudget = 200 - prefix.utf8.count - suffix.utf8.count
            let boundedID = Self.utf8Prefix(String(safeID), maximumBytes: identifierBudget)
            let candidate = prefix + boundedID + suffix
            guard candidate.utf8.count <= 200 else {
                throw FileHoldError.copyFailed
            }
            let descriptor = candidate.withCString { name in
                openat(
                    rootDescriptor,
                    name,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR
                )
            }
            if descriptor >= 0 {
                return (candidate, descriptor)
            }
            guard errno == EEXIST else { throw FileHoldError.copyFailed }
        }
        throw FileHoldError.copyFailed
    }

    private func copyBytes(
        from source: Int32,
        to destination: Int32,
        maximumBytes: Int64,
        observer: any FileHoldCopyObserving,
        shouldCommit: @Sendable () -> Bool
    ) async throws -> Int64 {
        let bufferSize = 256 * 1_024
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }

        var totalBytes: Int64 = 0
        while true {
            if Task.isCancelled {
                throw FileHoldError.cancelled
            }
            guard shouldCommit() else {
                throw FileHoldError.invalidExpiry
            }

            let bytesRead = readRetryingInterrupts(source, buffer, bufferSize)
            if bytesRead == 0 { return totalBytes }
            guard bytesRead > 0 else {
                throw FileHoldError.copyFailed
            }
            guard Int64(bytesRead) <= maximumBytes - totalBytes else {
                throw FileHoldError.sourceChangedDuringCopy
            }
            totalBytes += Int64(bytesRead)

            var written = 0
            while written < bytesRead {
                let result = writeRetryingInterrupts(
                    destination,
                    buffer.advanced(by: written),
                    bytesRead - written
                )
                guard result > 0 else {
                    throw FileHoldError.copyFailed
                }
                written += result
            }
            await observer.didCopy(byteCount: totalBytes)
            if Task.isCancelled {
                throw FileHoldError.cancelled
            }
            guard shouldCommit() else {
                throw FileHoldError.invalidExpiry
            }
            await Task.yield()
        }
    }

    private func quarantine(relativeName: String) throws -> String? {
        for _ in 0..<64 {
            let quarantineName = ".erylo-cleanup-\(UUID().uuidString.lowercased())"
            let result = relativeName.withCString { source in
                quarantineName.withCString { destination in
                    renameatx_np(
                        rootDescriptor,
                        source,
                        rootDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if result == 0 { return quarantineName }
            if errno == ENOENT { return nil }
            if errno == EEXIST { continue }
            throw FileHoldError.cleanupFailed
        }
        throw FileHoldError.cleanupFailed
    }

    private func removeExpectedEntry(
        relativeName: String,
        expectedIdentity: FileIdentity,
        expectedByteCount: Int64?
    ) throws {
        guard rootIsUnchanged(), Self.isSafeRelativeName(relativeName) else {
            throw FileHoldError.unsafeStorage
        }

        let boundDescriptor = relativeName.withCString {
            openat(rootDescriptor, $0, O_EVTONLY | O_SYMLINK | O_CLOEXEC)
        }
        guard boundDescriptor >= 0 else {
            if errno == ENOENT { return }
            throw FileHoldError.unsafeStorage
        }
        defer { close(boundDescriptor) }

        var boundStat = stat()
        guard fstat(boundDescriptor, &boundStat) == 0 else {
            throw FileHoldError.unsafeStorage
        }
        let boundIdentity = FileIdentity(
            device: UInt64(boundStat.st_dev),
            inode: UInt64(boundStat.st_ino)
        )

        guard let quarantineName = try quarantine(relativeName: relativeName) else {
            throw FileHoldError.recoveryRequired(
                lastKnownRecoveryRecord(relativeName: relativeName)
            )
        }

        var preObserverStat = stat()
        let preObserverInspection = quarantineName.withCString {
            fstatat(rootDescriptor, $0, &preObserverStat, AT_SYMLINK_NOFOLLOW)
        }
        guard preObserverInspection == 0,
              FileIdentity(
                  device: UInt64(preObserverStat.st_dev),
                  inode: UInt64(preObserverStat.st_ino)
              ) == boundIdentity else {
            throw FileHoldError.recoveryRequired(
                lastKnownRecoveryRecord(relativeName: quarantineName)
            )
        }

        observer.didQuarantineEntry(
            relativeName: quarantineName,
            originalName: relativeName
        )

        var quarantinedStat = stat()
        let inspection = quarantineName.withCString {
            fstatat(rootDescriptor, $0, &quarantinedStat, AT_SYMLINK_NOFOLLOW)
        }
        let quarantinedIdentity = FileIdentity(
            device: UInt64(quarantinedStat.st_dev),
            inode: UInt64(quarantinedStat.st_ino)
        )
        guard inspection == 0, quarantinedIdentity == boundIdentity else {
            throw FileHoldError.recoveryRequired(
                lastKnownRecoveryRecord(relativeName: quarantineName)
            )
        }

        let identityMatches = quarantinedStat.st_mode & S_IFMT == S_IFREG
            && quarantinedStat.st_nlink == 1
            && quarantinedIdentity == expectedIdentity
        let sizeMatches = expectedByteCount.map { Int64(quarantinedStat.st_size) == $0 } ?? true
        guard identityMatches && sizeMatches else {
            try restoreQuarantine(
                quarantineName,
                relativeName: relativeName,
                boundIdentity: boundIdentity
            )
            throw FileHoldError.unsafeStorage
        }

        guard quarantineName.withCString({ unlinkat(rootDescriptor, $0, 0) }) == 0 else {
            try restoreQuarantine(
                quarantineName,
                relativeName: relativeName,
                boundIdentity: boundIdentity
            )
            throw FileHoldError.cleanupFailed
        }
    }

    private func restoreQuarantine(
        _ quarantineName: String,
        relativeName: String,
        boundIdentity: FileIdentity
    ) throws {
        let result = quarantineName.withCString { source in
            relativeName.withCString { destination in
                renameatx_np(
                    rootDescriptor,
                    source,
                    rootDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            let recovery = recoveryRecord(
                relativeName: quarantineName,
                boundIdentity: boundIdentity
            )
            throw FileHoldError.recoveryRequired(
                FileHoldRecoveryRecord(
                    locator: recovery.locator,
                    accounting: recovery.accounting
                )
            )
        }
    }

    private func recoveryRecord(
        relativeName: String,
        boundIdentity: FileIdentity
    ) -> (locator: FileHoldRecoveryLocator, accounting: FileHoldRecoveryAccounting) {
        var recoveryStat = stat()
        let recoveryInspection = relativeName.withCString {
            fstatat(rootDescriptor, $0, &recoveryStat, AT_SYMLINK_NOFOLLOW)
        }
        let recoveryIdentity = FileIdentity(
            device: UInt64(recoveryStat.st_dev),
            inode: UInt64(recoveryStat.st_ino)
        )
        guard recoveryInspection == 0, recoveryIdentity == boundIdentity else {
            return (
                .lastKnownRelativeName(relativeName),
                .unquantifiable
            )
        }
        guard recoveryStat.st_mode & S_IFMT == S_IFREG,
              recoveryStat.st_nlink == 1,
              recoveryStat.st_size >= 0 else {
            return (
                .exactRelativeName(relativeName),
                .unquantifiable
            )
        }
        return (
            .exactRelativeName(relativeName),
            .exactRegularFile(
                byteCount: Int64(recoveryStat.st_size),
                identity: recoveryIdentity
            )
        )
    }

    private func lastKnownRecoveryRecord(relativeName: String) -> FileHoldRecoveryRecord {
        FileHoldRecoveryRecord(
            locator: .lastKnownRelativeName(relativeName),
            accounting: .unquantifiable
        )
    }

    private func collisionSafeName(_ originalName: String, collisionIndex: Int) -> String {
        let sanitized = Self.sanitizedName(originalName)
        let nsName = sanitized as NSString
        let rawBase = nsName.deletingPathExtension
        let rawExtension = nsName.pathExtension
        let suffix = collisionIndex == 1 ? "" : " \(collisionIndex)"
        let maximumBytes = 200
        let minimumBase = rawBase.isEmpty ? "Held File" : rawBase
        var extensionPart = rawExtension.isEmpty ? "" : ".\(rawExtension)"
        let maximumExtensionBytes = max(0, maximumBytes - suffix.utf8.count - 1)
        extensionPart = Self.utf8Prefix(extensionPart, maximumBytes: maximumExtensionBytes)
        let baseBudget = maximumBytes - suffix.utf8.count - extensionPart.utf8.count
        var base = Self.utf8Prefix(minimumBase, maximumBytes: baseBudget)
        if base.isEmpty {
            base = Self.utf8Prefix("Held File", maximumBytes: baseBudget)
        }
        return base + suffix + extensionPart
    }

    private static func sanitizedName(_ name: String) -> String {
        let filtered = name.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "/" {
                return "_"
            }
            return Character(String(scalar))
        }
        let result = String(filtered)
        return result.isEmpty || result == "." || result == ".." ? "Held File" : result
    }

    private static func isSafeRelativeName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && URL(fileURLWithPath: name).lastPathComponent == name
    }

    private static func matches(_ value: stat, copy: HeldFileCopy) -> Bool {
        FileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino)
        ) == copy.identity
            && value.st_nlink == 1
            && Int64(value.st_size) == copy.byteCount
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var result = ""
        result.reserveCapacity(min(value.count, maximumBytes))
        for character in value {
            let nextByteCount = result.utf8.count + String(character).utf8.count
            guard nextByteCount <= maximumBytes else { break }
            result.append(character)
        }
        return result
    }

    private static func createMarker(rootDescriptor: Int32) -> FileIdentity? {
        let markerDescriptor = markerName.withCString { name in
            openat(
                rootDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard markerDescriptor >= 0 else { return nil }
        defer { close(markerDescriptor) }

        var markerStat = stat()
        guard fstat(markerDescriptor, &markerStat) == 0 else { return nil }
        let identity = SourceFingerprint(markerStat).identity
        let wroteMarker = markerBytes.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let result = writeRetryingInterrupts(
                    markerDescriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                guard result > 0 else { return false }
                offset += result
            }
            return true
        }
        guard wroteMarker, fsync(markerDescriptor) == 0 else {
            _ = removeExpectedMarker(rootDescriptor: rootDescriptor, expectedIdentity: identity)
            return nil
        }
        return identity
    }

    private static func verifyMarker(rootDescriptor: Int32) -> Bool {
        let markerDescriptor = markerName.withCString { name in
            openat(rootDescriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard markerDescriptor >= 0 else { return false }
        defer { close(markerDescriptor) }

        var markerStat = stat()
        guard fstat(markerDescriptor, &markerStat) == 0,
              markerStat.st_mode & S_IFMT == S_IFREG,
              markerStat.st_uid == geteuid(),
              markerStat.st_nlink == 1,
              markerStat.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO) == (S_IRUSR | S_IWUSR),
              markerStat.st_size == markerBytes.count else {
            return false
        }

        var bytes = [UInt8](repeating: 0, count: markerBytes.count)
        let readResult = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return readRetryingInterrupts(
                markerDescriptor,
                baseAddress,
                buffer.count
            )
        }
        return readResult == markerBytes.count && bytes == markerBytes
    }

    private static func markerIdentity(rootDescriptor: Int32) -> FileIdentity? {
        var markerStat = stat()
        let result = markerName.withCString {
            fstatat(rootDescriptor, $0, &markerStat, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0, markerStat.st_mode & S_IFMT == S_IFREG else { return nil }
        return SourceFingerprint(markerStat).identity
    }

    private static func removeExpectedMarker(
        rootDescriptor: Int32,
        expectedIdentity: FileIdentity
    ) -> Bool {
        let quarantineName = ".erylo-marker-rollback-\(UUID().uuidString.lowercased())"
        let moved = markerName.withCString { source in
            quarantineName.withCString { destination in
                renameatx_np(
                    rootDescriptor,
                    source,
                    rootDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard moved == 0 else { return false }

        var movedStat = stat()
        let inspected = quarantineName.withCString {
            fstatat(rootDescriptor, $0, &movedStat, AT_SYMLINK_NOFOLLOW)
        }
        let matches = inspected == 0
            && movedStat.st_mode & S_IFMT == S_IFREG
            && SourceFingerprint(movedStat).identity == expectedIdentity
        guard matches else {
            _ = quarantineName.withCString { source in
                markerName.withCString { destination in
                    renameatx_np(
                        rootDescriptor,
                        source,
                        rootDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            return false
        }
        return quarantineName.withCString { unlinkat(rootDescriptor, $0, 0) } == 0
    }

    private static func rollbackNewDirectory(
        parentDescriptor: Int32,
        rootDescriptor: Int32,
        leafName: String,
        expectedIdentity: FileIdentity,
        markerIdentity: FileIdentity?
    ) {
        if let markerIdentity {
            _ = removeExpectedMarker(
                rootDescriptor: rootDescriptor,
                expectedIdentity: markerIdentity
            )
        }

        let quarantineName = ".erylo-root-rollback-\(UUID().uuidString.lowercased())"
        let moved = leafName.withCString { source in
            quarantineName.withCString { destination in
                renameatx_np(
                    parentDescriptor,
                    source,
                    parentDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard moved == 0 else { return }

        var movedStat = stat()
        let inspected = quarantineName.withCString {
            fstatat(parentDescriptor, $0, &movedStat, AT_SYMLINK_NOFOLLOW)
        }
        guard inspected == 0,
              movedStat.st_mode & S_IFMT == S_IFDIR,
              SourceFingerprint(movedStat).identity == expectedIdentity,
              quarantineName.withCString({ unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }) == 0 else {
            _ = quarantineName.withCString { source in
                leafName.withCString { destination in
                    renameatx_np(
                        parentDescriptor,
                        source,
                        parentDescriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            return
        }
        _ = fsync(parentDescriptor)
    }
}

private func readRetryingInterrupts(
    _ descriptor: Int32,
    _ buffer: UnsafeMutableRawPointer,
    _ count: Int
) -> Int {
    while true {
        let result = Darwin.read(descriptor, buffer, count)
        if result < 0, errno == EINTR { continue }
        return result
    }
}

private func writeRetryingInterrupts(
    _ descriptor: Int32,
    _ buffer: UnsafeRawPointer,
    _ count: Int
) -> Int {
    while true {
        let result = Darwin.write(descriptor, buffer, count)
        if result < 0, errno == EINTR { continue }
        return result
    }
}
