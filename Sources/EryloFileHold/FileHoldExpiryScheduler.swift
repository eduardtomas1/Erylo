import Foundation

public protocol FileHoldExpiryScheduling: Sendable {
    func sleep(until deadline: Date) async throws
}

public struct OneShotFileHoldExpiryScheduler: FileHoldExpiryScheduling {
    public init() {}

    public func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        guard interval.isFinite else {
            throw FileHoldError.invalidExpiry
        }
        guard interval > 0 else { return }

        guard interval <= FileHoldIngestLimits.hardMaximumExpiryInterval else {
            throw FileHoldError.invalidExpiry
        }
        let roundedNanoseconds = (interval * 1_000_000_000).rounded(.up)
        guard roundedNanoseconds.isFinite,
              roundedNanoseconds >= 0,
              roundedNanoseconds <= Double(UInt64.max) else {
            throw FileHoldError.invalidExpiry
        }
        let nanoseconds = UInt64(roundedNanoseconds)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
