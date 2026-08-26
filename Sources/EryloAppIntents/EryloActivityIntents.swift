import AppIntents
import EryloLocalIntegrations
import Foundation

/// App-bundle code registers one gateway with `EryloAppIntentDependencies.register(_:)`.
public actor EryloAppIntentGateway {
    private let handler: any ActivityIntegrationHandling

    public init(handler: any ActivityIntegrationHandling) {
        self.handler = handler
    }

    func handle(_ request: ActivityIntegrationRequest) async throws -> ActivityIntegrationResponse {
        let response = await handler.handle(request)
        if let error = response.error {
            throw EryloAppIntentError.rejected(error.message)
        }
        return response
    }
}

public enum EryloAppIntentDependencies {
    /// Registration is explicit and performs no background work by itself.
    public static func register(_ gateway: EryloAppIntentGateway) {
        AppDependencyManager.shared.add(dependency: gateway)
    }
}

public struct EryloAppIntentsPackage: AppIntentsPackage {}

public struct SubmitEryloActivityIntent: AppIntent {
    public static let title: LocalizedStringResource = "Submit Erylo Activity"
    public static let description = IntentDescription("Submits a validated declarative activity to Erylo.")
    public static let openAppWhenRun = false

    @Parameter(title: "Identifier")
    public var identifier: String

    @Parameter(title: "Source", default: "external")
    public var source: String

    @Parameter(title: "Kind", default: "generic")
    public var kind: String

    @Parameter(title: "Priority", default: 50, inclusiveRange: (0, 100))
    public var priority: Int

    @Parameter(title: "Title")
    public var activityTitle: String

    @Parameter(title: "Detail")
    public var detail: String?

    @Parameter(title: "Progress")
    public var progress: Double?

    @Parameter(title: "Expiry in Milliseconds")
    public var ttlMilliseconds: Int?

    @Dependency
    private var gateway: EryloAppIntentGateway

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let request = try ActivityIntegrationRequest(
            operation: .submit,
            activity: ActivityIntegrationPayload(
                identifier: identifier,
                source: source,
                kind: kind,
                priority: priority,
                title: activityTitle,
                detail: detail,
                progress: progress,
                ttlMilliseconds: ttlMilliseconds
            )
        )
        _ = try await gateway.handle(request)
        return .result(dialog: "Activity submitted.")
    }
}

public struct CancelEryloActivityIntent: AppIntent {
    public static let title: LocalizedStringResource = "Cancel Erylo Activity"
    public static let description = IntentDescription("Cancels one Erylo activity by its validated identity.")
    public static let openAppWhenRun = false

    @Parameter(title: "Source", default: "external")
    public var source: String

    @Parameter(title: "Identifier")
    public var identifier: String

    @Dependency
    private var gateway: EryloAppIntentGateway

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let request = try ActivityIntegrationRequest(
            operation: .cancel,
            identity: ActivityIntegrationIdentity(source: source, identifier: identifier)
        )
        let response = try await gateway.handle(request)
        let cancelled = response.result?.cancelled == true
        let dialog: IntentDialog = cancelled
            ? "Activity cancelled."
            : "No matching activity was active."
        return .result(dialog: dialog)
    }
}

public struct EryloActivityStatusIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Erylo Activity Status"
    public static let description = IntentDescription("Reports the number of active Erylo activities.")
    public static let openAppWhenRun = false

    @Dependency
    private var gateway: EryloAppIntentGateway

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let request = try ActivityIntegrationRequest(operation: .status)
        let response = try await gateway.handle(request)
        let snapshot = response.result?.snapshot
        let count = (snapshot?.current == nil ? 0 : 1) + (snapshot?.queued.count ?? 0)
        return .result(dialog: "Erylo has \(count) active activities.")
    }
}

private enum EryloAppIntentError: LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case let .rejected(message): message
        }
    }
}
