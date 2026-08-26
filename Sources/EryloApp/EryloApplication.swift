import AppKit
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
    private var panelCoordinator: PanelCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panelCoordinator = PanelCoordinator()
        self.panelCoordinator = panelCoordinator
        panelCoordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelCoordinator?.stop()
    }
}
