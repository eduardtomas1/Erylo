import Foundation

public enum DiagnosticsLimits {
    public static let maximumBufferedEvents = 128
    public static let maximumExportedEvents = 64
    public static let maximumProviders = 32
    public static let maximumInjectedItemsScanned = 256
    public static let maximumJSONBytes = 65_536
}

public enum DiagnosticSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

public enum DiagnosticSubsystem: String, Codable, Sendable {
    case settings
    case lifecycle
    case launchAtLogin = "launch-at-login"
    case diagnostics
}

/// Closed event codes keep arbitrary user content out of diagnostics by construction.
public enum DiagnosticEventCode: String, Codable, Sendable {
    case settingsLoaded = "settings-loaded"
    case settingsFallback = "settings-fallback"
    case settingsPersistFailed = "settings-persist-failed"
    case settingsReset = "settings-reset"
    case moduleEnabled = "module-enabled"
    case moduleDisabled = "module-disabled"
    case moduleEnableFailed = "module-enable-failed"
    case moduleDisableFailed = "module-disable-failed"
    case moduleRollbackFailed = "module-rollback-failed"
    case launchAtLoginChanged = "launch-at-login-changed"
    case launchAtLoginFailed = "launch-at-login-failed"
    case exportFailed = "export-failed"
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let severity: DiagnosticSeverity
    public let subsystem: DiagnosticSubsystem
    public let code: DiagnosticEventCode
    public let module: EryloModule?

    public init(
        timestamp: Date,
        severity: DiagnosticSeverity,
        subsystem: DiagnosticSubsystem,
        code: DiagnosticEventCode,
        module: EryloModule? = nil
    ) {
        self.timestamp = timestamp
        self.severity = severity
        self.subsystem = subsystem
        self.code = code
        self.module = module
    }
}

public protocol DiagnosticClock: Sendable {
    func now() -> Date
}

public struct SystemDiagnosticClock: DiagnosticClock {
    public init() {}

    public func now() -> Date {
        Date()
    }
}

public protocol DiagnosticEventProviding: Sendable {
    func recentEvents(limit: Int) async -> [DiagnosticEvent]
}

public protocol DiagnosticEventRecording: Sendable {
    func record(
        severity: DiagnosticSeverity,
        subsystem: DiagnosticSubsystem,
        code: DiagnosticEventCode,
        module: EryloModule?
    ) async
}

public actor InMemoryDiagnosticEventBuffer: DiagnosticEventProviding, DiagnosticEventRecording {
    private let capacity: Int
    private let clock: any DiagnosticClock
    private var events: [DiagnosticEvent] = []

    public init(
        capacity: Int = DiagnosticsLimits.maximumBufferedEvents,
        clock: any DiagnosticClock = SystemDiagnosticClock()
    ) {
        self.capacity = min(max(capacity, 1), DiagnosticsLimits.maximumBufferedEvents)
        self.clock = clock
    }

    public func record(
        severity: DiagnosticSeverity,
        subsystem: DiagnosticSubsystem,
        code: DiagnosticEventCode,
        module: EryloModule? = nil
    ) {
        events.append(
            DiagnosticEvent(
                timestamp: clock.now(),
                severity: severity,
                subsystem: subsystem,
                code: code,
                module: module
            )
        )
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    public func recentEvents(limit: Int) -> [DiagnosticEvent] {
        let boundedLimit = min(max(limit, 0), DiagnosticsLimits.maximumExportedEvents)
        return Array(events.suffix(boundedLimit))
    }
}

public enum ProviderRuntimeState: String, Codable, Equatable, Sendable {
    case disabled
    case starting
    case running
    case failed
}

public enum ProviderFailureCode: String, Codable, Error, Equatable, Sendable {
    case permissionDenied = "permission-denied"
    case factoryFailed = "factory-failed"
    case startFailed = "start-failed"
    case persistenceFailed = "persistence-failed"
    case rollbackFailed = "rollback-failed"
    case operationCancelled = "operation-cancelled"
}

public struct ProviderHealthSnapshot: Codable, Equatable, Sendable {
    public let module: EryloModule
    public let state: ProviderRuntimeState
    public let failure: ProviderFailureCode?

    public init(
        module: EryloModule,
        state: ProviderRuntimeState,
        failure: ProviderFailureCode? = nil
    ) {
        self.module = module
        self.state = state
        self.failure = failure
    }
}

public struct DiagnosticAppSnapshot: Codable, Equatable, Sendable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }
}

public struct DiagnosticPlatformSnapshot: Codable, Equatable, Sendable {
    public let operatingSystem: String
    public let version: String
    public let architecture: String

    public init(operatingSystem: String, version: String, architecture: String) {
        self.operatingSystem = operatingSystem
        self.version = version
        self.architecture = architecture
    }
}

public struct DiagnosticSettingsSnapshot: Codable, Equatable, Sendable {
    public enum DisplayScope: String, Codable, Sendable {
        case automatic
        case allAvailable = "all-available"
        case custom
    }

    public enum DisplaySelection: String, Codable, Sendable {
        case automatic
        case explicit
    }

    public let schemaVersion: Int
    public let enabledModules: [EryloModule]
    public let displaySurfaceEnabled: Bool
    public let displayScope: DisplayScope
    public let customDisplayCount: Int
    public let displaySelection: DisplaySelection
    public let motion: MotionPreference
    public let fullscreenBehavior: FullscreenBehavior
    public let launchAtLoginRequested: Bool
    public let crashAndDiagnosticSharingConsent: Bool
    public let onboardingCompleted: Bool

    public init(settings: EryloSettings) {
        schemaVersion = settings.schemaVersion
        enabledModules = settings.modules.enabledModules.sorted { $0.rawValue < $1.rawValue }
        displaySurfaceEnabled = settings.displays.isEnabled
        displayScope = switch settings.displays.surfaceScope {
        case .automatic: .automatic
        case .allAvailable: .allAvailable
        case .custom: .custom
        }
        customDisplayCount = min(
            settings.displays.enabledDisplayUUIDs?.count ?? 0,
            DiagnosticsLimits.maximumProviders
        )
        displaySelection = settings.displays.preferredDisplayUUID == nil ? .automatic : .explicit
        motion = settings.motion
        fullscreenBehavior = settings.fullscreenBehavior
        launchAtLoginRequested = settings.launchAtLogin
        crashAndDiagnosticSharingConsent = settings.crashAndDiagnosticSharingConsent
        onboardingCompleted = settings.onboardingCompleted
    }
}

public struct DiagnosticsReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let app: DiagnosticAppSnapshot
    public let platform: DiagnosticPlatformSnapshot
    public let settings: DiagnosticSettingsSnapshot
    public let providerHealth: [ProviderHealthSnapshot]
    public let recentEvents: [DiagnosticEvent]

    public init(
        generatedAt: Date,
        app: DiagnosticAppSnapshot,
        platform: DiagnosticPlatformSnapshot,
        settings: DiagnosticSettingsSnapshot,
        providerHealth: [ProviderHealthSnapshot],
        recentEvents: [DiagnosticEvent]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.app = app
        self.platform = platform
        self.settings = settings
        self.providerHealth = providerHealth
        self.recentEvents = recentEvents
    }
}

public protocol DiagnosticMetadataProviding: Sendable {
    func appSnapshot() -> DiagnosticAppSnapshot
    func platformSnapshot() -> DiagnosticPlatformSnapshot
}

public struct SystemDiagnosticMetadataProvider: DiagnosticMetadataProviding {
    public init() {}

    public func appSnapshot() -> DiagnosticAppSnapshot {
        let info = Bundle.main.infoDictionary
        return DiagnosticAppSnapshot(
            version: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info?["CFBundleVersion"] as? String ?? "unknown"
        )
    }

    public func platformSnapshot() -> DiagnosticPlatformSnapshot {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return DiagnosticPlatformSnapshot(
            operatingSystem: "macOS",
            version: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            architecture: architecture
        )
    }
}

public protocol DiagnosticsCollecting: Sendable {
    func collect(
        settings: EryloSettings,
        providerHealth: [ProviderHealthSnapshot]
    ) async throws -> DiagnosticsReport
}

public struct PrivacyPreservingDiagnosticsCollector: DiagnosticsCollecting {
    private let metadata: any DiagnosticMetadataProviding
    private let eventSource: any DiagnosticEventProviding
    private let clock: any DiagnosticClock

    public init(
        metadata: any DiagnosticMetadataProviding = SystemDiagnosticMetadataProvider(),
        eventSource: any DiagnosticEventProviding,
        clock: any DiagnosticClock = SystemDiagnosticClock()
    ) {
        self.metadata = metadata
        self.eventSource = eventSource
        self.clock = clock
    }

    public func collect(
        settings: EryloSettings,
        providerHealth: [ProviderHealthSnapshot]
    ) async throws -> DiagnosticsReport {
        let rawApp = metadata.appSnapshot()
        let rawPlatform = metadata.platformSnapshot()
        let rawEvents = await eventSource.recentEvents(limit: DiagnosticsLimits.maximumExportedEvents)
        let events = Array(rawEvents.suffix(DiagnosticsLimits.maximumExportedEvents))
        return DiagnosticsReport(
            generatedAt: clock.now(),
            app: DiagnosticAppSnapshot(
                version: DiagnosticSanitizer.safeVersion(rawApp.version),
                build: DiagnosticSanitizer.safeVersion(rawApp.build)
            ),
            platform: DiagnosticPlatformSnapshot(
                operatingSystem: "macOS",
                version: DiagnosticSanitizer.safeVersion(rawPlatform.version),
                architecture: DiagnosticSanitizer.safeArchitecture(rawPlatform.architecture)
            ),
            settings: DiagnosticSettingsSnapshot(settings: settings),
            providerHealth: DiagnosticSanitizer.boundedProviderHealth(providerHealth),
            recentEvents: events
        )
    }
}

private enum DiagnosticSanitizer {
    static func safeVersion(_ value: String) -> String {
        if value == "unknown" { return value }
        guard !value.isEmpty, value.utf8.count <= 32,
              value.first?.isNumber == true else {
            return "redacted"
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return "redacted" }
        let lowercased = value.lowercased()
        let forbiddenMarkers = ["token", "secret", "bearer", "apikey", "password", "users"]
        guard !forbiddenMarkers.contains(where: lowercased.contains) else { return "redacted" }
        return value
    }

    static func safeArchitecture(_ value: String) -> String {
        ["arm64", "x86_64"].contains(value) ? value : "unknown"
    }

    static func boundedProviderHealth(
        _ values: [ProviderHealthSnapshot]
    ) -> [ProviderHealthSnapshot] {
        var byModule: [EryloModule: ProviderHealthSnapshot] = [:]
        for value in values.prefix(DiagnosticsLimits.maximumInjectedItemsScanned) {
            if byModule[value.module] == nil {
                byModule[value.module] = value
            }
            if byModule.count == EryloModule.allCases.count { break }
        }
        return byModule.values
            .sorted { $0.module.rawValue < $1.module.rawValue }
            .prefix(DiagnosticsLimits.maximumProviders)
            .map { $0 }
    }

    static func rebound(_ report: DiagnosticsReport) -> DiagnosticsReport {
        DiagnosticsReport(
            generatedAt: report.generatedAt,
            app: DiagnosticAppSnapshot(
                version: safeVersion(report.app.version),
                build: safeVersion(report.app.build)
            ),
            platform: DiagnosticPlatformSnapshot(
                operatingSystem: "macOS",
                version: safeVersion(report.platform.version),
                architecture: safeArchitecture(report.platform.architecture)
            ),
            settings: report.settings,
            providerHealth: boundedProviderHealth(report.providerHealth),
            recentEvents: Array(report.recentEvents.suffix(DiagnosticsLimits.maximumExportedEvents))
        )
    }
}

public protocol DiagnosticsWriting: Sendable {
    func write(_ data: Data, to destination: URL) async throws
}

public struct AtomicDiagnosticsWriter: DiagnosticsWriting {
    public init() {}

    public func write(_ data: Data, to destination: URL) async throws {
        guard destination.isFileURL else { throw DiagnosticsExportError.invalidDestination }
        try data.write(to: destination, options: .atomic)
    }
}

public enum DiagnosticsExportError: String, Error, Equatable, Sendable {
    case invalidDestination = "invalid-destination"
    case collectionFailed = "collection-failed"
    case encodingFailed = "encoding-failed"
    case reportTooLarge = "report-too-large"
    case writeFailed = "write-failed"
}

public actor DiagnosticsExporter {
    private let collector: any DiagnosticsCollecting
    private let writer: any DiagnosticsWriting

    public init(
        collector: any DiagnosticsCollecting,
        writer: any DiagnosticsWriting = AtomicDiagnosticsWriter()
    ) {
        self.collector = collector
        self.writer = writer
    }

    @discardableResult
    public func export(
        settings: EryloSettings,
        providerHealth: [ProviderHealthSnapshot],
        to destination: URL
    ) async throws(DiagnosticsExportError) -> Int {
        guard destination.isFileURL else { throw .invalidDestination }

        let report: DiagnosticsReport
        do {
            let collected = try await collector.collect(
                settings: settings,
                providerHealth: providerHealth
            )
            report = DiagnosticSanitizer.rebound(collected)
        } catch {
            throw .collectionFailed
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(report)
        } catch {
            throw .encodingFailed
        }
        guard data.count <= DiagnosticsLimits.maximumJSONBytes else {
            throw .reportTooLarge
        }

        do {
            try await writer.write(data, to: destination)
        } catch {
            throw .writeFailed
        }
        return data.count
    }
}
