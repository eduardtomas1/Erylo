import CoreGraphics
import EryloCore
import Observation

@MainActor
@Observable
public final class PanelSurfaceModel {
    public private(set) var stateMachine: PanelStateMachine
    public private(set) var displayGeometry: DisplayGeometry
    public private(set) var interactionHitRegion: HitRegion
    public let metrics: PanelMetrics

    @ObservationIgnored
    public var didChange: (@MainActor @Sendable () -> Void)?

    @ObservationIgnored
    private let scheduler: any OneShotScheduling

    @ObservationIgnored
    private let timing: PanelInteractionTiming

    @ObservationIgnored
    private var pendingHoverOperation: (any ScheduledOperation)?

    @ObservationIgnored
    private var pendingMotionOperation: (any ScheduledOperation)?

    @ObservationIgnored
    private var isPointerInside = false

    @ObservationIgnored
    private var reduceMotion = false

    public var state: PanelPresentationState {
        stateMachine.state
    }

    public var layout: PanelLayout {
        PanelLayout(display: displayGeometry, state: state, metrics: metrics)
    }

    public init(
        displayGeometry: DisplayGeometry,
        initialState: PanelPresentationState = .compact,
        metrics: PanelMetrics = .feasibility,
        scheduler: any OneShotScheduling = TaskOneShotScheduler(),
        timing: PanelInteractionTiming = .standard
    ) {
        self.displayGeometry = displayGeometry
        self.metrics = metrics
        self.scheduler = scheduler
        self.timing = timing
        stateMachine = PanelStateMachine(initialState: initialState)
        interactionHitRegion = PanelLayout(
            display: displayGeometry,
            state: initialState,
            metrics: metrics
        ).hitRegion
    }

    public func send(_ event: PanelEvent) {
        if event != .hoverBegan, event != .hoverEnded {
            cancelPendingHover()
        }
        transition(event)
    }

    public func setPointerInside(_ isInside: Bool) {
        guard isPointerInside != isInside else { return }
        isPointerInside = isInside
        cancelPendingHover()

        let event: PanelEvent
        let delay: Duration
        switch (state, isInside) {
        case (.compact, true):
            event = .hoverBegan
            delay = timing.hoverEntryDelay
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

    public func pointerDisposition(at localPoint: CGPoint) -> PanelPointerDisposition {
        PanelPointerDisposition(
            acceptsMouseEvents: interactionHitRegion.contains(localPoint),
            isInsideTargetSurface: layout.hitRegion.contains(localPoint)
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

    public func update(displayGeometry: DisplayGeometry) {
        guard self.displayGeometry != displayGeometry else { return }
        self.displayGeometry = displayGeometry
        pendingMotionOperation?.cancel()
        pendingMotionOperation = nil
        interactionHitRegion = layout.hitRegion
        didChange?()
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
