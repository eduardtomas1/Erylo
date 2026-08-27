import Darwin
import EryloUpdates
import Foundation

@main
@MainActor
enum UpdateHarnessMain {
    static func main() {
        var harness = UpdateHarness()
        harness.verifyConfigurationGate()
        harness.verifyEffectivePreferencePolicy()
        harness.verifyInjectedRuntime()
        harness.finish()
    }
}

@MainActor
private struct UpdateHarness {
    private var checkCount = 0
    private var failures: [String] = []

    mutating func verifyConfigurationGate() {
        check(Self.disabledConfiguration().status == .disabled, "absent appcast metadata disables updates")
        check(
            Self.configuration(feedURL: "http://updates.erylo.test/appcast.xml").status == .invalid,
            "non-HTTPS feed is rejected"
        )
        check(
            UpdateConfiguration(infoDictionary: ["SUFeedURL": "://malformed"]).status == .invalid,
            "declared malformed feed metadata is invalid rather than silently disabled"
        )
        check(
            Self.configuration(feedURL: "https://updates.example.com/appcast.xml").status == .invalid,
            "example feed host is rejected"
        )
        check(
            Self.configuration(feedURL: "https://user:password@updates.erylo.test/appcast.xml").status == .invalid,
            "feed URL credentials are rejected"
        )
        check(
            Self.configuration(feedURL: "https://@updates.erylo.test/appcast.xml").status == .invalid,
            "feed URL empty userinfo is rejected"
        )
        check(
            Self.configuration(feedURL: "https://updates.erylo.test:443/appcast.xml").status == .invalid,
            "feed URL explicit default ports are rejected"
        )
        check(
            Self.configuration(feedURL: "https://updates.erylo.test:8443/appcast.xml").status == .invalid,
            "feed URL nondefault ports are rejected"
        )
        check(
            Self.configuration(feedURL: "HTTPS://updates.erylo.test/appcast.xml").status == .invalid,
            "feed URL scheme spelling is canonical lowercase HTTPS"
        )
        check(
            Self.configuration(feedURL: "https://updates.erylo.test/appcast.xml?channel=stable").status == .invalid,
            "feed URL queries are rejected"
        )
        check(
            Self.configuration(feedURL: "https://updates.erylo.test/appcast.xml#latest").status == .invalid,
            "feed URL fragments are rejected"
        )
        verifySharedFeedURLVectors()
        verifySharedPublicKeyVectors()
        check(
            Self.configuration(publicEdKey: "replace_me").status == .invalid,
            "placeholder public key is rejected"
        )
        check(
            Self.configuration(requiresSignedFeed: false).status == .invalid,
            "unsigned feed configuration is rejected"
        )
        check(
            Self.configuration(verifiesBeforeExtraction: false).status == .invalid,
            "pre-extraction verification is required"
        )
        check(
            Self.configuration(automaticChecksEnabled: true).status == .invalid,
            "automatic network checks remain disabled"
        )
        check(
            Self.configuration(automaticUpdatesAllowed: true).status == .invalid,
            "automatic downloads and installs remain disabled"
        )
        check(
            Self.configuration(automaticDownloadsEnabled: true).status == .invalid,
            "Sparkle automatic download preference remains disabled"
        )
        check(
            Self.configuration(systemProfilingEnabled: true).status == .invalid,
            "Sparkle system profiling remains disabled"
        )
        check(
            Self.configuration(overriding: ["SUDefaultsDomain": "app.erylo.updates"]).status == .invalid,
            "a custom Sparkle defaults domain is rejected"
        )
        verifySparkleBooleanCoercion()
        check(Self.configuration().status == .ready, "complete signed-feed configuration is ready")
    }

    private mutating func verifySparkleBooleanCoercion() {
        let variants: [(String, Any, Bool)] = [
            ("boolean true", true, true),
            ("boolean false", false, false),
            ("string YES", "YES", true),
            ("string NO", "NO", false),
            ("number one", NSNumber(value: 1), true),
            ("number zero", NSNumber(value: 0), false),
        ]
        let disabledKeys = [
            "SUEnableAutomaticChecks",
            "SUAllowsAutomaticUpdates",
            "SUAutomaticallyUpdate",
            "SUEnableSystemProfiling",
            "SUSendProfileInfo",
        ]
        for key in disabledKeys {
            for (name, value, coerced) in variants {
                let expected: UpdateConfigurationStatus = coerced ? .invalid : .ready
                check(
                    Self.configuration(overriding: [key: value]).status == expected,
                    "Sparkle coercion for \(key) \(name) matches the network-off gate"
                )
            }
        }
        for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            for (name, value, coerced) in variants {
                let expected: UpdateConfigurationStatus = coerced ? .ready : .invalid
                check(
                    Self.configuration(overriding: [key: value]).status == expected,
                    "Sparkle coercion for required \(key) \(name) matches the security gate"
                )
            }
        }
    }

    private mutating func verifySharedFeedURLVectors() {
        let vectorsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ReleaseFeedURLVectors.tsv")
        guard let contents = try? String(contentsOf: vectorsURL, encoding: .utf8) else {
            check(false, "shared release feed URL vectors are readable")
            return
        }

        for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                check(false, "shared release feed URL vector is well formed")
                continue
            }
            let expected: UpdateConfigurationStatus = fields[0] == "ready" ? .ready : .invalid
            check(
                Self.configuration(feedURL: String(fields[2])).status == expected,
                "shared feed URL vector \(fields[1]) is \(fields[0])"
            )
        }
    }

    private mutating func verifySharedPublicKeyVectors() {
        let vectorsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ReleasePublicKeyVectors.tsv")
        guard let contents = try? String(contentsOf: vectorsURL, encoding: .utf8) else {
            check(false, "shared release public-key vectors are readable")
            return
        }

        for line in contents.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                check(false, "shared release public-key vector is well formed")
                continue
            }
            let expected: UpdateConfigurationStatus = fields[0] == "ready" ? .ready : .invalid
            check(
                Self.configuration(publicEdKey: String(fields[2])).status == expected,
                "shared public-key vector \(fields[1]) is \(fields[0])"
            )
        }
    }

    mutating func verifyEffectivePreferencePolicy() {
        let suiteName = "app.erylo.UpdateHarness.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check(false, "isolated Sparkle defaults suite is available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let booleanKeys = [
            SparklePreferencePolicy.automaticChecksKey,
            SparklePreferencePolicy.automaticDownloadsKey,
            SparklePreferencePolicy.sendsSystemProfileKey,
        ]
        let preexistingVariants: [(String, Any)] = [
            ("boolean true", true),
            ("boolean false", false),
            ("string YES", "YES"),
            ("string NO", "NO"),
            ("number one", NSNumber(value: 1)),
            ("number zero", NSNumber(value: 0)),
        ]
        for key in booleanKeys {
            for (name, value) in preexistingVariants {
                defaults.set(value, forKey: key)
                defaults.set(86_400, forKey: SparklePreferencePolicy.scheduledCheckIntervalKey)
                defaults.set(
                    "https://persisted.invalid/appcast.xml",
                    forKey: SparklePreferencePolicy.feedOverrideKey
                )
                let policy = SparklePreferencePolicy(preferences: defaults)
                check(
                    policy.enforceAutomaticNetworkWorkDisabled(),
                    "preexisting \(key) \(name) is replaced by the closed policy"
                )
                check(
                    (defaults.object(forKey: key) as? NSNumber)?.boolValue == false,
                    "effective \(key) is false after replacing \(name)"
                )
                check(
                    defaults.double(forKey: SparklePreferencePolicy.scheduledCheckIntervalKey) == 0,
                    "effective Sparkle scheduled interval is zero"
                )
                check(
                    defaults.object(forKey: SparklePreferencePolicy.feedOverrideKey) == nil,
                    "persisted Sparkle feed override is removed"
                )
            }
        }

        for (name, unsafeValue) in [
            ("boolean true", true as Any),
            ("string YES", "YES" as Any),
            ("number one", NSNumber(value: 1) as Any),
        ] {
            for key in booleanKeys {
                let managed = ResistantPreferenceStore(values: Self.safePreferenceValues(overriding: [key: unsafeValue]))
                check(
                    !SparklePreferencePolicy(preferences: managed).enforceAutomaticNetworkWorkDisabled(),
                    "managed \(key) \(name) fails closed"
                )
            }
        }

        let managedInterval = ResistantPreferenceStore(
            values: Self.safePreferenceValues(overriding: [
                SparklePreferencePolicy.scheduledCheckIntervalKey: "86400",
            ])
        )
        check(
            !SparklePreferencePolicy(preferences: managedInterval).enforceAutomaticNetworkWorkDisabled(),
            "managed nonzero string interval fails closed"
        )
        let managedFeed = ResistantPreferenceStore(
            values: Self.safePreferenceValues(overriding: [
                SparklePreferencePolicy.feedOverrideKey: "https://managed.invalid/appcast.xml",
            ])
        )
        check(
            !SparklePreferencePolicy(preferences: managedFeed).enforceAutomaticNetworkWorkDisabled(),
            "managed feed override that resists removal fails closed"
        )
    }

    mutating func verifyInjectedRuntime() {
        let disabledDriver = RecordingUpdateDriver()
        var disabledFactoryCalls = 0
        let disabledRuntime = UpdateRuntime(configuration: Self.disabledConfiguration(), makeDriver: {
            disabledFactoryCalls += 1
            return disabledDriver
        })
        check(!disabledRuntime.startIfConfigured(), "disabled runtime does not start")
        check(disabledFactoryCalls == 0, "disabled runtime does not instantiate Sparkle")
        check(disabledDriver.startCount == 0, "disabled runtime performs no updater work")
        check(!disabledRuntime.checkForUpdates(), "disabled runtime cannot initiate network work")

        let readyDriver = RecordingUpdateDriver()
        var readyFactoryCalls = 0
        let readyRuntime = UpdateRuntime(
            configuration: Self.configuration(),
            enforcePreferencePolicy: { true },
            makeDriver: {
            readyFactoryCalls += 1
            return readyDriver
        })
        check(readyRuntime.startIfConfigured(), "ready runtime starts")
        check(readyRuntime.startIfConfigured(), "ready runtime start is idempotent")
        check(readyFactoryCalls == 1, "ready runtime creates exactly one driver")
        check(readyDriver.startCount == 1, "ready runtime starts the driver exactly once")
        check(readyRuntime.checkForUpdates(), "ready runtime exposes an injected manual check seam")
        check(readyDriver.checkCount == 1, "manual check is forwarded exactly once")
        readyRuntime.shutdown()
        readyRuntime.shutdown()
        check(!readyRuntime.startIfConfigured(), "terminal updater runtime cannot restart")
        check(!readyRuntime.checkForUpdates(), "terminal updater runtime rejects manual checks")
        check(readyDriver.startCount == 1, "repeated updater shutdown does not restart the driver")

        let blockedDriver = RecordingUpdateDriver()
        var blockedFactoryCalls = 0
        let blockedRuntime = UpdateRuntime(
            configuration: Self.configuration(),
            enforcePreferencePolicy: { false },
            makeDriver: {
                blockedFactoryCalls += 1
                return blockedDriver
            }
        )
        check(!blockedRuntime.startIfConfigured(), "unsafe effective Sparkle defaults block startup")
        check(blockedFactoryCalls == 0, "preference failure blocks Sparkle construction")
        check(blockedDriver.startCount == 0, "preference failure performs no updater work")
        check(!blockedRuntime.checkForUpdates(), "preference failure exposes no manual network seam")

        let refusingDriver = RecordingUpdateDriver(startResult: false)
        let refusingRuntime = UpdateRuntime(
            configuration: Self.configuration(),
            enforcePreferencePolicy: { true },
            makeDriver: { refusingDriver }
        )
        check(!refusingRuntime.startIfConfigured(), "driver policy enforcement failure blocks startup")
        check(refusingDriver.startCount == 1, "driver policy is attempted exactly once")
        check(!refusingRuntime.checkForUpdates(), "failed driver is never retained for manual checks")
    }

    private static func configuration(
        feedURL: String = "https://updates.erylo.app/appcast.xml",
        publicEdKey: String = Data(repeating: 7, count: 32).base64EncodedString(),
        requiresSignedFeed: Bool = true,
        verifiesBeforeExtraction: Bool = true,
        automaticChecksEnabled: Bool = false,
        automaticUpdatesAllowed: Bool = false,
        automaticDownloadsEnabled: Bool = false,
        systemProfilingEnabled: Bool = false
    ) -> UpdateConfiguration {
        configuration(overriding: [
            "SUFeedURL": feedURL,
            "SUPublicEDKey": publicEdKey,
            "SURequireSignedFeed": requiresSignedFeed,
            "SUVerifyUpdateBeforeExtraction": verifiesBeforeExtraction,
            "SUEnableAutomaticChecks": automaticChecksEnabled,
            "SUAllowsAutomaticUpdates": automaticUpdatesAllowed,
            "SUAutomaticallyUpdate": automaticDownloadsEnabled,
            "SUEnableSystemProfiling": systemProfilingEnabled,
        ])
    }

    private static func configuration(overriding values: [String: Any]) -> UpdateConfiguration {
        var info: [String: Any] = [
            "SUFeedURL": "https://updates.erylo.app/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
            "SURequireSignedFeed": true,
            "SUVerifyUpdateBeforeExtraction": true,
            "SUEnableAutomaticChecks": false,
            "SUAllowsAutomaticUpdates": false,
            "SUAutomaticallyUpdate": false,
            "SUEnableSystemProfiling": false,
        ]
        for (key, value) in values {
            info[key] = value
        }
        return UpdateConfiguration(infoDictionary: info)
    }

    private static func safePreferenceValues(overriding values: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [
            SparklePreferencePolicy.automaticChecksKey: false,
            SparklePreferencePolicy.scheduledCheckIntervalKey: 0,
            SparklePreferencePolicy.automaticDownloadsKey: false,
            SparklePreferencePolicy.sendsSystemProfileKey: false,
        ]
        for (key, value) in values {
            result[key] = value
        }
        return result
    }

    private static func disabledConfiguration() -> UpdateConfiguration {
        UpdateConfiguration(
            feedURL: nil,
            publicEdKey: nil,
            requiresSignedFeed: false,
            verifiesBeforeExtraction: false,
            automaticChecksEnabled: false,
            automaticUpdatesAllowed: false
        )
    }

    private mutating func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checkCount += 1
        if !condition() {
            failures.append(message)
        }
    }

    func finish() -> Never {
        if failures.isEmpty {
            print("Update harness passed \(checkCount) checks.")
            exit(EXIT_SUCCESS)
        }
        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        fputs("Update harness failed \(failures.count) of \(checkCount) checks.\n", stderr)
        exit(EXIT_FAILURE)
    }
}

@MainActor
private final class RecordingUpdateDriver: UpdateDriving {
    private(set) var startCount = 0
    private(set) var checkCount = 0
    private let startResult: Bool
    private let checkResult: Bool

    init(startResult: Bool = true, checkResult: Bool = true) {
        self.startResult = startResult
        self.checkResult = checkResult
    }

    func startWithAutomaticNetworkWorkDisabled() -> Bool {
        startCount += 1
        return startResult
    }

    func checkForUpdates() -> Bool {
        checkCount += 1
        return checkResult
    }
}

@MainActor
private final class ResistantPreferenceStore: UpdatePreferenceStoring {
    private let values: [String: Any]

    init(values: [String: Any]) {
        self.values = values
    }

    func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    func set(_ value: Any?, forKey defaultName: String) {}

    func removeObject(forKey defaultName: String) {}
}
