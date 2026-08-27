import CoreGraphics
import EryloCore
import EryloSurface

@MainActor
public protocol PanelPresenting: AnyObject {
    var displayIdentity: DisplayIdentity { get }

    func show()
    func hide()
    func close()
    func update(snapshot: DisplaySnapshot)
    func updatePointer(screenPoint: CGPoint)
    func performPrimaryAction()
    func performVisibilityToggle()
    func cancelPendingInteractions()
}

public extension PanelPresenting {
    /// Compatibility fallback for injected presenters that only implement the original action.
    /// The native presenter overrides this with a strict hidden/visible surface toggle.
    func performVisibilityToggle() {
        performPrimaryAction()
    }
}

public typealias PanelPresentationFactory = @MainActor (
    DisplaySnapshot
) -> any PanelPresenting

public typealias ActivityPanelPresentationFactory = @MainActor (
    DisplaySnapshot,
    SurfaceActivityModel
) -> any PanelPresenting
