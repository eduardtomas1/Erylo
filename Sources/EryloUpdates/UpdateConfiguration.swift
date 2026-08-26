import Foundation

public enum UpdateConfigurationStatus: Equatable, Sendable {
    case disabled
    case invalid
    case ready
}

public struct UpdateConfiguration: Equatable, Sendable {
    public let feedURL: URL?
    public let publicEdKey: String?
    public let requiresSignedFeed: Bool
    public let verifiesBeforeExtraction: Bool
    public let automaticChecksEnabled: Bool
    public let automaticUpdatesAllowed: Bool
    private let metadataWasDeclared: Bool

    public init(
        feedURL: URL?,
        publicEdKey: String?,
        requiresSignedFeed: Bool,
        verifiesBeforeExtraction: Bool,
        automaticChecksEnabled: Bool,
        automaticUpdatesAllowed: Bool
    ) {
        self.feedURL = feedURL
        self.publicEdKey = publicEdKey
        self.requiresSignedFeed = requiresSignedFeed
        self.verifiesBeforeExtraction = verifiesBeforeExtraction
        self.automaticChecksEnabled = automaticChecksEnabled
        self.automaticUpdatesAllowed = automaticUpdatesAllowed
        metadataWasDeclared = feedURL != nil || publicEdKey != nil
    }

    public init(infoDictionary: [String: Any]) {
        let feedString = infoDictionary["SUFeedURL"] as? String
        feedURL = feedString.flatMap(URL.init(string:))
        publicEdKey = infoDictionary["SUPublicEDKey"] as? String
        requiresSignedFeed = infoDictionary["SURequireSignedFeed"] as? Bool ?? false
        verifiesBeforeExtraction = infoDictionary["SUVerifyUpdateBeforeExtraction"] as? Bool ?? false
        automaticChecksEnabled = infoDictionary["SUEnableAutomaticChecks"] as? Bool ?? false
        automaticUpdatesAllowed = infoDictionary["SUAllowsAutomaticUpdates"] as? Bool ?? false
        metadataWasDeclared = infoDictionary.keys.contains("SUFeedURL")
            || infoDictionary.keys.contains("SUPublicEDKey")
    }

    public static var mainBundle: UpdateConfiguration {
        UpdateConfiguration(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    public var status: UpdateConfigurationStatus {
        guard metadataWasDeclared else {
            return .disabled
        }
        guard
            let feedURL,
            isCanonicalFeedURL(feedURL),
            let publicEdKey,
            !containsPlaceholder(publicEdKey),
            Data(base64Encoded: publicEdKey)?.count == 32,
            requiresSignedFeed,
            verifiesBeforeExtraction,
            !automaticChecksEnabled,
            !automaticUpdatesAllowed
        else {
            return .invalid
        }
        return .ready
    }

    private func isCanonicalFeedURL(_ url: URL) -> Bool {
        guard
            url.scheme == "https",
            let host = url.host?.lowercased(),
            !host.isEmpty,
            !host.hasSuffix(".invalid"),
            !host.contains("example"),
            url.user == nil,
            url.password == nil,
            url.port == nil,
            url.query == nil,
            url.fragment == nil,
            let schemeSeparator = url.absoluteString.range(of: "://")
        else {
            return false
        }

        let authorityStart = schemeSeparator.upperBound
        let authorityEnd = url.absoluteString[authorityStart...].firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? url.absoluteString.endIndex
        let authority = url.absoluteString[authorityStart..<authorityEnd]
        guard !authority.contains("@"), !authority.contains(":") else {
            return false
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253 else {
            return false
        }
        return labels.allSatisfy { label in
            let bytes = Array(label.utf8)
            guard
                !bytes.isEmpty,
                bytes.count <= 63,
                Self.isASCIILetterOrDigit(bytes[0]),
                Self.isASCIILetterOrDigit(bytes[bytes.count - 1])
            else {
                return false
            }
            return bytes.allSatisfy { Self.isASCIILetterOrDigit($0) || $0 == 45 }
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...122).contains(byte)
    }

    private func containsPlaceholder(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("placeholder")
            || normalized.contains("replace_me")
            || normalized.contains("replace-me")
            || normalized.contains("todo")
    }
}
