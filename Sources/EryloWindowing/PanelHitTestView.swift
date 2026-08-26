import AppKit
import EryloCore

@MainActor
final class PanelHitTestView: NSView {
    var hitRegion: HitRegion = .empty

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitRegion.contains(point) else { return nil }
        return super.hitTest(point)
    }
}
