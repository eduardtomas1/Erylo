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
package final class PanelWindowTransitionGate {
    /// One 60 Hz frame gives SwiftUI a real Hidden commit before Compact begins.
    /// A zero-delay main-actor hop can be coalesced into the final state.
    package static let orderInStagingDelay = Duration.milliseconds(16)

    package enum PendingKind: Equatable, Sendable {
        case orderInCommit
        case orderOut
    }

    private let scheduler: any OneShotScheduling
    private var pendingOperation: (any ScheduledOperation)?
    private var generation: UInt64 = 0

    package private(set) var pendingKind: PendingKind?

    package var hasPendingOrderOut: Bool {
        pendingKind == .orderOut
    }

    package init(scheduler: any OneShotScheduling) {
        self.scheduler = scheduler
    }

    /// Orders the transparent window first while its rendered model is Hidden,
    /// then commits the latest visible destination after one display frame so
    /// SwiftUI owns the morph.
    package func orderIn(
        stageHidden: @MainActor () -> Bool,
        orderFront: @MainActor () -> Void,
        commitCompact: @escaping @MainActor @Sendable () -> Void
    ) {
        cancel()
        let isStaged = stageHidden()
        orderFront()
        guard isStaged else { return }
        schedule(
            kind: .orderInCommit,
            after: Self.orderInStagingDelay,
            operation: commitCompact
        )
    }

    /// A nil delay is the Reduce Motion path and performs synchronously.
    package func orderOut(
        after delay: Duration?,
        perform: @escaping @MainActor @Sendable () -> Void
    ) {
        cancel()
        guard let delay else {
            perform()
            return
        }
        schedule(kind: .orderOut, after: delay, operation: perform)
    }

    package func cancel() {
        generation &+= 1
        pendingOperation?.cancel()
        pendingOperation = nil
        pendingKind = nil
    }

    private func schedule(
        kind: PendingKind,
        after delay: Duration,
        operation: @escaping @MainActor @Sendable () -> Void
    ) {
        generation &+= 1
        let lease = generation
        pendingKind = kind
        pendingOperation = scheduler.schedule(after: delay) { [weak self] in
            guard let self,
                  self.generation == lease,
                  self.pendingKind == kind else {
                return
            }
            self.pendingOperation = nil
            self.pendingKind = nil
            operation()
        }
    }
}

package enum DeliberatePanelFocusLeasePolicy {
    package static func admits(
        pending: PanelDeliberateFocusDestination,
        current: PanelDeliberateFocusDestination
    ) -> Bool {
        pending == current
    }
}

@MainActor
final class PanelController: PanelPresenting, PanelActivityVisibilityReporting,
    PanelPresentationDemandReporting, PanelFocusTimerLaunching,
    PanelImmediateEnvironmentalHiding, PanelExistingControlFocusing {
    let directDisplayID: CGDirectDisplayID

    var displayIdentity: DisplayIdentity {
        DisplayIdentity(rawValue: directDisplayID)
    }

    private let panel: NonActivatingPanel
    private let rootView: PanelHitTestView
    private let model: PanelSurfaceModel
    private let windowTransitionGate: PanelWindowTransitionGate
    private let expandedMouseDownMonitor = ExpandedMouseDownMonitor()
    private var isVisible = false
    private var lastReportedActivityVisibility = false
    private var activityVisibilityHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var lastReportedPresentationDemand = false
    private var presentationDemandHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var isFullscreenAuxiliaryEnabled = false
    private var pendingDeliberateKeyRequest: PanelDeliberateFocusDestination?

    var isActivitySurfaceVisible: Bool {
        isVisible && model.renderedState != .hidden
    }

    var wantsSurfacePresentation: Bool {
        model.state != .hidden
    }

    init(
        snapshot: DisplaySnapshot,
        activityModel: SurfaceActivityModel,
        initialState: PanelPresentationState = .hidden,
        transitionScheduler: any OneShotScheduling = TaskOneShotScheduler()
    ) {
        directDisplayID = CGDirectDisplayID(snapshot.identity.rawValue)
        windowTransitionGate = PanelWindowTransitionGate(
            scheduler: transitionScheduler
        )
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
        windowTransitionGate.orderIn(
            stageHidden: { [weak self] in
                guard let self else { return false }
                let isStaged = self.model.stageForWindowOrderIn()
                // SwiftUI commits asynchronously. A transparent mount prevents
                // AppKit from flashing the previously cached final frame before
                // the real Hidden frame has reached the render server.
                self.panel.alphaValue = isStaged ? 0 : 1
                return isStaged
            },
            orderFront: { [weak self] in
                guard let self, self.isVisible else { return }
                self.panel.orderFrontRegardless()
                self.model.setWindowPresented(true)
            },
            commitCompact: { [weak self] in
                guard let self, self.isVisible else { return }
                guard self.model.commitStagedWindowOrderIn() else { return }
                self.panel.alphaValue = 1
            }
        )
        synchronizeExpandedInteraction()
        updatePointer(screenPoint: NSEvent.mouseLocation)
        reportActivityVisibilityIfNeeded()
    }

    func close() {
        windowTransitionGate.cancel()
        pendingDeliberateKeyRequest = nil
        beginLogicalHide()
        panel.escapeDismissalHandler = nil
        model.setWindowPresented(false)
        model.prepareForWindowOrderOut()
        panel.close()
    }

    func hide() {
        pendingDeliberateKeyRequest = nil
        beginLogicalHide()
        let wasUnrevealedEntrance = windowTransitionGate.pendingKind == .orderInCommit
            && panel.alphaValue == 0
        // Nothing has reached the screen when the one-frame entrance is still
        // transparent, so there is no exit to animate. Every visible standard-
        // motion surface explicitly reaches Hidden before AppKit orders it out.
        let delay = wasUnrevealedEntrance ? nil : model.stageForWindowOrderOut()
        windowTransitionGate.orderOut(after: delay) { [weak self] in
            guard let self,
                  !self.isVisible,
                  self.model.renderedState == .hidden else {
                return
            }
            self.performPhysicalOrderOut()
        }
    }

    func hideImmediatelyForEnvironmentalTransition() {
        windowTransitionGate.cancel()
        pendingDeliberateKeyRequest = nil
        beginLogicalHide()
        performPhysicalOrderOut()
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
        // Shortcut and menu actions enter through the native owner. Pointer
        // taps mutate the model inside PanelSurfaceView and remain nonactivating.
        pendingDeliberateKeyRequest = nil
        let oldState = model.state
        model.send(.primaryAction)
        let isDeliberateFocusDestination = DeliberatePanelFocusPolicy.shouldRequestKey(
            from: oldState,
            to: model.state,
            isWindowPresented: true,
            hasExplicitControls: model.logicalContentHasExplicitControls
        )
        if isDeliberateFocusDestination {
            pendingDeliberateKeyRequest = model.deliberateFocusDestination
            fulfillPendingDeliberateKeyRequestIfReady()
        }
    }

    func focusExistingControls() -> Bool {
        guard DeliberatePanelFocusPolicy.shouldFocusExistingControls(
            state: model.state,
            isWindowPresented: isVisible,
            hasExplicitControls: model.logicalContentHasExplicitControls
        ) else {
            return false
        }
        pendingDeliberateKeyRequest = model.deliberateFocusDestination
        fulfillPendingDeliberateKeyRequestIfReady()
        return true
    }

    func performVisibilityToggle() {
        model.send(model.state == .hidden ? .show : .hide)
    }

    func cancelPendingInteractions() {
        model.cancelPendingInteractions()
    }

    func contractForEnvironmentalTransition() {
        pendingDeliberateKeyRequest = nil
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
            self?.handleEscape() ?? false
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
        if windowTransitionGate.pendingKind == .orderInCommit,
           model.motionStyle == .reduced {
            // Reduce Motion can change during the one-frame transparent mount.
            // Reveal the model's synchronously resolved state and retire the
            // now-invalid delayed commit instead of leaving an invisible panel.
            windowTransitionGate.cancel()
            panel.alphaValue = 1
        }
        if !isVisible,
           windowTransitionGate.hasPendingOrderOut,
           model.motionStyle == .reduced {
            windowTransitionGate.cancel()
            performPhysicalOrderOut()
            return
        }

        let layout = model.layout
        panel.setFrame(layout.fixedFrame, display: true, animate: false)
        rootView.frame = CGRect(origin: .zero, size: layout.fixedFrame.size)
        rootView.hitRegion = model.interactionHitRegion
        rootView.needsLayout = true
        synchronizeExpandedInteraction()
        fulfillPendingDeliberateKeyRequestIfReady()
        reportPresentationDemandIfNeeded()
        if isVisible {
            updatePointer(screenPoint: NSEvent.mouseLocation)
        }
        reportActivityVisibilityIfNeeded()
    }

    private func beginLogicalHide() {
        isVisible = false
        retireExpandedInteraction()
        panel.ignoresMouseEvents = true
        reportActivityVisibilityIfNeeded()
    }

    private func performPhysicalOrderOut() {
        guard !isVisible else { return }
        model.setWindowPresented(false)
        model.prepareForWindowOrderOut()
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private var expandedInteractionPolicy: ExpandedInteractionPolicy {
        ExpandedInteractionPolicy(
            state: model.state,
            isWindowPresented: isVisible,
            hitRegion: model.interactionHitRegion,
            hasExplicitControls: model.content.hasExplicitControls
        )
    }

    private func fulfillPendingDeliberateKeyRequestIfReady() {
        guard let pendingDeliberateKeyRequest else { return }
        guard isVisible else { return }
        guard DeliberatePanelFocusLeasePolicy.admits(
            pending: pendingDeliberateKeyRequest,
            current: model.deliberateFocusDestination
        ) else {
            self.pendingDeliberateKeyRequest = nil
            return
        }
        if model.renderedState != .hidden,
           model.state != .expanded,
           !model.content.hasExplicitControls {
            self.pendingDeliberateKeyRequest = nil
            return
        }
        guard model.renderedState == model.state,
              model.isHitRegionSettled,
              expandedInteractionPolicy.allowsKeyInteraction else {
            return
        }
        self.pendingDeliberateKeyRequest = nil
        panel.makeKeyAndOrderFront(nil)
        model.requestDeliberateControlFocus()
    }

    private func synchronizeExpandedInteraction() {
        let policy = expandedInteractionPolicy
        applyKeyInteractionEligibility(policy.allowsKeyInteraction)

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
        applyKeyInteractionEligibility(false)
    }

    private func applyKeyInteractionEligibility(_ allowsKeyInteraction: Bool) {
        panel.allowsKeyInteraction = allowsKeyInteraction
        let retirementAction = PanelKeyRetirementPolicy.action(
            allowsKeyInteraction: allowsKeyInteraction,
            panelIsKey: panel.isKeyWindow,
            isWindowPresented: isVisible,
            wantsSurfacePresentation: wantsSurfacePresentation
        )
        guard retirementAction != .none else { return }

        pendingDeliberateKeyRequest = nil
        model.retireDeliberateControlFocus()
        panel.orderOut(nil)
        if retirementAction == .orderOutAndRestore {
            // Preserve a still-demanded nonactivating surface without making it
            // key again now that keyboard eligibility has been withdrawn.
            panel.orderFrontRegardless()
        }
    }

    private func handleExpandedMouseDown(screenPoint: CGPoint) {
        let localPoint = panel.convertPoint(fromScreen: screenPoint)
        guard expandedInteractionPolicy.mouseDownDecision(at: localPoint) == .dismiss else {
            return
        }
        model.send(.dismiss)
    }

    private func handleEscape() -> Bool {
        switch expandedInteractionPolicy.escapeDecision(panelIsKey: panel.isKeyWindow) {
        case .ignore:
            return false
        case .dismissPresentation:
            model.send(.dismiss)
        case .retireKeyFocus:
            // Ordering the surface out is the supported AppKit route for
            // retiring a nonactivating key panel. The current activity remains
            // in the broker, so hiding a completion never acknowledges Done.
            model.send(.hide)
        }
        pendingDeliberateKeyRequest = nil
        model.retireDeliberateControlFocus()
        return true
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
