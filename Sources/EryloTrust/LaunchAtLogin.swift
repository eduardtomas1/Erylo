import ServiceManagement

public enum LaunchAtLoginCapability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
}

public enum LaunchAtLoginRegistrationState: String, Codable, Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval = "requires-approval"
    case unavailable
}

public enum LaunchAtLoginFailure: String, Codable, Error, Equatable, Sendable {
    case registrationFailed = "registration-failed"
    case unregistrationFailed = "unregistration-failed"
}

public struct LaunchAtLoginSnapshot: Codable, Equatable, Sendable {
    public let capability: LaunchAtLoginCapability
    public let registrationState: LaunchAtLoginRegistrationState
    public let failure: LaunchAtLoginFailure?

    public init(
        capability: LaunchAtLoginCapability,
        registrationState: LaunchAtLoginRegistrationState,
        failure: LaunchAtLoginFailure? = nil
    ) {
        self.capability = capability
        self.registrationState = registrationState
        self.failure = failure
    }

    public var isEnabled: Bool {
        registrationState == .enabled
    }

    public static let unavailable = LaunchAtLoginSnapshot(
        capability: .unavailable,
        registrationState: .unavailable
    )
}

@MainActor
public protocol LaunchAtLoginControlling: AnyObject, Sendable {
    func snapshot() -> LaunchAtLoginSnapshot
    func setEnabled(_ enabled: Bool) -> LaunchAtLoginSnapshot
}

/// Public SMAppService adapter for the containing application. It never shells out, writes a
/// launch agent, or claims success until SMAppService reports the resulting state.
@MainActor
public final class SystemLaunchAtLoginController: LaunchAtLoginControlling {
    private let service: SMAppService

    public init(service: SMAppService = .mainApp) {
        self.service = service
    }

    public func snapshot() -> LaunchAtLoginSnapshot {
        Self.snapshot(for: service.status)
    }

    public func setEnabled(_ enabled: Bool) -> LaunchAtLoginSnapshot {
        let initial = snapshot()
        if enabled, initial.registrationState == .enabled {
            return initial
        }
        if !enabled, initial.registrationState == .disabled {
            return initial
        }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            return snapshot()
        } catch {
            let current = snapshot()
            return LaunchAtLoginSnapshot(
                capability: current.capability,
                registrationState: current.registrationState,
                failure: enabled ? .registrationFailed : .unregistrationFailed
            )
        }
    }

    private static func snapshot(for status: SMAppService.Status) -> LaunchAtLoginSnapshot {
        switch status {
        case .notRegistered:
            LaunchAtLoginSnapshot(capability: .available, registrationState: .disabled)
        case .enabled:
            LaunchAtLoginSnapshot(capability: .available, registrationState: .enabled)
        case .requiresApproval:
            LaunchAtLoginSnapshot(capability: .available, registrationState: .requiresApproval)
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }
}
