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
    public let automaticDownloadsEnabled: Bool
    public let systemProfilingEnabled: Bool
    private let metadataWasDeclared: Bool
    private let rawFeedURL: String?
    private let customDefaultsDomainWasDeclared: Bool

    public init(
        feedURL: URL?,
        publicEdKey: String?,
        requiresSignedFeed: Bool,
        verifiesBeforeExtraction: Bool,
        automaticChecksEnabled: Bool,
        automaticUpdatesAllowed: Bool,
        automaticDownloadsEnabled: Bool = false,
        systemProfilingEnabled: Bool = false
    ) {
        self.feedURL = feedURL
        self.publicEdKey = publicEdKey
        self.requiresSignedFeed = requiresSignedFeed
        self.verifiesBeforeExtraction = verifiesBeforeExtraction
        self.automaticChecksEnabled = automaticChecksEnabled
        self.automaticUpdatesAllowed = automaticUpdatesAllowed
        self.automaticDownloadsEnabled = automaticDownloadsEnabled
        self.systemProfilingEnabled = systemProfilingEnabled
        rawFeedURL = feedURL?.absoluteString
        metadataWasDeclared = feedURL != nil || publicEdKey != nil
        customDefaultsDomainWasDeclared = false
    }

    public init(infoDictionary: [String: Any]) {
        let feedString = infoDictionary["SUFeedURL"] as? String
        feedURL = feedString.flatMap(URL.init(string:))
        publicEdKey = infoDictionary["SUPublicEDKey"] as? String
        requiresSignedFeed = Self.sparkleBoolean(infoDictionary["SURequireSignedFeed"]) ?? false
        verifiesBeforeExtraction = Self.sparkleBoolean(infoDictionary["SUVerifyUpdateBeforeExtraction"]) ?? false
        automaticChecksEnabled = Self.sparkleBoolean(infoDictionary["SUEnableAutomaticChecks"]) ?? false
        automaticUpdatesAllowed = Self.sparkleBoolean(infoDictionary["SUAllowsAutomaticUpdates"]) ?? false
        automaticDownloadsEnabled = Self.sparkleBoolean(infoDictionary["SUAutomaticallyUpdate"]) ?? false
        systemProfilingEnabled = (Self.sparkleBoolean(infoDictionary["SUEnableSystemProfiling"]) ?? false)
            || (Self.sparkleBoolean(infoDictionary["SUSendProfileInfo"]) ?? false)
        rawFeedURL = feedString
        metadataWasDeclared = infoDictionary.keys.contains("SUFeedURL")
            || infoDictionary.keys.contains("SUPublicEDKey")
        customDefaultsDomainWasDeclared = infoDictionary.keys.contains("SUDefaultsDomain")
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
            let rawFeedURL,
            isCanonicalFeedURL(feedURL, raw: rawFeedURL),
            let publicEdKey,
            !containsPlaceholder(publicEdKey),
            isCanonicalPublicKey(publicEdKey),
            requiresSignedFeed,
            verifiesBeforeExtraction,
            !automaticChecksEnabled,
            !automaticUpdatesAllowed,
            !automaticDownloadsEnabled,
            !systemProfilingEnabled,
            !customDefaultsDomainWasDeclared
        else {
            return .invalid
        }
        return .ready
    }

    private func isCanonicalFeedURL(_ url: URL, raw: String) -> Bool {
        guard
            raw.unicodeScalars.allSatisfy({ $0.value < 128 }),
            !raw.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }),
            raw == url.absoluteString,
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
            let schemeSeparator = raw.range(of: "://")
        else {
            return false
        }

        let authorityStart = schemeSeparator.upperBound
        let authorityEnd = raw[authorityStart...].firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? raw.endIndex
        let authority = raw[authorityStart..<authorityEnd]
        let path = raw[authorityEnd...]
        guard
            !authority.contains("@"),
            !authority.contains(":"),
            !authority.contains("%"),
            authority.lowercased() == host,
            authority.lowercased().utf8.allSatisfy({ byte in
                Self.isASCIILetterOrDigit(byte) || byte == 45 || byte == 46
            }),
            Self.hasCanonicalPercentEncoding(path)
        else {
            return false
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard
            host.utf8.count <= 253,
            labels.count >= 2,
            labels.last?.utf8.contains(where: { (97...122).contains($0) }) == true,
            host != "localhost",
            !host.hasSuffix(".localhost"),
            !host.hasSuffix(".local")
        else {
            return false
        }
        return labels.allSatisfy { label in
            let bytes = Array(label.utf8)
            guard
                !bytes.isEmpty,
                bytes.count <= 63,
                !label.hasPrefix("xn--"),
                Self.isASCIILetterOrDigit(bytes[0]),
                Self.isASCIILetterOrDigit(bytes[bytes.count - 1])
            else {
                return false
            }
            return bytes.allSatisfy { Self.isASCIILetterOrDigit($0) || $0 == 45 }
        }
    }

    private func isCanonicalPublicKey(_ value: String) -> Bool {
        guard let decoded = Data(base64Encoded: value), decoded.count == 32 else {
            return false
        }
        return decoded.base64EncodedString() == value
    }

    // Sparkle 2.9.6 accepts NSNumber and NSString values for boolean keys and
    // applies their Objective-C boolValue coercion. Mirror that behavior so a
    // plist string such as "YES" cannot be interpreted differently here.
    private static func sparkleBoolean(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? NSString {
            return string.boolValue
        }
        return nil
    }

    private static func hasCanonicalPercentEncoding(_ value: Substring) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, isUpperHex(bytes[index + 1]), isUpperHex(bytes[index + 2]) else {
                    return false
                }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private static func isUpperHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte)
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
