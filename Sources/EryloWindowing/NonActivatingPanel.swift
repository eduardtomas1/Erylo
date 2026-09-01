import AppKit

public final class NonActivatingPanel: NSPanel {
    /// Compact and Peek remain passive. The native owner enables this only for
    /// deliberate Expanded interaction, so hover can never take keyboard focus.
    package var allowsKeyInteraction = false {
        didSet {
            guard !allowsKeyInteraction, isKeyWindow else { return }
            resignKey()
        }
    }

    package var escapeDismissalHandler: (@MainActor @Sendable () -> Void)?

    public override var canBecomeKey: Bool { allowsKeyInteraction }
    public override var canBecomeMain: Bool { false }

    public override func cancelOperation(_ sender: Any?) {
        guard allowsKeyInteraction, isKeyWindow, let escapeDismissalHandler else {
            super.cancelOperation(sender)
            return
        }
        escapeDismissalHandler()
    }
}
