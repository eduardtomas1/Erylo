import Foundation

/// Shared conservative input limits for providers and future URL, CLI, and socket routes.
public enum ActivityLimits {
    public static let identifierBytes = 128
    public static let sourceBytes = 32
    public static let kindBytes = 32
    public static let titleBytes = 160
    public static let detailBytes = 320
    public static let actionIdentifierBytes = 64
    public static let actionLabelBytes = 80
    public static let actionIntentBytes = 32
    public static let presentationBytes = 512
    public static let minimumTTLMilliseconds = 1
    public static let maximumTTLMilliseconds = 86_400_000
    public static let minimumPriority = 0
    public static let maximumPriority = 100
    public static let maximumActivityCount = 128
    public static let maximumSubscriberCount = 32
}

public enum ActivityValidationField: String, Equatable, Sendable {
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
    case presentation
    case ttlMilliseconds
}

public enum ActivityValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty(ActivityValidationField)
    case tooLarge(ActivityValidationField, maximumBytes: Int)
    case invalidFormat(ActivityValidationField)
    case unknownValue(ActivityValidationField, String)
    case outOfRange(ActivityValidationField, minimum: Int, maximum: Int)

    public var description: String {
        switch self {
        case let .empty(field):
            "\(field.rawValue) must not be empty"
        case let .tooLarge(field, maximumBytes):
            "\(field.rawValue) exceeds \(maximumBytes) UTF-8 bytes"
        case let .invalidFormat(field):
            "\(field.rawValue) has an invalid format"
        case let .unknownValue(field, value):
            "\(field.rawValue) contains unknown value '\(value)'"
        case let .outOfRange(field, minimum, maximum):
            "\(field.rawValue) must be in \(minimum)...\(maximum)"
        }
    }
}

public enum ActivityBrokerError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(ActivityValidationError)
    case activityCapacityExceeded(maximum: Int)
    case subscriberCapacityExceeded(maximum: Int)

    public var description: String {
        switch self {
        case let .invalid(error):
            error.description
        case let .activityCapacityExceeded(maximum):
            "activity capacity of \(maximum) reached"
        case let .subscriberCapacityExceeded(maximum):
            "snapshot subscriber capacity of \(maximum) reached"
        }
    }
}

public enum ActivitySource: String, CaseIterable, Codable, Sendable {
    case battery
    case timer
    case calendar
    case volume
    case appleMusic = "apple-music"
    case spotify
    case fileHold = "file-hold"
    case external

    public init(validating value: String) throws(ActivityValidationError) {
        guard !value.isEmpty else { throw .empty(.source) }
        guard value.utf8.count <= ActivityLimits.sourceBytes else {
            throw .tooLarge(.source, maximumBytes: ActivityLimits.sourceBytes)
        }
        guard let source = Self(rawValue: value) else {
            throw .unknownValue(.source, value)
        }
        self = source
    }
}

public enum ActivityKind: String, CaseIterable, Codable, Sendable {
    case charging
    case battery
    case timer
    case meeting
    case volume
    case media
    case file
    case generic

    public init(validating value: String) throws(ActivityValidationError) {
        guard !value.isEmpty else { throw .empty(.kind) }
        guard value.utf8.count <= ActivityLimits.kindBytes else {
            throw .tooLarge(.kind, maximumBytes: ActivityLimits.kindBytes)
        }
        guard let kind = Self(rawValue: value) else {
            throw .unknownValue(.kind, value)
        }
        self = kind
    }
}

public struct ActivityIdentifier: Hashable, Sendable {
    public let rawValue: String

    public init(validating value: String) throws(ActivityValidationError) {
        try Self.validate(value)
        rawValue = value
    }

    private static func validate(_ value: String) throws(ActivityValidationError) {
        guard !value.isEmpty else { throw .empty(.identifier) }
        guard value.utf8.count <= ActivityLimits.identifierBytes else {
            throw .tooLarge(.identifier, maximumBytes: ActivityLimits.identifierBytes)
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard value.unicodeScalars.allSatisfy(allowed.contains),
              value.unicodeScalars.first.map(CharacterSet.alphanumerics.contains) == true else {
            throw .invalidFormat(.identifier)
        }
    }
}

public struct ActivityIdentity: Hashable, Sendable {
    public let source: ActivitySource
    public let identifier: ActivityIdentifier

    public init(source: ActivitySource, identifier: ActivityIdentifier) {
        self.source = source
        self.identifier = identifier
    }
}

public struct ActivityPriority: Equatable, Comparable, Sendable {
    public let rawValue: Int

    private init(unchecked value: Int) {
        rawValue = value
    }

    public init(validating value: Int) throws(ActivityValidationError) {
        guard (ActivityLimits.minimumPriority...ActivityLimits.maximumPriority).contains(value) else {
            throw .outOfRange(
                .priority,
                minimum: ActivityLimits.minimumPriority,
                maximum: ActivityLimits.maximumPriority
            )
        }
        rawValue = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static let low = Self(unchecked: 25)
    public static let normal = Self(unchecked: 50)
    public static let high = Self(unchecked: 75)
    public static let critical = Self(unchecked: 100)
}

public struct ActivityProgress: Equatable, Sendable {
    public let fractionCompleted: Double

    public init(validating value: Double) throws(ActivityValidationError) {
        guard value.isFinite, (0...1).contains(value) else {
            throw .outOfRange(.progress, minimum: 0, maximum: 1)
        }
        fractionCompleted = value
    }
}

public struct ActivityPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String?
    public let progress: ActivityProgress?

    public init(
        validatingTitle title: String,
        detail: String? = nil,
        progress: Double? = nil
    ) throws(ActivityValidationError) {
        try Self.validateText(title, field: .title, maximumBytes: ActivityLimits.titleBytes, allowEmpty: false)
        if let detail {
            try Self.validateText(detail, field: .detail, maximumBytes: ActivityLimits.detailBytes, allowEmpty: true)
        }

        let totalBytes = title.utf8.count + (detail?.utf8.count ?? 0)
        guard totalBytes <= ActivityLimits.presentationBytes else {
            throw .tooLarge(.presentation, maximumBytes: ActivityLimits.presentationBytes)
        }

        self.title = title
        self.detail = detail
        self.progress = try progress.map(ActivityProgress.init(validating:))
    }

    private static func validateText(
        _ value: String,
        field: ActivityValidationField,
        maximumBytes: Int,
        allowEmpty: Bool
    ) throws(ActivityValidationError) {
        if !allowEmpty, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw .empty(field)
        }
        guard value.utf8.count <= maximumBytes else {
            throw .tooLarge(field, maximumBytes: maximumBytes)
        }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw .invalidFormat(field)
        }
    }
}

public enum ActivityActionIntent: String, CaseIterable, Codable, Sendable {
    case dismiss
    case cancel
    case pause
    case resume
    case togglePlayback = "toggle-playback"
    case openSource = "open-source"

    public init(validating value: String) throws(ActivityValidationError) {
        guard !value.isEmpty else { throw .empty(.actionIntent) }
        guard value.utf8.count <= ActivityLimits.actionIntentBytes else {
            throw .tooLarge(.actionIntent, maximumBytes: ActivityLimits.actionIntentBytes)
        }
        guard let intent = Self(rawValue: value) else {
            throw .unknownValue(.actionIntent, value)
        }
        self = intent
    }
}

/// A declarative intent only. It contains no URL, closure, selector, shell text, or executable command.
public struct ActivityAction: Equatable, Sendable {
    public let identifier: String
    public let label: String
    public let intent: ActivityActionIntent

    public init(
        validatingIdentifier identifier: String,
        label: String,
        intent: ActivityActionIntent
    ) throws(ActivityValidationError) {
        try Self.validate(
            identifier,
            field: .actionIdentifier,
            maximumBytes: ActivityLimits.actionIdentifierBytes,
            identifierRules: true
        )
        try Self.validate(
            label,
            field: .actionLabel,
            maximumBytes: ActivityLimits.actionLabelBytes,
            identifierRules: false
        )
        self.identifier = identifier
        self.label = label
        self.intent = intent
    }

    private static func validate(
        _ value: String,
        field: ActivityValidationField,
        maximumBytes: Int,
        identifierRules: Bool
    ) throws(ActivityValidationError) {
        guard !value.isEmpty else { throw .empty(field) }
        if !identifierRules, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw .empty(field)
        }
        guard value.utf8.count <= maximumBytes else {
            throw .tooLarge(field, maximumBytes: maximumBytes)
        }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw .invalidFormat(field)
        }
        if identifierRules {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
            guard value.unicodeScalars.allSatisfy(allowed.contains),
                  value.unicodeScalars.first.map(CharacterSet.alphanumerics.contains) == true else {
                throw .invalidFormat(field)
            }
        }
    }
}

public struct ActivityTTL: Equatable, Sendable {
    public let rawValue: Int

    public init(validatingMilliseconds value: Int) throws(ActivityValidationError) {
        guard (ActivityLimits.minimumTTLMilliseconds...ActivityLimits.maximumTTLMilliseconds).contains(value) else {
            throw .outOfRange(
                .ttlMilliseconds,
                minimum: ActivityLimits.minimumTTLMilliseconds,
                maximum: ActivityLimits.maximumTTLMilliseconds
            )
        }
        rawValue = value
    }

    public var duration: Duration {
        .milliseconds(rawValue)
    }
}

public enum ActivityLifecycle: Equatable, Sendable {
    case untilCancelled
    case expires(ActivityTTL)
}

/// Raw declarative input suitable for adapters and, later, bounded local routes.
public struct ActivityRequest: Equatable, Codable, Sendable {
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
}

public struct Activity: Equatable, Sendable {
    public let identity: ActivityIdentity
    public let kind: ActivityKind
    public let priority: ActivityPriority
    public let presentation: ActivityPresentation
    public let action: ActivityAction?
    public let lifecycle: ActivityLifecycle

    public init(validating request: ActivityRequest) throws(ActivityValidationError) {
        let source = try ActivitySource(validating: request.source)
        identity = ActivityIdentity(
            source: source,
            identifier: try ActivityIdentifier(validating: request.identifier)
        )
        kind = try ActivityKind(validating: request.kind)
        priority = try ActivityPriority(validating: request.priority)
        presentation = try ActivityPresentation(
            validatingTitle: request.title,
            detail: request.detail,
            progress: request.progress
        )
        action = try Self.validateAction(request)
        if let ttlMilliseconds = request.ttlMilliseconds {
            lifecycle = .expires(try ActivityTTL(validatingMilliseconds: ttlMilliseconds))
        } else {
            lifecycle = .untilCancelled
        }
    }

    private static func validateAction(_ request: ActivityRequest) throws(ActivityValidationError) -> ActivityAction? {
        let fields = [request.actionIdentifier, request.actionLabel, request.actionIntent]
        guard fields.contains(where: { $0 != nil }) else { return nil }
        guard let identifier = request.actionIdentifier,
              let label = request.actionLabel,
              let rawIntent = request.actionIntent else {
            throw .invalidFormat(.actionIntent)
        }
        return try ActivityAction(
            validatingIdentifier: identifier,
            label: label,
            intent: ActivityActionIntent(validating: rawIntent)
        )
    }
}
