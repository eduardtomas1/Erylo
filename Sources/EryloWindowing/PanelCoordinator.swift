import AppKit
import CoreGraphics
import EryloCore
import EryloIntegrations
import EryloSurface

@MainActor
private final class PanelCoordinatorOwnedResources {
    let lifecycleEventSource: any PanelLifecycleEventSourcing
    let activityModel: SurfaceActivityModel
    var panels: [CGDirectDisplayID: any PanelPresenting] = [:]
    var activityObserverID: UUID?

    init(
        lifecycleEventSource: any PanelLifecycleEventSourcing,
        activityModel: SurfaceActivityModel
    ) {
        self.lifecycleEventSource = lifecycleEventSource
        self.activityModel = activityModel
    }

    func retireActivityObserver() {
        if let activityObserverID {
            activityModel.removeObserver(activityObserverID)
            self.activityObserverID = nil
        }
    }

    func cleanup() {
        retireActivityObserver()
        lifecycleEventSource.setPointerMonitoringEnabled(false)
        lifecycleEventSource.stop()
        panels.values.forEach { panel in
            (panel as? any PanelPresentationDemandReporting)?
                .setPresentationDemandHandler(nil)
            (panel as? any PanelActivityVisibilityReporting)?
                .setActivityVisibilityHandler(nil)
            panel.close()
        }
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
    private var displaySnapshots: [CGDirectDisplayID: DisplaySnapshot] = [:]
    private var displayFrames: [CGDirectDisplayID: CGRect] = [:]
    private var panelLeases: [CGDirectDisplayID: UUID] = [:]
    private var presentedPanelIDs: Set<CGDirectDisplayID> = []
    private var fallbackManualPresentationIDs: Set<CGDirectDisplayID> = []
    private var lastPointerScreenPoint: CGPoint?
    private var pointerDisplayID: CGDirectDisplayID?
    private var isTerminalCleanupInProgress = false
    private var terminalCleanupWaiters: [CheckedContinuation<Void, Never>] = []
    private var activityVisibilityHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var lastReportedActivityVisibility = false
    private var focusTimerStartHandler: (@MainActor @Sendable (Int) -> Bool)?

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
            lifecycleEventSource: lifecycleEventSource,
            activityModel: activityModel
        )
        ownedResources.activityObserverID = activityModel.addObserver { [weak self] in
            self?.activityDidChange()
        }
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
        ownedResources.retireActivityObserver()
        retireLifecycleEventSource()
        await activityModel.shutdown()
        closeAllPanels()
        activityVisibilityHandler = nil
        focusTimerStartHandler = nil
        finishTerminalCleanup()
    }

    /// Installs one edge-triggered aggregate visibility route for application
    /// services. Reporting itself owns no task, timer, observer, or polling loop.
    package func setActivityVisibilityHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        activityVisibilityHandler = handler
        reportActivityVisibilityIfNeeded(force: true)
    }

    package func setFocusTimerStartHandler(
        _ handler: (@MainActor @Sendable (Int) -> Bool)?
    ) {
        focusTimerStartHandler = handler
        panels.values.forEach {
            ($0 as? any PanelFocusTimerLaunching)?
                .setFocusTimerStartHandler(handler)
        }
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
        displaySnapshots = Dictionary(
            uniqueKeysWithValues: resolution.enabledDisplays.map {
                (CGDirectDisplayID($0.identity.rawValue), $0)
            }
        )
        displayFrames = Dictionary(
            uniqueKeysWithValues: resolution.enabledDisplays.map {
                (CGDirectDisplayID($0.identity.rawValue), $0.geometry.frame)
            }
        )

        let staleIDs = panels.keys.filter { !currentIDs.contains($0) }
        for staleID in staleIDs {
            retirePanel(displayID: staleID)
        }

        for snapshot in resolution.enabledDisplays {
            let directDisplayID = CGDirectDisplayID(snapshot.identity.rawValue)
            if let controller = panels[directDisplayID] {
                controller.update(snapshot: snapshot)
            }
        }

        if activityModel.current != nil {
            resolution.enabledDisplays.forEach { _ = ensurePanel(snapshot: $0) }
        }
        presentDemandedPanels()
        reportActivityVisibilityIfNeeded()
    }

    /// Deliberate keyboard/menu action for the currently selected display.
    /// The passive panel remains nonactivating; unavailable or disabled surfaces fail closed.
    @discardableResult
    package func performPrimaryActionOnSelectedDisplay() -> Bool {
        guard isRunning,
              policy.isEnabled,
              !isWorkspaceSleeping,
              !isShutdown,
              let selectedDisplayIdentity,
              let panel = ensurePanel(identity: selectedDisplayIdentity) else {
            return false
        }
        let displayID = CGDirectDisplayID(selectedDisplayIdentity.rawValue)
        guard !(panel is any PanelPresentationDemandReporting) else {
            panel.performPrimaryAction()
            return true
        }

        if activityModel.current == nil,
           fallbackManualPresentationIDs.contains(displayID),
           let lease = panelLeases[displayID] {
            panel.performPrimaryAction()
            fallbackManualPresentationIDs.remove(displayID)
            hidePanel(displayID: displayID, lease: lease)
            return true
        }

        panel.performPrimaryAction()
        if let lease = panelLeases[displayID],
           !presentedPanelIDs.contains(displayID) {
            if activityModel.current == nil {
                fallbackManualPresentationIDs.insert(displayID)
            }
            presentPanel(displayID: displayID, lease: lease)
        }
        return true
    }

    /// Menu-specific visibility toggle. Unlike the primary surface interaction,
    /// this always moves between hidden and a visible compact surface.
    @discardableResult
    package func toggleSelectedPanelVisibility() -> Bool {
        guard isRunning,
              policy.isEnabled,
              !isWorkspaceSleeping,
              !isShutdown,
              let selectedDisplayIdentity,
              let panel = ensurePanel(identity: selectedDisplayIdentity) else {
            return false
        }
        let displayID = CGDirectDisplayID(selectedDisplayIdentity.rawValue)
        guard !(panel is any PanelPresentationDemandReporting),
              let lease = panelLeases[displayID] else {
            panel.performVisibilityToggle()
            return true
        }

        if presentedPanelIDs.contains(displayID) {
            panel.performVisibilityToggle()
            fallbackManualPresentationIDs.remove(displayID)
            hidePanel(displayID: displayID, lease: lease)
        } else {
            panel.performVisibilityToggle()
            if activityModel.current == nil {
                fallbackManualPresentationIDs.insert(displayID)
            } else {
                fallbackManualPresentationIDs.remove(displayID)
            }
            presentPanel(displayID: displayID, lease: lease)
        }
        return true
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
            Array(panels.values).forEach { $0.hide() }
            presentedPanelIDs.removeAll()
            lifecycleEventSource.setPointerMonitoringEnabled(false)
        case .workspaceDidWake:
            isWorkspaceSleeping = false
            reconcileDisplays()
        case let .pointerMoved(screenPoint):
            guard !isWorkspaceSleeping else { return }
            updatePointer(screenPoint)
        case .primaryShortcut:
            _ = performPrimaryActionOnSelectedDisplay()
        }
    }

    private func activityDidChange() {
        guard isRunning, policy.isEnabled, !isWorkspaceSleeping, !isShutdown else {
            return
        }
        guard activityModel.current != nil else {
            for displayID in Array(presentedPanelIDs) {
                guard let panel = panels[displayID],
                      !(panel is any PanelPresentationDemandReporting),
                      !fallbackManualPresentationIDs.contains(displayID),
                      let lease = panelLeases[displayID] else { continue }
                hidePanel(displayID: displayID, lease: lease)
            }
            reportActivityVisibilityIfNeeded()
            return
        }
        if displaySnapshots.isEmpty {
            reconcileDisplays()
            return
        }
        displaySnapshots.values.forEach { _ = ensurePanel(snapshot: $0) }
        presentDemandedPanels()
    }

    private func ensurePanel(
        identity: DisplayIdentity
    ) -> (any PanelPresenting)? {
        let displayID = CGDirectDisplayID(identity.rawValue)
        if let panel = panels[displayID] {
            return panel
        }
        guard let snapshot = displaySnapshots[displayID] else { return nil }
        return ensurePanel(snapshot: snapshot)
    }

    @discardableResult
    private func ensurePanel(
        snapshot: DisplaySnapshot
    ) -> any PanelPresenting {
        let displayID = CGDirectDisplayID(snapshot.identity.rawValue)
        if let panel = panels[displayID] {
            panel.update(snapshot: snapshot)
            return panel
        }

        let panel = panelFactory(snapshot, activityModel)
        let lease = UUID()
        panels[displayID] = panel
        panelLeases[displayID] = lease

        (panel as? any PanelFocusTimerLaunching)?
            .setFocusTimerStartHandler(focusTimerStartHandler)

        if let demandReporter = panel as? any PanelPresentationDemandReporting {
            demandReporter.setPresentationDemandHandler { [weak self] isDemanded in
                self?.panelPresentationDemandDidChange(
                    displayID: displayID,
                    lease: lease,
                    isDemanded: isDemanded
                )
            }
        }
        (panel as? any PanelActivityVisibilityReporting)?
            .setActivityVisibilityHandler { [weak self] _ in
                self?.panelActivityVisibilityDidChange(
                    displayID: displayID,
                    lease: lease
                )
            }
        return panel
    }

    private func panelPresentationDemandDidChange(
        displayID: CGDirectDisplayID,
        lease: UUID,
        isDemanded: Bool
    ) {
        guard panelLeases[displayID] == lease,
              panels[displayID] != nil else { return }
        if isDemanded {
            presentPanel(displayID: displayID, lease: lease)
        } else {
            hidePanel(displayID: displayID, lease: lease)
        }
    }

    private func panelActivityVisibilityDidChange(
        displayID: CGDirectDisplayID,
        lease: UUID
    ) {
        guard panelLeases[displayID] == lease else { return }
        reportActivityVisibilityIfNeeded()
    }

    private func presentDemandedPanels() {
        for (displayID, panel) in panels {
            let isDemanded = (panel as? any PanelPresentationDemandReporting)?
                .wantsSurfacePresentation
                ?? (activityModel.current != nil
                    || fallbackManualPresentationIDs.contains(displayID))
            guard isDemanded, let lease = panelLeases[displayID] else { continue }
            presentPanel(displayID: displayID, lease: lease)
        }
    }

    private func presentPanel(
        displayID: CGDirectDisplayID,
        lease: UUID
    ) {
        guard isRunning,
              policy.isEnabled,
              !isWorkspaceSleeping,
              !isShutdown,
              panelLeases[displayID] == lease,
              let panel = panels[displayID] else { return }
        guard presentedPanelIDs.insert(displayID).inserted else { return }
        lifecycleEventSource.setPointerMonitoringEnabled(true)
        panel.show()
        updatePointer(NSEvent.mouseLocation, forceAll: true)
    }

    private func hidePanel(
        displayID: CGDirectDisplayID,
        lease: UUID
    ) {
        guard panelLeases[displayID] == lease,
              let panel = panels[displayID] else { return }
        if presentedPanelIDs.remove(displayID) != nil {
            panel.hide()
        }
        synchronizePointerMonitoring()
    }

    private func retirePanel(displayID: CGDirectDisplayID) {
        guard let panel = panels.removeValue(forKey: displayID) else { return }
        panelLeases.removeValue(forKey: displayID)
        presentedPanelIDs.remove(displayID)
        fallbackManualPresentationIDs.remove(displayID)
        (panel as? any PanelPresentationDemandReporting)?
            .setPresentationDemandHandler(nil)
        (panel as? any PanelActivityVisibilityReporting)?
            .setActivityVisibilityHandler(nil)
        panel.close()
        synchronizePointerMonitoring()
    }

    private func synchronizePointerMonitoring() {
        lifecycleEventSource.setPointerMonitoringEnabled(
            isRunning
                && policy.isEnabled
                && !isWorkspaceSleeping
                && !isShutdown
                && !presentedPanelIDs.isEmpty
        )
    }

    private func updatePointer(_ screenPoint: CGPoint, forceAll: Bool = false) {
        guard forceAll || lastPointerScreenPoint != screenPoint else { return }

        let previousDisplayID = pointerDisplayID
        var currentDisplayID: CGDirectDisplayID?
        for (displayID, frame) in displayFrames where frame.contains(screenPoint) {
            if let candidate = currentDisplayID {
                currentDisplayID = min(candidate, displayID)
            } else {
                currentDisplayID = displayID
            }
        }
        lastPointerScreenPoint = screenPoint
        pointerDisplayID = currentDisplayID

        if forceAll {
            panels.values.forEach { $0.updatePointer(screenPoint: screenPoint) }
            return
        }

        if let previousDisplayID {
            panels[previousDisplayID]?.updatePointer(screenPoint: screenPoint)
        }
        if let currentDisplayID, currentDisplayID != previousDisplayID {
            panels[currentDisplayID]?.updatePointer(screenPoint: screenPoint)
        }
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
        lifecycleEventSource.setPointerMonitoringEnabled(false)
        lifecycleEventSource.stop()
    }

    private func closeAllPanels() {
        panels.values.forEach { panel in
            (panel as? any PanelPresentationDemandReporting)?
                .setPresentationDemandHandler(nil)
            (panel as? any PanelActivityVisibilityReporting)?
                .setActivityVisibilityHandler(nil)
            panel.close()
        }
        panels.removeAll()
        panelLeases.removeAll()
        presentedPanelIDs.removeAll()
        fallbackManualPresentationIDs.removeAll()
        lifecycleEventSource.setPointerMonitoringEnabled(false)
        displaySnapshots.removeAll()
        displayFrames.removeAll()
        lastPointerScreenPoint = nil
        pointerDisplayID = nil
        selectedDisplayIdentity = nil
        reportActivityVisibilityIfNeeded()
    }

    private func reportActivityVisibilityIfNeeded(force: Bool = false) {
        let visible = panels.values.contains { panel in
            (panel as? any PanelActivityVisibilityReporting)?
                .isActivitySurfaceVisible == true
        }
        guard force || visible != lastReportedActivityVisibility else { return }
        lastReportedActivityVisibility = visible
        activityVisibilityHandler?(visible)
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
