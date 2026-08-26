public protocol FileHoldCopyObserving: Sendable {
    func didCopy(byteCount: Int64) async
    func didPublishCandidate(relativeName: String) async
}

public extension FileHoldCopyObserving {
    func didCopy(byteCount _: Int64) async {}
    func didPublishCandidate(relativeName _: String) async {}
}

public struct DisabledFileHoldCopyObserver: FileHoldCopyObserving {
    public init() {}

    public func didCopy(byteCount _: Int64) async {}
    public func didPublishCandidate(relativeName _: String) async {}
}

/// A deterministic seam for adversarial storage tests. Production callers use the disabled
/// implementation; callbacks must return promptly and must not enter `FileHoldStore`.
public protocol FileHoldStorageObserving: Sendable {
    func didQuarantineEntry(relativeName: String, originalName: String)
}

public struct DisabledFileHoldStorageObserver: FileHoldStorageObserving {
    public init() {}

    public func didQuarantineEntry(relativeName _: String, originalName _: String) {}
}
