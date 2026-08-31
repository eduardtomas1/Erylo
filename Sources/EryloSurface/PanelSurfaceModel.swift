import CoreGraphics
import EryloCore
import Foundation
import Observation

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
    public private(set) var displayGeometry: DisplayGeometry
    public private(set) var interactionHitRegion: HitRegion
    public let metrics: PanelMetrics
    public let activityModel: SurfaceActivityModel

    @ObservationIgnored
    public var didChange: (@MainActor @Sendable () -> Void)?

    @ObservationIgnored
    private let scheduler: any OneShotScheduling

    @ObservationIgnored
    private let timing: PanelInteractionTiming

    @ObservationIgnored
    private let ownedResources: PanelSurfaceOwnedResources

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
    private var reduceMotion = false

    @ObservationIgnored
    private var focusTimerStartHandler: (@MainActor @Sendable (Int) -> Bool)?

    public var state: PanelPresentationState {
        stateMachine.state
    }

    public var layout: PanelLayout {
        PanelLayout(
            display: displayGeometry,
            state: state,
            metrics: metrics,
            showsFocusTimerLauncher: showsFocusTimerLauncher,
            minimumNotchWingWidth: showsTemporalTimer ? 48 : 0
        )
    }

    public var showsFocusTimerLauncher: Bool {
        state == .compact && activityModel.current == nil && focusTimerStartHandler != nil
    }

    private var showsTemporalTimer: Bool {
        activityModel.current?.activity.presentation.temporalProgress != nil
    }

    package var isTemporalProjectionActive: Bool {
        isWindowPresented && state != .hidden && showsTemporalTimer
    }

    public var content: ActivitySurfaceContent {
        ActivitySurfaceContent(
            state: state,
            phase: activityModel.phase,
            current: activityModel.current,
            queueContext: activityModel.queueContext,
            action: activityModel.currentAction,
            actionDispatchState: activityModel.actionDispatchState,
            showsFocusTimerLauncher: showsFocusTimerLauncher
        )
    }

    public var accessibility: PanelSurfaceAccessibility {
        PanelSurfaceAccessibility(content: content)
    }

    public var motionStyle: PanelMotionStyle {
        reduceMotion ? .reduced : .standard
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
        let resolvedInitialState: PanelPresentationState =
            initialState == .expanded && activityModel.current == nil
                ? .compact
                : initialState
        var initialStateMachine = PanelStateMachine(initialState: resolvedInitialState)
        if resolvedInitialState == .hidden, activityModel.current != nil {
            initialStateMachine.updateActivityAvailability(true)
        }
        stateMachine = initialStateMachine
        interactionHitRegion = PanelLayout(
            display: displayGeometry,
            state: initialStateMachine.state,
            metrics: metrics
        ).hitRegion
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
            hoverRequiresExit = true
        }
        beginHitRegionTransition(to: layout.hitRegion)
        didChange?()
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
        case (.peek, false):
            event = .hoverEnded
            delay = timing.hoverExitDelay
        default:
            return
        }

        pendingHoverOperation = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.pendingHoverOperation = nil
            guard self.isPointerInside == isInside else { return }
            self.transition(event)
        }
    }

    public func updateReduceMotion(_ reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    package func setWindowPresented(_ isPresented: Bool) {
        guard isWindowPresented != isPresented else { return }
        isWindowPresented = isPresented
    }

    package func setFocusTimerStartHandler(
        _ handler: (@MainActor @Sendable (Int) -> Bool)?
    ) {
        guard (focusTimerStartHandler == nil) != (handler == nil) else {
            focusTimerStartHandler = handler
            return
        }
        focusTimerStartHandler = handler
        beginHitRegionTransition(to: layout.hitRegion)
        didChange?()
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
        let targetRegion = layout.hitRegion
        guard interactionHitRegion != targetRegion else { return }
        interactionHitRegion = targetRegion
        didChange?()
    }

    private func transition(_ event: PanelEvent) {
        let oldState = state
        stateMachine.send(event)
        if state != oldState {
            beginHitRegionTransition(to: layout.hitRegion)
            didChange?()
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
        interactionHitRegion = interactionHitRegion.intersecting(targetRegion)

        let duration = reduceMotion ? timing.reducedMotionDuration : timing.motionDuration
        pendingMotionOperation = scheduler.schedule(after: duration) { [weak self] in
            guard let self else { return }
            self.pendingMotionOperation = nil
            self.interactionHitRegion = self.layout.hitRegion
            self.didChange?()
        }
    }

    private func cancelPendingHover() {
        pendingHoverOperation?.cancel()
        pendingHoverOperation = nil
    }

    private func activityDidChange() {
        updateActivityAvailability(activityModel.current != nil)
        guard state == .compact,
              activityModel.current?.activity.presentation.presentationRole
                == .completionAcknowledgement else {
            return
        }
        cancelPendingHover()
        stateMachine.send(.hoverBegan)
        beginHitRegionTransition(to: layout.hitRegion)
        didChange?()
    }

    private func updateActivityAvailability(_ hasActivity: Bool) {
        cancelPendingHover()
        let oldState = state
        stateMachine.updateActivityAvailability(hasActivity)
        if state != oldState {
            if !hasActivity {
                hoverRequiresExit = true
            }
            beginHitRegionTransition(to: layout.hitRegion)
            didChange?()
        }
    }

    public func update(displayGeometry: DisplayGeometry) {
        guard self.displayGeometry != displayGeometry else { return }
        self.displayGeometry = displayGeometry
        pendingMotionOperation?.cancel()
        pendingMotionOperation = nil
        interactionHitRegion = layout.hitRegion
        didChange?()
    }
}

public enum PanelMotionStyle: Equatable, Sendable {
    case standard
    case reduced
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
    public let reducedMotionDuration: Duration

    public init(
        hoverEntryDelay: Duration,
        hoverExitDelay: Duration,
        motionDuration: Duration,
        reducedMotionDuration: Duration
    ) {
        self.hoverEntryDelay = hoverEntryDelay
        self.hoverExitDelay = hoverExitDelay
        self.motionDuration = motionDuration
        self.reducedMotionDuration = reducedMotionDuration
    }

    public static let standard = PanelInteractionTiming(
        hoverEntryDelay: .milliseconds(80),
        hoverExitDelay: .milliseconds(140),
        motionDuration: .milliseconds(220),
        reducedMotionDuration: .milliseconds(120)
    )
}
