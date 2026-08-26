import Foundation

public enum ActivityIntegrationRouteError: Error, Equatable, Sendable, CustomStringConvertible {
    case inputTooLarge(maximumBytes: Int)
    case tooManyArguments(maximum: Int)
    case invalidRoute
    case unsupportedVersion(String)
    case unknownOperation(String)
    case unknownParameter(String)
    case duplicateParameter(String)
    case missingParameter(String)
    case invalidValue(String)

    public var description: String {
        switch self {
        case let .inputTooLarge(maximumBytes):
            "input exceeds \(maximumBytes) bytes"
        case let .tooManyArguments(maximum):
            "argument count exceeds \(maximum)"
        case .invalidRoute:
            "invalid integration route"
        case let .unsupportedVersion(version):
            "unsupported route version '\(SafeIntegrationDiagnostic.token(version))'"
        case let .unknownOperation(operation):
            "unknown operation '\(SafeIntegrationDiagnostic.token(operation))'"
        case let .unknownParameter(parameter):
            "unknown parameter '\(SafeIntegrationDiagnostic.token(parameter))'"
        case let .duplicateParameter(parameter):
            "duplicate parameter '\(SafeIntegrationDiagnostic.token(parameter))'"
        case let .missingParameter(parameter):
            "missing parameter '\(SafeIntegrationDiagnostic.token(parameter))'"
        case let .invalidValue(parameter):
            "invalid value for '\(SafeIntegrationDiagnostic.token(parameter))'"
        }
    }
}

enum ActivityIntegrationRequestBuilder {
    private static let submitParameters: Set<String> = [
        "requestIdentifier", "identifier", "source", "kind", "priority", "title", "detail",
        "progress", "actionIdentifier", "actionLabel", "actionIntent", "ttlMilliseconds",
    ]
    private static let cancelParameters: Set<String> = ["requestIdentifier", "identifier", "source"]
    private static let statusParameters: Set<String> = ["requestIdentifier"]

    static func build(
        operationName: String,
        parameters: [String: String]
    ) throws -> ActivityIntegrationRequest {
        guard let operation = ActivityIntegrationOperation(rawValue: operationName) else {
            throw ActivityIntegrationRouteError.unknownOperation(operationName)
        }

        let allowed: Set<String>
        switch operation {
        case .submit:
            allowed = submitParameters
        case .cancel:
            allowed = cancelParameters
        case .status:
            allowed = statusParameters
        }
        if let unknown = parameters.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw ActivityIntegrationRouteError.unknownParameter(unknown)
        }

        switch operation {
        case .submit:
            let payload = ActivityIntegrationPayload(
                identifier: try required("identifier", in: parameters),
                source: try required("source", in: parameters),
                kind: try required("kind", in: parameters),
                priority: try integer("priority", in: parameters),
                title: try required("title", in: parameters),
                detail: parameters["detail"],
                progress: try optionalDouble("progress", in: parameters),
                actionIdentifier: parameters["actionIdentifier"],
                actionLabel: parameters["actionLabel"],
                actionIntent: parameters["actionIntent"],
                ttlMilliseconds: try optionalInteger("ttlMilliseconds", in: parameters)
            )
            return try ActivityIntegrationRequest(
                requestIdentifier: parameters["requestIdentifier"],
                operation: .submit,
                activity: payload
            )
        case .cancel:
            return try ActivityIntegrationRequest(
                requestIdentifier: parameters["requestIdentifier"],
                operation: .cancel,
                identity: ActivityIntegrationIdentity(
                    source: try required("source", in: parameters),
                    identifier: try required("identifier", in: parameters)
                )
            )
        case .status:
            return try ActivityIntegrationRequest(
                requestIdentifier: parameters["requestIdentifier"],
                operation: .status
            )
        }
    }

    private static func required(_ name: String, in parameters: [String: String]) throws -> String {
        guard let value = parameters[name] else {
            throw ActivityIntegrationRouteError.missingParameter(name)
        }
        return value
    }

    private static func integer(_ name: String, in parameters: [String: String]) throws -> Int {
        let raw = try required(name, in: parameters)
        guard let value = Int(raw) else { throw ActivityIntegrationRouteError.invalidValue(name) }
        return value
    }

    private static func optionalInteger(_ name: String, in parameters: [String: String]) throws -> Int? {
        guard let raw = parameters[name] else { return nil }
        guard let value = Int(raw) else { throw ActivityIntegrationRouteError.invalidValue(name) }
        return value
    }

    private static func optionalDouble(_ name: String, in parameters: [String: String]) throws -> Double? {
        guard let raw = parameters[name] else { return nil }
        guard let value = Double(raw), value.isFinite else {
            throw ActivityIntegrationRouteError.invalidValue(name)
        }
        return value
    }
}

extension ActivityIntegrationCodec {
    static func response(for routeError: ActivityIntegrationRouteError) -> ActivityIntegrationResponse {
        let code: ActivityIntegrationErrorCode
        if case .unsupportedVersion = routeError {
            code = .unsupportedVersion
        } else {
            code = .invalidRequest
        }
        return .failure(code: code, message: routeError.description)
    }
}
