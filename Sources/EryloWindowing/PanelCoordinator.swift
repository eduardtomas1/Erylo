import AppKit
import CoreGraphics
import EryloIntegrations

@MainActor
public final class PanelCoordinator {
    private let displayProvider: any EnabledDisplayProviding
    /// Enforces the product invariant directly at the platform boundary.
    private var panels: [CGDirectDisplayID: PanelController] = [:]
    private var screenObserver: NSObjectProtocol?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?

    public init(displayProvider: any EnabledDisplayProviding = SystemDisplayProvider()) {
        self.displayProvider = displayProvider
    }

    deinit {
        MainActor.assumeIsolated {
            if let screenObserver {
                NotificationCenter.default.removeObserver(screenObserver)
            }
            if let globalPointerMonitor {
                NSEvent.removeMonitor(globalPointerMonitor)
            }
            if let localPointerMonitor {
                NSEvent.removeMonitor(localPointerMonitor)
            }
        }
    }

    public func start() {
        reconcileDisplays()
        installEventDrivenObservers()
    }

    public func stop() {
        panels.values.forEach { $0.close() }
        panels.removeAll()

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
    }

    private func reconcileDisplays() {
        let snapshots = displayProvider.enabledDisplays()
        let currentIDs = Set(snapshots.map { CGDirectDisplayID($0.identity.rawValue) })

        for staleID in panels.keys where !currentIDs.contains(staleID) {
            panels.removeValue(forKey: staleID)?.close()
        }

        for snapshot in snapshots {
            let directDisplayID = CGDirectDisplayID(snapshot.identity.rawValue)
            if let controller = panels[directDisplayID] {
                controller.update(snapshot: snapshot)
            } else {
                let controller = PanelController(snapshot: snapshot)
                panels[directDisplayID] = controller
                controller.show()
            }
        }

        updatePointer(NSEvent.mouseLocation)
    }

    private func installEventDrivenObservers() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileDisplays()
            }
        }

        let pointerEvents: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) { [weak self] _ in
            Task { @MainActor in
                self?.updatePointer(NSEvent.mouseLocation)
            }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { [weak self] event in
            MainActor.assumeIsolated {
                self?.updatePointer(NSEvent.mouseLocation)
            }
            return event
        }
    }

    private func updatePointer(_ screenPoint: CGPoint) {
        panels.values.forEach { $0.updatePointer(screenPoint: screenPoint) }
    }
}
