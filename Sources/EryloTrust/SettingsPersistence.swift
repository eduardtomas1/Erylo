import Foundation

/// Stores one opaque value per settings generation. Implementations must either replace the
/// complete value or leave the previous value readable; partial multi-key writes are forbidden.
public protocol AtomicSettingsStorage: Sendable {
    func data(forKey key: String) throws -> Data?
    func replace(_ data: Data, forKey key: String) throws
}

public struct UserDefaultsSettingsStorage: AtomicSettingsStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public init?(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = defaults
    }

    public func data(forKey key: String) throws -> Data? {
        defaults.data(forKey: key)
    }

    public func replace(_ data: Data, forKey key: String) throws {
        // A single value replacement is the UserDefaults atomicity boundary. Synchronize is
        // intentionally not used: it is deprecated as a durability signal and cannot improve it.
        defaults.set(data, forKey: key)
    }
}

public enum SettingsPersistenceError: Error, Equatable, Sendable {
    case encodingFailed
    case storageReadFailed
    case storageWriteFailed
    case settingsResetRequired(SettingsLoadDisposition)
}

public actor SettingsRepository {
    public static let defaultStorageKey = "erylo.settings"

    private let storage: any AtomicSettingsStorage
    private let storageKey: String
    private let codec: SettingsCodec
    private var settings: EryloSettings
    private var report: SettingsLoadReport

    public init(
        storage: any AtomicSettingsStorage = UserDefaultsSettingsStorage(),
        storageKey: String = SettingsRepository.defaultStorageKey,
        codec: SettingsCodec = SettingsCodec(),
        automaticallyPersistsMigrations: Bool = true
    ) {
        self.storage = storage
        self.storageKey = storageKey
        self.codec = codec

        let initialResult: SettingsDecodeResult
        do {
            initialResult = codec.decode(try storage.data(forKey: storageKey))
        } catch {
            initialResult = SettingsDecodeResult(
                settings: .safeDefaults,
                report: SettingsLoadReport(disposition: .readFailure)
            )
        }

        settings = initialResult.settings
        report = initialResult.report

        if automaticallyPersistsMigrations,
           initialResult.report.disposition == .migrated,
           let migratedData = try? codec.encode(initialResult.settings) {
            do {
                try storage.replace(migratedData, forKey: storageKey)
                report = SettingsLoadReport(
                    disposition: .migrated,
                    storedSchemaVersion: initialResult.report.storedSchemaVersion,
                    migrationWasPersisted: true
                )
            } catch {
                // The migrated in-memory value remains useful. The unchanged legacy value can be
                // retried on the next launch; the report remains honest about persistence.
            }
        }
    }

    public func current() -> EryloSettings {
        settings
    }

    public func loadReport() -> SettingsLoadReport {
        report
    }

    @discardableResult
    public func replace(with candidate: EryloSettings) throws(SettingsPersistenceError) -> EryloSettings {
        try persist(candidate, intent: .ordinaryChange)
    }

    @discardableResult
    public func update(
        _ mutation: @Sendable (inout EryloSettings) -> Void
    ) throws(SettingsPersistenceError) -> EryloSettings {
        var candidate = settings
        mutation(&candidate)
        return try persist(candidate, intent: .ordinaryChange)
    }

    @discardableResult
    public func resetToSafeDefaults() throws(SettingsPersistenceError) -> EryloSettings {
        try persist(.safeDefaults, intent: .explicitReset)
    }

    private enum PersistenceIntent {
        case ordinaryChange
        case explicitReset
    }

    private func persist(
        _ candidate: EryloSettings,
        intent: PersistenceIntent
    ) throws(SettingsPersistenceError) -> EryloSettings {
        if case .ordinaryChange = intent, report.requiresExplicitReset {
            throw .settingsResetRequired(report.disposition)
        }
        let normalized = candidate.normalized()
        let data: Data
        do {
            data = try codec.encode(normalized)
        } catch {
            throw .encodingFailed
        }

        do {
            try storage.replace(data, forKey: storageKey)
        } catch {
            throw .storageWriteFailed
        }

        settings = normalized
        report = SettingsLoadReport(
            disposition: .current,
            storedSchemaVersion: EryloSettings.currentSchemaVersion
        )
        return normalized
    }
}
