import EryloActivity
import Foundation

public protocol ActivityIntegrationHandling: Sendable {
    func handle(
        _ request: ActivityIntegrationRequest,
        lease: ActivityIntegrationLease
    ) async -> ActivityIntegrationResponse
}

public extension ActivityIntegrationHandling {
    func handle(_ request: ActivityIntegrationRequest) async -> ActivityIntegrationResponse {
        await handle(request, lease: ActivityIntegrationLease())
    }
}

/// A transport invalidates this lease before stop returns. Acquired broker mutations drain first.
public final class ActivityIntegrationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var activePermitCount = 0
    private var invalidationWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    func acquirePermit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { return false }
        activePermitCount += 1
        return true
    }

    func releasePermit() {
        lock.lock()
        activePermitCount -= 1
        let waiters: [CheckedContinuation<Void, Never>]
        if !valid, activePermitCount == 0 {
            waiters = invalidationWaiters
            invalidationWaiters.removeAll()
        } else {
            waiters = []
        }
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func invalidateNow() {
        lock.lock()
        valid = false
        let waiters: [CheckedContinuation<Void, Never>]
        if activePermitCount == 0 {
            waiters = invalidationWaiters
            invalidationWaiters.removeAll()
        } else {
            waiters = []
        }
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func invalidateAndWait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            valid = false
            if activePermitCount == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                invalidationWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// The only public bridge to broker mutations. Routes receive this protocol, never the broker actor.
public actor ActivityIntegrationController: ActivityIntegrationHandling {
    private let broker: ActivityBroker

    public init() {
        broker = ActivityBroker()
    }

    /// Injects the process-wide broker while keeping every route behind the handling protocol.
    public init(broker: ActivityBroker) {
        self.broker = broker
    }

    public func handle(
        _ request: ActivityIntegrationRequest,
        lease: ActivityIntegrationLease
    ) async -> ActivityIntegrationResponse {
        if Task.isCancelled || !lease.acquirePermit() {
            return .failure(
                requestIdentifier: request.requestIdentifier,
                code: .cancelled,
                message: "request cancelled"
            )
        }
        defer { lease.releasePermit() }

        do {
            let result: ActivityIntegrationResult
            switch request.operation {
            case .submit:
                guard let activity = request.activity else {
                    return .failure(
                        requestIdentifier: request.requestIdentifier,
                        code: .invalidRequest,
                        message: "submit requires activity"
                    )
                }
                let snapshot = try await broker.submit(activity.activityRequest)
                result = ActivityIntegrationResult(
                    operation: .submit,
                    accepted: true,
                    snapshot: ActivityIntegrationSnapshot(snapshot)
                )
            case .cancel:
                guard let identity = request.identity else {
                    return .failure(
                        requestIdentifier: request.requestIdentifier,
                        code: .invalidRequest,
                        message: "cancel requires identity"
                    )
                }
                let activityIdentity = try ActivityIdentity(
                    source: ActivitySource(validating: identity.source),
                    identifier: ActivityIdentifier(validating: identity.identifier)
                )
                let cancelled = await broker.cancel(activityIdentity)
                result = ActivityIntegrationResult(
                    operation: .cancel,
                    cancelled: cancelled,
                    snapshot: ActivityIntegrationSnapshot(await broker.snapshot())
                )
            case .status:
                result = ActivityIntegrationResult(
                    operation: .status,
                    snapshot: ActivityIntegrationSnapshot(await broker.snapshot())
                )
            }
            return .success(requestIdentifier: request.requestIdentifier, result: result)
        } catch let error as ActivityBrokerError {
            switch error {
            case .activityCapacityExceeded:
                return .failure(
                    requestIdentifier: request.requestIdentifier,
                    code: .activityCapacityExceeded,
                    message: error.description
                )
            case .invalid, .subscriberCapacityExceeded:
                let message: String
                if case let .invalid(validationError) = error {
                    message = SafeIntegrationDiagnostic.validationMessage(validationError)
                } else {
                    message = "snapshot subscriber capacity reached"
                }
                return .failure(
                    requestIdentifier: request.requestIdentifier,
                    code: .invalidRequest,
                    message: message
                )
            }
        } catch let error as ActivityValidationError {
            return .failure(
                requestIdentifier: request.requestIdentifier,
                code: .invalidRequest,
                message: SafeIntegrationDiagnostic.validationMessage(error)
            )
        } catch {
            return .failure(
                requestIdentifier: request.requestIdentifier,
                code: .internalError,
                message: "request handling failed"
            )
        }
    }
}
