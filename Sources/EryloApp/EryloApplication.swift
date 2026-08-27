import AppKit
import EryloAppRuntime

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
    private let runtime: ApplicationRuntime
    private var isStopping = false

    override init() {
        runtime = ApplicationRuntime.production(
            requestApplicationTermination: {
                NSApplication.shared.terminate(nil)
            }
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await runtime.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isStopping else { return .terminateLater }
        isStopping = true
        Task { @MainActor in
            await runtime.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
