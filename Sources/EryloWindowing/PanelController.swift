import AppKit
import EryloCore
import EryloSurface
import SwiftUI

package enum PanelCollectionBehaviorPolicy {
    package static func make(
        allowsFullscreenAuxiliary: Bool
    ) -> NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        if allowsFullscreenAuxiliary {
            behavior.insert(.fullScreenAuxiliary)
        }
        return behavior
    }
}

@MainActor
final class PanelController: PanelPresenting, PanelActivityVisibilityReporting,
    PanelPresentationDemandReporting, PanelFocusTimerLaunching {
    let directDisplayID: CGDirectDisplayID

    var displayIdentity: DisplayIdentity {
        DisplayIdentity(rawValue: directDisplayID)
    }

    private let panel: NonActivatingPanel
    private let rootView: PanelHitTestView
    private let model: PanelSurfaceModel
    private let expandedMouseDownMonitor = ExpandedMouseDownMonitor()
    private var isVisible = false
    private var lastReportedActivityVisibility = false
    private var activityVisibilityHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var lastReportedPresentationDemand = false
    private var presentationDemandHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var isFullscreenAuxiliaryEnabled = false

    var isActivitySurfaceVisible: Bool {
        isVisible && model.state != .hidden
    }

    var wantsSurfacePresentation: Bool {
        model.state != .hidden
    }

    init(
        snapshot: DisplaySnapshot,
        activityModel: SurfaceActivityModel,
        initialState: PanelPresentationState = .hidden
    ) {
        directDisplayID = CGDirectDisplayID(snapshot.identity.rawValue)
        model = PanelSurfaceModel(
            displayGeometry: snapshot.geometry,
            initialState: initialState,
            activityModel: activityModel
        )
        model.setWindowPresented(false)
        let layout = model.layout

        panel = NonActivatingPanel(
            contentRect: layout.fixedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        rootView = PanelHitTestView(frame: CGRect(origin: .zero, size: layout.fixedFrame.size))

        configurePanel()
        installSurface()
        refreshLayout()
        model.didChange = { [weak self] in
            self?.refreshLayout()
        }
    }

    func setActivityVisibilityHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        activityVisibilityHandler = handler
        reportActivityVisibilityIfNeeded(force: true)
    }

    func setPresentationDemandHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        presentationDemandHandler = handler
        reportPresentationDemandIfNeeded(force: true)
    }

    func setFocusTimerStartHandler(
        _ handler: (@MainActor @Sendable (Int) -> Bool)?
    ) {
        model.setFocusTimerStartHandler(handler)
    }

    func show() {
        isVisible = true
        panel.orderFrontRegardless()
        model.setWindowPresented(true)
        synchronizeExpandedInteraction()
        updatePointer(screenPoint: NSEvent.mouseLocation)
        reportActivityVisibilityIfNeeded()
    }

    func close() {
        isVisible = false
        retireExpandedInteraction()
        panel.escapeDismissalHandler = nil
        model.setWindowPresented(false)
        model.prepareForWindowOrderOut()
        panel.ignoresMouseEvents = true
        panel.close()
        reportActivityVisibilityIfNeeded()
    }

    func hide() {
        isVisible = false
        retireExpandedInteraction()
        model.setWindowPresented(false)
        model.prepareForWindowOrderOut()
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
        reportActivityVisibilityIfNeeded()
    }

    func update(snapshot: DisplaySnapshot) {
        model.update(displayGeometry: snapshot.geometry)
    }

    func updatePointer(screenPoint: CGPoint) {
        guard isVisible else {
            panel.ignoresMouseEvents = true
            return
        }
        let localPoint = panel.convertPoint(fromScreen: screenPoint)
        let pointerDisposition = model.pointerDisposition(at: localPoint)
        panel.ignoresMouseEvents = !pointerDisposition.acceptsMouseEvents
        model.setPointerInside(pointerDisposition.isInsideTargetSurface)
    }

    func performPrimaryAction() {
        model.send(.primaryAction)
    }

    func performVisibilityToggle() {
        model.send(model.state == .hidden ? .show : .hide)
    }

    func cancelPendingInteractions() {
        model.cancelPendingInteractions()
    }

    func contractForEnvironmentalTransition() {
        retireExpandedInteraction()
        model.prepareForWindowOrderOut()
    }

    func setFullscreenAuxiliaryEnabled(_ enabled: Bool) {
        guard isFullscreenAuxiliaryEnabled != enabled else { return }
        isFullscreenAuxiliaryEnabled = enabled
        updateCollectionBehavior()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        updateCollectionBehavior()
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.escapeDismissalHandler = { [weak self] in
            self?.dismissExpandedSurfaceForEscape()
        }
    }

    private func updateCollectionBehavior() {
        panel.collectionBehavior = PanelCollectionBehaviorPolicy.make(
            allowsFullscreenAuxiliary: isFullscreenAuxiliaryEnabled
        )
    }

    private func installSurface() {
        let hostingView = NSHostingView(rootView: PanelSurfaceView(model: model))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: rootView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        panel.contentView = rootView
    }

    private func refreshLayout() {
        let layout = model.layout
        panel.setFrame(layout.fixedFrame, display: true, animate: false)
        rootView.frame = CGRect(origin: .zero, size: layout.fixedFrame.size)
        rootView.hitRegion = model.interactionHitRegion
        rootView.needsLayout = true
        synchronizeExpandedInteraction()
        reportPresentationDemandIfNeeded()
        if isVisible {
            updatePointer(screenPoint: NSEvent.mouseLocation)
        }
        reportActivityVisibilityIfNeeded()
    }

    private var expandedInteractionPolicy: ExpandedInteractionPolicy {
        ExpandedInteractionPolicy(
            state: model.state,
            isWindowPresented: isVisible,
            hitRegion: model.interactionHitRegion
        )
    }

    private func synchronizeExpandedInteraction() {
        let policy = expandedInteractionPolicy
        panel.allowsKeyInteraction = policy.allowsKeyInteraction

        if policy.requiresMouseDownMonitoring {
            expandedMouseDownMonitor.start { [weak self] screenPoint in
                self?.handleExpandedMouseDown(screenPoint: screenPoint)
            }
        } else {
            expandedMouseDownMonitor.stop()
        }
    }

    private func retireExpandedInteraction() {
        expandedMouseDownMonitor.stop()
        panel.allowsKeyInteraction = false
    }

    private func handleExpandedMouseDown(screenPoint: CGPoint) {
        let localPoint = panel.convertPoint(fromScreen: screenPoint)
        guard expandedInteractionPolicy.mouseDownDecision(at: localPoint) == .dismiss else {
            return
        }
        model.send(.dismiss)
    }

    private func dismissExpandedSurfaceForEscape() {
        guard expandedInteractionPolicy.shouldHandleEscape(panelIsKey: panel.isKeyWindow) else {
            return
        }
        model.send(.dismiss)
    }

    private func reportPresentationDemandIfNeeded(force: Bool = false) {
        let isDemanded = wantsSurfacePresentation
        guard force || isDemanded != lastReportedPresentationDemand else { return }
        lastReportedPresentationDemand = isDemanded
        presentationDemandHandler?(isDemanded)
    }

    private func reportActivityVisibilityIfNeeded(force: Bool = false) {
        let visible = isActivitySurfaceVisible
        guard force || visible != lastReportedActivityVisibility else { return }
        lastReportedActivityVisibility = visible
        activityVisibilityHandler?(visible)
    }
}
