import EryloActivity
import Foundation

/// Public integration events are intentionally declarative: providers cannot submit code to execute.
public enum ActivityEvent: Equatable, Sendable {
    case submit(ActivityRequest)
    case cancel(ActivityIdentity)
}

public protocol ActivityProvider: Sendable {
    var identifier: String { get }
    func events() -> AsyncStream<ActivityEvent>
}

/// An explicit disabled provider. Its stream terminates immediately and starts no work.
public struct DisabledActivityProvider: ActivityProvider {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }

    public func events() -> AsyncStream<ActivityEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
