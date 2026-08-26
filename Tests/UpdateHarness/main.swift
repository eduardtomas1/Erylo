import Darwin
import EryloUpdates
import Foundation

@main
@MainActor
enum UpdateHarnessMain {
    static func main() {
        var harness = UpdateHarness()
        harness.verifyConfigurationGate()
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
        check(Self.configuration().status == .ready, "complete signed-feed configuration is ready")
    }

    mutating func verifyInjectedRuntime() {
        let disabledDriver = RecordingUpdateDriver()
        var disabledFactoryCalls = 0
        let disabledRuntime = UpdateRuntime(configuration: Self.disabledConfiguration()) {
            disabledFactoryCalls += 1
            return disabledDriver
        }
        check(!disabledRuntime.startIfConfigured(), "disabled runtime does not start")
        check(disabledFactoryCalls == 0, "disabled runtime does not instantiate Sparkle")
        check(disabledDriver.startCount == 0, "disabled runtime performs no updater work")
        check(!disabledRuntime.checkForUpdates(), "disabled runtime cannot initiate network work")

        let readyDriver = RecordingUpdateDriver()
        var readyFactoryCalls = 0
        let readyRuntime = UpdateRuntime(configuration: Self.configuration()) {
            readyFactoryCalls += 1
            return readyDriver
        }
        check(readyRuntime.startIfConfigured(), "ready runtime starts")
        check(readyRuntime.startIfConfigured(), "ready runtime start is idempotent")
        check(readyFactoryCalls == 1, "ready runtime creates exactly one driver")
        check(readyDriver.startCount == 1, "ready runtime starts the driver exactly once")
        check(readyRuntime.checkForUpdates(), "ready runtime exposes an injected manual check seam")
        check(readyDriver.checkCount == 1, "manual check is forwarded exactly once")
    }

    private static func configuration(
        feedURL: String = "https://updates.erylo.app/appcast.xml",
        publicEdKey: String = Data(repeating: 7, count: 32).base64EncodedString(),
        requiresSignedFeed: Bool = true,
        verifiesBeforeExtraction: Bool = true,
        automaticChecksEnabled: Bool = false,
        automaticUpdatesAllowed: Bool = false
    ) -> UpdateConfiguration {
        UpdateConfiguration(
            feedURL: URL(string: feedURL),
            publicEdKey: publicEdKey,
            requiresSignedFeed: requiresSignedFeed,
            verifiesBeforeExtraction: verifiesBeforeExtraction,
            automaticChecksEnabled: automaticChecksEnabled,
            automaticUpdatesAllowed: automaticUpdatesAllowed
        )
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

    func start() {
        startCount += 1
    }

    func checkForUpdates() {
        checkCount += 1
    }
}
