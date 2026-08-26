import EryloCore
import Observation

@MainActor
@Observable
public final class PanelSurfaceModel {
    public private(set) var stateMachine: PanelStateMachine
    public private(set) var displayGeometry: DisplayGeometry
    public let metrics: PanelMetrics

    @ObservationIgnored
    public var didChange: (@MainActor @Sendable () -> Void)?

    public var state: PanelPresentationState {
        stateMachine.state
    }

    public var layout: PanelLayout {
        PanelLayout(display: displayGeometry, state: state, metrics: metrics)
    }

    public init(
        displayGeometry: DisplayGeometry,
        initialState: PanelPresentationState = .compact,
        metrics: PanelMetrics = .feasibility
    ) {
        self.displayGeometry = displayGeometry
        self.metrics = metrics
        stateMachine = PanelStateMachine(initialState: initialState)
    }

    public func send(_ event: PanelEvent) {
        let oldState = state
        stateMachine.send(event)
        if state != oldState {
            didChange?()
        }
    }

    public func update(displayGeometry: DisplayGeometry) {
        guard self.displayGeometry != displayGeometry else { return }
        self.displayGeometry = displayGeometry
        didChange?()
    }
}
