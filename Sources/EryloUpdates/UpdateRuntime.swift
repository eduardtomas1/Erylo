import Sparkle

@MainActor
public protocol UpdateDriving: AnyObject {
    func start()
    func checkForUpdates()
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

    public func start() {
        controller.startUpdater()
    }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
public final class UpdateRuntime {
    private let configuration: UpdateConfiguration
    private let makeDriver: @MainActor () -> any UpdateDriving
    private var driver: (any UpdateDriving)?

    public init(
        configuration: UpdateConfiguration,
        makeDriver: @escaping @MainActor () -> any UpdateDriving = { SparkleUpdateDriver() }
    ) {
        self.configuration = configuration
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
        let driver = makeDriver()
        driver.start()
        self.driver = driver
        return true
    }

    @discardableResult
    public func checkForUpdates() -> Bool {
        guard let driver else {
            return false
        }
        driver.checkForUpdates()
        return true
    }
}
