import AppKit
import EryloActivity
import EryloCore
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
    private let previewInitialState: PanelPresentationState?
    private var panelCoordinator: PanelCoordinator?
    private var isStopping = false

    override init() {
        let activityBroker = ActivityBroker()
        self.activityBroker = activityBroker
        #if DEBUG
        if ProcessInfo.processInfo.environment["ERYLO_PREVIEW_SCENARIO"] == "timer",
           let snapshot = try? ActivitySurfacePreviewCatalog.timer.snapshot() {
            activityModel = SurfaceActivityModel(previewSnapshot: snapshot)
            previewInitialState = ActivitySurfacePreviewCatalog.timer.state
        } else {
            activityModel = SurfaceActivityModel(broker: activityBroker)
            previewInitialState = nil
        }
        #else
        activityModel = SurfaceActivityModel(broker: activityBroker)
        previewInitialState = nil
        #endif
        super.init()
    }
    private var updateRuntime: UpdateRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panelCoordinator = if let previewInitialState {
            PanelCoordinator(
                activityModel: activityModel,
                previewInitialState: previewInitialState
            )
        } else {
            PanelCoordinator(activityModel: activityModel)
        }
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
