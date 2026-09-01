import CoreGraphics
import EryloActivity
import EryloCore
import Foundation
import Observation

package struct PanelDeliberateFocusDestination: Equatable, Sendable {
    private let state: PanelPresentationState
    private let activitySource: String?
    private let activityIdentifier: String?
    private let activityRevision: UInt64?

    fileprivate init(
        state: PanelPresentationState,
        current: PresentedActivity?
    ) {
        self.state = state
        activitySource = current?.activity.identity.source.rawValue
        activityIdentifier = current?.activity.identity.identifier.rawValue
        activityRevision = current?.revision
    }
}

package enum PanelFocusableControl: Hashable, Sendable {
    case focusTimerPreset(Int)
    case completionDone
}

package struct PanelControlFocusRequest: Equatable, Sendable {
    package let control: PanelFocusableControl
    package let revision: UInt64
}

@MainActor
private final class PanelSurfaceOwnedResources {
    let activityModel: SurfaceActivityModel
    var activityObserverID: UUID?
    var pendingHoverOperation: (any ScheduledOperation)?
    var pendingMotionOperation: (any ScheduledOperation)?

    init(activityModel: SurfaceActivityModel) {
        self.activityModel = activityModel
    }

    func cleanup() {
        pendingHoverOperation?.cancel()
        pendingHoverOperation = nil
        pendingMotionOperation?.cancel()
        pendingMotionOperation = nil
        if let activityObserverID {
            activityModel.removeObserver(activityObserverID)
            self.activityObserverID = nil
        }
    }
}

@MainActor
@Observable
/// Borrows the shared activity model and owns only its observer registration and
/// one-shot interaction tokens. Detached release transfers those resources to
/// MainActor cleanup without capturing `self`.
public final class PanelSurfaceModel {
    public private(set) var stateMachine: PanelStateMachine
    /// The state currently drawn by SwiftUI. Window ordering may briefly stage
    /// this at Hidden while the logical reducer remains Compact and continues
    /// to demand presentation from the native coordinator.
    package private(set) var renderedState: PanelPresentationState
    public private(set) var displayGeometry: DisplayGeometry
    public private(set) var interactionHitRegion: HitRegion
    /// Newly revealed controls stay visually reserved but inert until AppKit's
    /// exact hit region has caught up with the completed surface morph.
    public private(set) var isHitRegionSettled = true
    public let metrics: PanelMetrics
    public let activityModel: SurfaceActivityModel
    package private(set) var deliberateControlFocusRequest: PanelControlFocusRequest? = nil

    @ObservationIgnored
    public var didChange: (@MainActor @Sendable () -> Void)?

    @ObservationIgnored
    private let scheduler: any OneShotScheduling

    @ObservationIgnored
    private let timing: PanelInteractionTiming

    @ObservationIgnored
    private let ownedResources: PanelSurfaceOwnedResources

    @ObservationIgnored
    private var nextControlFocusRevision: UInt64 = 0

    private var pendingHoverOperation: (any ScheduledOperation)? {
        get { ownedResources.pendingHoverOperation }
        set { ownedResources.pendingHoverOperation = newValue }
    }

    private var pendingMotionOperation: (any ScheduledOperation)? {
        get { ownedResources.pendingMotionOperation }
        set { ownedResources.pendingMotionOperation = newValue }
    }

    package private(set) var isPointerInside = false

    /// Physical NSPanel presentation, independent of the logical surface state.
    /// An ordered-out panel must not retain a SwiftUI timeline schedule.
    package private(set) var isWindowPresented = true

    @ObservationIgnored
    private var hoverRequiresExit = false

    @ObservationIgnored
    private var targetHitRegion: HitRegion

    /// A physically new window is mounted with Hidden geometry for one real
    /// display frame before its current logical state is committed. Keep this
    /// independent from the reducer so an activity handoff can change the
    /// destination (for example Compact to Peek) without exposing the final
    /// geometry before the entrance begins.
    @ObservationIgnored
    private var isWindowOrderInStaged = false

    @ObservationIgnored
    private var lastObservedActivity: ObservedActivityKey?

    private var reduceMotion = false

    @ObservationIgnored
    private var focusTimerStartHandler: (@MainActor @Sendable (Int) -> Bool)?

    public var state: PanelPresentationState {
        stateMachine.state
    }

    public var layout: PanelLayout {
        PanelLayout(
            display: displayGeometry,
            state: renderedState,
            metrics: metrics,
            showsFocusTimerLauncher: showsFocusTimerLauncher,
            minimumNotchWingWidth: minimumNotchWingWidth,
            minimumNotchBodyHeight: minimumNotchBodyHeight
        )
    }

    package var geometryAnimationKey: PanelSurfaceGeometryAnimationKey {
        PanelSurfaceGeometryAnimationKey(layout: layout)
    }

    public var showsFocusTimerLauncher: Bool {
        showsFocusTimerLauncher(in: renderedState)
    }

    private func showsFocusTimerLauncher(
        in presentationState: PanelPresentationState
    ) -> Bool {
        presentationState == .compact
            && activityModel.current == nil
            && focusTimerStartHandler != nil
    }

    private var showsTemporalTimer: Bool {
        activityModel.current?.activity.presentation.temporalProgress != nil
    }

    private var minimumNotchWingWidth: CGFloat {
        if showsTemporalTimer { return 48 }
        return switch activityModel.current?.activity.presentation.presentationRole {
        case .volumeMuted, .volumeUnmuted:
            42
        case .volumeOutputChanged:
            82
        case .standard:
            currentSurfaceItem?.composition == .standard ? 76 : 0
        case .completionAcknowledgement, .volumeLevelChanged, .none:
            0
        }
    }

    /// Notch-native states compose their body below the camera housing. Reserve
    /// enough vertical space for the active composition, bounded by the fixed
    /// panel envelope when unusually tall hardware leaves less room.
    private var minimumNotchBodyHeight: CGFloat {
        guard let occlusion = displayGeometry.topEdgeOcclusion else { return 0 }
        let availableBodyHeight = max(
            metrics.maximumSize.height - max(occlusion.frame.height, 0),
            0
        )
        return min(desiredMinimumNotchBodyHeight, availableBodyHeight)
    }

    private var desiredMinimumNotchBodyHeight: CGFloat {
        switch renderedState {
        case .peek:
            return switch currentSurfaceItem?.composition {
            case .timerCompletion:
                40
            case .standard:
                36
            case .timerCountdown,
                 .volumeLevel,
                 .volumeMuted,
                 .volumeUnmuted,
                 .volumeOutput,
                 .battery,
                 .charging,
                 .none:
                0
            }
        case .expanded:
            switch currentSurfaceItem?.composition {
            case .timerCountdown:
                return 112
            case .standard:
                if !activityModel.queueContext.items.isEmpty { return 176 }
                if activityModel.currentAction != nil { return 132 }
                return 104
            case .timerCompletion,
                 .volumeLevel,
                 .volumeMuted,
                 .volumeUnmuted,
                 .volumeOutput,
                 .battery,
                 .charging,
                 .none:
                return 0
            }
        case .hidden, .compact, .dropTarget:
            return 0
        }
    }

    package var isTemporalProjectionActive: Bool {
        isWindowPresented && renderedState != .hidden && showsTemporalTimer
    }

    /// The silhouette itself is a control only when tapping its background has
    /// a deterministic action. Child buttons own their own events so preset,
    /// Done, and provider actions cannot also trigger the ancestor surface.
    package var acceptsBackgroundTap: Bool {
        switch content.interactionRole {
        case .expand:
            true
        case .collapse:
            content.action == nil
        case .dismiss, .none:
            false
        }
    }

    /// Passive acknowledgements are visual HUDs, not dead controls. They must
    /// remain click-through so a Volume or Battery cue cannot block menu extras.
    package var acceptsPointerInteraction: Bool {
        showsFocusTimerLauncher || content.action != nil || acceptsBackgroundTap
    }

    public var content: ActivitySurfaceContent {
        ActivitySurfaceContent(
            state: renderedState,
            phase: activityModel.phase,
            current: activityModel.current,
            queueContext: activityModel.queueContext,
            action: activityModel.currentAction,
            actionDispatchState: activityModel.actionDispatchState,
            showsFocusTimerLauncher: showsFocusTimerLauncher
        )
    }

    /// Focus admission follows the reducer destination, not the temporarily
    /// staged render. A synchronous presentation-demand callback can move
    /// `renderedState` back to Hidden before the shortcut owner resumes.
    package var logicalContentHasExplicitControls: Bool {
        ActivitySurfaceContent(
            state: state,
            phase: activityModel.phase,
            current: activityModel.current,
            queueContext: activityModel.queueContext,
            action: activityModel.currentAction,
            actionDispatchState: activityModel.actionDispatchState,
            showsFocusTimerLauncher: showsFocusTimerLauncher(in: state)
        ).hasExplicitControls
    }

    package var deliberateFocusDestination: PanelDeliberateFocusDestination {
        PanelDeliberateFocusDestination(
            state: state,
            current: activityModel.current
        )
    }

    package func requestDeliberateControlFocus() {
        guard let control = preferredFocusableControl else { return }
        nextControlFocusRevision &+= 1
        deliberateControlFocusRequest = PanelControlFocusRequest(
            control: control,
            revision: nextControlFocusRevision
        )
    }

    package func retireDeliberateControlFocus() {
        deliberateControlFocusRequest = nil
    }

    public var accessibility: PanelSurfaceAccessibility {
        PanelSurfaceAccessibility(content: content)
    }

    public var motionStyle: PanelMotionStyle {
        reduceMotion ? .reduced : .standard
    }

    package var accessibilitySurfaceAction: PanelAccessibilitySurfaceAction? {
        switch content.interactionRole {
        case .expand:
            .expand
        case .collapse:
            .collapse
        case .dismiss:
            .dismiss
        case .none:
            nil
        }
    }

    /// Preserves the original technical-spike construction API with a fully inert activity model.
    public convenience init(
        displayGeometry: DisplayGeometry,
        initialState: PanelPresentationState = .compact,
        metrics: PanelMetrics = .feasibility,
        scheduler: any OneShotScheduling = TaskOneShotScheduler(),
        timing: PanelInteractionTiming = .standard
    ) {
        self.init(
            displayGeometry: displayGeometry,
            initialState: initialState,
            metrics: metrics,
            scheduler: scheduler,
            timing: timing,
            activityModel: SurfaceActivityModel(inert: ())
        )
    }

    public init(
        displayGeometry: DisplayGeometry,
        initialState: PanelPresentationState = .hidden,
        metrics: PanelMetrics = .feasibility,
        scheduler: any OneShotScheduling = TaskOneShotScheduler(),
        timing: PanelInteractionTiming = .standard,
        activityModel: SurfaceActivityModel
    ) {
        self.displayGeometry = displayGeometry
        self.metrics = metrics
        self.scheduler = scheduler
        self.timing = timing
        self.activityModel = activityModel
        ownedResources = PanelSurfaceOwnedResources(activityModel: activityModel)
        let resolvedInitialState = Self.normalizedInitialState(
            initialState,
            current: activityModel.current,
            action: activityModel.currentAction,
            queue: activityModel.queueContext
        )
        var initialStateMachine = PanelStateMachine(initialState: resolvedInitialState)
        if resolvedInitialState == .hidden, activityModel.current != nil {
            initialStateMachine.updateActivityAvailability(true)
        }
        if initialStateMachine.state == .compact,
           activityModel.current.map(ActivitySurfaceItem.init)?.composition == .timerCompletion {
            // A lazily created panel may receive an already-current completion
            // before its observer is installed. Mirror activityDidChange so its
            // routed Done control is visible on the first presented frame.
            initialStateMachine.send(.hoverBegan)
        }
        stateMachine = initialStateMachine
        renderedState = initialStateMachine.state
        interactionHitRegion = .empty
        targetHitRegion = .empty
        lastObservedActivity = Self.observedActivityKey(activityModel.current)
        let initialLayout = layout
        interactionHitRegion = initialLayout.hitRegion
        targetHitRegion = initialLayout.hitRegion
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

    public func send(_ event: PanelEvent) {
        if event != .hoverBegan, event != .hoverEnded {
            cancelPendingHover()
        }
        if event == .hoverBegan, hoverRequiresExit {
            return
        }
        if event == .primaryAction,
           content.interactionRole == .dismiss {
            dispatchCompletionDismissAction()
            return
        }
        guard admits(event) else { return }
        let oldState = state
        if event == .primaryAction,
           activityModel.current == nil,
           state != .dropTarget {
            stateMachine.send(state == .hidden ? .show : .hide)
        } else {
            stateMachine.send(event)
        }
        guard state != oldState else { return }
        if isExplicitContraction(event, from: oldState, to: state) {
            hoverRequiresExit = isPointerInside
        }
        publishStateLayoutChange()
    }

    public func setPointerInside(_ isInside: Bool) {
        if !isInside {
            hoverRequiresExit = false
        }
        guard isPointerInside != isInside else { return }
        isPointerInside = isInside
        cancelPendingHover()

        let event: PanelEvent
        let delay: Duration
        switch (state, isInside) {
        case (.compact, true) where !hoverRequiresExit && allowsHoverPeek:
            event = .hoverBegan
            delay = timing.hoverEntryDelay
        case (.peek, false):
            event = .hoverEnded
            delay = timing.hoverExitDelay
        default:
            return
        }

        scheduleHoverTransition(event, pointerInside: isInside, after: delay)
    }

    private func scheduleHoverTransition(
        _ event: PanelEvent,
        pointerInside: Bool,
        after delay: Duration
    ) {
        pendingHoverOperation = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.pendingHoverOperation = nil
            guard self.isPointerInside == pointerInside else { return }
            self.transition(event)
        }
    }

    public func updateReduceMotion(_ reduceMotion: Bool) {
        guard self.reduceMotion != reduceMotion else { return }
        self.reduceMotion = reduceMotion
        guard reduceMotion else { return }

        pendingMotionOperation?.cancel()
        pendingMotionOperation = nil
        isWindowOrderInStaged = false
        renderedState = state
        let exactRegion = layout.hitRegion
        targetHitRegion = exactRegion
        interactionHitRegion = exactRegion
        isHitRegionSettled = true
        // This notification also lets the native window owner finish a pending
        // delayed order-out immediately when Reduce Motion becomes enabled.
        didChange?()
    }

    package func performAccessibilitySurfaceAction() {
        switch accessibilitySurfaceAction {
        case .expand:
            send(.primaryAction)
        case .collapse:
            send(.dismiss)
        case .dismiss:
            dispatchCompletionDismissAction()
        case nil:
            break
        }
    }

    package func setWindowPresented(_ isPresented: Bool) {
        guard isWindowPresented != isPresented else { return }
        isWindowPresented = isPresented
        if !isPresented {
            isWindowOrderInStaged = false
        }
    }

    /// Stages a physically ordered-in panel at zero rendered geometry.
    /// Logical state is deliberately untouched so the presentation demand that
    /// caused the order-in cannot recursively withdraw itself. The destination
    /// may be Compact or Peek and may change while the window is staged.
    @discardableResult
    package func stageForWindowOrderIn() -> Bool {
        guard !reduceMotion,
              !isWindowPresented,
              state == .compact || state == .peek,
              renderedState == state else {
            return false
        }

        pendingMotionOperation?.cancel()
        pendingMotionOperation = nil
        isWindowOrderInStaged = true
        renderedState = .hidden
        let hiddenRegion = layout.hitRegion
        targetHitRegion = hiddenRegion
        interactionHitRegion = hiddenRegion
        isHitRegionSettled = true
        didChange?()
        return true
    }

    /// Commits the staged render after the window gate's one-frame delay. Every guard is a
    /// stale-callback barrier for activity loss, environmental retirement, or a
    /// newer visibility request.
    @discardableResult
    package func commitStagedWindowOrderIn() -> Bool {
        guard isWindowPresented,
              isWindowOrderInStaged,
              state != .hidden,
              renderedState == .hidden else {
            return false
        }
        isWindowOrderInStaged = false
        renderedState = state
        publishRenderedLayoutChange()
        return true
    }

    /// A nil delay is the Reduce Motion contract: no physical exit staging.
    package var windowOrderOutDelay: Duration? {
        reduceMotion ? nil : timing.motionDuration
    }

    /// Keeps the physical window alive while SwiftUI morphs the currently
    /// rendered surface to Hidden. Logical demand is not rewritten here: menu
    /// visibility and coordinator policy remain the source of truth.
    @discardableResult
    package func stageForWindowOrderOut() -> Duration? {
        guard isWindowPresented else { return nil }
        isWindowOrderInStaged = false
        let delay = reduceMotion ? nil : timing.motionDuration

        cancelPendingHover()
        pendingMotionOperation?.cancel()
        pendingMotionOperation = nil
        isPointerInside = false
        hoverRequiresExit = false

        guard renderedState != .hidden else {
            return delay
        }

        renderedState = .hidden
        let hiddenRegion = layout.hitRegion
        targetHitRegion = hiddenRegion
        interactionHitRegion = interactionHitRegion.intersecting(hiddenRegion)
        isHitRegionSettled = interactionHitRegion == hiddenRegion
        didChange?()
        return delay
    }

    /// Physical retirement is a presentation boundary. Preserve valid activity
    /// content, but discard transient or deliberate expansion so wake, a Space
    /// change, or a later policy reconciliation can only restore Compact.
    package func prepareForWindowOrderOut() {
        cancelPendingHover()
        pendingMotionOperation?.cancel()
        pendingMotionOperation = nil
        isWindowOrderInStaged = false
        isPointerInside = false
        hoverRequiresExit = false

        let oldState = state
        let oldRenderedState = renderedState
        let oldInteractionHitRegion = interactionHitRegion
        let wasHitRegionSettled = isHitRegionSettled
        if activityModel.current == nil {
            stateMachine.send(.hide)
        } else {
            switch state {
            case .peek:
                stateMachine.send(.hoverEnded)
            case .expanded, .dropTarget:
                stateMachine.send(.dismiss)
            case .hidden, .compact:
                break
            }
        }

        renderedState = state
        let contractedRegion = layout.hitRegion
        targetHitRegion = contractedRegion
        interactionHitRegion = contractedRegion
        isHitRegionSettled = true
        if state != oldState
            || renderedState != oldRenderedState
            || interactionHitRegion != oldInteractionHitRegion
            || !wasHitRegionSettled {
            didChange?()
        }
    }

    package func setFocusTimerStartHandler(
        _ handler: (@MainActor @Sendable (Int) -> Bool)?
    ) {
        guard (focusTimerStartHandler == nil) != (handler == nil) else {
            focusTimerStartHandler = handler
            return
        }
        focusTimerStartHandler = handler
        synchronizeSameStateLayoutIfNeeded()
    }

    @discardableResult
    package func startFocusTimer(minutes: Int) -> Bool {
        guard [15, 25, 50].contains(minutes),
              showsFocusTimerLauncher,
              let focusTimerStartHandler else {
            return false
        }
        return focusTimerStartHandler(minutes)
    }

    public func pointerDisposition(at localPoint: CGPoint) -> PanelPointerDisposition {
        guard acceptsPointerInteraction else {
            return PanelPointerDisposition(
                acceptsMouseEvents: false,
                isInsideTargetSurface: false
            )
        }
        let currentLayout = layout
        let isInsideHoverTarget = currentLayout.hoverAnchorRegion.contains(localPoint)
            || currentLayout.hitRegion.contains(localPoint)
        return PanelPointerDisposition(
            acceptsMouseEvents: interactionHitRegion.contains(localPoint),
            isInsideTargetSurface: isInsideHoverTarget
        )
    }

    public func cancelPendingInteractions() {
        cancelPendingHover()
        pendingMotionOperation?.cancel()
        pendingMotionOperation = nil
        isPointerInside = false
        hoverRequiresExit = false
        let targetRegion = layout.hitRegion
        targetHitRegion = targetRegion
        let needsChange = interactionHitRegion != targetRegion || !isHitRegionSettled
        guard needsChange else { return }
        interactionHitRegion = targetRegion
        isHitRegionSettled = true
        didChange?()
    }

    private func transition(_ event: PanelEvent) {
        guard admits(event) else { return }
        let oldState = state
        stateMachine.send(event)
        if state != oldState {
            publishStateLayoutChange()
        }
    }

    private func isExplicitContraction(
        _ event: PanelEvent,
        from oldState: PanelPresentationState,
        to newState: PanelPresentationState
    ) -> Bool {
        switch (event, oldState, newState) {
        case (.primaryAction, .expanded, .compact),
             (.primaryAction, _, .hidden),
             (.hide, _, .hidden),
             (.dismiss, _, .compact),
             (.dismiss, _, .hidden):
            true
        default:
            false
        }
    }

    private func beginHitRegionTransition(to targetRegion: HitRegion) {
        pendingMotionOperation?.cancel()
        self.targetHitRegion = targetRegion
        interactionHitRegion = interactionHitRegion.intersecting(targetRegion)

        if reduceMotion || interactionHitRegion == targetRegion {
            interactionHitRegion = targetRegion
            isHitRegionSettled = true
            pendingMotionOperation = nil
            return
        }

        isHitRegionSettled = false
        pendingMotionOperation = scheduler.schedule(after: timing.motionDuration) { [weak self] in
            guard let self else { return }
            self.pendingMotionOperation = nil
            self.interactionHitRegion = self.layout.hitRegion
            self.isHitRegionSettled = true
            self.didChange?()
        }
    }

    private func publishStateLayoutChange() {
        if isWindowOrderInStaged {
            if state == .hidden {
                isWindowOrderInStaged = false
            } else {
                // Preserve the committed Hidden frame while the logical target
                // evolves. The order-in gate will reveal the newest valid state.
                didChange?()
                return
            }
        }
        renderedState = state
        publishRenderedLayoutChange()
    }

    private func publishRenderedLayoutChange() {
        let currentLayout = layout
        beginHitRegionTransition(to: currentLayout.hitRegion)
        didChange?()
    }

    /// Activity content and launcher availability can change geometry without a
    /// presentation-state transition. Shrinking adopts the exact smaller hit region
    /// immediately; growth remains conservative until the visual morph settles.
    private func synchronizeSameStateLayoutIfNeeded() {
        let currentLayout = layout
        guard currentLayout.hitRegion != targetHitRegion else { return }
        beginHitRegionTransition(to: currentLayout.hitRegion)
        didChange?()
    }

    private func cancelPendingHover() {
        pendingHoverOperation?.cancel()
        pendingHoverOperation = nil
    }

    private func activityDidChange() {
        let hadPendingHover = pendingHoverOperation != nil
        let shouldRestoreHoverEntry = hadPendingHover
            && state == .compact
            && isPointerInside
        let shouldRestoreHoverExit = hadPendingHover
            && state == .peek
            && !isPointerInside
        cancelPendingHover()
        let previousActivity = lastObservedActivity
        let nextActivity = Self.observedActivityKey(activityModel.current)
        lastObservedActivity = nextActivity
        let hasActivity = activityModel.current != nil
        let oldState = state
        stateMachine.updateActivityAvailability(hasActivity)

        if oldState == .expanded, previousActivity != nextActivity {
            stateMachine.send(hasActivity ? .dismiss : .hide)
        } else if state == .expanded, !allowsExpandedPresentation {
            stateMachine.send(.dismiss)
        }

        if state == .peek,
           !isCompletionAcknowledgement,
           !allowsHoverPeek {
            stateMachine.send(.hoverEnded)
        }
        if state == .compact,
           isCompletionAcknowledgement {
            stateMachine.send(.hoverBegan)
        }
        if state != oldState {
            if oldState == .expanded, state != .expanded {
                hoverRequiresExit = isPointerInside
            } else if !hasActivity {
                hoverRequiresExit = isPointerInside
            }
            publishStateLayoutChange()
        } else {
            synchronizeSameStateLayoutIfNeeded()
        }

        if shouldRestoreHoverEntry,
           state == .compact,
           isPointerInside,
           !hoverRequiresExit,
           allowsHoverPeek {
            scheduleHoverTransition(
                .hoverBegan,
                pointerInside: true,
                after: timing.hoverEntryDelay
            )
        } else if shouldRestoreHoverExit,
                  state == .peek,
                  !isPointerInside,
                  allowsHoverPeek {
            scheduleHoverTransition(
                .hoverEnded,
                pointerInside: false,
                after: timing.hoverExitDelay
            )
        }
    }

    public func update(displayGeometry: DisplayGeometry) {
        guard self.displayGeometry != displayGeometry else { return }
        self.displayGeometry = displayGeometry
        pendingMotionOperation?.cancel()
        pendingMotionOperation = nil
        let currentLayout = layout
        interactionHitRegion = currentLayout.hitRegion
        targetHitRegion = currentLayout.hitRegion
        isHitRegionSettled = true
        didChange?()
    }

    private var currentSurfaceItem: ActivitySurfaceItem? {
        activityModel.current.map(ActivitySurfaceItem.init)
    }

    private var preferredFocusableControl: PanelFocusableControl? {
        if showsFocusTimerLauncher(in: state) {
            return .focusTimerPreset(25)
        }
        guard isCompletionAcknowledgement,
              (state == .compact || state == .peek),
              activityModel.currentAction?.intent == .dismiss else {
            return nil
        }
        return .completionDone
    }

    private var isCompletionAcknowledgement: Bool {
        currentSurfaceItem?.composition == .timerCompletion
    }

    private var allowsHoverPeek: Bool {
        currentSurfaceItem?.hasUsefulPeekDetail == true
    }

    private var allowsExpandedPresentation: Bool {
        guard let currentSurfaceItem else { return false }
        return currentSurfaceItem.supportsExpandedPresentation(
            action: activityModel.currentAction,
            queue: activityModel.queueContext
        )
    }

    private func admits(_ event: PanelEvent) -> Bool {
        switch (state, event) {
        case (.compact, .hoverBegan):
            allowsHoverPeek
        case (.compact, .primaryAction), (.peek, .primaryAction):
            activityModel.current == nil || allowsExpandedPresentation
        default:
            true
        }
    }

    private func dispatchCompletionDismissAction() {
        guard isCompletionAcknowledgement,
              let action = activityModel.currentAction,
              action.intent == .dismiss else {
            return
        }
        _ = activityModel.dispatch(action)
    }

    private static func normalizedInitialState(
        _ state: PanelPresentationState,
        current: PresentedActivity?,
        action: SurfaceActivityAction?,
        queue: ActivityQueueContext
    ) -> PanelPresentationState {
        guard let current else {
            return (state == .expanded || state == .peek) ? .compact : state
        }
        let item = ActivitySurfaceItem(current)
        switch state {
        case .peek:
            return item.composition == .timerCompletion || item.hasUsefulPeekDetail
                ? .peek
                : .compact
        case .expanded:
            return item.supportsExpandedPresentation(action: action, queue: queue)
                ? .expanded
                : .compact
        case .hidden, .compact, .dropTarget:
            return state
        }
    }

    private static func observedActivityKey(
        _ current: PresentedActivity?
    ) -> ObservedActivityKey? {
        current.map {
            ObservedActivityKey(identity: $0.activity.identity, revision: $0.revision)
        }
    }
}

private struct ObservedActivityKey: Equatable {
    let identity: ActivityIdentity
    let revision: UInt64
}

package struct PanelSurfaceGeometryAnimationKey: Equatable, Sendable {
    package let surfaceSize: CGSize
    package let cornerRadius: CGFloat
    package let topCornerRadius: CGFloat
    package let contentTopInset: CGFloat
    package let attachment: PanelAttachment

    package init(layout: PanelLayout) {
        surfaceSize = layout.surfaceFrame.size
        cornerRadius = layout.cornerRadius
        topCornerRadius = layout.topCornerRadius
        contentTopInset = layout.surfaceContentTopInset
        attachment = layout.attachment
    }
}

public enum PanelMotionStyle: Equatable, Sendable {
    case standard
    case reduced

    package var allowsHoverOpacityAnimation: Bool {
        self == .standard
    }
}

package enum PanelAccessibilitySurfaceAction: Equatable, Sendable {
    case expand
    case collapse
    case dismiss

    package var label: String {
        switch self {
        case .expand:
            SurfaceStrings.expandAction
        case .collapse:
            SurfaceStrings.collapseAction
        case .dismiss:
            SurfaceStrings.dismissCompletionAction
        }
    }
}

public struct PanelPointerDisposition: Equatable, Sendable {
    public let acceptsMouseEvents: Bool
    public let isInsideTargetSurface: Bool

    public init(acceptsMouseEvents: Bool, isInsideTargetSurface: Bool) {
        self.acceptsMouseEvents = acceptsMouseEvents
        self.isInsideTargetSurface = isInsideTargetSurface
    }
}

public struct PanelInteractionTiming: Equatable, Sendable {
    public let hoverEntryDelay: Duration
    public let hoverExitDelay: Duration
    public let motionDuration: Duration

    public init(
        hoverEntryDelay: Duration,
        hoverExitDelay: Duration,
        motionDuration: Duration
    ) {
        self.hoverEntryDelay = hoverEntryDelay
        self.hoverExitDelay = hoverExitDelay
        self.motionDuration = motionDuration
    }

    public static let standard = PanelInteractionTiming(
        hoverEntryDelay: .milliseconds(120),
        hoverExitDelay: .milliseconds(300),
        motionDuration: .milliseconds(220)
    )
}
