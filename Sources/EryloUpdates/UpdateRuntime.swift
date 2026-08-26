import Foundation
import Sparkle

@MainActor
public protocol UpdateDriving: AnyObject {
    func startWithAutomaticNetworkWorkDisabled() -> Bool
    func checkForUpdates() -> Bool
}

@MainActor
public protocol UpdatePreferenceStoring: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: UpdatePreferenceStoring {}

@MainActor
public final class SparklePreferencePolicy {
    public static let automaticChecksKey = "SUEnableAutomaticChecks"
    public static let scheduledCheckIntervalKey = "SUScheduledCheckInterval"
    public static let automaticDownloadsKey = "SUAutomaticallyUpdate"
    public static let sendsSystemProfileKey = "SUSendProfileInfo"
    public static let feedOverrideKey = "SUFeedURL"

    private let preferences: any UpdatePreferenceStoring

    public init(preferences: any UpdatePreferenceStoring = UserDefaults.standard) {
        self.preferences = preferences
    }

    // Sparkle gives effective NSUserDefaults values precedence over Info.plist.
    // Write the closed policy, then read it back through Sparkle's NSNumber /
    // NSString coercion rules. Managed or argument-domain values that resist
    // the write therefore fail before an updater is constructed.
    public func enforceAutomaticNetworkWorkDisabled() -> Bool {
        preferences.set(false, forKey: Self.automaticChecksKey)
        preferences.set(0.0, forKey: Self.scheduledCheckIntervalKey)
        preferences.set(false, forKey: Self.automaticDownloadsKey)
        preferences.set(false, forKey: Self.sendsSystemProfileKey)
        preferences.removeObject(forKey: Self.feedOverrideKey)

        return Self.sparkleBoolean(preferences.object(forKey: Self.automaticChecksKey)) == false
            && Self.sparkleDouble(preferences.object(forKey: Self.scheduledCheckIntervalKey)) == 0
            && Self.sparkleBoolean(preferences.object(forKey: Self.automaticDownloadsKey)) == false
            && Self.sparkleBoolean(preferences.object(forKey: Self.sendsSystemProfileKey)) == false
            && preferences.object(forKey: Self.feedOverrideKey) == nil
    }

    private static func sparkleBoolean(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? NSString {
            return string.boolValue
        }
        return nil
    }

    private static func sparkleDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? NSString {
            return string.doubleValue
        }
        return nil
    }
}

@MainActor
public final class SparkleUpdateDriver: UpdateDriving {
    private let controller: SPUStandardUpdaterController

    public init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    public func startWithAutomaticNetworkWorkDisabled() -> Bool {
        guard enforceUpdaterPolicy() else {
            return false
        }
        controller.startUpdater()
        return enforceUpdaterPolicy()
    }

    public func checkForUpdates() -> Bool {
        guard enforceUpdaterPolicy() else {
            return false
        }
        controller.checkForUpdates(nil)
        return true
    }

    private func enforceUpdaterPolicy() -> Bool {
        let updater = controller.updater
        _ = updater.clearFeedURLFromUserDefaults()
        updater.updateCheckInterval = 0
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        return updater.updateCheckInterval == 0
            && !updater.automaticallyChecksForUpdates
            && !updater.automaticallyDownloadsUpdates
            && !updater.sendsSystemProfile
            && !updater.allowsAutomaticUpdates
    }
}

@MainActor
public final class UpdateRuntime {
    private let configuration: UpdateConfiguration
    private let enforcePreferencePolicy: @MainActor () -> Bool
    private let makeDriver: @MainActor () -> any UpdateDriving
    private var driver: (any UpdateDriving)?

    public init(
        configuration: UpdateConfiguration,
        enforcePreferencePolicy: @escaping @MainActor () -> Bool = {
            SparklePreferencePolicy().enforceAutomaticNetworkWorkDisabled()
        },
        makeDriver: @escaping @MainActor () -> any UpdateDriving = { SparkleUpdateDriver() }
    ) {
        self.configuration = configuration
        self.enforcePreferencePolicy = enforcePreferencePolicy
        self.makeDriver = makeDriver
    }

    @discardableResult
    public func startIfConfigured() -> Bool {
        guard configuration.status == .ready else {
            return false
        }
        guard driver == nil else {
            return true
        }
        guard enforcePreferencePolicy() else {
            return false
        }
        let driver = makeDriver()
        guard driver.startWithAutomaticNetworkWorkDisabled() else {
            return false
        }
        self.driver = driver
        return true
    }

    @discardableResult
    public func checkForUpdates() -> Bool {
        guard let driver else {
            return false
        }
        return driver.checkForUpdates()
    }
}
