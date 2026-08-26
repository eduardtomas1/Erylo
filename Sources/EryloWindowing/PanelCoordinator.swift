import AppKit
import CoreGraphics
import EryloCore
import EryloIntegrations
import EryloSurface

@MainActor
private final class PanelCoordinatorOwnedResources {
    let lifecycleEventSource: any PanelLifecycleEventSourcing
    var panels: [CGDirectDisplayID: any PanelPresenting] = [:]

    init(lifecycleEventSource: any PanelLifecycleEventSourcing) {
        self.lifecycleEventSource = lifecycleEventSource
    }

    func cleanup() {
        lifecycleEventSource.stop()
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }
}

@MainActor
/// Borrows the injected activity model. Releasing a coordinator retires only the
/// event source and panels it owns; the final model owner must call `shutdown()`.
public final class PanelCoordinator {
    public private(set) var isRunning = false
    public private(set) var policy: DisplayPolicy

    public var activeDisplayIdentities: Set<DisplayIdentity> {
        Set(panels.values.map(\.displayIdentity))
    }

    private let displayProvider: any EnabledDisplayProviding
    private let panelFactory: ActivityPanelPresentationFactory
    private let activityModel: SurfaceActivityModel
    private let ownedResources: PanelCoordinatorOwnedResources
    /// Enforces the product invariant directly at the platform boundary.
    private var panels: [CGDirectDisplayID: any PanelPresenting] {
        get { ownedResources.panels }
        set { ownedResources.panels = newValue }
    }

    private var lifecycleEventSource: any PanelLifecycleEventSourcing {
        ownedResources.lifecycleEventSource
    }
    private var selectedDisplayIdentity: DisplayIdentity?
    private var isWorkspaceSleeping = false
    private var isShutdown = false
    private var activeEventLease: UUID?
    private var isTerminalCleanupInProgress = false
    private var terminalCleanupWaiters: [CheckedContinuation<Void, Never>] = []

    /// Preserves the original coordinator entry point with a stopped, zero-work activity model.
    public convenience init(
        displayProvider: any EnabledDisplayProviding = SystemDisplayProvider(),
        policy: DisplayPolicy = .safeDefault,
        lifecycleEventSource: any PanelLifecycleEventSourcing = SystemPanelLifecycleEventSource()
    ) {
        let activityModel = SurfaceActivityModel(inert: ())
        self.init(
            displayProvider: displayProvider,
            policy: policy,
            lifecycleEventSource: lifecycleEventSource,
            activityModel: activityModel,
            panelFactory: { PanelController(snapshot: $0, activityModel: $1) }
        )
    }

    public convenience init(
        activityModel: SurfaceActivityModel,
        displayProvider: any EnabledDisplayProviding = SystemDisplayProvider(),
        policy: DisplayPolicy = .safeDefault,
        lifecycleEventSource: any PanelLifecycleEventSourcing = SystemPanelLifecycleEventSource()
    ) {
        self.init(
            displayProvider: displayProvider,
            policy: policy,
            lifecycleEventSource: lifecycleEventSource,
            activityModel: activityModel,
            panelFactory: { PanelController(snapshot: $0, activityModel: $1) }
        )
    }

    package convenience init(
        activityModel: SurfaceActivityModel,
        previewInitialState: PanelPresentationState,
        displayProvider: any EnabledDisplayProviding = SystemDisplayProvider(),
        policy: DisplayPolicy = .safeDefault,
        lifecycleEventSource: any PanelLifecycleEventSourcing = SystemPanelLifecycleEventSource()
    ) {
        self.init(
            displayProvider: displayProvider,
            policy: policy,
            lifecycleEventSource: lifecycleEventSource,
            activityModel: activityModel,
            panelFactory: {
                PanelController(
                    snapshot: $0,
                    activityModel: $1,
                    initialState: previewInitialState
                )
            }
        )
    }

    /// Preserves the original injectable one-argument panel factory.
    public convenience init(
        displayProvider: any EnabledDisplayProviding,
        policy: DisplayPolicy,
        lifecycleEventSource: any PanelLifecycleEventSourcing,
        panelFactory: @escaping PanelPresentationFactory
    ) {
        self.init(
            displayProvider: displayProvider,
            policy: policy,
            lifecycleEventSource: lifecycleEventSource,
            activityModel: SurfaceActivityModel(inert: ()),
            panelFactory: { snapshot, _ in panelFactory(snapshot) }
        )
    }

    public init(
        displayProvider: any EnabledDisplayProviding,
        policy: DisplayPolicy,
        lifecycleEventSource: any PanelLifecycleEventSourcing,
        activityModel: SurfaceActivityModel,
        panelFactory: @escaping ActivityPanelPresentationFactory
    ) {
        self.displayProvider = displayProvider
        self.policy = policy
        self.activityModel = activityModel
        self.panelFactory = panelFactory
        ownedResources = PanelCoordinatorOwnedResources(
            lifecycleEventSource: lifecycleEventSource
        )
    }

    deinit {
        let ownedResources = ownedResources
        Task { @MainActor in
            ownedResources.cleanup()
        }
    }

    /// Source-compatible immediate request. Use `startAndWait()` when a physical
    /// model-lifecycle settlement barrier is required.
    public func start() {
        guard !isShutdown, !isRunning else { return }
        isRunning = true
        isWorkspaceSleeping = false
        guard policy.isEnabled else {
            retireLifecycleEventSource()
            closeAllPanels()
            activityModel.requestStop()
            return
        }
        activityModel.start()
        startLifecycleEventSource()
        reconcileDisplays()
    }

    public func startAndWait() async {
        start()
        await waitForLifecycleSettlement()
    }

    /// Source-compatible immediate request. The shared model owns the resulting
    /// generation-safe drain until it physically settles.
    public func stop() {
        guard !isShutdown else { return }
        isRunning = false
        isWorkspaceSleeping = false
        retireLifecycleEventSource()
        closeAllPanels()
        activityModel.requestStop()
    }

    public func stopAndWait() async {
        stop()
        await waitForLifecycleSettlement()
    }

    /// Final process shutdown cannot be superseded by a later start or policy request.
    /// Call only from the final owner of the injected shared activity model.
    public func shutdown() async {
        if isTerminalCleanupInProgress {
            await waitForTerminalCleanup()
            return
        }
        guard !isShutdown else { return }
        isShutdown = true
        isTerminalCleanupInProgress = true
        isRunning = false
        isWorkspaceSleeping = false
        retireLifecycleEventSource()
        await activityModel.shutdown()
        closeAllPanels()
        finishTerminalCleanup()
    }

    /// Source-compatible immediate policy request. Use `updateAndWait(policy:)`
    /// when disabling must also be a physical activity-model drain barrier.
    public func update(policy: DisplayPolicy) {
        guard !isShutdown, self.policy != policy else { return }
        self.policy = policy
        guard isRunning else { return }
        if policy.isEnabled {
            activityModel.start()
            startLifecycleEventSource()
            guard !isWorkspaceSleeping else { return }
            reconcileDisplays()
        } else {
            retireLifecycleEventSource()
            closeAllPanels()
            activityModel.requestStop()
        }
    }

    public func updateAndWait(policy: DisplayPolicy) async {
        update(policy: policy)
        await waitForLifecycleSettlement()
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
                let controller = panelFactory(snapshot, activityModel)
                panels[directDisplayID] = controller
                if !isWorkspaceSleeping {
                    controller.show()
                }
            }
        }

        updatePointer(NSEvent.mouseLocation)
    }

    private func handle(_ event: PanelLifecycleEvent, lease: UUID) {
        guard activeEventLease == lease,
              lifecycleEventSource.isRunning,
              isRunning,
              policy.isEnabled,
              !isShutdown else {
            return
        }

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
        if lifecycleEventSource.isRunning, activeEventLease != nil { return }
        if lifecycleEventSource.isRunning {
            lifecycleEventSource.stop()
        }
        let lease = UUID()
        activeEventLease = lease
        lifecycleEventSource.start { [weak self] event in
            self?.handle(event, lease: lease)
        }
    }

    private func retireLifecycleEventSource() {
        activeEventLease = nil
        lifecycleEventSource.stop()
    }

    private func closeAllPanels() {
        panels.values.forEach { $0.close() }
        panels.removeAll()
        selectedDisplayIdentity = nil
    }

    private func waitForTerminalCleanup() async {
        guard isTerminalCleanupInProgress else { return }
        await withCheckedContinuation { continuation in
            terminalCleanupWaiters.append(continuation)
        }
    }

    private func finishTerminalCleanup() {
        isTerminalCleanupInProgress = false
        let waiters = terminalCleanupWaiters
        terminalCleanupWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForLifecycleSettlement() async {
        await activityModel.waitForRequestedLifecycleSettlement()
        if isTerminalCleanupInProgress {
            await waitForTerminalCleanup()
        }
    }
}
