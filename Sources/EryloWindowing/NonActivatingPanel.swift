import AppKit

public final class NonActivatingPanel: NSPanel {
    /// The native owner enables this for Expanded content and for Compact/Peek
    /// states with real child controls. Only a deliberate route makes the panel
    /// key; automatic HUD arrival and hover never take keyboard focus.
    package var allowsKeyInteraction = false {
        didSet {
            guard !allowsKeyInteraction, isKeyWindow else { return }
            resignKey()
        }
    }

    package var escapeDismissalHandler: (@MainActor @Sendable () -> Bool)?

    public override var canBecomeKey: Bool { allowsKeyInteraction }
    public override var canBecomeMain: Bool { false }

    public override func cancelOperation(_ sender: Any?) {
        guard allowsKeyInteraction,
              isKeyWindow,
              let escapeDismissalHandler,
              escapeDismissalHandler() else {
            super.cancelOperation(sender)
            return
        }
    }
}
