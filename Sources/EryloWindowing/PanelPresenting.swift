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

/// Package-only feedback from native panels to the process coordinator. The
/// surface is demanded only while its window is shown and its state is not hidden.
@MainActor
package protocol PanelActivityVisibilityReporting: AnyObject {
    var isActivitySurfaceVisible: Bool { get }

    func setActivityVisibilityHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    )
}

/// Package-only state demand from a panel model to its native window owner.
/// A hidden model keeps its already-constructed tree ordered out and owns no
/// pointer monitors; a visible model asks the coordinator to prepare pointer
/// delivery before ordering the window in.
@MainActor
package protocol PanelPresentationDemandReporting: AnyObject {
    var wantsSurfacePresentation: Bool { get }

    func setPresentationDemandHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    )
}

@MainActor
package protocol PanelFocusTimerLaunching: AnyObject {
    func setFocusTimerStartHandler(
        _ handler: (@MainActor @Sendable (Int) -> Bool)?
    )
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
