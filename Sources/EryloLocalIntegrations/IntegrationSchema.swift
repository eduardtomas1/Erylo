import EryloActivity
import Foundation

public enum ActivityIntegrationAPI {
    public static let version = 1
    public static let maximumRequestBodyBytes = 16 * 1_024
    public static let maximumResponseBodyBytes = 256 * 1_024
    public static let maximumURLBytes = 4 * 1_024
    public static let maximumCommandLineBytes = 16 * 1_024
    public static let maximumCommandLineArguments = 32
    public static let maximumRequestIdentifierBytes = 64
}

public enum ActivityIntegrationOperation: String, Codable, Equatable, Sendable {
    case submit
    case cancel
    case status
}

public struct ActivityIntegrationPayload: Codable, Equatable, Sendable {
    public let identifier: String
    public let source: String
    public let kind: String
    public let priority: Int
    public let title: String
    public let detail: String?
    public let progress: Double?
    public let actionIdentifier: String?
    public let actionLabel: String?
    public let actionIntent: String?
    public let ttlMilliseconds: Int?

    public init(
        identifier: String,
        source: String,
        kind: String,
        priority: Int,
        title: String,
        detail: String? = nil,
        progress: Double? = nil,
        actionIdentifier: String? = nil,
        actionLabel: String? = nil,
        actionIntent: String? = nil,
        ttlMilliseconds: Int? = nil
    ) {
        self.identifier = identifier
        self.source = source
        self.kind = kind
        self.priority = priority
        self.title = title
        self.detail = detail
        self.progress = progress
        self.actionIdentifier = actionIdentifier
        self.actionLabel = actionLabel
        self.actionIntent = actionIntent
        self.ttlMilliseconds = ttlMilliseconds
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case identifier
        case source
        case kind
        case priority
        case title
        case detail
        case progress
        case actionIdentifier
        case actionLabel
        case actionIntent
        case ttlMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        source = try container.decode(String.self, forKey: .source)
        kind = try container.decode(String.self, forKey: .kind)
        priority = try container.decode(Int.self, forKey: .priority)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        actionIdentifier = try container.decodeIfPresent(String.self, forKey: .actionIdentifier)
        actionLabel = try container.decodeIfPresent(String.self, forKey: .actionLabel)
        actionIntent = try container.decodeIfPresent(String.self, forKey: .actionIntent)
        ttlMilliseconds = try container.decodeIfPresent(Int.self, forKey: .ttlMilliseconds)
    }

    var activityRequest: ActivityRequest {
        ActivityRequest(
            identifier: identifier,
            source: source,
            kind: kind,
            priority: priority,
            title: title,
            detail: detail,
            progress: progress,
            actionIdentifier: actionIdentifier,
            actionLabel: actionLabel,
            actionIntent: actionIntent,
            ttlMilliseconds: ttlMilliseconds
        )
    }
}

public struct ActivityIntegrationIdentity: Codable, Equatable, Sendable {
    public let source: String
    public let identifier: String

    public init(source: String, identifier: String) {
        self.source = source
        self.identifier = identifier
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source
        case identifier
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        identifier = try container.decode(String.self, forKey: .identifier)
    }
}

public struct ActivityIntegrationRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let requestIdentifier: String?
    public let operation: ActivityIntegrationOperation
    public let activity: ActivityIntegrationPayload?
    public let identity: ActivityIntegrationIdentity?

    public init(
        version: Int = ActivityIntegrationAPI.version,
        requestIdentifier: String? = nil,
        operation: ActivityIntegrationOperation,
        activity: ActivityIntegrationPayload? = nil,
        identity: ActivityIntegrationIdentity? = nil
    ) throws {
        self.version = version
        self.requestIdentifier = requestIdentifier
        self.operation = operation
        self.activity = activity
        self.identity = identity
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case requestIdentifier
        case operation
        case activity
        case identity
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        requestIdentifier = try container.decodeIfPresent(String.self, forKey: .requestIdentifier)
        operation = try container.decode(ActivityIntegrationOperation.self, forKey: .operation)
        activity = try container.decodeIfPresent(ActivityIntegrationPayload.self, forKey: .activity)
        identity = try container.decodeIfPresent(ActivityIntegrationIdentity.self, forKey: .identity)
        try validate()
    }

    private func validate() throws {
        guard version == ActivityIntegrationAPI.version else {
            throw ActivityIntegrationSchemaError.unsupportedVersion(version)
        }
        if let requestIdentifier {
            guard !requestIdentifier.isEmpty,
                  requestIdentifier.utf8.count <= ActivityIntegrationAPI.maximumRequestIdentifierBytes,
                  requestIdentifier.unicodeScalars.allSatisfy(Self.requestIdentifierCharacters.contains) else {
                throw ActivityIntegrationSchemaError.invalidRequestIdentifier
            }
        }

        switch operation {
        case .submit:
            guard activity != nil, identity == nil else {
                throw ActivityIntegrationSchemaError.invalidShape("submit requires activity and forbids identity")
            }
        case .cancel:
            guard activity == nil, identity != nil else {
                throw ActivityIntegrationSchemaError.invalidShape("cancel requires identity and forbids activity")
            }
        case .status:
            guard activity == nil, identity == nil else {
                throw ActivityIntegrationSchemaError.invalidShape("status forbids activity and identity")
            }
        }
    }

    private static let requestIdentifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"
    )
}

public enum ActivityIntegrationSchemaError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyBody
    case bodyTooLarge(maximumBytes: Int)
    case malformedBody
    case unknownField(String)
    case duplicateField(String)
    case unsupportedVersion(Int)
    case invalidRequestIdentifier
    case invalidShape(String)

    public var description: String {
        switch self {
        case .emptyBody:
            "request body must not be empty"
        case let .bodyTooLarge(maximumBytes):
            "request body exceeds \(maximumBytes) bytes"
        case .malformedBody:
            "request body is not valid strict JSON"
        case let .unknownField(field):
            "unknown field '\(SafeIntegrationDiagnostic.token(field))'"
        case let .duplicateField(field):
            "duplicate field '\(SafeIntegrationDiagnostic.token(field))'"
        case let .unsupportedVersion(version):
            "unsupported API version \(version)"
        case .invalidRequestIdentifier:
            "requestIdentifier has an invalid format"
        case let .invalidShape(message):
            message
        }
    }
}

public enum ActivityIntegrationErrorCode: String, Codable, Equatable, Sendable {
    case invalidRequest = "invalid_request"
    case unsupportedVersion = "unsupported_version"
    case activityCapacityExceeded = "activity_capacity_exceeded"
    case frameTooLarge = "frame_too_large"
    case serverBusy = "server_busy"
    case peerRejected = "peer_rejected"
    case requestLimitExceeded = "request_limit_exceeded"
    case requestTimeout = "request_timeout"
    case cancelled
    case internalError = "internal_error"
}

public struct ActivityIntegrationErrorPayload: Codable, Equatable, Sendable {
    public let code: ActivityIntegrationErrorCode
    public let message: String

    public init(code: ActivityIntegrationErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ActivityIntegrationActivityView: Codable, Equatable, Sendable {
    public let identifier: String
    public let source: String
    public let kind: String
    public let priority: Int
    public let title: String
    public let detail: String?
    public let progress: Double?
    public let actionIdentifier: String?
    public let actionLabel: String?
    public let actionIntent: String?
    public let ttlMilliseconds: Int?
    public let submissionSequence: UInt64
    public let revision: UInt64

    init(_ presented: PresentedActivity) {
        let activity = presented.activity
        identifier = activity.identity.identifier.rawValue
        source = activity.identity.source.rawValue
        kind = activity.kind.rawValue
        priority = activity.priority.rawValue
        title = activity.presentation.title
        detail = activity.presentation.detail
        progress = activity.presentation.progress?.fractionCompleted
        actionIdentifier = activity.action?.identifier
        actionLabel = activity.action?.label
        actionIntent = activity.action?.intent.rawValue
        if case let .expires(ttl) = activity.lifecycle {
            ttlMilliseconds = ttl.rawValue
        } else {
            ttlMilliseconds = nil
        }
        submissionSequence = presented.submissionSequence
        revision = presented.revision
    }
}

public struct ActivityIntegrationSnapshot: Codable, Equatable, Sendable {
    public let version: UInt64
    public let current: ActivityIntegrationActivityView?
    public let queued: [ActivityIntegrationActivityView]

    init(_ snapshot: ActivityBrokerSnapshot) {
        version = snapshot.version
        current = snapshot.current.map(ActivityIntegrationActivityView.init)
        queued = snapshot.queued.map(ActivityIntegrationActivityView.init)
    }
}

public struct ActivityIntegrationResult: Codable, Equatable, Sendable {
    public let operation: ActivityIntegrationOperation
    public let accepted: Bool?
    public let cancelled: Bool?
    public let snapshot: ActivityIntegrationSnapshot

    public init(
        operation: ActivityIntegrationOperation,
        accepted: Bool? = nil,
        cancelled: Bool? = nil,
        snapshot: ActivityIntegrationSnapshot
    ) {
        self.operation = operation
        self.accepted = accepted
        self.cancelled = cancelled
        self.snapshot = snapshot
    }
}

public struct ActivityIntegrationResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let requestIdentifier: String?
    public let result: ActivityIntegrationResult?
    public let error: ActivityIntegrationErrorPayload?

    public var isSuccess: Bool { result != nil && error == nil }

    public static func success(
        requestIdentifier: String?,
        result: ActivityIntegrationResult
    ) -> Self {
        Self(
            version: ActivityIntegrationAPI.version,
            requestIdentifier: requestIdentifier,
            result: result,
            error: nil
        )
    }

    public static func failure(
        requestIdentifier: String? = nil,
        code: ActivityIntegrationErrorCode,
        message: String
    ) -> Self {
        Self(
            version: ActivityIntegrationAPI.version,
            requestIdentifier: requestIdentifier,
            result: nil,
            error: ActivityIntegrationErrorPayload(code: code, message: message)
        )
    }
}

public enum ActivityIntegrationCodec {
    public static func decodeRequest(_ data: Data) throws -> ActivityIntegrationRequest {
        guard !data.isEmpty else { throw ActivityIntegrationSchemaError.emptyBody }
        guard data.count <= ActivityIntegrationAPI.maximumRequestBodyBytes else {
            throw ActivityIntegrationSchemaError.bodyTooLarge(
                maximumBytes: ActivityIntegrationAPI.maximumRequestBodyBytes
            )
        }
        do {
            try StrictJSONPreflight.validate(data)
            return try JSONDecoder().decode(ActivityIntegrationRequest.self, from: data)
        } catch let error as ActivityIntegrationSchemaError {
            throw error
        } catch {
            throw ActivityIntegrationSchemaError.malformedBody
        }
    }

    public static func encodeResponse(_ response: ActivityIntegrationResponse) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(response),
              encoded.count <= ActivityIntegrationAPI.maximumResponseBodyBytes else {
            return Data(
                "{\"error\":{\"code\":\"internal_error\",\"message\":\"response encoding failed\"},\"version\":1}"
                    .utf8
            )
        }
        return encoded
    }

    public static func response(for error: any Error, requestIdentifier: String? = nil) -> ActivityIntegrationResponse {
        if let schemaError = error as? ActivityIntegrationSchemaError {
            let code: ActivityIntegrationErrorCode
            if case .unsupportedVersion = schemaError {
                code = .unsupportedVersion
            } else {
                code = .invalidRequest
            }
            return .failure(requestIdentifier: requestIdentifier, code: code, message: schemaError.description)
        }
        return .failure(requestIdentifier: requestIdentifier, code: .invalidRequest, message: "invalid request")
    }
}

enum SafeIntegrationDiagnostic {
    static func token(_ value: String, maximumCharacters: Int = 64) -> String {
        var output = ""
        output.reserveCapacity(min(value.count, maximumCharacters) + 3)
        var characterCount = 0
        var wasTruncated = false
        for scalar in value.unicodeScalars {
            guard characterCount < maximumCharacters else {
                wasTruncated = true
                break
            }
            if scalar.isASCII,
               (scalar.properties.isAlphabetic || scalar.properties.numericType != nil || "._:-".unicodeScalars.contains(scalar)) {
                output.unicodeScalars.append(scalar)
            } else {
                output.append("?")
            }
            characterCount += 1
        }
        if wasTruncated { output.append("...") }
        return output.isEmpty ? "?" : output
    }

    static func validationMessage(_ error: ActivityValidationError) -> String {
        switch error {
        case let .empty(field):
            "\(field.rawValue) must not be empty"
        case let .tooLarge(field, maximumBytes):
            "\(field.rawValue) exceeds \(maximumBytes) UTF-8 bytes"
        case let .invalidFormat(field):
            "\(field.rawValue) has an invalid format"
        case let .unknownValue(field, _):
            "\(field.rawValue) contains an unknown value"
        case let .outOfRange(field, minimum, maximum):
            "\(field.rawValue) must be in \(minimum)...\(maximum)"
        }
    }
}

private struct ArbitraryCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private func rejectUnknownKeys<Key>(in decoder: any Decoder, allowed: Key.Type) throws
where Key: CodingKey & CaseIterable, Key.AllCases: Sequence {
    let container = try decoder.container(keyedBy: ArbitraryCodingKey.self)
    let allowedNames = Set(Key.allCases.map(\.stringValue))
    if let unknown = container.allKeys.map(\.stringValue).filter({ !allowedNames.contains($0) }).sorted().first {
        throw ActivityIntegrationSchemaError.unknownField(unknown)
    }
}
