import AppKit
import EryloActivity
import EryloSurface
import EryloUpdates
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
        #if DEBUG
        if ProcessInfo.processInfo.environment["ERYLO_PREVIEW_SCENARIO"] == "timer",
           let snapshot = try? ActivitySurfacePreviewCatalog.timer.snapshot() {
            activityModel = SurfaceActivityModel(previewSnapshot: snapshot)
        } else {
            activityModel = SurfaceActivityModel(broker: activityBroker)
        }
        #else
        activityModel = SurfaceActivityModel(broker: activityBroker)
        #endif
        super.init()
    }
    private var updateRuntime: UpdateRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panelCoordinator = PanelCoordinator(activityModel: activityModel)
        self.panelCoordinator = panelCoordinator
        let updateRuntime = UpdateRuntime(configuration: .mainBundle)
        self.updateRuntime = updateRuntime
        updateRuntime.startIfConfigured()
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
