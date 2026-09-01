import EryloCore
import Foundation

public enum SettingsLimits {
    public static let maximumEncodedBytes = 65_536
    public static let maximumEnabledDisplayUUIDs = 32
}

public enum EryloModule: String, CaseIterable, Codable, Sendable {
    case fileHold = "file-hold"
    case appleMusic = "apple-music"
    case spotify
    case battery
    case timer
    case calendar
    case volume
    case localIntegrations = "local-integrations"

    public var isTrustSensitive: Bool {
        switch self {
        case .fileHold, .appleMusic, .spotify, .calendar, .localIntegrations:
            true
        case .battery, .timer, .volume:
            false
        }
    }

    public var permissionRequirement: ModulePermissionRequirement? {
        switch self {
        case .calendar:
            .calendar
        case .appleMusic, .spotify:
            .appleEvents
        case .fileHold, .battery, .timer, .volume, .localIntegrations:
            nil
        }
    }
}

public enum ModulePermissionRequirement: String, Codable, Equatable, Sendable {
    case calendar
    case appleEvents = "apple-events"
}

public struct ModulePreferences: Codable, Equatable, Sendable {
    public var fileHold: Bool
    public var appleMusic: Bool
    public var spotify: Bool
    public var battery: Bool
    public var timer: Bool
    public var calendar: Bool
    public var volume: Bool
    public var localIntegrations: Bool

    public init(
        fileHold: Bool = false,
        appleMusic: Bool = false,
        spotify: Bool = false,
        battery: Bool = false,
        timer: Bool = false,
        calendar: Bool = false,
        volume: Bool = false,
        localIntegrations: Bool = false
    ) {
        self.fileHold = fileHold
        self.appleMusic = appleMusic
        self.spotify = spotify
        self.battery = battery
        self.timer = timer
        self.calendar = calendar
        self.volume = volume
        self.localIntegrations = localIntegrations
    }

    public subscript(module: EryloModule) -> Bool {
        get {
            switch module {
            case .fileHold: fileHold
            case .appleMusic: appleMusic
            case .spotify: spotify
            case .battery: battery
            case .timer: timer
            case .calendar: calendar
            case .volume: volume
            case .localIntegrations: localIntegrations
            }
        }
        set {
            switch module {
            case .fileHold: fileHold = newValue
            case .appleMusic: appleMusic = newValue
            case .spotify: spotify = newValue
            case .battery: battery = newValue
            case .timer: timer = newValue
            case .calendar: calendar = newValue
            case .volume: volume = newValue
            case .localIntegrations: localIntegrations = newValue
            }
        }
    }

    public var enabledModules: Set<EryloModule> {
        Set(EryloModule.allCases.filter { self[$0] })
    }

    public static let safeDefaults = ModulePreferences()
}

public struct DisplayPreferences: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Automatic (the safe default) uses one display. All Displays is an explicit
    /// opt-in. Custom uses `enabledDisplayUUIDs`.
    public var surfaceScope: DisplaySurfaceScope
    /// Used only by custom scope. UUIDs that are not currently available are
    /// retained but never remapped to a different physical display.
    public var enabledDisplayUUIDs: [DisplayUUID]?
    /// The menu and shortcut target. An unavailable UUID intentionally resolves to
    /// no target until that display returns or the user chooses another.
    public var preferredDisplayUUID: DisplayUUID?

    public init(
        isEnabled: Bool = true,
        surfaceScope: DisplaySurfaceScope = .automatic,
        enabledDisplayUUIDs: [DisplayUUID]? = nil,
        preferredDisplayUUID: DisplayUUID? = nil
    ) {
        self.isEnabled = isEnabled
        self.surfaceScope = surfaceScope
        self.enabledDisplayUUIDs = enabledDisplayUUIDs.map(Self.boundedUniqueUUIDs)
        self.preferredDisplayUUID = preferredDisplayUUID
    }

    public var displayPolicy: DisplayPolicy {
        DisplayPolicy(
            isEnabled: isEnabled,
            surfaceScope: surfaceScope,
            enabledDisplayUUIDs: enabledDisplayUUIDs.map(Set.init),
            preferredDisplayUUID: preferredDisplayUUID
        )
    }

    public static let safeDefaults = DisplayPreferences()

    static func boundedUniqueUUIDs(_ values: [DisplayUUID]) -> [DisplayUUID] {
        var seen: Set<DisplayUUID> = []
        var result: [DisplayUUID] = []
        result.reserveCapacity(min(values.count, SettingsLimits.maximumEnabledDisplayUUIDs))
        for value in values where seen.insert(value).inserted {
            result.append(value)
            if result.count == SettingsLimits.maximumEnabledDisplayUUIDs { break }
        }
        return result.sorted()
    }
}

public enum MotionPreference: String, Codable, CaseIterable, Sendable {
    case systemDefault = "system-default"
    case reduce

    public func shouldReduceMotion(systemValue: Bool) -> Bool {
        switch self {
        case .systemDefault: systemValue
        case .reduce: true
        }
    }
}

public enum FullscreenBehavior: String, Codable, CaseIterable, Sendable {
    case hide
    case remainAvailable = "remain-available"
}

public struct EryloSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public private(set) var schemaVersion: Int
    public var modules: ModulePreferences
    public var displays: DisplayPreferences
    public var motion: MotionPreference
    public var fullscreenBehavior: FullscreenBehavior
    public var launchAtLogin: Bool
    /// Consent only. This package contains no uploader, analytics SDK, or crash transport.
    public var crashAndDiagnosticSharingConsent: Bool
    public var onboardingCompleted: Bool

    public init(
        modules: ModulePreferences = .safeDefaults,
        displays: DisplayPreferences = .safeDefaults,
        motion: MotionPreference = .systemDefault,
        fullscreenBehavior: FullscreenBehavior = .hide,
        launchAtLogin: Bool = false,
        crashAndDiagnosticSharingConsent: Bool = false,
        onboardingCompleted: Bool = false
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.modules = modules
        self.displays = displays
        self.motion = motion
        self.fullscreenBehavior = fullscreenBehavior
        self.launchAtLogin = launchAtLogin
        self.crashAndDiagnosticSharingConsent = crashAndDiagnosticSharingConsent
        self.onboardingCompleted = onboardingCompleted
    }

    public static let safeDefaults = EryloSettings()

    /// Complete window/display policy derived from the one persisted settings value.
    public var displayPolicy: DisplayPolicy {
        var policy = displays.displayPolicy
        policy.allowsFullscreenAuxiliary = fullscreenBehavior == .remainAvailable
        return policy
    }

    func normalized() -> EryloSettings {
        var result = self
        result.schemaVersion = Self.currentSchemaVersion
        result.displays.enabledDisplayUUIDs = displays.enabledDisplayUUIDs.map {
            DisplayPreferences.boundedUniqueUUIDs($0)
        }
        if result.displays.surfaceScope != .custom {
            result.displays.enabledDisplayUUIDs = nil
        }
        return result
    }
}

public enum SettingsLoadDisposition: String, Equatable, Sendable {
    case missing
    case current
    case migrated
    case corrupt
    case unsupportedVersion = "unsupported-version"
    case oversized
    case readFailure = "read-failure"
}

public struct SettingsLoadReport: Equatable, Sendable {
    public let disposition: SettingsLoadDisposition
    public let storedSchemaVersion: Int?
    public let migrationWasPersisted: Bool

    public init(
        disposition: SettingsLoadDisposition,
        storedSchemaVersion: Int? = nil,
        migrationWasPersisted: Bool = false
    ) {
        self.disposition = disposition
        self.storedSchemaVersion = storedSchemaVersion
        self.migrationWasPersisted = migrationWasPersisted
    }
}

public struct SettingsDecodeResult: Equatable, Sendable {
    public let settings: EryloSettings
    public let report: SettingsLoadReport

    public init(settings: EryloSettings, report: SettingsLoadReport) {
        self.settings = settings
        self.report = report
    }
}

public struct SettingsCodec: Sendable {
    public init() {}

    public func encode(_ settings: EryloSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings.normalized())
        guard data.count <= SettingsLimits.maximumEncodedBytes else {
            throw SettingsCodecError.encodedValueTooLarge
        }
        return data
    }

    public func decode(_ data: Data?) -> SettingsDecodeResult {
        guard let data else {
            return SettingsDecodeResult(
                settings: .safeDefaults,
                report: SettingsLoadReport(disposition: .missing)
            )
        }
        guard data.count <= SettingsLimits.maximumEncodedBytes else {
            return safeFallback(.oversized)
        }

        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(VersionEnvelope.self, from: data) else {
            return safeFallback(.corrupt)
        }

        switch envelope.schemaVersion {
        case EryloSettings.currentSchemaVersion:
            guard let settings = try? decoder.decode(EryloSettings.self, from: data) else {
                return safeFallback(.corrupt, version: envelope.schemaVersion)
            }
            return SettingsDecodeResult(
                settings: settings.normalized(),
                report: SettingsLoadReport(
                    disposition: .current,
                    storedSchemaVersion: envelope.schemaVersion
                )
            )
        case 1:
            guard let legacy = try? decoder.decode(LegacySettingsV1.self, from: data) else {
                return safeFallback(.corrupt, version: envelope.schemaVersion)
            }
            return SettingsDecodeResult(
                settings: legacy.migrated(),
                report: SettingsLoadReport(
                    disposition: .migrated,
                    storedSchemaVersion: envelope.schemaVersion
                )
            )
        case 2:
            guard let legacy = try? decoder.decode(LegacySettingsV2.self, from: data) else {
                return safeFallback(.corrupt, version: envelope.schemaVersion)
            }
            return SettingsDecodeResult(
                settings: legacy.migrated(),
                report: SettingsLoadReport(
                    disposition: .migrated,
                    storedSchemaVersion: envelope.schemaVersion
                )
            )
        default:
            return safeFallback(.unsupportedVersion, version: envelope.schemaVersion)
        }
    }

    private func safeFallback(
        _ disposition: SettingsLoadDisposition,
        version: Int? = nil
    ) -> SettingsDecodeResult {
        SettingsDecodeResult(
            settings: .safeDefaults,
            report: SettingsLoadReport(
                disposition: disposition,
                storedSchemaVersion: version
            )
        )
    }
}

public enum SettingsCodecError: Error, Equatable, Sendable {
    case encodedValueTooLarge
}

private struct VersionEnvelope: Decodable {
    let schemaVersion: Int
}

private struct LegacySettingsV1: Decodable {
    let schemaVersion: Int
    let modules: ModulePreferences
    let displayEnabled: Bool
    let enabledDisplayIDs: [UInt32]?
    let selectedDisplayID: UInt32?
    let reduceMotion: Bool
    let fullscreenBehavior: FullscreenBehavior
    let launchAtLogin: Bool
    let diagnosticSharingConsent: Bool

    func migrated() -> EryloSettings {
        EryloSettings(
            modules: modules,
            displays: Self.safeDisplayMigration(
                isEnabled: displayEnabled,
                enabledDisplayIDs: enabledDisplayIDs
            ),
            motion: reduceMotion ? .reduce : .systemDefault,
            fullscreenBehavior: fullscreenBehavior,
            launchAtLogin: launchAtLogin,
            crashAndDiagnosticSharingConsent: diagnosticSharingConsent,
            onboardingCompleted: false
        )
    }

    private static func safeDisplayMigration(
        isEnabled: Bool,
        enabledDisplayIDs: [UInt32]?
    ) -> DisplayPreferences {
        // Session-scoped IDs cannot be mapped safely after a restart. Preserve only
        // an intentional empty scope; otherwise reset to one automatic display.
        DisplayPreferences(
            isEnabled: isEnabled,
            surfaceScope: enabledDisplayIDs?.isEmpty == true ? .custom : .automatic,
            enabledDisplayUUIDs: enabledDisplayIDs?.isEmpty == true ? [] : nil,
            preferredDisplayUUID: nil
        )
    }
}

private struct LegacySettingsV2: Decodable {
    private struct LegacyDisplayPreferences: Decodable {
        let isEnabled: Bool
        let enabledDisplayIDs: [UInt32]?
        let selectedDisplayID: UInt32?
    }

    let schemaVersion: Int
    let modules: ModulePreferences
    private let displays: LegacyDisplayPreferences
    let motion: MotionPreference
    let fullscreenBehavior: FullscreenBehavior
    let launchAtLogin: Bool
    let crashAndDiagnosticSharingConsent: Bool
    let onboardingCompleted: Bool

    func migrated() -> EryloSettings {
        EryloSettings(
            modules: modules,
            displays: DisplayPreferences(
                isEnabled: displays.isEnabled,
                surfaceScope: displays.enabledDisplayIDs?.isEmpty == true ? .custom : .automatic,
                enabledDisplayUUIDs: displays.enabledDisplayIDs?.isEmpty == true ? [] : nil,
                preferredDisplayUUID: nil
            ),
            motion: motion,
            fullscreenBehavior: fullscreenBehavior,
            launchAtLogin: launchAtLogin,
            crashAndDiagnosticSharingConsent: crashAndDiagnosticSharingConsent,
            onboardingCompleted: onboardingCompleted
        )
    }
}
