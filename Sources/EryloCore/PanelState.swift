public enum PanelPresentationState: String, CaseIterable, Codable, Sendable {
    case hidden
    case compact
    case peek
    case expanded
    case dropTarget
}

public enum PanelEvent: Equatable, Sendable {
    case show
    case hide
    case hoverBegan
    case hoverEnded
    case primaryAction
    case dragEntered
    case dragExited
    case dropCompleted
    case dismiss
}

/// The deliberately small state reducer used by the feasibility surface.
public struct PanelStateMachine: Equatable, Sendable {
    public private(set) var state: PanelPresentationState

    public init(initialState: PanelPresentationState = .hidden) {
        state = initialState
    }

    @discardableResult
    public mutating func send(_ event: PanelEvent) -> PanelPresentationState {
        switch (state, event) {
        case (_, .hide):
            state = .hidden
        case (.hidden, .show):
            state = .compact
        case (.compact, .hoverBegan):
            state = .peek
        case (.peek, .hoverEnded):
            state = .compact
        case (.compact, .primaryAction), (.peek, .primaryAction):
            state = .expanded
        case (.expanded, .primaryAction), (.expanded, .dismiss):
            state = .compact
        case (.compact, .dragEntered), (.peek, .dragEntered), (.expanded, .dragEntered):
            state = .dropTarget
        case (.dropTarget, .dragExited), (.dropTarget, .dismiss):
            state = .compact
        case (.dropTarget, .dropCompleted):
            state = .expanded
        default:
            break
        }

        return state
    }
}
