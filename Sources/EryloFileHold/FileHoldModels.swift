import Foundation

public enum FileHoldMode: String, Codable, Sendable {
    /// Erylo owns a private copy. Removing the held item may only remove that copy.
    case temporaryCopy

    /// Erylo retains a bookmark and never owns or mutates the referenced file.
    case reference
}

public enum FileHoldDuplicatePolicy: String, Codable, Sendable {
    /// Reject a source whose filesystem identity is already available in the hold.
    case reject

    /// Create a distinct held item even when the same source was already ingested.
    case allow
}

public struct FileHoldIngestLimits: Equatable, Sendable {
    public static let hardMaximumInputCount = 1_024
    public static let hardMaximumItemCount = 256
    public static let hardMaximumItemBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    public static let hardMaximumTotalBytes: Int64 = 16 * 1_024 * 1_024 * 1_024
    public static let hardMaximumPathBytes = 16 * 1_024
    public static let hardMaximumBookmarkBytes = 256 * 1_024
    public static let hardMaximumExpiryInterval: TimeInterval = 365 * 24 * 60 * 60
    public static let hardMaximumTerminalHistoryCount = 1_024

    public var maximumInputCount: Int
    public var maximumItemCount: Int
    public var maximumItemBytes: Int64
    public var maximumTotalBytes: Int64
    public var maximumPathBytes: Int
    public var maximumBookmarkBytes: Int
    public var maximumExpiryInterval: TimeInterval
    public var maximumTerminalHistoryCount: Int

    public init(
        maximumInputCount: Int = 256,
        maximumItemCount: Int = 64,
        maximumItemBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumTotalBytes: Int64 = 4 * 1_024 * 1_024 * 1_024,
        maximumPathBytes: Int = 4_096,
        maximumBookmarkBytes: Int = 64 * 1_024,
        maximumExpiryInterval: TimeInterval = 30 * 24 * 60 * 60,
        maximumTerminalHistoryCount: Int = 128
    ) {
        self.maximumInputCount = maximumInputCount
        self.maximumItemCount = maximumItemCount
        self.maximumItemBytes = maximumItemBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumPathBytes = maximumPathBytes
        self.maximumBookmarkBytes = maximumBookmarkBytes
        self.maximumExpiryInterval = maximumExpiryInterval
        self.maximumTerminalHistoryCount = maximumTerminalHistoryCount
    }

    var isValid: Bool {
        maximumInputCount > 0 && maximumInputCount <= Self.hardMaximumInputCount
            && maximumItemCount > 0 && maximumItemCount <= Self.hardMaximumItemCount
            && maximumItemBytes >= 0 && maximumItemBytes <= Self.hardMaximumItemBytes
            && maximumTotalBytes >= 0 && maximumTotalBytes <= Self.hardMaximumTotalBytes
            && maximumPathBytes > 0 && maximumPathBytes <= Self.hardMaximumPathBytes
            && maximumBookmarkBytes > 0
            && maximumBookmarkBytes <= Self.hardMaximumBookmarkBytes
            && maximumExpiryInterval.isFinite
            && maximumExpiryInterval > 0
            && maximumExpiryInterval <= Self.hardMaximumExpiryInterval
            && maximumTerminalHistoryCount >= 0
            && maximumTerminalHistoryCount <= Self.hardMaximumTerminalHistoryCount
    }
}

public struct FileHoldIngestOptions: Equatable, Sendable {
    public var mode: FileHoldMode
    public var duplicatePolicy: FileHoldDuplicatePolicy
    public var expiresAt: Date?

    public init(
        mode: FileHoldMode,
        duplicatePolicy: FileHoldDuplicatePolicy = .reject,
        expiresAt: Date? = nil
    ) {
        self.mode = mode
        self.duplicatePolicy = duplicatePolicy
        self.expiresAt = expiresAt
    }
}

public struct HeldFileID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct FileIdentity: Hashable, Codable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct HeldFileSource: Equatable, Codable, Sendable {
    public let originalURL: URL
    public let displayName: String
    public let byteCount: Int64
    public let modificationDate: Date
    public let identity: FileIdentity

    public init(
        originalURL: URL,
        displayName: String,
        byteCount: Int64,
        modificationDate: Date,
        identity: FileIdentity
    ) {
        self.originalURL = originalURL
        self.displayName = displayName
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.identity = identity
    }
}

public enum FileHoldRecoveryAccounting: Equatable, Codable, Sendable {
    /// Exact accounting is permitted only for a no-follow inspected regular file with one link.
    case exactRegularFile(byteCount: Int64, identity: FileIdentity)

    /// Directories, links, special files, or otherwise unverifiable content are never traversed.
    /// The store blocks further byte admission until the recovery is acknowledged.
    case unquantifiable

    public var exactByteCount: Int64? {
        guard case let .exactRegularFile(byteCount, _) = self else { return nil }
        return byteCount
    }
}

public enum FileHoldRecoveryLocator: Equatable, Codable, Sendable {
    /// The retained entry was visible at this app-generated root-relative name when recorded.
    case exactRelativeName(String)

    /// The app-generated name disappeared or no longer names the descriptor-bound entry. The
    /// store does not scan or guess where another actor moved it; this is the last known locator.
    case lastKnownRelativeName(String)

    public var relativeName: String {
        switch self {
        case let .exactRelativeName(name), let .lastKnownRelativeName(name):
            return name
        }
    }
}

public struct FileHoldRecoveryRecord: Equatable, Codable, Sendable {
    /// Privacy-safe locator relative to the app-owned File Hold root.
    public let locator: FileHoldRecoveryLocator
    /// Fail-closed capacity treatment for the retained entry.
    public let accounting: FileHoldRecoveryAccounting

    public var relativeName: String { locator.relativeName }

    public init(
        locator: FileHoldRecoveryLocator,
        accounting: FileHoldRecoveryAccounting
    ) {
        self.locator = locator
        self.accounting = accounting
    }
}

public enum FileHoldError: Error, Equatable, Codable, Sendable {
    case invalidConfiguration
    case notFileURL
    case nonLocalFileURL
    case pathTooLong(maximumBytes: Int)
    case tooManyInputs(maximum: Int)
    case tooManyItems(maximum: Int)
    case sourceMissing
    case sourceIsSymbolicLink
    case sourceIsNotRegularFile
    case itemTooLarge(maximumBytes: Int64, actualBytes: Int64)
    case totalSizeExceeded(maximumBytes: Int64)
    case duplicate(existingItemID: HeldFileID)
    case identifierAllocationFailed
    case invalidExpiry
    case sourceChangedDuringCopy
    case copyFailed
    case bookmarkCreationFailed
    case bookmarkTooLarge(maximumBytes: Int)
    case bookmarkResolutionFailed
    case staleBookmark
    case securityScopeDenied
    case referenceTargetChanged
    case expirySchedulerFailed
    case storeShutDown
    case reentrantShutdownFromPresentation
    case cancelled
    case itemNotFound
    case itemUnavailable
    case unsafeStorage
    case cleanupFailed
    case recoveryRequired(FileHoldRecoveryRecord)
    case unsupportedDragRepresentation
    case invalidDragRepresentation
    case dragRepresentationTooLarge(maximumBytes: Int)
    case dragRepresentationTimedOut
    case dragTimeoutSchedulingFailed
}

public struct HeldFileCopy: Equatable, Codable, Sendable {
    /// A single path component relative to the injected, app-owned root.
    public let relativeName: String
    public let identity: FileIdentity
    public let byteCount: Int64

    public init(relativeName: String, identity: FileIdentity, byteCount: Int64) {
        self.relativeName = relativeName
        self.identity = identity
        self.byteCount = byteCount
    }
}

public enum HeldFileLocation: Equatable, Codable, Sendable {
    case temporaryCopy(HeldFileCopy)
    case reference(bookmark: Data)
}

public enum HeldFileTerminalDisposition: Equatable, Codable, Sendable {
    case expired(at: Date)
    case removed(at: Date)
    case failed(error: FileHoldError, at: Date)
}

public enum HeldFileStatus: Equatable, Codable, Sendable {
    case available
    case attentionRequired(error: FileHoldError, at: Date)
    case cleanupPending(HeldFileTerminalDisposition)
    case cleanupFailed(
        error: FileHoldError,
        disposition: HeldFileTerminalDisposition,
        at: Date
    )
    case expired(at: Date)
    case removed(at: Date)
    case failed(error: FileHoldError, at: Date)

    public var isAvailable: Bool {
        switch self {
        case .available, .attentionRequired:
            return true
        case .cleanupPending, .cleanupFailed, .expired, .removed, .failed:
            return false
        }
    }
}

public struct HeldFileItem: Equatable, Codable, Sendable {
    public let id: HeldFileID
    public let mode: FileHoldMode
    public var source: HeldFileSource
    public let location: HeldFileLocation
    public let createdAt: Date
    public var expiresAt: Date?
    public var status: HeldFileStatus

    init(
        id: HeldFileID,
        mode: FileHoldMode,
        source: HeldFileSource,
        location: HeldFileLocation,
        createdAt: Date,
        expiresAt: Date?,
        status: HeldFileStatus
    ) {
        self.id = id
        self.mode = mode
        self.source = source
        self.location = location
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.status = status
    }
}

public enum FileHoldIngestOutcome: Equatable, Sendable {
    case held(HeldFileItem)
    case failed(FileHoldError)
}

public struct FileHoldIngestEntry: Equatable, Sendable {
    public let inputIndex: Int
    public let sourceURL: URL
    public let outcome: FileHoldIngestOutcome

    public init(inputIndex: Int, sourceURL: URL, outcome: FileHoldIngestOutcome) {
        self.inputIndex = inputIndex
        self.sourceURL = sourceURL
        self.outcome = outcome
    }
}

public struct FileHoldIngestReport: Equatable, Sendable {
    public let entries: [FileHoldIngestEntry]
    public let unprocessedInputCount: Int

    public init(entries: [FileHoldIngestEntry], unprocessedInputCount: Int = 0) {
        self.entries = entries
        self.unprocessedInputCount = unprocessedInputCount
    }

    public var heldItems: [HeldFileItem] {
        entries.compactMap { entry in
            guard case let .held(item) = entry.outcome else { return nil }
            return item
        }
    }

    public var failures: [FileHoldIngestEntry] {
        entries.filter { entry in
            if case .failed = entry.outcome { return true }
            return false
        }
    }
}

public enum FileHoldCleanupOutcome: Equatable, Sendable {
    case cleaned
    case deferredUntilLeaseEnds
    case alreadyCleaned
    case failed(FileHoldError)
}

public struct FileHoldCleanupResult: Equatable, Sendable {
    public let item: HeldFileItem
    public let outcome: FileHoldCleanupOutcome

    public init(item: HeldFileItem, outcome: FileHoldCleanupOutcome) {
        self.item = item
        self.outcome = outcome
    }
}

public struct FileHoldRecoveryEntry: Equatable, Sendable {
    public let itemID: HeldFileID
    public let record: FileHoldRecoveryRecord

    public init(itemID: HeldFileID, record: FileHoldRecoveryRecord) {
        self.itemID = itemID
        self.record = record
    }
}

public struct FileHoldShutdownReport: Equatable, Sendable {
    public let cleanupResults: [FileHoldCleanupResult]
    public let recoveryEntries: [FileHoldRecoveryEntry]

    public init(
        cleanupResults: [FileHoldCleanupResult],
        recoveryEntries: [FileHoldRecoveryEntry]
    ) {
        self.cleanupResults = cleanupResults
        self.recoveryEntries = recoveryEntries
    }
}

public enum FileHoldPresentationPurpose: String, Sendable {
    case quickLookThumbnail
    case quickLookPreview
    case share
}

public struct FileHoldPresentationResource: Equatable, Sendable {
    public let itemID: HeldFileID
    public let url: URL
    public let displayName: String

    public init(itemID: HeldFileID, url: URL, displayName: String) {
        self.itemID = itemID
        self.url = url
        self.displayName = displayName
    }
}
