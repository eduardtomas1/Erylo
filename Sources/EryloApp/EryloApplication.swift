import AppKit
import EryloActivity
import EryloSurface
import EryloWindowing

@main
enum EryloApplication {
    @MainActor
    private static var delegate: ApplicationDelegate?

    @MainActor
    static func main() {
        let application = NSApplication.shared
        let applicationDelegate = ApplicationDelegate()
        delegate = applicationDelegate
        application.delegate = applicationDelegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let activityBroker: ActivityBroker
    private let activityModel: SurfaceActivityModel
    private var panelCoordinator: PanelCoordinator?
    private var isStopping = false

    override init() {
        let activityBroker = ActivityBroker()
        self.activityBroker = activityBroker
        activityModel = SurfaceActivityModel(broker: activityBroker)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panelCoordinator = PanelCoordinator(activityModel: activityModel)
        self.panelCoordinator = panelCoordinator
        Task { @MainActor in
            await panelCoordinator.startAndWait()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let panelCoordinator else { return .terminateNow }
        guard !isStopping else { return .terminateLater }
        isStopping = true
        Task { @MainActor in
            await panelCoordinator.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
