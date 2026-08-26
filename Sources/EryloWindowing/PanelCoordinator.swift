import AppKit
import CoreGraphics
import EryloCore
import EryloIntegrations

@MainActor
public final class PanelCoordinator {
    public private(set) var isRunning = false
    public private(set) var policy: DisplayPolicy

    public var activeDisplayIdentities: Set<DisplayIdentity> {
        Set(panels.values.map(\.displayIdentity))
    }

    private let displayProvider: any EnabledDisplayProviding
    private let lifecycleEventSource: any PanelLifecycleEventSourcing
    private let panelFactory: PanelPresentationFactory
    /// Enforces the product invariant directly at the platform boundary.
    private var panels: [CGDirectDisplayID: any PanelPresenting] = [:]
    private var selectedDisplayIdentity: DisplayIdentity?
    private var isWorkspaceSleeping = false

    public convenience init(
        displayProvider: any EnabledDisplayProviding = SystemDisplayProvider(),
        policy: DisplayPolicy = .safeDefault,
        lifecycleEventSource: any PanelLifecycleEventSourcing = SystemPanelLifecycleEventSource()
    ) {
        self.init(
            displayProvider: displayProvider,
            policy: policy,
            lifecycleEventSource: lifecycleEventSource,
            panelFactory: { PanelController(snapshot: $0) }
        )
    }

    public init(
        displayProvider: any EnabledDisplayProviding,
        policy: DisplayPolicy,
        lifecycleEventSource: any PanelLifecycleEventSourcing,
        panelFactory: @escaping PanelPresentationFactory
    ) {
        self.displayProvider = displayProvider
        self.policy = policy
        self.lifecycleEventSource = lifecycleEventSource
        self.panelFactory = panelFactory
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }

    public func start() {
        guard !isRunning else { return }

        isRunning = true
        isWorkspaceSleeping = false
        if policy.isEnabled {
            startLifecycleEventSource()
            reconcileDisplays()
        }
    }

    public func stop() {
        guard isRunning || !panels.isEmpty else { return }
        isRunning = false
        isWorkspaceSleeping = false
        lifecycleEventSource.stop()

        panels.values.forEach { $0.close() }
        panels.removeAll()
        selectedDisplayIdentity = nil
    }

    public func update(policy: DisplayPolicy) {
        guard self.policy != policy else { return }
        let wasEnabled = self.policy.isEnabled
        self.policy = policy
        guard isRunning else { return }

        if !policy.isEnabled {
            lifecycleEventSource.stop()
            panels.values.forEach { $0.close() }
            panels.removeAll()
            selectedDisplayIdentity = nil
            return
        }

        if !wasEnabled {
            startLifecycleEventSource()
        }
        guard !isWorkspaceSleeping else { return }
        reconcileDisplays()
    }

    public func reconcileDisplays() {
        guard isRunning, policy.isEnabled, !isWorkspaceSleeping else { return }
        let resolution = policy.resolve(displayProvider.enabledDisplays())
        selectedDisplayIdentity = resolution.selectedDisplayIdentity
        let currentIDs = Set(
            resolution.enabledDisplays.map { CGDirectDisplayID($0.identity.rawValue) }
        )

        let staleIDs = panels.keys.filter { !currentIDs.contains($0) }
        for staleID in staleIDs {
            panels.removeValue(forKey: staleID)?.close()
        }

        for snapshot in resolution.enabledDisplays {
            let directDisplayID = CGDirectDisplayID(snapshot.identity.rawValue)
            if let controller = panels[directDisplayID] {
                controller.update(snapshot: snapshot)
                if !isWorkspaceSleeping {
                    controller.show()
                }
            } else {
                let controller = panelFactory(snapshot)
                panels[directDisplayID] = controller
                if !isWorkspaceSleeping {
                    controller.show()
                }
            }
        }

        updatePointer(NSEvent.mouseLocation)
    }

    private func handle(_ event: PanelLifecycleEvent) {
        guard isRunning else { return }

        switch event {
        case .displayConfigurationChanged, .activeSpaceChanged:
            guard !isWorkspaceSleeping else { return }
            reconcileDisplays()
        case .workspaceWillSleep:
            guard !isWorkspaceSleeping else { return }
            isWorkspaceSleeping = true
            panels.values.forEach { $0.hide() }
        case .workspaceDidWake:
            isWorkspaceSleeping = false
            reconcileDisplays()
        case let .pointerMoved(screenPoint):
            guard !isWorkspaceSleeping else { return }
            updatePointer(screenPoint)
        case .primaryShortcut:
            guard !isWorkspaceSleeping,
                  let selectedDisplayIdentity,
                  let panel = panels[CGDirectDisplayID(selectedDisplayIdentity.rawValue)] else {
                return
            }
            panel.performPrimaryAction()
        }
    }

    private func updatePointer(_ screenPoint: CGPoint) {
        panels.values.forEach { $0.updatePointer(screenPoint: screenPoint) }
    }

    private func startLifecycleEventSource() {
        lifecycleEventSource.start { [weak self] event in
            self?.handle(event)
        }
    }
}
